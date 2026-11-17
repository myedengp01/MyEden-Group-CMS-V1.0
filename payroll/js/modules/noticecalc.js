// Notice period calculator (v2026.11.17) — HR / Admin. Pick an employee (join date, probation, contract notice, a recorded resignation
// and the salary are filled in) or type the dates. The notice under the Employment Act s.12 (4 / 6 / 8 weeks), the company policy /
// Employee Handbook (4 / 6 / 12 weeks, 4 on probation — the default), the contract, or any number typed. The end date is worked out
// the same way as the resignation letters (start + weeks × 7). Optional: notice in lieu for an earlier last day (basic ÷ the calendar
// days of each month). On screen only; nothing is saved.
import { h, clear, pageHead, toast, failed, fmtDate } from '../ui.js';
import { loadHolidaySet } from '../leave-data.js';
import { completedYears } from '../engines/notice.js';
import { addDays, todayIso, isoToMs } from '../engines/employee.js';
import { dayName, calDays, workDaysBetween, calendarPay, DEFAULT_NOTICE } from '../engines/resign.js';

const rm = (x) => `RM${Number(x || 0).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const ISO = /^\d{4}-\d{2}-\d{2}$/;

/** Employment Act s.12(2): under 2 years 4 weeks, 2 to under 5 years 6 weeks, 5 years and over 8 weeks. */
export const eaWeeks = (years) => (years < 2 ? 4 : years < 5 ? 6 : 8);
/** Company policy / Employee Handbook bands; probation has its own notice. */
export function policyWeeks(years, onProbation, policy = DEFAULT_NOTICE) {
  if (onProbation) return Number(policy.probation_weeks ?? 4);
  const b = (policy.bands || []).find((x) => years >= Number(x.from_years) && (x.to_years == null || years < Number(x.to_years)));
  return b ? Number(b.weeks) : null;
}
/** Length of service as nY nM nD, the start day counted as day 1. */
export function svcYMD(start, end) {
  if (!ISO.test(start || '') || !ISO.test(end || '') || end < start) return '';
  const [sy, sm, sd] = start.split('-').map(Number); const e = isoToMs(end) + 864e5;
  let k = (new Date(e).getUTCFullYear() - sy) * 12 + new Date(e).getUTCMonth() - (sm - 1);
  while (k > 0 && Date.UTC(sy, sm - 1 + k, sd) > e) k -= 1;
  return `${Math.floor(k / 12)}Y ${k % 12}M ${Math.round((e - Date.UTC(sy, sm - 1 + k, sd)) / 864e5)}D`;
}
/** The whole calculation, from plain inputs. */
export function noticeCalc({ join, start, probation, rule, customValue, customUnit, contract, policy, lastDay, holidays, basic }) {
  if (!ISO.test(join || '') || !ISO.test(start || '')) return { ok: false, error: 'Enter the join date and the notice start date.' };
  if (start < join) return { ok: false, error: 'The notice starts before the join date.' };
  const years = completedYears(join, start);
  const rules = {
    policy: { label: 'Company policy / Employee Handbook', days: (policyWeeks(years, probation, policy) ?? 0) * 7, text: `${policyWeeks(years, probation, policy)} weeks${probation ? ' (on probation)' : ''}` },
    ea: { label: 'Employment Act s.12 (minimum)', days: eaWeeks(years) * 7, text: `${eaWeeks(years)} weeks` },
  };
  if (contract && Number(contract.value) > 0) { const d = Number(contract.value) * (/day/i.test(contract.unit || '') ? 1 : /month/i.test(contract.unit || '') ? 30 : 7);
    rules.contract = { label: 'Employment contract', days: d, text: `${Number(contract.value)} ${contract.unit || 'weeks'}` }; }
  const cv = Number(customValue);
  if (cv > 0) rules.custom = { label: 'Custom', days: cv * (customUnit === 'days' ? 1 : 7), text: `${cv} ${customUnit === 'days' ? 'days' : 'weeks'}` };
  const use = rules[rule] ? rule : 'policy';
  const R = rules[use];
  const end = addDays(start, R.days);
  const H = holidays || new Set();
  const out = { ok: true, years, service: svcYMD(join, start), rules, use, chosen: R, end, endDay: dayName(end), endOff: [0, 6].includes(new Date(isoToMs(end)).getUTCDay()) || H.has(end),
    endHoliday: H.has(end), calendar: calDays(addDays(start, 1), end), working: workDaysBetween(addDays(start, 1), end, H, [1, 2, 3, 4, 5]),
    belowEA: R.days < rules.ea.days };
  if (ISO.test(lastDay || '')) {
    out.last = lastDay;
    if (lastDay < end) {
      const from = addDays(lastDay, 1);
      out.short = { from, to: end, calendar: calDays(from, end), working: workDaysBetween(from, end, H, [1, 2, 3, 4, 5]) };
      if (Number(basic) > 0) out.short.pay = calendarPay(from, end, Number(basic));
    } else if (lastDay > end) out.beyond = calDays(addDays(end, 1), lastDay);
  }
  return out;
}

export async function render(el, ctx, params, query) {
  const { data: list, error } = await ctx.sb.from('eppd_employee_list').select('id,emp_id,full_name,resigned_date').order('full_name');
  if (error) { el.append(h('div', { class: 'empty-state' }, error.message)); return; }
  const today = todayIso();
  const people = (list || []).filter((p) => !p.resigned_date || p.resigned_date >= addDays(today, -365));
  let holidays = new Set(); let hy = '';
  const st = { emp: '', join: '', start: today, probation: false, rule: 'policy', customValue: '', customUnit: 'weeks', contract: null, policy: DEFAULT_NOTICE,
    lastDay: '', inLieu: false, basic: '', salaryFromCMS: false, note: '' };
  try { const { data } = await ctx.sb.from('eppd_policies').select('value').eq('key', 'notice_period').maybeSingle(); if (data?.value) st.policy = data.value; } catch (e) { /* default policy */ }

  el.append(pageHead('Notice Period Calculator', 'The notice for a resignation or termination: company policy (the default), the Employment Act minimum, the contract, or your own figure. Pick an employee or just type the dates. Nothing is saved.'));
  const form = h('section', { class: 'panel', style: 'padding:1rem' });
  const out = h('section', { class: 'panel nc-out' });
  el.append(form, out);

  const inp = (type, val, on, attrs = {}) => { const i = h('input', { type, ...attrs }); i.value = val ?? ''; i.addEventListener('change', () => on(i.value)); return i; };

  async function pickEmp(id) {
    st.emp = id; st.contract = null; st.note = ''; st.salaryFromCMS = false; st.rule = 'policy'; st.lastDay = '';
    if (!id) { drawForm(); draw(); return; }
    const { data, error: e } = await ctx.sb.rpc('cms_notice_context', { p_employee: Number(id) });
    if (failed(e)) return;
    st.join = data.join_date || ''; st.contract = data.contract_notice || null; if (data.policy) st.policy = data.policy;
    const res = data.resignation;
    st.start = res?.notice_start || res?.letter_date || today;
    st.probation = data.confirmation_status === 'UP' || (!!data.confirmed_date && data.confirmed_date > st.start);
    st.basic = data.salary?.pay_basis === 'monthly' ? String(data.salary.amount) : ''; st.salaryFromCMS = !!st.basic;
    st.note = res ? `Resignation recorded: letter ${fmtDate(res.letter_date)}, notice to ${fmtDate(res.notice_end)}.` : '';
    drawForm(); draw();
  }

  function drawForm() {
    clear(form);
    form.append(h('div', { class: 'form-grid' },
      h('label', { class: 'field span-2' }, 'Employee (optional)', (() => { const s = h('select', {}, h('option', { value: '' }, 'No employee — type the dates'),
        people.map((p) => h('option', { value: p.id, selected: String(p.id) === String(st.emp) }, `${p.full_name}${p.emp_id ? ` (${p.emp_id})` : ''}${p.resigned_date ? ` — last day ${fmtDate(p.resigned_date)}` : ''}`)));
        s.addEventListener('change', () => pickEmp(s.value)); return s; })(),
        st.note ? h('small', { class: 'muted' }, st.note) : null),
      h('label', { class: 'field' }, 'Date joined', inp('date', st.join, (v) => { st.join = v; draw(); })),
      h('label', { class: 'field' }, 'Notice starts (letter date)', inp('date', st.start, (v) => { st.start = v; draw(); })),
      h('div', { class: 'field' }, h('span', {}, 'Status'), h('label', { class: 'check-row', style: 'min-height:2.5rem' }, (() => { const c = h('input', { type: 'checkbox' }); c.checked = st.probation; c.addEventListener('change', () => { st.probation = c.checked; draw(); }); return c; })(), 'On probation (4 weeks by company policy)')),
      h('label', { class: 'field' }, 'Last day (optional)', inp('date', st.lastDay, (v) => { st.lastDay = v; draw(); }),
        h('small', { class: 'muted' }, 'To check an agreed or requested last day against the notice.'))));
  }

  // redraws are queued: a field losing focus while the result is being rebuilt must not rebuild it twice
  let qd = null; const draw = () => { clearTimeout(qd); qd = setTimeout(drawNow, 0); };
  async function drawNow() {
    clear(out);
    const ys = [st.start, st.lastDay].filter((x) => ISO.test(x || '')).map((x) => Number(x.slice(0, 4)));
    const want = ys.length ? [...new Set([...ys, ys[0] + 1])].sort().join(',') : '';
    if (want && want !== hy) { hy = want; try { holidays = await loadHolidaySet(ctx.sb, want.split(',').map(Number)); } catch (e) { holidays = new Set(); } }
    const c = noticeCalc({ join: st.join, start: st.start, probation: st.probation, rule: st.rule, customValue: st.customValue, customUnit: st.customUnit,
      contract: st.contract, policy: st.policy, lastDay: st.lastDay, holidays, basic: st.inLieu ? st.basic : '' });
    if (!c.ok) { out.append(h('div', { class: 'empty-state' }, c.error)); return; }

    const ruleRow = (key, r) => { const radio = h('input', { type: 'radio', name: 'nc-rule', value: key }); radio.checked = c.use === key;
      radio.addEventListener('change', () => { st.rule = key; draw(); });
      return h('label', { class: `nc-rule ${c.use === key ? 'on' : ''}` }, radio, h('span', {}, h('b', {}, r.label), key === 'policy' ? h('small', { class: 'muted' }, ' default') : null),
        h('span', { class: 'nc-w' }, r.text), h('span', { class: 'muted small' }, `ends ${fmtDate(addDays(st.start, r.days))}`)); };
    const cv = inp('number', st.customValue, (v) => { st.customValue = v; if (Number(v) > 0) st.rule = 'custom'; draw(); }, { min: 1, step: 1, style: 'width:5rem', placeholder: 'e.g. 12' });
    const cu = h('select', { style: 'width:auto' }, [['weeks', 'weeks'], ['days', 'days']].map(([k, l]) => h('option', { value: k, selected: k === st.customUnit }, l)));
    cu.addEventListener('change', () => { st.customUnit = cu.value; draw(); });

    out.append(h('div', { style: 'padding:1rem;display:grid;gap:1rem' },
      h('div', { class: 'nc-head' },
        h('div', {}, h('small', { class: 'muted' }, 'Service at the notice date'), h('b', { class: 'nc-big' }, c.service), h('small', { class: 'muted' }, `${c.years} completed year${c.years === 1 ? '' : 's'}`)),
        h('div', {}, h('small', { class: 'muted' }, `Notice · ${c.chosen.label}`), h('b', { class: 'nc-big' }, c.chosen.text), h('small', { class: 'muted' }, `${c.calendar} calendar days · ${c.working} working days`)),
        h('div', {}, h('small', { class: 'muted' }, 'Notice ends / last day'), h('b', { class: 'nc-big' }, fmtDate(c.end)), h('small', { class: c.endOff ? 'warn-txt' : 'muted' }, `${c.endDay}${c.endHoliday ? ' · public holiday' : c.endOff ? ' · not a working day' : ''}`))),
      c.belowEA ? h('p', { class: 'note warn small' }, `The chosen notice (${c.chosen.text}) is shorter than the Employment Act minimum (${c.rules.ea.text}) for ${c.years} completed year(s) of service. Check the contract before using it.`) : null,
      h('div', {}, h('h3', { style: 'margin:0 0 .4rem' }, 'Notice by each rule'),
        h('div', { class: 'nc-rules' }, Object.entries(c.rules).filter(([k]) => k !== 'custom').map(([k, r]) => ruleRow(k, r)),
          h('label', { class: `nc-rule ${c.use === 'custom' ? 'on' : ''}` }, (() => { const r = h('input', { type: 'radio', name: 'nc-rule', value: 'custom', disabled: !(Number(st.customValue) > 0) }); r.checked = c.use === 'custom';
            r.addEventListener('change', () => { st.rule = 'custom'; draw(); }); return r; })(), h('span', {}, h('b', {}, 'Custom')), h('span', { class: 'nc-w' }, cv, ' ', cu),
            h('span', { class: 'muted small' }, c.rules.custom ? `ends ${fmtDate(addDays(st.start, c.rules.custom.days))}` : 'type a number')),
          !c.rules.contract ? h('p', { class: 'muted small', style: 'margin:.2rem 0 0' }, st.emp ? 'No notice period recorded in this person\'s contract.' : 'Pick an employee to include the contract notice.') : null),
        h('p', { class: 'muted small', style: 'margin:.5rem 0 0' }, 'Company policy: 4 weeks under 2 years, 6 weeks 2 to under 5 years, 12 weeks 5 years and over, 4 weeks on probation. Employment Act s.12: 4 / 6 / 8 weeks. The end date is the start date + the weeks × 7, as in the resignation letters.')),
      st.lastDay ? lastBlock(c) : null));
  }

  function lastBlock(c) {
    const box = h('div', { class: 'nc-last' }, h('h3', { style: 'margin:0 0 .4rem' }, `Last day ${fmtDate(c.last)} (${dayName(c.last)})`));
    if (c.beyond) { box.append(h('p', {}, `${c.beyond} calendar day(s) after the notice ends — a longer period than the notice; it needs both sides to agree.`)); return box; }
    if (!c.short) { box.append(h('p', {}, 'The same day the notice ends: the notice is served in full.')); return box; }
    box.append(h('p', {}, `${c.short.calendar} calendar day(s) (${c.short.working} working day(s)) of notice not served: ${fmtDate(c.short.from)} – ${fmtDate(c.short.to)}.`));
    const tick = h('input', { type: 'checkbox' }); tick.checked = st.inLieu; tick.addEventListener('change', () => { st.inLieu = tick.checked; draw(); });
    const basic = inp('number', st.basic, (v) => { st.basic = v; st.salaryFromCMS = false; draw(); }, { min: 0, step: '0.01', style: 'width:8rem', placeholder: 'Monthly basic' });
    box.append(h('div', { style: 'display:flex;gap:.6rem;align-items:center;flex-wrap:wrap' }, h('label', { class: 'check-row', style: 'white-space:nowrap' }, tick, 'Work out notice in lieu'),
      st.inLieu ? h('span', {}, 'Monthly basic RM ', basic, st.salaryFromCMS ? h('small', { class: 'muted' }, ' from payroll') : null) : null));
    if (st.inLieu && c.short.pay) {
      box.append(h('table', { class: 'data compact', style: 'margin-top:.6rem' }, h('thead', {}, h('tr', {}, ['Month', 'Days not served', 'Basic ÷ days in month', 'Amount'].map((t) => h('th', {}, t)))),
        h('tbody', {}, (c.short.pay.parts || []).map((p) => h('tr', {}, h('td', {}, new Date(`${p.month}-01T00:00:00Z`).toLocaleDateString('en-MY', { month: 'short', year: 'numeric', timeZone: 'UTC' })), h('td', { class: 'num' }, `${p.days} / ${p.of}`),
          h('td', { class: 'num' }, p.rate != null ? rm(p.rate) : ''), h('td', { class: 'num' }, rm(p.amount))))),
        h('tfoot', {}, h('tr', {}, h('th', { colspan: 3 }, 'Notice in lieu (s.13(1), Employment Act)'), h('th', { class: 'num' }, rm(c.short.pay.amount))))));
    } else if (st.inLieu) box.append(h('p', { class: 'muted small' }, 'Enter the monthly basic salary.'));
    return box;
  }

  drawForm(); draw();
}
