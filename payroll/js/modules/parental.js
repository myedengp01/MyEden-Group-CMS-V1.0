// Maternity & paternity entitlement checker (v2026.11.10) — HR / Admin.
// Employment Act 1955 as amended (from 1 Jan 2023): maternity s.37 / s.38, paternity s.60FA; checks run on the server
// (cms_parental_check). Company decisions (CLC 10 Nov 2026): monthly salary continues through maternity leave, each allowance paid or
// not case by case; paternity = 7 consecutive calendar days; the number of surviving children is kept as a number on the payroll
// profile. "Record leave" is optional and creates the maternity / paternity leave record with the check attached.
import { h, clear, pageHead, toast, failed, fmtDate, confirmDialog } from '../ui.js';
import { todayIso } from '../engines/employee.js';

const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const rm = (x) => (x === null || x === undefined || Number.isNaN(Number(x)) ? '—' : `RM${Number(x).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
const addDays = (d, n) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 864e5).toISOString().slice(0, 10);
const mLabel = (m) => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-MY', { month: 'short', year: 'numeric', timeZone: 'UTC' });
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const LBL = { AL: 'Annual leave', SL: 'Sick leave', HPL: 'Hospitalisation', RL: 'Replacement leave', CPL: 'Compassionate', UPL: 'Unpaid', UPH: 'Unpaid hours', MTL: 'Maternity', PTL: 'Paternity', CCL: 'Company closure' };

/** The checks to show: [{ok: true|false|null, text, ref}] — null = not known / HR to confirm. */
export function conditions(c) {
  if (c.type === 'MTL') return [
    { ok: c.female, text: 'Female employee', ref: 's.37' },
    { ok: c.employed_4m, text: 'Employed at some time in the 4 months before the birth', ref: 's.37(2)(a)' },
    { ok: c.days_employed_9m >= 90, text: `Employed ${c.days_employed_9m} days in the 9 months before the birth (at least 90)`, ref: 's.37(2)(a)' },
    { ok: c.under5, text: c.surviving_children == null ? 'Number of surviving children not entered yet (fewer than 5 needed for paid leave)' : `${c.surviving_children} surviving child${c.surviving_children === 1 ? '' : 'ren'} (fewer than 5 needed for paid leave)`, ref: 's.37(2)(c)' },
    { ok: !c.early_start, text: c.early_start ? 'Leave starts more than 30 days before the birth — too early' : 'Leave starts no earlier than 30 days before the birth', ref: 's.37(1)(c)' },
    { ok: !c.late_start, text: c.late_start ? 'Leave starts later than the day after the birth' : 'Leave starts no later than the day after the birth', ref: 's.37(1)(c)' },
    { ok: c.notice_ok, text: c.notice ? `Notice given ${fmtDate(c.notice)} (due within the 60 days before the expected birth)` : 'Notice date not entered (due within the 60 days before the expected birth)', ref: 's.38' },
  ];
  return [
    { ok: c.male, text: 'Male employee', ref: 's.60FA(1)' },
    { ok: c.married, text: `Married (profile: ${c.marital_status || 'not entered'}) — confirm with the marriage certificate`, ref: 's.60FA(1)' },
    { ok: c.service_ok, text: `${c.service_months} months with the company when the leave starts (at least 12)${c.join_date ? `, joined ${fmtDate(c.join_date)}` : ''}`, ref: 's.60FA(2)(a)' },
    { ok: c.within_limit, text: `${c.previous_paternity} earlier paternity leave${c.previous_paternity === 1 ? '' : 's'} (${c.previous_paternity_cms} in the CMS) — up to 5 births`, ref: 's.60FA(1)' },
    { ok: c.notice_ok, text: c.notice ? `Notice given ${fmtDate(c.notice)} (at least 30 days before the expected birth, or as soon as possible after it)` : 'Notice date not entered (at least 30 days before the expected birth, or as soon as possible after it)', ref: 's.60FA(2)(b)' },
  ];
}

/** Maternity pay per month for a monthly-paid employee: salary continues; allowances switched off are left out for the days on leave. */
export function maternityMonths(c, pay) {
  const allw = c.allowances || [];
  const basic = Number(c.basic) || 0;
  const full = basic + allw.reduce((s, a) => s + Number(a.amount), 0);
  return (c.months || []).map((m) => {
    const part = m.days / m.cal_days;
    if (!c.eligible) { const unpaid = r2(full * part); return { ...m, basic, allowances: 0, notPaid: 0, unpaid, total: r2(full - unpaid) }; }
    const notPaid = r2(allw.filter((a) => pay[a.id] === false).reduce((s, a) => s + Number(a.amount) * part, 0));
    const paidAllw = r2(allw.filter((a) => pay[a.id] !== false).reduce((s, a) => s + Number(a.amount), 0));
    return { ...m, basic, allowances: paidAllw, notPaid, unpaid: 0, total: r2(full - notPaid) };
  });
}

export async function render(el, ctx, params, query) {
  const canEdit = ctx.can(['leave.edit']);
  const [{ data: list, error }, { data: extra }] = await Promise.all([
    ctx.sb.from('eppd_employee_list').select('id,emp_id,full_name,gender,company_name,department_code,join_date,resigned_date').order('full_name'),
    ctx.sb.from('eppd_employees').select('id,marital_status,surviving_children')]);
  if (error) { el.append(h('div', { class: 'empty-state' }, error.message)); return; }
  const ex = new Map((extra || []).map((x) => [x.id, x]));
  const today = todayIso();
  const people = (list || []).filter((p) => !p.resigned_date || p.resigned_date >= addDays(today, -365)).map((p) => ({ ...p, ...(ex.get(p.id) || {}) }));
  const st = { emp: Number(query.emp) || '', type: query.type === 'PTL' ? 'PTL' : 'MTL', event: '', start: '', notice: '', prior: 0, children: '', check: null, pay: {} };

  el.append(pageHead('Maternity & Paternity Checker',
    'Checks the leave and pay against the Employment Act (maternity s.37, paternity s.60FA), works out the dates and the pay, and prints the result for the file. Recording the leave is optional.'));
  const form = h('section', { class: 'panel', style: 'padding:1rem' });
  const out = h('section', { class: 'panel pc-out' });
  el.append(form, out);

  const sel = (opts, val, on, attrs = {}) => { const s = h('select', attrs, opts.map(([k, l]) => h('option', { value: k, selected: String(k) === String(val) }, l))); s.addEventListener('change', () => on(s.value)); return s; };
  const inp = (type, val, on, attrs = {}) => { const i = h('input', { type, ...attrs }); i.value = val ?? ''; i.addEventListener('change', () => on(i.value)); return i; };
  const person = () => people.find((p) => p.id === Number(st.emp));

  function drawForm() {
    clear(form);
    const p = person();
    const mtl = st.type === 'MTL';
    const childIn = inp('number', st.children, (v) => { st.children = v; }, { min: 0, max: 30, step: 1, style: 'width:5rem' });
    form.append(h('div', { class: 'form-grid' },
      h('label', { class: 'field span-2' }, 'Employee', sel([['', 'Choose…'], ...people.map((x) => [x.id, `${x.full_name}${x.emp_id ? ` (${x.emp_id})` : ''}${x.resigned_date ? ' — left' : ''}`])], st.emp, (v) => {
        st.emp = v; const q = person(); if (q) { st.type = q.gender === 'M' ? 'PTL' : 'MTL'; st.children = q.surviving_children ?? ''; } st.check = null; drawForm(); clear(out); })),
      h('label', { class: 'field' }, 'Leave', sel([['MTL', 'Maternity (98 days)'], ['PTL', 'Paternity (7 days)']], st.type, (v) => { st.type = v; st.check = null; drawForm(); clear(out); })),
      h('label', { class: 'field' }, mtl ? 'Expected / actual date of birth (confinement)' : 'Expected / actual date of birth', inp('date', st.event, (v) => { st.event = v; if (!st.start) st.start = v; drawForm(); })),
      h('label', { class: 'field' }, 'Leave starts', inp('date', st.start, (v) => { st.start = v; }),
        h('small', { class: 'muted' }, mtl ? 'From 30 days before the birth up to the day after.' : 'Usually from the birth.')),
      h('label', { class: 'field' }, 'Notice given on (optional)', inp('date', st.notice, (v) => { st.notice = v; }),
        h('small', { class: 'muted' }, mtl ? 'Due within the 60 days before the expected birth.' : 'At least 30 days before, or as soon as possible after the birth.')),
      mtl ? h('div', { class: 'field' }, h('span', {}, 'Surviving children (number only)'), h('div', { style: 'display:flex;gap:.5rem;align-items:center' }, childIn,
          canEdit && p ? h('button', { type: 'button', class: 'btn sm', onclick: async () => {
            const n = childIn.value === '' ? null : Number(childIn.value);
            const { error: e } = await ctx.sb.rpc('cms_set_surviving_children', { p_employee: p.id, p_count: n });
            if (failed(e)) return; p.surviving_children = n; toast('Saved to the profile.'); if (st.check) check();
          } }, 'Save to profile') : null),
          h('small', { class: 'muted' }, p ? `On the profile: ${p.surviving_children ?? 'not entered'}. Not counting the baby being born.` : ''))
        : h('label', { class: 'field' }, 'Paternity leave taken before the CMS (births)', inp('number', st.prior, (v) => { st.prior = Number(v) || 0; }, { min: 0, max: 10, step: 1 }),
          h('small', { class: 'muted' }, 'Earlier paternity leave with the company not in the leave records.'))),
    h('div', { style: 'margin-top:1rem;display:flex;gap:.5rem' }, h('button', { type: 'button', class: 'btn primary', onclick: check }, 'Check')));
  }

  async function check() {
    if (!st.emp || !st.event) { toast('Choose the employee and the date of birth.', 'error'); return; }
    const { data, error: e } = await ctx.sb.rpc('cms_parental_check', { p: { employee_id: Number(st.emp), type: st.type, event: st.event, start: st.start || st.event, notice: st.notice || null, prior_paternity: st.prior } });
    if (failed(e)) return;
    st.check = data; st.pay = {};
    drawOut();
  }

  function drawOut() {
    const c = st.check; clear(out); if (!c) return;
    const mtl = c.type === 'MTL';
    const conds = conditions(c);
    const mark = (ok) => h('span', { class: `tag ${ok === true ? 'ok' : ok === false ? 'bad' : 'warn'}`, style: 'min-width:1.6rem;text-align:center' }, ok === true ? '✓' : ok === false ? '✗' : '?');
    const verdict = mtl ? (c.female ? (c.eligible ? 'Maternity leave: 98 days, PAID' : 'Maternity leave: 98 days, NOT paid (not eligible for the allowance)') : 'Not eligible: maternity leave is for female employees')
      : (c.eligible ? 'Paternity leave: 7 days, paid' : 'Not eligible for paternity leave');
    const good = mtl ? c.female && c.eligible : c.eligible;
    const warns = [];
    if (mtl && c.surviving_children == null) warns.push('Enter the number of surviving children (fewer than 5 is needed for paid maternity leave) and save it to the profile.');
    if (c.notice_ok === false) warns.push(mtl ? 'Notice was not given within the 60 days before the expected birth: under s.38 the allowance can be held back until notice is given.' : 'Notice was not given 30 days before the expected birth: check it was given as soon as possible after the birth.');
    if (mtl && c.early_start) warns.push('The leave starts more than 30 days before the birth; move the start date.');
    if (!mtl && c.starts_before_birth) warns.push('Paternity leave starts before the birth; check this is intended.');
    if ((c.overlaps || []).length) warns.push(`Other leave already recorded over these dates: ${c.overlaps.map((o) => `${LBL[o.type] || o.type} ${fmtDate(o.from)}${o.to !== o.from ? ` – ${fmtDate(o.to)}` : ''} (${Number(o.days)} d)`).join('; ')}. Cancel or change it before recording.`);
    if (mtl && c.previous_maternity) warns.push(`${c.previous_maternity} earlier maternity leave on record (there is no limit on the leave; the allowance needs fewer than 5 surviving children).`);

    const body = h('div', { style: 'padding:1rem' },
      h('div', { class: `pc-verdict ${good ? 'ok' : 'bad'}` }, h('b', {}, verdict), h('div', { class: 'small' }, `${c.name}${c.emp_id ? ` (${c.emp_id})` : ''} · birth ${fmtDate(c.event)}`)),
      h('div', { class: 'pc-grid' },
        h('div', {}, h('h3', {}, 'Conditions'), h('ul', { class: 'pc-cond' }, conds.map((k) => h('li', {}, mark(k.ok), h('span', {}, k.text), h('small', { class: 'muted' }, ` EA ${k.ref}`))))),
        h('div', {}, h('h3', {}, 'Dates'), h('table', { class: 'data compact' }, h('tbody', {},
          h('tr', {}, h('td', {}, 'Leave'), h('td', {}, h('b', {}, `${fmtDate(c.leave_from)} – ${fmtDate(c.leave_to)}`), ` · ${c.days} consecutive days`)),
          h('tr', {}, h('td', {}, 'Back at work'), h('td', {}, fmtDate(c.return_date), h('small', { class: 'muted' }, ' (next working day)'))),
          mtl ? h('tr', {}, h('td', {}, 'Earliest start'), h('td', {}, fmtDate(addDays(c.event, -30)), ' · latest ', fmtDate(addDays(c.event, 1)))) : null,
          mtl ? h('tr', {}, h('td', {}, 'Notice due'), h('td', {}, `${fmtDate(addDays(c.event, -60))} – ${fmtDate(c.event)}`)) : h('tr', {}, h('td', {}, 'Notice due by'), h('td', {}, fmtDate(addDays(c.event, -30)))))))),
      warns.length ? h('div', { class: 'pc-warn' }, h('b', {}, 'Check'), h('ul', {}, warns.map((w) => h('li', {}, w)))) : null,
      h('h3', {}, 'Pay'), mtl ? payMtl(c) : payPtl(c),
      h('p', { class: 'small muted', style: 'margin-top:1rem' }, `Checked ${new Date(c.checked_at).toLocaleString('en-MY')} against the Employment Act 1955 as amended (from 1 Jan 2023). Not legal advice; check unusual cases.`),
      h('div', { class: 'pc-actions' },
        h('button', { type: 'button', class: 'btn', onclick: () => printOut(c) }, 'Print / save PDF'),
        c.can_record && canEdit ? h('button', { type: 'button', class: 'btn primary', disabled: !(mtl ? c.female : c.eligible) || (c.overlaps || []).some((o) => o.type === c.type),
          title: (mtl ? c.female : c.eligible) ? '' : 'Not eligible', onclick: record }, `Record ${mtl ? 'maternity' : 'paternity'} leave`) : null,
        h('small', { class: 'muted' }, 'Recording is optional; the check alone changes nothing.')));
    out.append(body);
  }

  function payMtl(c) {
    const box = h('div');
    const draw = () => {
      clear(box);
      if (!c.eligible) box.append(h('p', { class: 'pc-warn' }, 'Not eligible for the maternity allowance: she still gets the 98 days\' leave, but the days are unpaid (payroll deducts them).'));
      if (c.pay_basis !== 'monthly') {
        box.append(h('p', {}, `Not monthly-paid: allowance = ordinary rate of pay × each day. ORP ${rm(c.orp)} (basic earned in the 3 months before ÷ days worked)${c.orp ? `; 98 days = ${rm(c.orp * 98)}` : ' — not enough work records; enter the days worked on the leave record'}.`));
        return;
      }
      const allw = c.allowances || [];
      box.append(h('p', { class: 'small muted' }, 'Monthly-paid: the monthly salary continues through the 98 days. Choose which allowances are paid during the leave.'),
        h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Pay item', 'Monthly', 'During the leave'].map((t) => h('th', {}, t)))),
          h('tbody', {}, h('tr', {}, h('td', {}, 'Basic salary'), h('td', { class: 'num' }, rm(c.basic)), h('td', {}, c.eligible ? 'Paid (continues)' : 'Not paid')),
            allw.length ? allw.map((a) => { const s = h('input', { type: 'checkbox', disabled: !c.eligible }); s.checked = st.pay[a.id] !== false && c.eligible;
              s.addEventListener('change', () => { st.pay[a.id] = s.checked; draw(); });
              return h('tr', {}, h('td', {}, a.name, a.to ? h('small', { class: 'muted' }, ` until ${fmtDate(a.to)}`) : null), h('td', { class: 'num' }, rm(a.amount)),
                h('td', {}, h('label', { class: 'check-row' }, s, s.checked ? 'Pay' : "Don't pay"))); })
              : h('tr', {}, h('td', { colspan: 3, class: 'muted' }, 'No allowances on the payroll for this period.')))),
        h('h4', { style: 'margin:1rem 0 .3rem' }, 'Estimate by month'),
        h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Month', 'Days on leave', 'Basic', 'Allowances paid', 'Not paid', 'Pay for the month'].map((t) => h('th', { class: t === 'Month' ? '' : 'num' }, t)))),
          h('tbody', {}, maternityMonths(c, st.pay).map((m) => h('tr', {}, h('td', {}, mLabel(m.month)), h('td', { class: 'num' }, `${m.days} / ${m.cal_days}`), h('td', { class: 'num' }, rm(m.basic)),
            h('td', { class: 'num' }, rm(m.allowances)), h('td', { class: `num ${m.notPaid || m.unpaid ? 'neg' : ''}` }, m.unpaid ? `−${rm(m.unpaid)}` : m.notPaid ? `−${rm(m.notPaid)}` : '—'), h('td', { class: 'num strong' }, rm(m.total)))))),
        h('p', { class: 'small muted' }, 'Allowances not paid are left out for the days on leave in each month (calendar days). Statutory deductions (EPF, SOCSO, EIS, PCB) apply as usual in payroll.'));
    };
    draw();
    return box;
  }
  function payPtl(c) {
    return h('p', {}, c.eligible ? `Paid leave at the normal rate: the monthly salary continues (ordinary rate of pay ${rm(c.basic ? c.basic / 26 : null)} a day × 7 = ${rm(c.basic ? (c.basic / 26) * 7 : null)}).`
      : 'Not eligible: if he needs the days off, record them as annual or unpaid leave instead.');
  }

  async function record() {
    const c = st.check; const mtl = c.type === 'MTL';
    const allw = (c.allowances || []).map((a) => ({ id: a.id, code: a.code, name: a.name, amount: Number(a.amount), pay: c.eligible && st.pay[a.id] !== false }));
    const off = allw.filter((a) => !a.pay);
    if (!(await confirmDialog(`Record ${mtl ? 'maternity' : 'paternity'} leave`,
      `${c.name}: ${fmtDate(c.leave_from)} – ${fmtDate(c.leave_to)} (${c.days} days)${mtl ? `, ${c.eligible ? 'paid' : 'NOT paid'}${off.length && c.eligible ? `; not paying ${off.map((a) => a.name).join(', ')}` : ''}` : ''}. The check is saved with the leave record.`, 'Record'))) return;
    const { data, error: e } = await ctx.sb.rpc('cms_parental_record', { p: { employee_id: c.employee_id, type: c.type, event: c.event, start: c.leave_from, notice: c.notice,
      allowance: mtl ? (c.eligible ? 'paid' : 'unpaid') : null, orp: c.orp, allowances: allw, check: { ...c, allowances: undefined, months: undefined, overlaps: undefined } } });
    if (failed(e)) return;
    toast(`Leave recorded: ${fmtDate(data.from)} – ${fmtDate(data.to)}.`);
    check();
  }

  function printOut(c) {
    const mtl = c.type === 'MTL';
    const rows = conditions(c).map((k) => `<tr><td>${k.ok === true ? '✓' : k.ok === false ? '✗' : '?'}</td><td>${esc(k.text)}</td><td>EA ${esc(k.ref)}</td></tr>`).join('');
    const months = mtl && c.pay_basis === 'monthly' ? maternityMonths(c, st.pay) : [];
    const allw = (c.allowances || []).map((a) => `<tr><td>${esc(a.name)}</td><td class="n">${rm(a.amount)}</td><td>${c.eligible && st.pay[a.id] !== false ? 'Pay' : 'Not paid'}</td></tr>`).join('');
    const w = window.open('', '_blank');
    if (!w) { toast('Allow pop-ups to print.', 'error'); return; }
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${mtl ? 'Maternity' : 'Paternity'} leave check · ${esc(c.name)}</title>
      <style>body{font:13px/1.45 Arial,sans-serif;color:#111;margin:28px}h1{font-size:18px;margin:0 0 4px}h2{font-size:14px;margin:18px 0 6px}table{border-collapse:collapse;width:100%}
      td,th{border:1px solid #bbb;padding:4px 6px;text-align:left;vertical-align:top}.n{text-align:right}.v{padding:8px 10px;border:2px solid ${(mtl ? c.female && c.eligible : c.eligible) ? '#1d8a45' : '#b4232f'};margin:10px 0}
      small{color:#555}.sig{display:flex;gap:40px;margin-top:40px}.sig div{flex:1;border-top:1px solid #333;padding-top:4px}</style></head><body>
      <h1>${mtl ? 'Maternity' : 'Paternity'} leave entitlement check</h1><small>MyEden Group · checked ${esc(new Date(c.checked_at).toLocaleString('en-MY'))}</small>
      <div class="v"><b>${esc(mtl ? (c.female ? (c.eligible ? 'Eligible: 98 days, paid' : 'Leave given (98 days) — NOT paid: not eligible for the allowance') : 'Not eligible') : (c.eligible ? 'Eligible: 7 days, paid' : 'Not eligible'))}</b></div>
      <table><tr><th>Employee</th><td>${esc(c.name)} ${c.emp_id ? `(${esc(c.emp_id)})` : ''}</td><th>Date of birth (confinement)</th><td>${esc(fmtDate(c.event))}</td></tr>
      <tr><th>Leave</th><td>${esc(fmtDate(c.leave_from))} – ${esc(fmtDate(c.leave_to))} (${c.days} consecutive days)</td><th>Back at work</th><td>${esc(fmtDate(c.return_date))}</td></tr>
      <tr><th>Notice given</th><td>${c.notice ? esc(fmtDate(c.notice)) : '—'}</td><th>${mtl ? 'Surviving children' : 'Earlier paternity leave'}</th><td>${mtl ? (c.surviving_children ?? '—') : c.previous_paternity}</td></tr></table>
      <h2>Conditions (Employment Act 1955)</h2><table>${rows}</table>
      ${mtl && c.pay_basis === 'monthly' ? `<h2>Pay during the leave</h2><table><tr><th>Item</th><th class="n">Monthly</th><th>During the leave</th></tr><tr><td>Basic salary</td><td class="n">${rm(c.basic)}</td><td>${c.eligible ? 'Paid (continues)' : 'Not paid'}</td></tr>${allw}</table>
        <h2>Estimate by month</h2><table><tr><th>Month</th><th class="n">Days on leave</th><th class="n">Basic</th><th class="n">Allowances paid</th><th class="n">Not paid</th><th class="n">Pay</th></tr>
        ${months.map((m) => `<tr><td>${esc(mLabel(m.month))}</td><td class="n">${m.days} / ${m.cal_days}</td><td class="n">${rm(m.basic)}</td><td class="n">${rm(m.allowances)}</td><td class="n">${m.unpaid || m.notPaid ? `−${rm(m.unpaid || m.notPaid)}` : '—'}</td><td class="n"><b>${rm(m.total)}</b></td></tr>`).join('')}</table>`
        : mtl ? `<h2>Pay</h2><p>Not monthly-paid: ORP ${rm(c.orp)} a day × each day of leave.</p>` : `<h2>Pay</h2><p>${c.eligible ? `Paid at the normal rate (ORP ${rm(c.basic ? c.basic / 26 : null)} a day).` : 'Not eligible.'}</p>`}
      <div class="sig"><div>Checked by (HR)</div><div>Approved by</div><div>Employee</div></div>
      <p><small>Employment Act 1955 as amended (from 1 Jan 2023): maternity s.37–s.38, paternity s.60FA.</small></p>
      <script>window.onload=()=>{window.print();}<\/script></body></html>`);
    w.document.close();
  }

  drawForm();
}
