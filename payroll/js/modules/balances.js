// Leave balances for everyone employed in a year
import { h, clear, pageHead, openModal, field, toast, failed } from '../ui.js';
import { loadLeaveYear, balancesFor, peopleInYear, leaveForMonth, LEAVE_LABELS } from '../leave-data.js';
import { todayIso } from '../engines/employee.js';
import { eligibleCarry } from '../engines/leave.js';
import { editKpi } from './kpi.js';

export async function render(el, ctx, params, query) {
  const thisYear = Number(todayIso().slice(0, 4));
  const year = Number(query.year) || thisYear;
  const D = await loadLeaveYear(ctx.sb, year);
  if (query.view === 'monthly' || query.view === 'grid') return monthlyReport(el, ctx, D, year, thisYear, query);
  const asOf = year < thisYear ? `${year}-12-31` : todayIso();
  const list = peopleInYear(D.people, year).filter((p) => query.all || p.status.key !== 'former' || year < thisYear);
  const rows = list.map((p) => ({ p, b: balancesFor(p, D, asOf) }));
  const cf = D.ref.policies.carry_forward || {};
  const kpi = new Map(D.kpi.map((k) => [k.employee_id, k]));
  const provisional = (p) => D.adjustments.some((a) => a.provisional && a.employee_id === p.id);
  const elig = (p) => { const k = kpi.get(p.id); return eligibleCarry({ confirmed: p.employment?.confirmation_status === 'C', grade: k?.grade || null, override: k?.cf_override ?? null }, cf); };
  const canKpi = ctx.can(['admin', 'hr']);

  const yearSel = h('select', { 'aria-label': 'Year', style: 'width:auto' }, [thisYear - 1, thisYear, thisYear + 1].map((y) => h('option', { value: y, selected: y === year }, y)));
  yearSel.addEventListener('change', () => { location.hash = `#/leave/balances?year=${yearSel.value}`; });
  const search = h('input', { type: 'search', placeholder: 'Search name or ID', 'aria-label': 'Search' });
  const body = h('div', { class: 'table-wrap' });
  const needHours = rows.filter((r) => r.b.AL.needsHours).length;

  el.append(pageHead('Leave balances', `Position as at ${asOf}. Annual leave uses your AL calculator rules; sick, hospitalisation, maternity and paternity follow the Employment Act; compassionate leave follows company policy.`,
    yearSel, h('a', { class: 'btn', href: `#/leave/balances?year=${year}&view=monthly` }, 'Monthly report'), h('a', { class: 'btn', href: `#/leave/kpi?year=${year}` }, 'KPI grades'), h('button', { class: 'btn', type: 'button', onclick: exportCsv }, 'Export')),
  D.prevClosed === null && D.adjustments.some((a) => a.provisional) ? h('p', { class: 'small muted', style: 'margin-bottom:.8rem' }, `* Carried days from ${year - 1} are provisional: worked out from the 31 Dec ${year - 1} balance and KPI grades until ${year - 1} is closed at Year-end close.`) : null,
  needHours ? h('p', { class: 'setup-warning', style: 'margin-bottom:1rem' }, `${needHours} part-timer${needHours > 1 ? 's have' : ' has'} no weekly hours recorded, so full-time entitlements are shown. Add weekly hours in their Employment tab to pro-rate leave as the Employment Act requires.`) : null,
  h('section', { class: 'panel' }, h('div', { class: 'panel-head filters' }, h('div', { class: 'filter-row', style: 'justify-content:flex-start' }, search)), body));

  function draw() {
    const q = search.value.trim().toLowerCase();
    const shown = rows.filter((r) => !q || `${r.p.full_name} ${r.p.emp_id}`.toLowerCase().includes(q));
    clear(body);
    if (!shown.length) { body.append(h('div', { class: 'empty-state' }, 'No one to show.')); return; }
    const neg = (n) => (n < 0 ? 'neg' : '');
    body.append(h('table', { class: 'data bal-table' },
      h('thead', {},
        h('tr', {}, h('th', { rowspan: 2 }, 'Employee'), h('th', { colspan: 6, class: 'grp' }, 'Annual leave'), h('th', { colspan: 3, class: 'grp' }, 'Sick'),
          h('th', { class: 'grp' }, 'Hosp.'), h('th', { class: 'grp' }, 'Compass.'), h('th', { class: 'grp' }, 'Repl.'), h('th', { colspan: 3, class: 'grp', title: `Carry forward from ${year} into ${year + 1}` }, `Carry into ${year + 1}`), h('th', { rowspan: 2 }, '')),
        h('tr', {}, ['Entitled', 'Earned to date', 'Carried', 'Taken', 'Other', 'Balance', 'Entitled', 'Taken', 'Balance', 'Left', 'Left', 'Balance', 'KPI', 'Eligible', 'Will carry'].map((t) => h('th', { class: 'num' }, t)))),
      h('tbody', {}, shown.map(({ p, b }) => h('tr', {},
        h('td', {}, h('a', { href: `#/employees/${p.id}?tab=leave`, class: 'row-link' }, p.full_name),
          h('div', { class: 'small muted' }, [p.emp_id, b.AL.cls === 'CASUAL' ? 'Casual' : b.AL.cls === 'PT' ? 'Part-time' : p.employment?.job_status === 'PT' ? 'Part-time' : null, p.status.key === 'former' ? 'Left' : null].filter(Boolean).join(' · '))),
        h('td', { class: 'num' }, b.AL.entitled, b.AL.needsHours ? h('span', { class: 'tag warn', title: 'Part-timer without weekly hours: full-time entitlement shown' }, '!') : null),
        h('td', { class: 'num', title: `Earned to ${asOf}: this year's entitlement for the months counted so far` }, b.AL.earned ?? ''),
        h('td', { class: 'num' }, b.AL.carried || '', provisional(p) ? h('span', { title: 'Provisional until last year is closed' }, '*') : null), h('td', { class: 'num' }, b.AL.taken || ''),
        h('td', { class: 'num', title: 'Manual adjustments, buy-back, forfeited or expired days' }, (b.AL.adjusted - b.AL.buyback - b.AL.forfeit - b.AL.carriedExpired) || ''),
        h('td', { class: `num strong ${neg(b.AL.balance)}` }, b.AL.balance),
        h('td', { class: 'num' }, b.SL.entitled), h('td', { class: 'num' }, b.SL.taken || ''), h('td', { class: `num strong ${neg(b.SL.balance)}` }, b.SL.balance),
        h('td', { class: `num ${neg(b.HPL.balance)}` }, b.HPL.balance), h('td', { class: `num ${neg(b.CPL.balance)}` }, b.CPL.balance), h('td', { class: `num ${neg(b.RL.balance)}` }, b.RL.balance || ''),
        ...carryCells(p, b),
        h('td', { class: 'actions' }, h('a', { class: 'btn sm', href: `#/leave/al-calculator?emp=${p.id}&year=${year}` }, 'Breakdown'),
          h('button', { class: 'btn sm ghost', type: 'button', onclick: () => adjust(p) }, 'Adjust')))))));
  }
  function carryCells(p, b) {
    const k = kpi.get(p.id); const e = elig(p);
    const gradeTxt = k?.grade || (p.employment?.confirmation_status !== 'C' && cf.confirmed_only ? 'n/c' : '—');
    const g = canKpi ? h('button', { class: 'linkish', type: 'button', title: 'KPI grade and carry-forward override', onclick: () => editKpi(ctx, { person: p, year, row: k, cf, onSaved: (row) => { kpi.set(p.id, row); draw(); } }) }, gradeTxt) : gradeTxt;
    const will = b.AL.balance < 0 ? h('span', { class: 'neg', title: 'Negative at 31 Dec: unpaid leave in December' }, `UPL ${-b.AL.balance}`) : Math.min(Math.max(0, b.AL.balance), e.days);
    return [h('td', { class: 'num' }, g), h('td', { class: 'num', title: e.basis === 'override' ? `Override: ${k?.cf_override_reason || ''}` : '' }, e.days, e.basis === 'override' ? h('span', { class: 'tag warn', style: 'margin-left:.3rem' }, 'override') : null),
      h('td', { class: 'num strong' }, will)];
  }
  search.addEventListener('input', draw);
  draw();

  function adjust(p) {
    const F = {
      leave_type: field('Leave type', { type: 'select', value: 'AL', options: [['AL', 'Annual'], ['RL', 'Replacement'], ['SL', 'Sick'], ['CPL', 'Compassionate']] }),
      kind: field('What', { type: 'select', value: 'manual', options: [['manual', 'Correction (+ adds, − removes)'], ['earned', 'Replacement leave earned'], ['opening', 'Opening / brought-forward balance'], ['forfeit', 'Forfeit days'], ['buyback', 'Buy back days']] }),
      days: field('Days', { type: 'number', step: '0.5', required: true }),
      buyback_pct: field('Buy-back rate (%)', { type: 'number', value: 100, hint: 'Only for buy-back.' }),
      effective_date: field('Date', { type: 'date', value: asOf }),
      note: field('Reason', { type: 'textarea', span2: true, required: true }),
    };
    openModal({ title: `Adjust leave · ${p.full_name}`, body: h('div', { class: 'form-grid' }, Object.values(F)),
      actions: [{ label: 'Save adjustment', primary: true, onClick: async (close) => {
        const v = Object.fromEntries(Object.entries(F).map(([k, f]) => [k, f.getValue()]));
        if (v.days === null || !v.note) { toast('Days and a reason are required.', 'error'); return false; }
        if (v.kind !== 'buyback') v.buyback_pct = null;
        const { error } = await ctx.sb.from('eppd_leave_adjustments').insert({ ...v, employee_id: p.id, year, source: 'manual' });
        if (failed(error)) return false;
        toast('Adjustment saved.'); close(); window.dispatchEvent(new HashChangeEvent('hashchange')); return true;
      } }] });
  }

  function exportCsv() {
    const head = ['Employee ID', 'Name', 'AL entitled', 'AL carried', 'AL taken', 'AL other', 'AL balance', 'SL entitled', 'SL taken', 'SL balance', 'HPL left', 'CPL left', 'RL balance', 'KPI grade', 'Eligible carry', 'Override reason'];
    const lines = rows.map(({ p, b }) => [p.emp_id || '', p.full_name, b.AL.entitled, b.AL.carried, b.AL.taken, b.AL.adjusted - b.AL.buyback - b.AL.forfeit - b.AL.carriedExpired,
      b.AL.balance, b.SL.entitled, b.SL.taken, b.SL.balance, b.HPL.balance, b.CPL.balance, b.RL.balance, kpi.get(p.id)?.grade || '', elig(p).days, kpi.get(p.id)?.cf_override_reason || ''].map((x) => (/[",]/.test(String(x)) ? `"${String(x).replace(/"/g, '""')}"` : x)).join(','));
    const a = h('a', { href: URL.createObjectURL(new Blob(['﻿' + [head.join(','), ...lines].join('\r\n')], { type: 'text/csv' })), download: `leave-balances-${year}.csv` });
    document.body.append(a); a.click(); a.remove();
  }
}

// ---------------------------------------------------------------- monthly leave records report (v2026.11.10)
// "Month": every leave record in one month per person, the days by type and the balances at the month end.
// "Year by month": one leave type, days taken per person in each month of the year.
const MR_TYPES = ['AL', 'SL', 'RL', 'CPL', 'UPL'];
const OTHER = (t) => !MR_TYPES.includes(t) && t !== 'UPH';
const r2m = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const mEnd = (m) => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1); d.setUTCDate(0); return d.toISOString().slice(0, 10); };
const mLabel = (m) => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-MY', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const dShort = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-MY', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const csvCell = (x) => (/[",\r\n]/.test(String(x ?? '')) ? `"${String(x).replace(/"/g, '""')}"` : (x ?? ''));
function saveCsv(name, head, lines) {
  const a = h('a', { href: URL.createObjectURL(new Blob(['\ufeff' + [head, ...lines].map((l) => l.map(csvCell).join(',')).join('\r\n')], { type: 'text/csv' })), download: name });
  document.body.append(a); a.click(); a.remove();
}

/** Records of one person that start in a month (cancelled ones left out), oldest first. */
export function monthRecords(D, personId, month) {
  const end = mEnd(month);
  return D.records.filter((r) => r.employee_id === personId && r.status !== 'cancelled' && String(r.date_from) >= `${month}-01` && String(r.date_from) <= end)
    .sort((a, b) => String(a.date_from).localeCompare(String(b.date_from)));
}

function monthlyReport(el, ctx, D, year, thisYear, query) {
  const view = query.view;
  const nowM = new Date().toISOString().slice(0, 7);
  const month = /^\d{4}-\d{2}$/.test(query.month || '') && query.month.startsWith(String(year)) ? query.month : (year === thisYear ? nowM : `${year}-12`);
  const type = [...MR_TYPES, 'HPL', 'MTL', 'PTL', 'CCL'].includes(query.type) ? query.type : 'AL';
  const go = (q) => { location.hash = `#/leave/balances?${new URLSearchParams({ year, view, month, type, ...q })}`; };
  const yearSel = h('select', { 'aria-label': 'Year', style: 'width:auto' }, [thisYear - 1, thisYear, thisYear + 1].map((y) => h('option', { value: y, selected: y === year }, y)));
  yearSel.addEventListener('change', () => go({ year: yearSel.value, month: `${yearSel.value}-${month.slice(5)}` }));
  const tabs = h('div', { class: 'seg-tabs' },
    h('a', { class: 'btn sm ghost', href: `#/leave/balances?year=${year}` }, 'Balances'),
    h('button', { type: 'button', class: `btn sm ${view === 'monthly' ? 'primary' : 'ghost'}`, onclick: () => go({ view: 'monthly' }) }, 'Month'),
    h('button', { type: 'button', class: `btn sm ${view === 'grid' ? 'primary' : 'ghost'}`, onclick: () => go({ view: 'grid' }) }, 'Year by month'));
  const search = h('input', { type: 'search', placeholder: 'Search name or ID', 'aria-label': 'Search' });
  const onlyLeave = h('input', { type: 'checkbox' }); onlyLeave.checked = query.all !== '1';
  const body = h('div', { class: 'table-wrap' });
  const people = peopleInYear(D.people, year).sort((a, b) => a.full_name.localeCompare(b.full_name));
  let exportFn = () => {};

  if (view === 'monthly') {
    const monthIn = h('input', { type: 'month', value: month, min: `${year}-01`, max: `${year}-12`, 'aria-label': 'Month', style: 'width:auto' });
    monthIn.addEventListener('change', () => { if (monthIn.value) go({ month: monthIn.value, year: monthIn.value.slice(0, 4) }); });
    el.append(pageHead('Leave balances · monthly report', `Leave records in ${mLabel(month)}, the days by type and each balance at ${fmtD(mEnd(month))}. Cancelled records are left out.`,
      yearSel, monthIn, h('button', { class: 'btn', type: 'button', onclick: () => exportFn() }, 'Export'), h('button', { class: 'btn', type: 'button', onclick: () => window.print() }, 'Print')),
    h('section', { class: 'panel' }, h('div', { class: 'panel-head filters' }, h('div', { class: 'filter-row', style: 'justify-content:flex-start;gap:.6rem;flex-wrap:wrap' }, tabs, search,
      h('label', { class: 'check-row' }, onlyLeave, 'Only people with leave this month'))), body));
    const start = `${month}-01`, end = mEnd(month);
    const rows = people.filter((p) => { const e = p.employment || {}; return (!e.join_date || e.join_date <= end) && (!e.resigned_date || e.resigned_date >= start); })
      .map((p) => { const recs = monthRecords(D, p.id, month); const lm = leaveForMonth(p, D, start);
        const by = (t) => r2m(recs.filter((r) => r.leave_type === t).reduce((s, r) => s + Number(r.days), 0));
        return { p, recs, lm, by, other: r2m(recs.filter((r) => OTHER(r.leave_type)).reduce((s, r) => s + Number(r.days), 0)) }; });
    const draw = () => {
      const q = search.value.trim().toLowerCase();
      const shown = rows.filter((r) => (!onlyLeave.checked || r.recs.length) && (!q || `${r.p.full_name} ${r.p.emp_id}`.toLowerCase().includes(q)));
      clear(body);
      if (!shown.length) { body.append(h('div', { class: 'empty-state' }, onlyLeave.checked ? `No leave recorded in ${mLabel(month)}.` : 'No one to show.')); return; }
      const tot = (f) => r2m(shown.reduce((s, r) => s + f(r), 0));
      body.append(h('table', { class: 'data bal-table' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), h('th', {}, 'Leave records this month'), ...MR_TYPES.map((t) => h('th', { class: 'num' }, t)), h('th', { class: 'num', title: 'Hospitalisation, maternity, paternity, company closure' }, 'Other'),
          h('th', { class: 'num' }, 'AL taken to date'), h('th', { class: 'num' }, 'AL balance'), h('th', { class: 'num' }, 'SL balance'), h('th', { class: 'num' }, 'RL balance'))),
        h('tbody', {}, shown.map(({ p, recs, lm, by, other }) => h('tr', {},
          h('td', {}, h('a', { href: `#/employees/${p.id}?tab=leave`, class: 'row-link' }, p.full_name), h('div', { class: 'small muted' }, [p.emp_id, p.department_code].filter(Boolean).join(' · '))),
          h('td', { class: 'small' }, recs.length ? h('ul', { class: 'plain', style: 'margin:0;padding-left:1rem' }, recs.map((r) => h('li', {},
            `${LEAVE_LABELS[r.leave_type] || r.leave_type} · ${r.source === 'import' ? 'month total (workbook)' : r.date_from === r.date_to ? dShort(r.date_from) : `${dShort(r.date_from)} – ${dShort(r.date_to)}`} · `,
            h('b', {}, r.leave_type === 'UPH' ? `${Number(r.hours || 0)} h` : `${Number(r.days)} d`), r.half_day && r.half_day !== 'none' ? ` (${r.half_day.toUpperCase()})` : '',
            r.note ? h('span', { class: 'muted' }, ` — ${r.note}`) : null))) : h('span', { class: 'muted' }, '—')),
          ...MR_TYPES.map((t) => h('td', { class: 'num' }, by(t) || '')), h('td', { class: 'num' }, other || ''),
          h('td', { class: 'num' }, lm.AL.toDate || ''), h('td', { class: `num strong ${lm.AL.balance < 0 ? 'neg' : ''}` }, lm.AL.balance),
          h('td', { class: `num ${lm.SL.balance < 0 ? 'neg' : ''}` }, lm.SL.balance), h('td', { class: `num ${lm.RL.balance < 0 ? 'neg' : ''}` }, lm.RL.balance || '')))),
        h('tfoot', {}, h('tr', {}, h('th', {}, `${shown.length} people`), h('th', {}, `${tot((r) => r.recs.length)} record(s)`), ...MR_TYPES.map((t) => h('th', { class: 'num' }, tot((r) => r.by(t)) || '')),
          h('th', { class: 'num' }, tot((r) => r.other) || ''), h('th', {}), h('th', {}), h('th', {}), h('th', {})))));
      exportFn = () => saveCsv(`leave-${month}.csv`, ['Employee ID', 'Name', 'Department', 'Leave type', 'From', 'To', 'Days', 'Hours', 'Note', 'AL balance at month end', 'SL balance at month end', 'RL balance at month end'],
        shown.flatMap(({ p, recs, lm }) => (recs.length ? recs : [null]).map((r) => [p.emp_id || '', p.full_name, p.department_code || '', r ? (LEAVE_LABELS[r.leave_type] || r.leave_type) : '', r?.date_from || '', r?.date_to || '',
          r ? Number(r.days) : '', r?.hours || '', r?.note || '', lm.AL.balance, lm.SL.balance, lm.RL.balance])));
    };
    search.addEventListener('input', draw); onlyLeave.addEventListener('change', draw); draw();
    return;
  }

  // year by month
  const typeSel = h('select', { 'aria-label': 'Leave type', style: 'width:auto' }, [...MR_TYPES, 'HPL', 'MTL', 'PTL', 'CCL'].map((t) => h('option', { value: t, selected: t === type }, LEAVE_LABELS[t] || t)));
  typeSel.addEventListener('change', () => go({ type: typeSel.value }));
  el.append(pageHead('Leave balances · year by month', `${LEAVE_LABELS[type] || type} leave taken in each month of ${year}, by the month the leave starts. Cancelled records are left out.`,
    yearSel, typeSel, h('button', { class: 'btn', type: 'button', onclick: () => exportFn() }, 'Export'), h('button', { class: 'btn', type: 'button', onclick: () => window.print() }, 'Print')),
  h('section', { class: 'panel' }, h('div', { class: 'panel-head filters' }, h('div', { class: 'filter-row', style: 'justify-content:flex-start;gap:.6rem;flex-wrap:wrap' }, tabs, search,
    h('label', { class: 'check-row' }, onlyLeave, 'Only people with this leave'))), body));
  const months = Array.from({ length: 12 }, (_, i) => `${year}-${String(i + 1).padStart(2, '0')}`);
  const rows = people.map((p) => {
    const recs = D.records.filter((r) => r.employee_id === p.id && r.status !== 'cancelled' && r.leave_type === type);
    const per = months.map((m) => r2m(recs.filter((r) => String(r.date_from).slice(0, 7) === m).reduce((s, r) => s + Number(r.days), 0)));
    const b = balancesFor(p, D, year < thisYear ? `${year}-12-31` : new Date().toISOString().slice(0, 10));
    return { p, per, total: r2m(per.reduce((s, x) => s + x, 0)), bal: b[type]?.balance ?? null };
  });
  const draw = () => {
    const q = search.value.trim().toLowerCase();
    const shown = rows.filter((r) => (!onlyLeave.checked || r.total) && (!q || `${r.p.full_name} ${r.p.emp_id}`.toLowerCase().includes(q)));
    clear(body);
    if (!shown.length) { body.append(h('div', { class: 'empty-state' }, 'No one to show.')); return; }
    const mShort = (m) => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-MY', { month: 'short', timeZone: 'UTC' });
    body.append(h('table', { class: 'data bal-table' },
      h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), ...months.map((m) => h('th', { class: 'num' }, h('a', { href: `#/leave/balances?year=${year}&view=monthly&month=${m}`, title: `Records in ${mLabel(m)}` }, mShort(m)))),
        h('th', { class: 'num' }, 'Total'), h('th', { class: 'num' }, 'Balance now'))),
      h('tbody', {}, shown.map(({ p, per, total, bal }) => h('tr', {},
        h('td', {}, h('a', { href: `#/employees/${p.id}?tab=leave`, class: 'row-link' }, p.full_name), h('div', { class: 'small muted' }, [p.emp_id, p.department_code].filter(Boolean).join(' · '))),
        ...per.map((x) => h('td', { class: 'num' }, x || '')), h('td', { class: 'num strong' }, total || ''), h('td', { class: `num ${bal < 0 ? 'neg' : ''}` }, bal ?? '')))),
      h('tfoot', {}, h('tr', {}, h('th', {}, `${shown.length} people`), ...months.map((_, i) => h('th', { class: 'num' }, r2m(shown.reduce((s, r) => s + r.per[i], 0)) || '')),
        h('th', { class: 'num' }, r2m(shown.reduce((s, r) => s + r.total, 0)) || ''), h('th', {})))));
    exportFn = () => saveCsv(`leave-${type}-${year}-by-month.csv`, ['Employee ID', 'Name', 'Department', ...months, 'Total', 'Balance'],
      shown.map(({ p, per, total, bal }) => [p.emp_id || '', p.full_name, p.department_code || '', ...per, total, bal ?? '']));
  };
  search.addEventListener('input', draw); onlyLeave.addEventListener('change', draw); draw();
}
const fmtD = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-MY', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
