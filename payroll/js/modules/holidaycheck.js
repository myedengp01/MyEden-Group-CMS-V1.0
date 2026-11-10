// Holiday checks (v2026.11.10)
// 1. Replacement leave: a public holiday on a rest / off day earns a replacement day. For each such holiday, everyone employed that
//    day with the replacement leave already earned in that month; HR marks each person granted (adds the replacement leave),
//    already handled or not entitled (e.g. non-operation HQ staff). Decisions are kept and logged (cms_rl_check_set).
// 2. Leave over holidays: leave records whose dates include a public holiday or a company closure day and whose days are more than
//    the working days in them (e.g. recorded before the holiday list was loaded). HR can recount a record; nothing changes by itself.
import { h, clear, pageHead, toast, failed, fmtDate, confirmDialog } from '../ui.js';
import { loadLeaveYear, loadHolidaySet, LEAVE_LABELS, peopleInYear } from '../leave-data.js';
import { countLeaveDays } from '../engines/leave.js';
import { todayIso } from '../engines/employee.js';

const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const dow = (d) => new Date(`${d}T00:00:00Z`).getUTCDay();
const wd = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-MY', { weekday: 'long', timeZone: 'UTC' });
const monthName = (d) => new Date(`${d.slice(0, 7)}-01T00:00:00Z`).toLocaleDateString('en-MY', { month: 'short', year: 'numeric', timeZone: 'UTC' });
const DEC = { granted: ['Granted', 'ok'], handled: ['Already handled', ''], not_entitled: ['Not entitled', 'warn'] };
const COUNTED = ['AL', 'SL', 'HPL', 'RL', 'CPL', 'UPL'];

/** Holidays of the year that fall on a rest or off day: [{date, name, day}] */
export function restDayHolidays(rows, ww) {
  const skip = new Set([...(ww?.rest_days ?? [0]), ...(ww?.off_days ?? [6])]);
  return rows.filter((x) => skip.has(dow(x.holiday_date))).map((x) => ({ date: x.holiday_date, name: x.name, day: (ww?.rest_days ?? [0]).includes(dow(x.holiday_date)) ? 'rest day' : 'off day' }));
}

/** Leave records whose days are more than the working days in their dates. */
export function overHolidays(records, holidays, ww) {
  const out = [];
  for (const r of records) {
    if (r.status === 'cancelled' || r.source === 'import' || !COUNTED.includes(r.leave_type) || r.details?.closure_id) continue;
    const inside = []; for (let t = Date.parse(`${r.date_from}T00:00:00Z`); t <= Date.parse(`${r.date_to || r.date_from}T00:00:00Z`); t += 864e5) { const d = new Date(t).toISOString().slice(0, 10); if (holidays.has(d)) inside.push(d); }
    if (!inside.length) continue;
    const n = countLeaveDays(r.date_from, r.date_to || r.date_from, { holidays, restDays: ww?.rest_days, offDays: ww?.off_days, halfDay: r.half_day });
    if (Number(r.days) > n) out.push({ r, inside, recount: n });
  }
  return out;
}

