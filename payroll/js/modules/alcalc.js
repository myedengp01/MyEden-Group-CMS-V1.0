// AL calculator: period-by-period breakdown (replaces the AL CALCULATOR sheet), and the resignation calculator
// (notice period, last days, annual leave on leaving and notice in lieu — same engine as Record resignation on the profile).
import { h, clear, pageHead, field, fmtDate } from '../ui.js';
import { loadRef, fetchAll } from '../data.js';
import { loadPeople } from '../leave-data.js';
import { alPeriods, proRate, leaveRules, CLASS_LABEL } from '../engines/leave.js';
import { resignCalc, dayName } from '../engines/resign.js';
import { resignContext } from '../resign-data.js';
import { todayIso } from '../engines/employee.js';

const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const rm = (x) => `${Number(x) < 0 ? '−' : ''}RM ${Math.abs(Number(x) || 0).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dd = (iso) => (iso ? `${fmtDate(iso)} (${dayName(iso)})` : '—');

export async function render(el, ctx, params, query) {
  const ref = await loadRef(ctx.sb);
  const people = await loadPeople(ctx.sb, ref);
  const pt = ref.policies.part_time || {};
  const thisYear = Number(todayIso().slice(0, 4));
  const F = {
    emp: field('Employee (or leave blank and type dates)', { type: 'select', value: query.emp || '',
      options: [['', '— Enter dates by hand —'], ...people.filter((p) => p.employment?.join_date).map((p) => [p.id, `${p.full_name}${p.emp_id ? ` (${p.emp_id})` : ''}${p.status.key === 'former' ? ' · left' : ''}`])], span2: true }),
    join: field('Date joined', { type: 'date' }),
    resign: field('Last working day (if leaving)', { type: 'date' }),
    year: field('Leave year', { type: 'number', value: query.year || thisYear }),
    hours: field('Part-time weekly hours (blank = full-time)', { type: 'number', step: '0.5' }),
  };
  const out = h('div', {});
  el.append(pageHead('AL calculator', `Annual leave entitlement for joiners, current staff and leavers: 8 / 12 / 16 days by service band, split by calendar year and band, a month counts if service starts by the 15th or ends on or after the 15th, each period rounded half up. From the ${pt.from_year || 2027} leave year part time gets 6 / 8 / 11 days and casual none (Employment (Part-Time Employees) Regulations 2010).`),
    h('section', { class: 'panel' }, h('div', { class: 'panel-body' }, h('div', { class: 'form-grid' }, Object.values(F)))), out);

  const chosen = () => people.find((x) => String(x.id) === String(F.emp.getValue())) || null;
  const fill = () => {
    const p = chosen();
    if (p) { F.join.input.value = p.employment.join_date || ''; F.resign.input.value = p.employment.resigned_date || ''; F.hours.input.value = p.employment.job_status === 'PT' || p.employment.hours_class ? (p.employment.weekly_hours ?? '') : ''; }
  };
  F.emp.input.addEventListener('change', () => { fill(); calc(); resetResign(); });
  Object.values(F).slice(1).forEach((f) => f.input.addEventListener('input', calc));

  function calc() {
    const join = F.join.getValue(), resign = F.resign.getValue(), year = F.year.getValue();
    clear(out);
    if (!join || !year) { out.append(h('div', { class: 'empty-state' }, 'Choose an employee or enter the date joined.')); return; }
    const p = chosen(); const hrs = F.hours.getValue();
    const em = p ? { ...p.employment, weekly_hours: hrs ?? p.employment.weekly_hours } : { job_status: hrs ? 'PT' : 'FT', weekly_hours: hrs };
    const LR = leaveRules(em, year, ref.policies);
    const bands = LR.alBands;
    const periods = alPeriods({ joinDate: join, resignDate: resign, bands, toYear: year });
    const inYear = periods.filter((x) => Number(x.end.slice(0, 4)) === year);
    const total = inYear.reduce((s, x) => s + x.entitled, 0);
    const pro = LR.mode === 'hours' && hrs ? proRate(total, hrs, pt) : null;
    const bandName = (i) => ['First 2 years', '2nd to 5th year', '5 years and above'][i] || '';
    const bandIdx = (d) => Math.max(0, bands.findIndex((b) => b.days === d));
    const rule = LR.mode === 'pt' ? `Part time (${CLASS_LABEL.PT.toLowerCase()} rules from ${pt.from_year}): ${bands.map((b) => b.days).join(' / ')} days by service`
      : LR.mode === 'casual' ? 'Casual (30 % or less of a full-time week): no paid annual leave' : LR.mode === 'hours' ? 'Part time before the new rules: full-time days × weekly hours ÷ full-time hours' : 'Full time';
    out.append(
      h('div', { class: 'facts' }, h('div', { class: 'fact big' }, h('b', {}, pro ?? total), h('span', {}, `days annual leave for ${year}`)),
        pro !== null ? h('div', { class: 'fact' }, h('b', {}, total), h('span', {}, `full-time days × ${hrs} ÷ ${pt.full_time_weekly_hours || 45} hours`)) : null,
        h('div', { class: 'fact' }, h('b', {}, LR.cls === 'CASUAL' ? 'Casual' : LR.cls === 'PT' ? 'Part time' : 'Full time'), h('span', {}, rule))),
      h('section', { class: 'panel' }, h('div', { class: 'panel-head' }, h('h2', {}, 'How it is worked out')),
        h('div', { class: 'table-wrap' }, h('table', { class: 'data' },
          h('thead', {}, h('tr', {}, ['Service band', 'From', 'To', 'Months counted', 'Days a year', 'Exact', 'Rounded', ''].map((t, i) => h('th', { class: i >= 3 && i <= 6 ? 'num' : '' }, t)))),
          h('tbody', {}, periods.map((x) => {
            const counts = Number(x.end.slice(0, 4)) === year;
            return h('tr', { class: counts ? 'hit' : 'inactive' }, h('td', {}, bandName(bandIdx(x.days))), h('td', {}, fmtDate(x.start)), h('td', {}, fmtDate(x.end)),
              h('td', { class: 'num' }, x.months), h('td', { class: 'num' }, x.days), h('td', { class: 'num' }, x.raw.toFixed(2)), h('td', { class: 'num strong' }, x.entitled),
              h('td', { class: 'small muted' }, counts ? `counts for ${year}` : ''));
          })))),
        h('p', { class: 'small muted', style: 'padding:.8rem 1.2rem' }, 'A period that starts and ends in the same month counts as 1 month only if it starts on or before the 15th and ends on or after the 15th (AL CALCULATOR v.042026).')));
  }
  if (query.emp) fill();
  calc();

  // ---------------------------------------------------------------- resignation calculator
  const today = todayIso();
  const R = {
    letter: field('Resignation letter date', { type: 'date', value: today }),
    start: field('Notice starts (blank = the letter date)', { type: 'date' }),
    agreed: field('Agreed notice end (blank = the policy)', { type: 'date' }),
    last: field('Last physical working day (blank = the notice end)', { type: 'date' }),
    al: field('Annual leave balance', { type: 'select', value: 'payout', options: [['payout', 'Pay out in the final salary (basic ÷ 26 a day)'], ['offset', 'Use up before the employment end date (offset)'], ['none', 'Do not pay out']] }),
    payer: field('Notice not served', { type: 'select', value: 'employee', options: [['employee', 'Employee pays (deducted)'], ['company', 'Company pays'], ['waived', 'Waived']] }),
    basic: field('Basic salary (RM a month)', { type: 'number', step: '0.01', hint: 'Filled from the payroll record when an employee is chosen and you can see salaries.' }),
    taken: field('Annual leave taken this year (days)', { type: 'number', step: '0.5', hint: 'Only when typing dates by hand; for an employee it comes from the leave records.' }),
    prob: field('On probation at the letter date', { type: 'switch' }),
  };
  const res = h('div', {}); const acts = h('div', { class: 'btn-row', style: 'margin-top:.8rem' });
  el.append(h('section', { class: 'panel', style: 'margin-top:1.25rem' },
    h('div', { class: 'panel-head' }, h('h2', {}, 'Resignation')),
    h('div', { class: 'panel-body' },
      h('p', { class: 'small muted' }, 'Notice = letter date + 4 / 6 / 12 weeks by completed years of service (4 on probation). Annual leave on leaving is paid at the ordinary rate of pay (basic ÷ 26, Employment Act s.60I) or used up on the last working days (Monday–Saturday, public holidays skipped). Notice not served = basic ÷ the days of each month × the calendar days not served.'),
      h('div', { class: 'form-grid' }, Object.values(R)), res, acts)));

  let rctx = null; let rctxFor = ''; let seq = 0; let salHist = null; let mid = null;
  function resetResign() { rctx = null; rctxFor = ''; salHist = null; mid = null; R.basic.input.value = ''; runResign(); }
  async function personCtx(p, letter) {
    const key = `${p.id}|${letter.slice(0, 4)}`;
    if (rctx && rctxFor === key) return rctx;
    if (salHist === null) {
      try {
        const asg = await fetchAll(() => ctx.sb.from('eppd_assignments').select('id,is_primary').eq('employment_id', p.employment.id));
        const ids = asg.filter((a) => a.is_primary).map((a) => a.id);
        salHist = ids.length ? await fetchAll(() => ctx.sb.from('eppd_salary_history').select('effective_from,amount,pay_basis').in('assignment_id', ids).order('effective_from')) : [];
      } catch { salHist = []; }
      try { const { data } = await ctx.sb.from('eppd_employees').select('employee_master_id').eq('id', p.id).maybeSingle(); mid = data?.employee_master_id || null; } catch { mid = null; }
    }
    rctx = await resignContext(ctx.sb, { employment: p.employment, eppd_employee_id: p.id, salary: salHist, policies: ref.policies }, { letterDate: letter });
    rctxFor = key; return rctx;
  }
  async function runResign() {
    const n = ++seq; clear(res); clear(acts);
    const letter = R.letter.getValue(); const p = chosen(); const join = F.join.getValue();
    if (!letter || !join) { res.append(h('p', { class: 'small muted' }, 'Choose an employee (or enter the date joined) and the letter date.')); return; }
    const inp = { letterDate: letter, noticeStart: R.start.getValue(), noticeEnd: R.agreed.getValue(), lastPhysical: R.last.getValue(), alUse: R.al.getValue(), payer: R.payer.getValue() };
    let c;
    try {
      if (p) {
        const C = await personCtx(p, letter); if (n !== seq) return;
        const basic = R.basic.getValue();
        c = C.calc({ ...inp, ...(basic ? { salary: { amount: basic, pay_basis: 'monthly' } } : {}) });
        if (!R.basic.input.value && c.basic && !c.hourly) R.basic.input.value = String(c.basic);
      } else {
        const hrs = F.hours.getValue(); const em = { join_date: join, job_status: hrs ? 'PT' : 'FT', weekly_hours: hrs };
        const taken = Number(R.taken.getValue()) || 0;
        const alAt = (end) => { const y = Number(end.slice(0, 4)); const LR = leaveRules(em, y, ref.policies);
          const per = alPeriods({ joinDate: join, resignDate: end, bands: LR.alBands, toYear: y }).filter((x) => Number(x.end.slice(0, 4)) === y);
          let ent = per.reduce((s, x) => s + x.entitled, 0); if (LR.mode === 'hours' && hrs) ent = proRate(ent, hrs, pt) ?? ent;
          return { balance: r2(ent - taken), entitled: ent, carried: 0, taken, months: per.reduce((s, x) => s + x.months, 0), bandDays: per.length ? per[per.length - 1].days : null, asOf: today < end ? today : end, mode: LR.mode }; };
        const basic = R.basic.getValue();
        c = resignCalc({ ...inp, joinDate: join, confirmationStatus: R.prob.getValue() ? 'UP' : 'C', salary: basic ? { amount: basic, pay_basis: 'monthly' } : null, holidays: new Set(), alAt,
          workDays: ref.policies.settlement?.work_days || [1, 2, 3, 4, 5, 6], divisor: ref.policies.payroll?.daily_rate_divisor || 26 }, ref.policies.notice_period);
        c.salaryKnown = !!basic;
      }
    } catch (e) { res.append(h('p', { class: 'small bad' }, e.message)); return; }
    if (n !== seq) return;
    if (!c.ok && !c.noticeEnd) { res.append(h('p', { class: 'small bad' }, c.errors.join(' '))); return; }
    const A = c.al; const S = c.short; const amt = c.salaryKnown;
    const rows = [
      ['Service at the letter date', `${c.years} completed year(s)${c.onProbation ? ', on probation' : ''} → ${c.weeks} weeks' notice`],
      ['Notice', `${dd(c.noticeStart)} → ${dd(c.noticeEnd)}${c.noticeEnd !== c.noticeEndPolicy ? ` (agreed; policy ${fmtDate(c.noticeEndPolicy)})` : ''}`],
      ['Last physical working day', dd(c.lastPhysical)],
      c.offset?.days > 0 ? ['Annual leave used up', `${c.offset.days} day(s): ${fmtDate(c.offset.from)} – ${fmtDate(c.offset.to)}`] : null,
      ['Employment ends', dd(c.employmentEnd)],
      ['Annual leave balance at the end', A ? `${A.balance} day(s) (earned ${r2((A.entitled || 0) + (A.carried || 0))}, taken ${A.taken})` : 'not available'],
      c.payoutDays ? [c.payoutDays < 0 ? 'Annual leave taken in advance (deducted)' : 'Annual leave paid out', `${Math.abs(c.payoutDays)} day(s)${amt ? ` × RM ${c.orp.toFixed(2)} = ${rm(c.alAmount)}` : ''}`] : null,
      ['Notice not served', S.calendar ? `${S.calendar} calendar day(s), ${fmtDate(S.from)} – ${fmtDate(S.to)}${amt && !c.hourly ? ` · ${S.parts.map((x) => `${x.days} × RM ${x.rate.toFixed(2)} (basic ÷ ${x.of})`).join(' + ')}` : ''}${amt ? ` = ${rm(c.noticeAmount)} (${c.payer === 'employee' ? 'employee pays' : c.payer === 'company' ? 'company pays' : 'waived'})` : ''}` : 'None — served in full'],
      amt ? ['Net settlement', `${rm(c.net)} ${c.net < 0 ? 'deducted from' : 'added to'} the final salary`] : null,
      amt && c.lastMonthBasic != null ? ['Final month (estimate)', `basic ${rm(c.lastMonthBasic)} + settlement = ${rm(c.finalEst)} before EPF / SOCSO / EIS / PCB${c.owed ? ` · balance owed by the employee ${rm(c.owed)}` : ''}`] : null,
    ].filter(Boolean);
    res.append(h('table', { class: 'data', style: 'margin-top:1rem;max-width:900px' }, h('tbody', {}, rows.map(([k, v]) => h('tr', {}, h('th', { style: 'width:16rem;text-align:left' }, k), h('td', {}, v))))),
      ...(c.errors || []).map((x) => h('p', { class: 'small bad' }, x)), ...(c.notes || []).map((x) => h('p', { class: 'small muted' }, x)),
      !amt ? h('p', { class: 'small muted' }, 'Enter the basic salary to see the amounts.') : null,
      p && rctx && !rctx.hasHolidays ? h('p', { class: 'small muted' }, `No public holidays are entered for ${rctx.years.join(' / ')} (Settings › Holidays), so none are skipped.`) : null);
    if (p && mid && c.ok) {
      const q = new URLSearchParams({ id: mid, tab: 'employment', resign: '1', letter, start: R.start.getValue() || '', last: R.last.getValue() || '', al: R.al.getValue(), payer: R.payer.getValue() });
      acts.append(h('button', { class: 'btn primary sm', type: 'button', onclick: () => { location.hash = `#/person?${q}`; } }, 'Save to the person…'),
        h('span', { class: 'small muted' }, 'Opens Record resignation on their profile with these values; the reason for leaving is added there.'));
    }
  }
  Object.values(R).forEach((f) => { f.input.addEventListener('input', runResign); f.input.addEventListener('change', runResign); });
  [F.join, F.hours].forEach((f) => f.input.addEventListener('change', runResign));
  runResign();
}
