// MyEden Group CMS · engines/resign.js — resignation: notice period, last days, annual leave on leaving and notice in lieu.
// Pure functions (no DOM, no network), Node-testable. Rules agreed with HR (Oct 2026):
//  · notice = letter date (or another start date HR sets) + N weeks, N from the notice-period policy (4 / 6 / 12 weeks, 4 on probation)
//  · annual leave on leaving is paid at the ordinary rate of pay (Employment Act s.60I: monthly basic ÷ 26), or used up ("offset")
//    on the last working days of the notice — Monday to Saturday, public holidays skipped
//  · notice not served is worth the basic salary of those calendar days: basic ÷ the actual days of each month
import { isoToMs, msToIso, addDays } from './employee.js';
import { computeNotice } from './notice.js';

const DAY = 86400000;
const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
export const dayName = (iso) => (iso ? DAYS[new Date(isoToMs(iso)).getUTCDay()] : '');
export const longDate = (iso) => { if (!iso) return ''; const [y, m, d] = String(iso).slice(0, 10).split('-').map(Number); return `${d} ${MONTHS[m - 1]} ${y}`; };
export const daysInMonth = (iso) => { const [y, m] = String(iso).slice(0, 10).split('-').map(Number); return new Date(Date.UTC(y, m, 0)).getUTCDate(); };
export const calDays = (from, to) => (from && to && to >= from ? Math.round((isoToMs(to) - isoToMs(from)) / DAY) + 1 : 0);
const rm = (x) => `RM ${Number(r2(x)).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const num = (x) => String(r2(x));

/** Working day for the offset and the notice count: Monday–Saturday by default, not a public holiday. */
export function isWorkDay(iso, holidays = new Set(), workDays = [1, 2, 3, 4, 5, 6]) {
  return workDays.includes(new Date(isoToMs(iso)).getUTCDay()) && !holidays.has(iso);
}
export function workDaysBetween(from, to, holidays, workDays) {
  let n = 0; if (!from || !to || to < from) return 0;
  for (let t = isoToMs(from); t <= isoToMs(to); t += DAY) if (isWorkDay(msToIso(t), holidays, workDays)) n += 1;
  return n;
}

/** Notice from the policy, counted from noticeStart (default: the letter date). */
export const DEFAULT_NOTICE = { probation_weeks: 4, bands: [{ from_years: 0, to_years: 2, weeks: 4 }, { from_years: 2, to_years: 5, weeks: 6 }, { from_years: 5, to_years: null, weeks: 12 }] };
export function noticeOf({ joinDate, letterDate, noticeStart, confirmationStatus, confirmedDate }, policy = DEFAULT_NOTICE) {
  policy = policy || DEFAULT_NOTICE;
  if (!joinDate || !letterDate) return null;
  const onProbation = confirmationStatus === 'UP' || (!!confirmedDate && confirmedDate > letterDate);
  const n = computeNotice({ joinDate, letterDate, onProbation }, policy);
  if (!n) return null;
  const start = noticeStart || letterDate;
  return { ...n, onProbation, start, end: addDays(start, n.days) };
}

/**
 * Leave used up after the last physical day: the next `days` working days, never past the notice end.
 * Returns { days (used), available, from, to } — a half day counts on the last working day.
 */
export function offsetWindow(lastPhysical, noticeEnd, days, holidays, workDays) {
  const available = workDaysBetween(addDays(lastPhysical, 1), noticeEnd, holidays, workDays);
  const want = Math.max(0, Math.min(Number(days) || 0, available));
  if (!(want > 0)) return { days: 0, available, from: null, to: null };
  let left = want; let from = null; let to = null;
  for (let t = isoToMs(addDays(lastPhysical, 1)); t <= isoToMs(noticeEnd) && left > 0; t += DAY) {
    const iso = msToIso(t); if (!isWorkDay(iso, holidays, workDays)) continue;
    if (!from) from = iso; to = iso; left = r2(left - 1);
  }
  return { days: want, available, from, to };
}

/** Basic salary of the calendar days from–to: basic ÷ the actual days of each month, month by month. */
export function calendarPay(from, to, monthlyBasic) {
  const parts = []; if (!from || !to || to < from) return { days: 0, amount: 0, parts };
  let cur = from;
  while (cur <= to) {
    const ym = cur.slice(0, 7); const dim = daysInMonth(cur);
    const monthEnd = `${ym}-${String(dim).padStart(2, '0')}`; const end = monthEnd < to ? monthEnd : to;
    const d = calDays(cur, end); const rate = Number(monthlyBasic) / dim;
    parts.push({ month: ym, days: d, of: dim, rate: r2(rate), amount: r2(d * rate) });
    cur = addDays(end, 1);
  }
  return { days: parts.reduce((s, p) => s + p.days, 0), amount: r2(parts.reduce((s, p) => s + p.amount, 0)), parts };
}

/**
 * The whole calculation.
 * input: { joinDate, letterDate, noticeStart?, noticeEnd? (agreed), confirmationStatus, confirmedDate, lastPhysical?, alUse: 'offset'|'payout'|'none',
 *          payer: 'employee'|'company'|'waived', salary: { amount, pay_basis }, normalHours, holidays:Set, workDays?, divisor?,
 *          alAt(endIso) → { balance, entitled, carried, taken, months, bandDays, asOf } | null }
 */
export function resignCalc(input, policy) {
  const out = { ok: false, errors: [], notes: [] };
  const N = noticeOf(input, policy);
  if (!N) { out.errors.push(!input.joinDate ? 'No date joined on record.' : 'Enter the resignation letter date.'); return out; }
  if (input.letterDate < input.joinDate) out.errors.push('The letter date is before the date joined.');
  const H = input.holidays || new Set(); const WD = input.workDays || [1, 2, 3, 4, 5, 6];
  const noticeEnd = input.noticeEnd || N.end;
  const alUse0 = input.alUse || 'payout';
  // offset with no earlier last day chosen: the leave fills the last working days of the notice, counted back from its end
  let back = null;
  if (alUse0 === 'offset' && !input.lastPhysical && input.alAt) {
    const A0 = input.alAt(noticeEnd); const want = Math.max(0, Math.floor((A0?.balance || 0) * 2) / 2);
    const avail = workDaysBetween(addDays(input.letterDate, 1), noticeEnd, input.holidays || new Set(), input.workDays || [1, 2, 3, 4, 5, 6]);
    const take = Math.min(want, Math.max(0, avail - 1));
    if (take > 0) {
      let left = Math.ceil(take); let from = null; const to = (() => { for (let t = isoToMs(noticeEnd); ; t -= DAY) { const iso = msToIso(t); if (isWorkDay(iso, input.holidays, input.workDays)) return iso; } })();
      for (let t = isoToMs(noticeEnd); left > 0; t -= DAY) { const iso = msToIso(t); if (isWorkDay(iso, input.holidays, input.workDays)) { from = iso; left -= 1; } }
      let lp = addDays(from, -1); while (!isWorkDay(lp, input.holidays, input.workDays)) lp = addDays(lp, -1);
      back = { last: lp, window: { days: take, available: avail - 1, from, to } };
    }
  }
  const last = input.lastPhysical || back?.last || noticeEnd;
  if (last > noticeEnd) out.errors.push('The last physical working day is after the end of the notice. Change the agreed notice end instead.');
  if (last < input.letterDate) out.errors.push('The last physical working day is before the letter date.');
  const alUse = input.alUse || 'payout'; const payer = input.payer || 'employee';
  const sal = input.salary || null; const basic = Number(sal?.amount) || 0; const hourly = sal?.pay_basis === 'hourly';
  const orp = hourly ? r2(basic * (Number(input.normalHours) || 8)) : basic / (Number(input.divisor) || 26);

  // annual leave: the balance on the day employment ends; with offset, the end moves to the last leave day (worked out again until it settles)
  let end = last; let A = input.alAt ? input.alAt(end) : null; let W = { days: 0, available: workDaysBetween(addDays(last, 1), noticeEnd, H, WD), from: null, to: null };
  if (back) { end = noticeEnd; A = input.alAt(end); W = back.window; }
  else if (alUse === 'offset' && A) {
    for (let i = 0; i < 5; i += 1) {
      W = offsetWindow(last, noticeEnd, Math.max(0, A.balance), H, WD);
      const e2 = W.days > 0 ? W.to : last;
      if (e2 === end) break;
      end = e2; A = input.alAt(end);
    }
    // the whole notice is covered by leave: employment runs to the notice end
    if (W.days > 0 && W.days >= W.available) end = noticeEnd;
  }
  if (alUse !== 'offset' && last === noticeEnd) end = noticeEnd;
  const bal = A ? r2(A.balance) : null;
  const payoutDays = bal === null ? null : alUse === 'offset' ? r2(bal - W.days) : alUse === 'payout' ? bal : Math.min(0, bal);
  const alAmount = payoutDays === null ? 0 : r2(payoutDays * orp);
  if (alUse === 'offset' && bal !== null && bal > W.days && W.available <= W.days) out.notes.push(`Only ${W.available} working day(s) are left in the notice, so ${num(bal - W.days)} day(s) of leave are paid out instead.`);
  if (bal !== null && bal < 0) out.notes.push(`More leave was taken than earned: ${num(-bal)} day(s) are deducted at the daily rate.`);

  // notice not served: the calendar days after employment ends, to the notice end
  const shortFrom = end < noticeEnd ? addDays(end, 1) : null;
  const P = shortFrom ? (hourly ? null : calendarPay(shortFrom, noticeEnd, basic)) : { days: 0, amount: 0, parts: [] };
  const shortCal = shortFrom ? calDays(shortFrom, noticeEnd) : 0;
  const shortWork = shortFrom ? workDaysBetween(shortFrom, noticeEnd, H, WD) : 0;
  const noticeAmount = !shortFrom ? 0 : hourly ? r2(shortWork * orp) : P.amount;
  const noticeSigned = payer === 'employee' ? -noticeAmount : payer === 'company' ? noticeAmount : 0;
  if (shortFrom && payer === 'waived') out.notes.push('Notice not served is waived: nothing is paid or deducted for it (approver recorded).');
  const net = r2(alAmount + noticeSigned);

  // a rough last-month figure: basic for the calendar days worked in the month employment ends, plus the settlement
  const monthStart = `${end.slice(0, 7)}-01`; const first = input.joinDate > monthStart ? input.joinDate : monthStart;
  const lastMonthBasic = hourly ? null : r2(basic * calDays(first, end) / daysInMonth(end));
  const finalEst = lastMonthBasic === null ? null : r2(lastMonthBasic + net);
  if (!isWorkDay(noticeEnd, H, WD)) out.notes.push(`The notice ends on a ${dayName(noticeEnd)}${H.has(noticeEnd) ? ' (public holiday)' : ''}; it stays the official end date.`);
  if (!isWorkDay(last, H, WD)) out.notes.push(`The last physical working day is a ${dayName(last)}${H.has(last) ? ' (public holiday)' : ''}.`);

  Object.assign(out, {
    ok: !out.errors.length, years: N.years, weeks: N.weeks, basis: N.basis, onProbation: N.onProbation, noticeStart: N.start, noticeEndPolicy: N.end, noticeEnd,
    lastPhysical: last, employmentEnd: end, alUse, payer, orp: r2(orp), hourly, basic,
    al: A ? { ...A, balance: bal } : null, offset: W, payoutDays, alAmount,
    short: { from: shortFrom, to: shortFrom ? noticeEnd : null, calendar: shortCal, working: shortWork, parts: P ? P.parts : [] }, noticeAmount, noticeSigned, net, lastMonthBasic, finalEst,
    owed: finalEst !== null && finalEst < 0 ? r2(-finalEst) : 0,
    arrangement: alUse === 'offset' && W.days > 0 ? (end < noticeEnd ? 'in_lieu' : 'offset') : (end < noticeEnd ? 'in_lieu' : 'full'),
  });
  out.fields = letterFields(out, input);
  return out;
}

/** Values for the resignation letter placeholders. */
export function letterFields(c, input) {
  const A = c.al || {};
  return {
    resignation_date: longDate(input.letterDate), notice_period: `${c.weeks} weeks`, notice_weeks: String(c.weeks), notice_start_date: longDate(c.noticeStart),
    last_notice_date: longDate(c.noticeEnd), lastnotice_day: dayName(c.noticeEnd),
    last_working_day: longDate(c.lastPhysical), lastday_day: dayName(c.lastPhysical),
    employment_end_date: longDate(c.employmentEnd), employment_end_day: dayName(c.employmentEnd),
    start_datetime: longDate(input.joinDate),
    months_worked: A.months != null ? String(A.months) : '', leave_entitlement: A.bandDays != null ? String(A.bandDays) : '',
    calculated_leaves: A.entitled != null ? num((A.entitled || 0) + (A.carried || 0)) : '', al_taken: A.taken != null ? num(A.taken) : '',
    al_asofdate: longDate(A.asOf), al_balance: c.al ? num(c.al.balance) : '',
    al_offset_period: c.offset?.days > 0 ? (c.offset.from === c.offset.to ? longDate(c.offset.from) : `${longDate(c.offset.from)} to ${longDate(c.offset.to)}`) : 'Not applicable',
    al_offset_days: c.offset?.days > 0 ? num(c.offset.days) : '0',
    al_payout_days: c.payoutDays != null ? num(c.payoutDays) : '', al_payout_amount: rm(c.alAmount), daily_rate: rm(c.orp),
    short_notice_days: String(c.short.calendar || 0), notice_in_lieu_amount: rm(c.noticeAmount),
    net_settlement: `${c.net < 0 ? '−' : ''}${rm(Math.abs(c.net))}`,
    notice_in_lieu_terms: noticeTerms(c),
  };
}
/** The sentence on the notice not served, for the letter. */
export function noticeTerms(c) {
  const d = c.short.calendar || 0;
  if (!d) return 'You will serve your notice period in full. No payment in lieu of notice is due from either party.';
  const basis = c.hourly ? `your ordinary rate of pay for the ${c.short.working} working day(s) not served` : `your basic salary for the ${d} calendar day(s) not served (monthly basic salary ÷ the number of days in the month)`;
  if (c.payer === 'company') return `As the Company has asked you to leave before the end of your notice period, the Company will pay you, in lieu of the notice not served, ${basis}, amounting to ${rm(c.noticeAmount)}, in your final salary (Section 13(1), Employment Act 1955).`;
  if (c.payer === 'waived') return `The Company waives the ${d} calendar day(s) of notice not served. No payment in lieu of notice is due from either party.`;
  return `As you will leave before the end of your notice period, the notice not served is settled by an indemnity equal to ${basis}, amounting to ${rm(c.noticeAmount)}, in accordance with Section 13(1) of the Employment Act 1955. This amount will be deducted from your final salary.`;
}
/** What is kept with the resignation record (and used for the final settlement). */
export function calcSnapshot(c) {
  return { weeks: c.weeks, basis: c.basis, on_probation: c.onProbation, notice_end_policy: c.noticeEndPolicy, orp: c.orp, hourly: c.hourly, basic: c.basic,
    al_balance: c.al ? c.al.balance : null, al_asof: c.al?.asOf || null, al_entitled: c.al ? c.al.entitled : null, al_taken: c.al ? c.al.taken : null,
    offset_days: c.offset?.days || 0, offset_from: c.offset?.from || null, offset_to: c.offset?.to || null, payout_days: c.payoutDays, al_amount: c.alAmount,
    short_days: c.short.calendar || 0, short_working: c.short.working || 0, short_from: c.short.from, notice_amount: c.noticeAmount, net: c.net,
    last_month_basic: c.lastMonthBasic, final_estimate: c.finalEst, owed: c.owed, arrangement: c.arrangement };
}
