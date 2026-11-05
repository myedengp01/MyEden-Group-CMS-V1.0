// Leave records: list, record leave (auto day count, override), edit, cancel
import { h, clear, pageHead, fmtDate, openModal, field, toast, failed, confirmDialog } from '../ui.js';
import { loadLeaveYear, balancesFor, loadHolidaySet, LEAVE_LABELS, peopleInYear } from '../leave-data.js';
import { countLeaveDays, workClass } from '../engines/leave.js';
import { todayIso } from '../engines/employee.js';

export async function render(el, ctx, params, query) {
  const year = Number(query.year) || Number(todayIso().slice(0, 4));
  const D = await loadLeaveYear(ctx.sb, year);
  const holidays = await loadHolidaySet(ctx.sb, [year - 1, year, year + 1]);
  const ww = D.ref.policies.working_week || { rest_days: [0], off_days: [6] };
  const byId = new Map(D.people.map((p) => [p.id, p]));
  const st = { type: query.type || '', q: query.q || '', emp: query.emp ? Number(query.emp) : null };

  const yearSel = h('select', { 'aria-label': 'Year', style: 'width:auto' }, [year - 1, year, year + 1].map((y) => h('option', { value: y, selected: y === year }, y)));
  yearSel.addEventListener('change', () => { location.hash = `#/leave?year=${yearSel.value}`; });
  const typeSel = h('select', { 'aria-label': 'Leave type', style: 'width:auto' }, h('option', { value: '' }, 'All types'),
    Object.entries(LEAVE_LABELS).map(([k, l]) => h('option', { value: k, selected: k === st.type }, l)));
  const search = h('input', { type: 'search', placeholder: 'Search name or ID', 'aria-label': 'Search', value: st.q });
  const body = h('div', { class: 'table-wrap' }); const foot = h('p', { class: 'small muted' });

  el.append(
    pageHead('Leave records', `Leave taken in ${year}. Days are counted Monday to Friday, skipping Saturday (off day), Sunday (rest day) and public holidays; maternity and paternity count calendar days.`,
      yearSel, h('button', { class: 'btn primary', type: 'button', onclick: () => openRecord(null) }, 'Record leave')),
    h('section', { class: 'panel' }, h('div', { class: 'panel-head filters' }, h('div', { class: 'filter-row', style: 'justify-content:flex-start' }, search, typeSel)), body, h('div', { class: 'panel-foot' }, foot)));

  function draw() {
    const q = st.q.trim().toLowerCase();
    const list = D.records.filter((r) => (!st.type || r.leave_type === st.type) && (!st.emp || r.employee_id === st.emp)
      && (!q || `${byId.get(r.employee_id)?.full_name} ${byId.get(r.employee_id)?.emp_id}`.toLowerCase().includes(q)));
    foot.textContent = `${list.length} record${list.length === 1 ? '' : 's'} · ${list.filter((r) => r.status !== 'cancelled').reduce((s, r) => s + Number(r.days), 0)} days`;
    clear(body);
    if (!list.length) { body.append(h('div', { class: 'empty-state' }, D.records.length ? 'No leave matches these filters.' : `No leave recorded for ${year} yet.`)); return; }
    body.append(h('table', { class: 'data' },
      h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), h('th', {}, 'Type'), h('th', {}, 'Dates'), h('th', { class: 'num' }, 'Days'), h('th', {}, 'Note'), h('th', {}))),
      h('tbody', {}, list.map((r) => {
        const p = byId.get(r.employee_id);
        return h('tr', { class: r.status === 'cancelled' ? 'inactive' : '' },
          h('td', {}, h('a', { href: `#/employees/${r.employee_id}?tab=leave`, class: 'row-link' }, p?.full_name || '?'), h('div', { class: 'small muted' }, p?.emp_id || '')),
          h('td', {}, LEAVE_LABELS[r.leave_type] || r.leave_type, r.status === 'cancelled' ? h('span', { class: 'tag', style: 'margin-left:.4rem' }, 'Cancelled') : null),
          h('td', { class: 'nowrap' }, r.source === 'import' ? `${new Date(r.date_from + 'T00:00:00').toLocaleDateString('en-MY', { month: 'long', year: 'numeric' })} (total)` :
            r.date_from === r.date_to ? fmtDate(r.date_from) + (r.half_day !== 'none' ? ` (${r.half_day.toUpperCase()})` : '') : `${fmtDate(r.date_from)} – ${fmtDate(r.date_to)}`),
          h('td', { class: 'num' }, r.leave_type === 'UPH' ? `${Number(r.hours || 0)} h` : Number(r.days), r.days_override && r.source !== 'import' ? h('span', { class: 'small muted', title: 'Typed by HR' }, ' *') : null),
          h('td', { class: 'small muted' }, r.note || ''),
          h('td', { class: 'actions' }, h('button', { class: 'btn sm', type: 'button', onclick: () => openRecord(r) }, 'Edit'),
            h('button', { class: 'btn sm ghost', type: 'button', onclick: () => remove(r) }, 'Delete')));
      }))));
  }
  search.addEventListener('input', () => { st.q = search.value; draw(); });
  typeSel.addEventListener('change', () => { st.type = typeSel.value; draw(); });
  draw();

  async function remove(r) {
    if (!(await confirmDialog('Delete leave record', `Delete this ${LEAVE_LABELS[r.leave_type]} leave (${r.days} days)? To keep a trace, edit it and mark it cancelled instead.`, 'Delete', true))) return;
    const { error } = await ctx.sb.from('eppd_leave_records').delete().eq('id', r.id);
    if (!failed(error, 'Delete')) { toast('Deleted.'); window.dispatchEvent(new HashChangeEvent('hashchange')); }
  }

  function openRecord(r) { openLeaveForm(ctx, D, holidays, ww, r, { employeeId: st.emp, onSaved: () => window.dispatchEvent(new HashChangeEvent('hashchange')) }); }
}