export async function render(el, ctx, params, query) {
  const canEdit = ctx.can(['leave.edit']);
  const year = Number(query.year) || Number(todayIso().slice(0, 4));
  const tab = query.tab === 'records' ? 'records' : 'rl';
  const go = (q) => { location.hash = `#/leave/holiday-check?${new URLSearchParams({ year, tab, ...q })}`; };
  const [D, holSet, hr, ck] = await Promise.all([
    loadLeaveYear(ctx.sb, year, { provisional: false }), loadHolidaySet(ctx.sb, [year]),
    ctx.sb.from('eppd_holidays').select('holiday_date,name').eq('is_active', true).gte('holiday_date', `${year}-01-01`).lte('holiday_date', `${year}-12-31`).order('holiday_date'),
    ctx.sb.from('cms_rl_checks').select('*').gte('holiday_date', `${year}-01-01`).lte('holiday_date', `${year}-12-31`)]);
  const ww = D.ref.policies.working_week || { rest_days: [0], off_days: [6] };
  const checks = new Map((ck.data || []).map((x) => [`${x.holiday_date}|${x.employee_id}`, x]));

  const yearSel = h('select', { 'aria-label': 'Year', style: 'width:auto' }, [year - 1, year, year + 1].map((y) => h('option', { value: y, selected: y === year }, y)));
  yearSel.addEventListener('change', () => go({ year: yearSel.value }));
  const tabs = h('div', { class: 'seg-tabs' },
    h('button', { type: 'button', class: `btn sm ${tab === 'rl' ? 'primary' : 'ghost'}`, onclick: () => go({ tab: 'rl' }) }, 'Replacement leave'),
    h('button', { type: 'button', class: `btn sm ${tab === 'records' ? 'primary' : 'ghost'}`, onclick: () => go({ tab: 'records' }) }, 'Leave over holidays'));
  el.append(pageHead('Holiday checks', tab === 'rl'
    ? `Public holidays in ${year} that fell on a rest or off day, and whether each person has had the replacement day. Mark each person: grant (adds the replacement leave), already handled, or not entitled.`
    : `Leave in ${year} recorded with more days than the working days in its dates, because the dates include a public holiday or a company closure day. Recount a record to correct the balance.`,
  yearSel), h('div', { style: 'margin-bottom:.8rem' }, tabs));
  const box = h('section', { class: 'panel' }); el.append(box);
  if (!(hr.data || []).length) { box.append(h('div', { class: 'empty-state' }, `No public holidays entered for ${year}. Add them on the Public holidays page first.`)); return; }
  if (tab === 'rl') rlTab(); else recTab();

  function rlTab() {
    const hols = restDayHolidays(hr.data || [], ww);
    if (!hols.length) { box.append(h('div', { class: 'empty-state' }, `No public holiday fell on a rest or off day in ${year}.`)); return; }
    const st = { hol: hols.some((x) => x.date === query.hol) ? query.hol : hols[0].date, show: query.show === 'all' ? 'all' : 'open', sel: new Set() };
    const holSel = h('select', { style: 'width:auto', 'aria-label': 'Holiday' }, hols.map((x) => h('option', { value: x.date, selected: x.date === st.hol }, `${fmtDate(x.date)} · ${x.name} (${x.day})`)));
    holSel.addEventListener('change', () => go({ hol: holSel.value, show: st.show }));
    const showSel = h('select', { style: 'width:auto', 'aria-label': 'Show' }, [['open', 'Needs a decision'], ['all', 'Everyone']].map(([k, l]) => h('option', { value: k, selected: k === st.show }, l)));
    showSel.addEventListener('change', () => go({ hol: st.hol, show: showSel.value }));
    const H = hols.find((x) => x.date === st.hol);
    const ms = `${st.hol.slice(0, 7)}-01`, me = `${st.hol.slice(0, 7)}-31`;
    const list = peopleInYear(D.people, year).filter((p) => { const e = p.employment || {}; return (!e.join_date || e.join_date <= st.hol) && (!e.resigned_date || e.resigned_date >= st.hol); })
      .map((p) => ({ p, ck: checks.get(`${st.hol}|${p.id}`) || null,
        earned: r2(D.adjustments.filter((a) => a.employee_id === p.id && a.leave_type === 'RL' && a.kind === 'earned' && String(a.effective_date || '') >= ms && String(a.effective_date || '') <= me).reduce((s, a) => s + Number(a.days), 0)) }))
      .sort((a, b) => (a.earned ? 1 : 0) - (b.earned ? 1 : 0) || String(a.p.department_code || '').localeCompare(String(b.p.department_code || '')) || a.p.full_name.localeCompare(b.p.full_name));
    const shown = list.filter((x) => st.show === 'all' || !x.ck);
    const eff = h('input', { type: 'date', value: st.hol, style: 'width:auto', 'aria-label': 'Replacement leave date' });
    const daysIn = h('input', { type: 'number', value: 1, min: 0.5, step: 0.5, style: 'width:4.5rem', 'aria-label': 'Days' });
    const note = h('input', { type: 'text', placeholder: 'Note (optional)', style: 'min-width:12rem' });
    const count = h('b', {}, '0 selected');
    const body = h('div', { class: 'table-wrap' });
    box.append(h('div', { class: 'panel-head filters' }, h('div', { class: 'filter-row', style: 'justify-content:flex-start;gap:.6rem;flex-wrap:wrap' }, holSel, showSel)),
      h('p', { class: 'small muted', style: 'padding:0 1rem' }, `${H.name} fell on ${wd(H.date)} (${H.day}). "Earned in ${monthName(H.date)}" is the replacement leave already recorded for that month, e.g. from the payroll workbook — someone with a day there has most likely had it.`),
      body,
      canEdit ? h('div', { class: 'panel-foot', style: 'display:flex;gap:.5rem;align-items:center;flex-wrap:wrap' }, count,
        h('button', { class: 'btn primary sm', type: 'button', onclick: () => save('granted') }, 'Grant'), daysIn, 'day(s) dated', eff,
        h('button', { class: 'btn sm', type: 'button', onclick: () => save('handled') }, 'Already handled'),
        h('button', { class: 'btn sm', type: 'button', onclick: () => save('not_entitled') }, 'Not entitled'), note) : null);
    if (!shown.length) { body.append(h('div', { class: 'empty-state' }, st.show === 'open' ? 'Everyone has a decision for this holiday.' : 'No one was employed on this day.')); return; }
    const all = h('input', { type: 'checkbox', 'aria-label': 'Select all', disabled: !canEdit });
    const boxes = [];
    all.addEventListener('change', () => { boxes.forEach(([b, id]) => { if (!b.disabled) { b.checked = all.checked; if (all.checked) st.sel.add(id); else st.sel.delete(id); } }); count.textContent = `${st.sel.size} selected`; });
    body.append(h('table', { class: 'data' },
      h('thead', {}, h('tr', {}, h('th', {}, all), ['Employee', 'Department', `Earned in ${monthName(H.date)}`, 'Decision'].map((t) => h('th', {}, t)))),
      h('tbody', {}, shown.map(({ p, ck: c, earned }) => {
        const b = h('input', { type: 'checkbox', disabled: !canEdit || c?.decision === 'granted' });
        b.addEventListener('change', () => { if (b.checked) st.sel.add(p.id); else st.sel.delete(p.id); count.textContent = `${st.sel.size} selected`; });
        boxes.push([b, p.id]);
        return h('tr', {}, h('td', {}, b),
          h('td', {}, h('a', { href: `#/employees/${p.id}?tab=leave`, class: 'row-link' }, p.full_name), h('div', { class: 'small muted' }, [p.emp_id, p.job_title].filter(Boolean).join(' · '))),
          h('td', {}, p.department_code || '—', p.company_name ? h('div', { class: 'small muted' }, p.company_name) : null),
          h('td', { class: 'num' }, earned ? `${earned} day(s)` : h('span', { class: 'muted' }, 'none')),
          h('td', {}, c ? h('span', {}, h('span', { class: `tag ${DEC[c.decision][1]}` }, DEC[c.decision][0]), c.decision === 'granted' ? ` ${r2(c.days)} day(s) dated ${fmtDate(c.effective_date)}` : '',
            h('div', { class: 'small muted' }, [c.decided_by_name, fmtDate(c.decided_at), c.note].filter(Boolean).join(' · '))) : h('span', { class: 'muted' }, '—')));
      }))));
    async function save(decision) {
      if (!st.sel.size) { toast('Tick the people first.', 'error'); return; }
      if (decision === 'granted' && !(Number(daysIn.value) > 0)) { toast('Days must be more than 0.', 'error'); return; }
      const who = list.filter((x) => st.sel.has(x.p.id));
      const what = decision === 'granted' ? `grant ${daysIn.value} day(s) of replacement leave dated ${fmtDate(eff.value)} to` : decision === 'handled' ? 'mark as already handled' : 'mark as not entitled';
      if (!(await confirmDialog('Replacement leave', `${what[0].toUpperCase()}${what.slice(1)} ${who.length} people for ${H.name} (${fmtDate(H.date)})?`, 'Save'))) return;
      const items = who.map((x) => ({ holiday_date: H.date, holiday_name: H.name, employee_id: x.p.id, name: x.p.full_name, decision, days: decision === 'granted' ? Number(daysIn.value) : null,
        effective_date: decision === 'granted' ? eff.value : null, note: note.value.trim() || null }));
      const { data, error } = await ctx.sb.rpc('cms_rl_check_set', { p: { items } });
      if (failed(error)) return;
      toast(`${data.saved} saved${data.granted ? `, ${data.granted} granted` : ''}.`); go({ hol: st.hol, show: st.show });
    }
  }

  function recTab() {
    const rows = overHolidays(D.records, holSet, ww);
    const byId = new Map(D.people.map((p) => [p.id, p]));
    if (!rows.length) { box.append(h('div', { class: 'empty-state' }, `No leave in ${year} counts a public holiday or closure day.`)); return; }
    box.append(h('div', { class: 'table-wrap' }, h('table', { class: 'data' },
      h('thead', {}, h('tr', {}, ['Employee', 'Leave', 'Dates', 'Holidays inside', 'Days recorded', 'Working days', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map(({ r, inside, recount }) => { const p = byId.get(r.employee_id); return h('tr', {},
        h('td', {}, p?.full_name || r.employee_id, h('div', { class: 'small muted' }, p?.emp_id || '')),
        h('td', {}, LEAVE_LABELS[r.leave_type] || r.leave_type),
        h('td', { class: 'nowrap' }, r.date_from === r.date_to ? fmtDate(r.date_from) : `${fmtDate(r.date_from)} – ${fmtDate(r.date_to)}`),
        h('td', { class: 'small' }, inside.map((d) => fmtDate(d)).join(', ')),
        h('td', { class: 'num strong' }, Number(r.days), r.days_override ? h('span', { class: 'small muted', title: 'Typed by HR' }, ' *') : null),
        h('td', { class: 'num' }, recount),
        h('td', { class: 'actions' }, canEdit ? h('button', { class: 'btn sm', type: 'button', onclick: () => fix(r, recount, p) }, `Use ${recount}`) : null)); })))),
    h('div', { class: 'panel-foot small muted' }, `${rows.length} record(s). * = days typed by HR. Recounting changes only that record; the change is noted on it.`));
  }
  async function fix(r, n, p) {
    if (!(await confirmDialog('Recount leave', `${p?.full_name || ''}: change ${LEAVE_LABELS[r.leave_type] || r.leave_type} ${fmtDate(r.date_from)}${r.date_to !== r.date_from ? ` – ${fmtDate(r.date_to)}` : ''} from ${Number(r.days)} to ${n} day(s)?`, 'Recount'))) return;
    const { error } = await ctx.sb.from('eppd_leave_records').update({ days: n, days_override: false, note: `${r.note ? `${r.note} · ` : ''}Recounted for public holidays ${todayIso()}: ${Number(r.days)} → ${n}` }).eq('id', r.id);
    if (failed(error)) return;
    toast('Leave recounted.'); go({ tab: 'records' });
  }
}
