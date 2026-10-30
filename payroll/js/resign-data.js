// MyEden Group CMS · resign-data.js — gathers what the resignation calculator needs (leave balances, holidays, salary) for one person,
// then works it out with engines/resign.js. R = the result of the cms_resignation_get RPC.
import { loadLeaveYear, balancesFor, loadHolidaySet } from './leave-data.js';
import { resignCalc, calcSnapshot } from './engines/resign.js';
import { salaryAsOf, todayIso } from './engines/employee.js';
import { ratesOfPay } from './engines/payroll.js';

/** Loads the leave years and holidays once; returns calc(inputs) → the calculation. */
export async function resignContext(sb, R, { letterDate } = {}) {
  const emp = R.employment || {};
  const y0 = Number(String(letterDate || R.record?.letter_date || todayIso()).slice(0, 4));
  const years = [y0, y0 + 1];
  const [D0, D1, holidays] = await Promise.all([
    loadLeaveYear(sb, years[0]).catch(() => null), loadLeaveYear(sb, years[1]).catch(() => null), loadHolidaySet(sb, years).catch(() => new Set())]);
  const Ds = new Map([[years[0], D0], [years[1], D1]]);
  const today = todayIso();
  const alAt = (end) => {
    const D = Ds.get(Number(end.slice(0, 4))); if (!D) return null;
    const person = D.people.find((p) => p.id === R.eppd_employee_id); if (!person) return null;
    const b = balancesFor({ ...person, employment: { ...(person.employment || {}), ...emp, resigned_date: end } }, D, end);
    const inYear = (b.AL.periods || []).filter((p) => p.end.slice(0, 4) === end.slice(0, 4));
    return { balance: b.AL.balance, entitled: b.AL.entitled, carried: b.AL.carried || 0, taken: b.AL.taken, months: inYear.reduce((s, p) => s + p.months, 0),
      bandDays: inYear.length ? inYear[inYear.length - 1].days : null, asOf: today < end ? today : end, cls: b.AL.cls, mode: b.AL.mode };
  };
  const pol = R.policies || {};
  const workDays = pol.settlement?.work_days || [1, 2, 3, 4, 5, 6];
  return {
    holidays, years, hasHolidays: holidays.size > 0,
    calc(inp) {
      const end = inp.lastPhysical || inp.letterDate || today;
      const sal = R.salary ? salaryAsOf(R.salary, end) || salaryAsOf(R.salary, today) || R.salary[R.salary.length - 1] || null : null;
      const rates = ratesOfPay(sal, emp, pol.payroll || undefined);
      const c = resignCalc({ joinDate: emp.join_date, confirmationStatus: emp.confirmation_status, confirmedDate: emp.confirmed_date, salary: sal, normalHours: rates.normal,
        holidays, workDays, divisor: pol.payroll?.daily_rate_divisor || 26, alAt, ...inp }, pol.notice_period);
      c.salaryKnown = !!(inp.salary || sal); c.snapshot = c.ok ? calcSnapshot(c) : null;
      return c;
    },
  };
}