/** Record / edit leave. Shared with the employee profile's Leave tab. */
export function openLeaveForm(ctx, D, holidays, ww, r, { employeeId = null, onSaved } = {}) {
  const current = peopleInYear(D.people, D.year).filter((p) => p.status.key !== 'former' || (r && p.id === r.employee_id) || p.id === employeeId);
  const F = {
    employee_id: field('Employee', { type: 'select', required: true, value: r?.employee_id ?? employeeId ?? '',
      options: [['', 'Choose…'], ...current.map((p) => [p.id, `${p.full_name}${p.emp_id ? ` (${p.emp_id})` : ''}`])], span2: true }),
    leave_type: field('Leave type', { type: 'select', value: r?.leave_type || 'AL', options: Object.entries(LEAVE_LABELS) }),
    half_day: field('Half day', { type: 'select', value: r?.half_day || 'none', options: [['none', 'Full day(s)'], ['am', 'Morning only'], ['pm', 'Afternoon only']] }),
    date_from: field('From', { type: 'date', required: true, value: r?.date_from || todayIso() }),
    date_to: field('To', { type: 'date', required: true, value: r?.date_to || todayIso() }),
    days: field('Days', { type: 'number', step: '0.5', value: r?.days ?? '' }),
    status: field('Status', { type: 'select', value: r?.status || 'taken', options: [['taken', 'Taken'], ['cancelled', 'Cancelled']] }),
    note: field('Note', { type: 'textarea', value: r?.note, span2: true }),
  };
  // v2026.11.05: unpaid hours (hours off, unearned wages), maternity / paternity details and checks
  const det = { ...(r?.details || {}) };
  const X = {
    hours: field('Hours off', { type: 'number', step: '0.25', min: 0, value: r?.hours ?? '', hint: 'Deducted from pay as unpaid hours (basic ÷ days in the month ÷ normal daily hours × hours). Not taken from annual leave.' }),
    event: field('Expected confinement date (due date)', { type: 'date', value: det.event || '' }),
    under5: field('Fewer than five surviving children (needed for the allowance)', { type: 'switch', value: det.under5 !== false, span2: true }),
    allowance: field('Maternity allowance', { type: 'select', value: det.allowance || 'paid', options: [['paid', 'Paid (eligible)'], ['unpaid', 'Not eligible: leave is unpaid']] }),
    days_worked: field('Days worked in the 3 months before (non-monthly pay)', { type: 'number', step: '1', min: 0, value: det.days_worked ?? '' }),
  };
  const chk = h('div', { class: 'span-2 bal-box' });
  let lastCheck = null;
  const personOf = () => D.people.find((x) => x.id === Number(F.employee_id.getValue()));
  async function runCheck() {
    const t = F.leave_type.getValue(); clear(chk); lastCheck = null;
    if (!['MTL', 'PTL'].includes(t) || !X.event.getValue() || !F.employee_id.getValue()) return;
    chk.append(h('p', { class: 'small muted' }, 'Checking entitlement…'));
    const { data: ee } = await ctx.sb.from('eppd_employees').select('employee_master_id').eq('id', Number(F.employee_id.getValue())).maybeSingle();
    if (!ee?.employee_master_id) { clear(chk).append(h('p', { class: 'small muted' }, 'Not linked to a CMS person: check by hand.')); return; }
    const { data: c, error } = await ctx.sb.rpc('cms_leave_entitlement_check', { p_person: ee.employee_master_id, p_type: t, p_event: X.event.getValue(), p_start: F.date_from.getValue() || null });
    if (error || !c) { clear(chk).append(h('p', { class: 'form-err' }, error?.message || 'Could not check.')); return; }
    lastCheck = c; drawCheck();
  }
  function drawCheck() {
    const c = lastCheck; clear(chk); if (!c) return;
    const ok = (b) => h('span', { class: `tag ${b ? 'ok' : 'warn'}`, style: 'margin-right:.4rem' }, b ? '✓' : '✗');
    const money = (x) => (x === null || x === undefined ? '—' : `RM${Number(x).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
    if (c.type === 'MTL') {
      const dw = Number(X.days_worked.getValue()) || c.days_worked_3m || 0;
      const orp = c.pay_basis === 'monthly' ? c.orp : (dw > 0 ? Math.round((c.earned_3m / dw) * 100) / 100 : null);
      const eligible = c.eligible_allowance && X.under5.getValue();
      chk.append(h('div', { class: 'notice-calc' }, h('b', {}, eligible ? 'Maternity allowance: eligible' : 'Maternity allowance: NOT eligible (the leave is still given, unpaid)'),
        h('div', {}, ok(c.female), 'Female employee'),
        h('div', {}, ok(c.days_employed_9m >= 90), `Employed ${c.days_employed_9m} days in the 9 months before confinement (at least 90)`),
        h('div', {}, ok(c.employed_4m), 'Employed at some time in the 4 months before confinement'),
        h('div', {}, ok(X.under5.getValue()), 'Fewer than five surviving children (ticked by HR)'),
        h('div', {}, ok(!c.early_start), c.early_start ? 'Leave starts more than 30 days before the due date' : 'Leave starts within 30 days before the due date (or later)'),
        h('div', { class: 'small' }, `98 consecutive days: ${c.leave_from} to ${c.leave_to}. Earlier maternity leave on record: ${c.previous_maternity}.`),
        h('div', { class: 'small' }, c.pay_basis === 'monthly' ? `Monthly salary RM${c.salary} continues as the allowance (ORP ${money(c.orp)} a day × 98 = ${money(c.allowance)}).`
          : `Not monthly-paid: ORP = ${money(c.earned_3m)} basic earned in the 3 months before ÷ ${dw || '?'} days worked = ${money(orp)} a day; allowance 98 × ORP = ${money(orp ? orp * 98 : null)}, paid month by month in payroll.`)));
      if (!r?.details?.allowance) X.allowance.input.value = eligible ? 'paid' : 'unpaid';
      det.check = { ...c, orp, eligible }; det.orp = orp;
    } else {
      chk.append(h('div', { class: 'notice-calc' }, h('b', {}, c.eligible ? 'Paternity leave: eligible' : 'Paternity leave: NOT eligible'),
        h('div', {}, ok(c.male), 'Male employee (married: confirm with the marriage certificate)'),
        h('div', {}, ok(c.service_ok), `${c.service_months} months' service at the birth (at least 12)`),
        h('div', {}, ok(c.within_limit), `${c.previous_paternity} earlier paternity leave on record (up to 5 confinements)`),
        h('div', { class: 'small' }, `7 consecutive days: ${c.leave_from} to ${c.leave_to}.`)));
      det.check = c;
    }
  }
  X.event.input.addEventListener('change', runCheck); X.under5.input.addEventListener('change', drawCheck); X.days_worked.input.addEventListener('input', drawCheck);
  F.date_from.input.addEventListener('change', () => { if (['MTL', 'PTL'].includes(F.leave_type.getValue())) runCheck(); });
  let override = !!r?.days_override;
  const auto = h('p', { class: 'small muted span-2' });
  const balBox = h('div', { class: 'span-2 bal-box' });
  const recompute = () => {
    const type = F.leave_type.getValue(); const from = F.date_from.getValue(); const to = F.date_to.getValue() || from;
    const show = (f, on) => { f.style.display = on ? '' : 'none'; };
    show(X.hours, type === 'UPH'); show(X.event, ['MTL', 'PTL'].includes(type)); show(X.under5, type === 'MTL'); show(X.allowance, type === 'MTL'); show(X.days_worked, type === 'MTL' && lastCheck?.pay_basis && lastCheck.pay_basis !== 'monthly');
    X.event.firstChild.textContent = type === 'PTL' ? 'Baby’s date of birth (or expected date)' : 'Expected confinement date (due date)';
    if (type === 'UPH') { F.date_to.input.value = from; F.half_day.input.value = 'none'; }
    // part-timers take whole days only, when the policy says so (Payroll Settings › Part-time and casual staff)
    const pp = personOf(); const ptp = D.ref.policies.part_time || {};
    const blockHalf = type === 'AL' && !!ptp.block_half_day_pt && pp && workClass(pp.employment || {}, ptp) === 'PT';
    F.half_day.input.disabled = blockHalf || type === 'UPH'; if (blockHalf) F.half_day.input.value = 'none';
    F.half_day.title = blockHalf ? 'Part-timers take whole days only; use unpaid hours for part of a day' : '';
    if (F.half_day.getValue() !== 'none' && to !== from) { F.date_to.input.value = from; }
    const n = countLeaveDays(from, F.date_to.getValue() || from, { holidays, restDays: ww.rest_days, offDays: ww.off_days,
      calendar: ['MTL', 'PTL'].includes(type), halfDay: F.half_day.getValue() });
    auto.textContent = `Automatic count: ${n} day${n === 1 ? '' : 's'}${['MTL', 'PTL'].includes(type) ? ' (calendar days)' : ' (Mon–Fri, excluding public holidays)'}.` + (override ? ' You typed your own number.' : '');
    if (!override) F.days.input.value = type === 'UPH' ? 0 : n;
    drawBalance(); if (['MTL', 'PTL'].includes(type) && !lastCheck) runCheck(); if (!['MTL', 'PTL'].includes(type)) clear(chk);
  };
  F.days.input.addEventListener('input', () => { override = true; recompute(); });
  ['leave_type', 'date_from', 'date_to', 'half_day', 'employee_id'].forEach((k) => F[k].input.addEventListener('change', recompute));
  function drawBalance() {
    const p = D.people.find((x) => x.id === Number(F.employee_id.getValue()));
    clear(balBox); if (!p) return;
    const b = balancesFor(p, D);
    const t = F.leave_type.getValue();
    const line = t === 'AL' ? `Annual leave left in ${D.year}: ${b.AL.balance} of ${b.AL.entitled + b.AL.carried} days` :
      t === 'SL' ? `Sick leave left: ${b.SL.balance} of ${b.SL.entitled} days` : t === 'HPL' ? `Hospitalisation pool left (shared with sick leave): ${b.HPL.balance} days` :
      t === 'CPL' ? `Compassionate leave left this year: ${b.CPL.balance} of ${b.CPL.entitled} (${b.CPL.perEvent} per occasion)` :
      t === 'RL' ? `Replacement leave balance: ${b.RL.balance} days` : t === 'MTL' ? `Maternity: ${b.MTL.perEvent} consecutive days per confinement` :
      t === 'PTL' ? `Paternity: ${b.PTL.perEvent} consecutive days per birth${b.PTL.eligible === false ? ' (not eligible: needs 12 months’ service and male)' : ''}`
      : t === 'UPH' ? 'Unpaid hours: deducted from pay; annual leave is not used' : 'Unpaid leave';
    balBox.append(h('p', { class: 'notice-calc' }, line));
  }
  openModal({ title: r ? 'Edit leave' : 'Record leave', wide: true, body: h('div', { class: 'form-grid' }, Object.values(F).slice(0, 6), X.hours, X.event, X.allowance, X.days_worked, X.under5, auto, F.status, balBox, chk, F.note),
    actions: [{ label: r ? 'Save changes' : 'Record leave', primary: true, onClick: async (close) => {
      const v = Object.fromEntries(Object.entries(F).map(([k, f]) => [k, f.getValue()]));
      if (!v.employee_id || !v.date_from) { toast('Choose the employee and the dates.', 'error'); return false; }
      v.date_to = v.date_to || v.date_from; v.employee_id = Number(v.employee_id);
      if (v.date_to < v.date_from) { toast('“To” must be on or after “From”.', 'error'); return false; }
      if (v.days === null) { toast('Days is required.', 'error'); return false; }
      v.days_override = override;
      if (v.leave_type === 'UPH') { const hrs = Number(X.hours.getValue()); if (!(hrs > 0)) { toast('Enter the hours off.', 'error'); return false; } v.hours = hrs; v.days = 0; v.date_to = v.date_from; v.half_day = 'none'; }
      else v.hours = null;
      if (['MTL', 'PTL'].includes(v.leave_type)) {
        if (!X.event.getValue()) { toast(v.leave_type === 'MTL' ? 'Enter the expected confinement date.' : 'Enter the baby’s date of birth.', 'error'); return false; }
        v.details = { ...det, event: X.event.getValue(), ...(v.leave_type === 'MTL' ? { under5: X.under5.getValue(), allowance: X.allowance.getValue(), days_worked: Number(X.days_worked.getValue()) || null } : {}), checked_at: new Date().toISOString() };
      } else v.details = null;
      const q = r ? ctx.sb.from('eppd_leave_records').update(v).eq('id', r.id) : ctx.sb.from('eppd_leave_records').insert(v);
      const { error } = await q; if (failed(error)) return false;
      toast(r ? 'Leave updated.' : 'Leave recorded.'); close(); onSaved?.(); return true;
    } }] });
  recompute();
}
