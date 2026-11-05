// MyPayroll in the CMS · engines/minwage.js — minimum wage check on basic salary (Minimum Wages Order; CLC 5 Nov 2026). Warning only.
// Policy minimum_wage: { from: 'YYYY-MM-DD', monthly: 1700, hourly: 8.72, daily: { '4': 98.08, '5': 78.46, '6': 65.38 } }.
// Hourly RM8.72 = RM1,700 × 12 ÷ 52 ÷ 45 h. Basic only: allowances, overtime and claims do not count.
import { workClass } from './leave.js';

const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const money = (x) => Number(x).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/**
 * salary { amount, pay_basis }, employment { weekly_hours, job_status, hours_class, fte_weekly_hours }, policies (key → value), period 'YYYY-MM-DD'.
 * Returns null (fine / not applicable) or { level, code: 'below' | 'unknown', text, floor, rate }.
 */
export function minWageCheck(salary, employment, policies = {}, period = null) {
  const mw = policies.minimum_wage; const amt = Number(salary?.amount) || 0;
  if (!mw || !salary || !(amt > 0)) return null;
  if (period && mw.from && String(period).slice(0, 7) < String(mw.from).slice(0, 7)) return null;   // before the Order applied
  const hourly = Number(mw.hourly) || 0; const monthly = Number(mw.monthly) || 0;
  if (salary.pay_basis === 'hourly') {
    return hourly && amt + 1e-9 < hourly ? { level: 'warn', code: 'below', floor: hourly, rate: amt, text: `Below minimum wage: hourly rate RM${money(amt)} is under RM${money(hourly)} an hour.` } : null;
  }
  const cls = workClass(employment || {}, policies.part_time || {});
  if (cls === 'FT') return monthly && amt + 1e-9 < monthly ? { level: 'warn', code: 'below', floor: monthly, rate: amt, text: `Below minimum wage: basic RM${money(amt)} is under RM${money(monthly)} a month for full-time staff.` } : null;
  const wk = Number(employment?.weekly_hours) || 0;
  if (!wk) return { level: 'info', code: 'unknown', text: 'Minimum wage not checked: record this part-timer’s weekly hours (Time & Leave › Working hours).' };
  const monthHours = (wk * 52) / 12; const floor = r2(monthHours * hourly); const rate = r2(amt / monthHours);
  return hourly && rate + 1e-9 < hourly ? { level: 'warn', code: 'below', floor, rate,
    text: `Below minimum wage: basic RM${money(amt)} for ${wk} h a week is RM${money(rate)} an hour; the minimum is RM${money(hourly)} (at least RM${money(floor)} a month).` } : null;
}
