// Company closure days (v2026.11.10): days the company is closed outside the public holidays (e.g. students still on holiday
// after the staff holidays). The working days are split into free days (company paid leave, nothing deducted) and days taken from
// annual leave. Everyone in scope gets the leave records in one go; HR can set exceptions per person (on duty, excluded, another split).
// When the AL balance cannot cover the AL days, the shortfall is unpaid leave by default; Admin / Director may make it free or borrowed
// from next year's annual leave. Applying and cancelling run on the server (cms_closure_apply / cms_closure_cancel) and are logged.
import { h, clear, pageHead, toast, failed, fmtDate, openModal, confirmDialog } from '../ui.js';
import { loadLeaveYear, balancesFor } from '../leave-data.js';

const DAY = 864e5;
const iso = (t) => new Date(t).toISOString().slice(0, 10);
const days = (a, b) => { const o = []; for (let t = Date.parse(`${a}T00:00:00Z`); t <= Date.parse(`${b}T00:00:00Z`); t += DAY) o.push(iso(t)); return o; };
const dow = (d) => new Date(`${d}T00:00:00Z`).getUTCDay();
const wd = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-MY', { weekday: 'short', timeZone: 'UTC' });
const short = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-MY', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
const STATUS = { draft: ['Draft', 'warn'], applied: ['Applied', 'ok'], cancelled: ['Cancelled', ''] };
const MODES = [['split', 'Closure split'], ['custom', 'Own split'], ['duty', 'On duty (no leave)'], ['excluded', 'Excluded']];
const SHORT = [['unpaid', 'Unpaid leave'], ['borrow', "Borrow next year's AL"], ['free', 'Make free']];

/** Working days of a closure: not a rest / off day and not a public holiday. */
export function workingDays(from, to, holidays, ww) {
  const skip = new Set([...(ww?.rest_days ?? [0]), ...(ww?.off_days ?? [6])]);
  return days(from, to).filter((d) => !skip.has(dow(d)) && !holidays.has(d));
}

/** One person's outcome: AL days covered by the balance first, the rest follow the shortfall choice. */
export function personPlan({ mode, freeCount, shortfall }, closure, work, balance) {
  let free = [], al = [];
  if (mode === 'split') { free = closure.free_dates || []; al = closure.al_dates || []; }
  else if (mode === 'custom') { const k = Math.max(0, Math.min(work.length, Number(freeCount) || 0)); free = work.slice(0, k); al = work.slice(k); }
  const cover = Math.min(al.length, Math.max(0, Math.floor(balance ?? al.length)));
  const shortDays = al.length - cover;
  // borrowed days are added to this year's AL and taken off next year's, so this year's balance after is the same as with unpaid
  const after = balance == null ? null : r2(balance - cover);
  return { free, al, cover, shortDays, after };
}

export async function render(el, ctx, params, query) {
  const canEdit = ctx.can(['leave.edit']);
  const boss = ctx.can(['boss']);
  const { data: rows, error } = await ctx.sb.from('cms_closures').select('*').order('date_from', { ascending: false });
  if (error) { el.append(h('div', { class: 'empty-state' }, `Company closures could not be loaded: ${error.message}`)); return; }
  if (query.id || query.new) return editor(el, ctx, (rows || []).find((r) => r.id === query.id) || null, { canEdit, boss });

  el.append(pageHead('Company closure days',
    'Days the company is closed outside the public holidays, e.g. when students are still on holiday after the staff holidays. Each working day is either free (company paid leave) or taken from annual leave; the leave records are created for everyone in scope when you apply it.',
    canEdit ? h('a', { class: 'btn primary', href: '#/leave/closures?new=1' }, 'New closure') : null));
  const body = h('div', { class: 'table-wrap' });
  el.append(h('section', { class: 'panel' }, body));
  if (!rows?.length) { body.append(h('div', { class: 'empty-state' }, 'No company closures yet.')); return; }
  body.append(h('table', { class: 'data' },
    h('thead', {}, h('tr', {}, ['Closure', 'Dates', 'Free days', 'AL days', 'Scope', 'Status', ''].map((t) => h('th', {}, t)))),
    h('tbody', {}, rows.map((c) => h('tr', {},
      h('td', {}, h('b', {}, c.title), c.note ? h('div', { class: 'small muted' }, c.note) : null),
      h('td', { class: 'nowrap' }, `${fmtDate(c.date_from)} – ${fmtDate(c.date_to)}`),
      h('td', {}, (c.free_dates || []).map(short).join(', ') || '—'),
      h('td', {}, (c.al_dates || []).map(short).join(', ') || '—'),
      h('td', { class: 'small' }, scopeText(c.scope)),
      h('td', {}, h('span', { class: `tag ${STATUS[c.status]?.[1] || ''}` }, STATUS[c.status]?.[0] || c.status),
        c.applied_summary ? h('div', { class: 'small muted' }, summaryText(c.applied_summary)) : null),
      h('td', { class: 'actions' }, h('a', { class: 'btn sm', href: `#/leave/closures?id=${c.id}` }, c.status === 'draft' && canEdit ? 'Open' : 'View')))))));
}

const scopeText = (s) => { const c = s?.companies || [], d = s?.departments || []; return !c.length && !d.length ? 'All staff' : [c.join(', '), d.join(', ')].filter(Boolean).join(' · '); };
const summaryText = (s) => `${s.people} people · ${s.free} free · ${s.al} AL${s.unpaid ? ` · ${s.unpaid} unpaid` : ''}${s.borrowed ? ` · ${s.borrowed} borrowed` : ''}${s.made_free ? ` · ${s.made_free} made free` : ''}`;

async function editor(el, ctx, c, { canEdit, boss }) {
  const draft = !c || c.status === 'draft';
  const editable = canEdit && draft;
  const st = { title: c?.title || '', from: c?.date_from || '', to: c?.date_to || '', note: c?.note || '',
               companies: new Set(c?.scope?.companies || []), departments: new Set(c?.scope?.departments || []),
               free: new Set(c?.free_dates || []), al: new Set(c?.al_dates || []) };
  const yearOf = () => Number((st.from || new Date().toISOString()).slice(0, 4));
  let D = null, Dyear = null, hol = new Set(), people = [], applied = [];
  const ww = () => D?.ref?.policies?.working_week || { rest_days: [0], off_days: [6] };
  const per = new Map();     // employee id -> { mode, freeCount, shortfall, note }

  async function load() {
    const y = yearOf();
    if (Dyear !== y) {
      D = await loadLeaveYear(ctx.sb, y); Dyear = y;
      const { data } = await ctx.sb.from('eppd_holidays').select('holiday_date').eq('is_active', true).gte('holiday_date', `${y - 1}-01-01`).lte('holiday_date', `${y + 1}-12-31`);
      hol = new Set((data || []).map((x) => x.holiday_date));
    }
    if (c && c.status !== 'draft') {
      const { data } = await ctx.sb.from('cms_closure_people').select('*').eq('closure_id', c.id).order('name');
      applied = data || [];
    }
  }
  await load();
  const companies = [...new Set(D.people.map((p) => p.company_name).filter(Boolean))].sort();
  const departments = [...new Set(D.people.map((p) => p.department_code).filter(Boolean))].sort();

  const head = pageHead(c ? c.title : 'New company closure', c ? `${fmtDate(c.date_from)} – ${fmtDate(c.date_to)} · ${STATUS[c.status]?.[0] || c.status}` : 'Dates, how the working days are split, and who it applies to.',
    h('a', { class: 'btn', href: '#/leave/closures' }, 'All closures'));
  const form = h('section', { class: 'panel', style: 'padding:1rem' });
  const prev = h('section', { class: 'panel' });
  el.append(head, form, prev);

  const inp = (type, val, on, attrs = {}) => { const i = h('input', { type, disabled: !editable, ...attrs }); i.value = val; i.addEventListener('change', () => on(i.value)); return i; };

  function drawForm() {
    clear(form);
    const work = st.from && st.to && st.to >= st.from ? workingDays(st.from, st.to, hol, ww()) : [];
    // keep the split inside the working days; new days default to AL
    for (const d of [...st.free]) if (!work.includes(d)) st.free.delete(d);
    for (const d of [...st.al]) if (!work.includes(d)) st.al.delete(d);
    for (const d of work) if (!st.free.has(d) && !st.al.has(d)) st.al.add(d);
    const all = st.from && st.to && st.to >= st.from ? days(st.from, st.to) : [];
    form.append(
      h('div', { class: 'form-grid' },
        h('label', { class: 'field span-2' }, 'Title', inp('text', st.title, (v) => { st.title = v; }, { placeholder: 'e.g. CNY company closure 2027' })),
        h('label', { class: 'field' }, 'First day', inp('date', st.from, async (v) => { st.from = v; if (!st.to || st.to < v) st.to = v; await load(); drawForm(); drawPreview(); })),
        h('label', { class: 'field' }, 'Last day', inp('date', st.to, (v) => { st.to = v; drawForm(); drawPreview(); })),
        h('label', { class: 'field span-2' }, 'Note (optional)', inp('text', st.note, (v) => { st.note = v; }))),
      all.length ? h('div', { style: 'margin-top:1rem' },
        h('h3', { style: 'margin:0 0 .4rem' }, `${work.length} working day${work.length === 1 ? '' : 's'}`),
        h('p', { class: 'small muted', style: 'margin:0 0 .6rem' }, 'Saturdays, Sundays and public holidays are not counted. Click a working day to switch it between free and annual leave.'),
        h('div', { class: 'cl-days' }, all.map((d) => {
          const isWork = work.includes(d); const free = st.free.has(d);
          const why = !isWork ? (hol.has(d) ? 'Public holiday' : 'Rest / off day') : free ? 'Free' : 'Annual leave';
          return h('button', { type: 'button', class: `cl-day ${!isWork ? 'off' : free ? 'free' : 'al'}`, disabled: !isWork || !editable,
            title: `${fmtDate(d)} · ${why}`, onclick: () => { if (free) { st.free.delete(d); st.al.add(d); } else { st.al.delete(d); st.free.add(d); } drawForm(); drawPreview(); } },
          h('b', {}, short(d)), h('small', {}, wd(d)), h('span', {}, why));
        })),
        h('p', { style: 'margin:.6rem 0 0' }, h('b', {}, `${st.free.size} free`), ' (company paid leave) · ', h('b', {}, `${st.al.size} from annual leave`),
          editable && work.length ? h('span', { class: 'small muted' }, ' · quick split: ',
            work.map((_, k) => k).concat(work.length).map((k) => h('button', { type: 'button', class: 'linkish', style: 'margin:0 .25rem',
              onclick: () => { st.free = new Set(work.slice(0, k)); st.al = new Set(work.slice(k)); drawForm(); drawPreview(); } }, `${k} free`))) : null)) : null,
      h('div', { style: 'margin-top:1rem' }, h('h3', { style: 'margin:0 0 .4rem' }, 'Applies to'),
        h('p', { class: 'small muted', style: 'margin:0 0 .4rem' }, 'Nothing ticked = all staff. Ticking companies and/or departments limits it to those.'),
        h('div', { class: 'cl-scope' }, h('b', {}, 'Companies'), companies.map((x) => tick(x, st.companies))),
        h('div', { class: 'cl-scope' }, h('b', {}, 'Departments'), departments.map((x) => tick(x, st.departments)))),
      editable ? h('div', { style: 'margin-top:1rem;display:flex;gap:.5rem' }, h('button', { class: 'btn primary', type: 'button', onclick: save }, c ? 'Save changes' : 'Save draft')) : null);
  }
  function tick(x, set) {
    const i = h('input', { type: 'checkbox', disabled: !editable }); i.checked = set.has(x);
    i.addEventListener('change', () => { if (i.checked) set.add(x); else set.delete(x); drawPreview(); });
    return h('label', { class: 'check-row' }, i, x);
  }
  async function save() {
    if (!st.title.trim() || !st.from || !st.to) { toast('Give a title and the closure dates.', 'error'); return; }
    const { data, error } = await ctx.sb.rpc('cms_closure_save', { p: { id: c?.id || null, title: st.title, date_from: st.from, date_to: st.to, note: st.note,
      scope: { companies: [...st.companies], departments: [...st.departments] }, free_dates: [...st.free].sort(), al_dates: [...st.al].sort() } });
    if (failed(error)) return;
    toast('Closure saved. Check the people below, then apply it.');
    location.hash = `#/leave/closures?id=${data.id}`; window.dispatchEvent(new HashChangeEvent('hashchange'));
  }

  function inScope(p) {
    const e = p.employment; if (!e || !st.from || !st.to) return false;
    if (e.join_date && e.join_date > st.to) return false;
    if (e.resigned_date && e.resigned_date < st.from) return false;
    if (!e.resigned_date && p.status?.key === 'former') return false;
    if (st.companies.size && !st.companies.has(p.company_name)) return false;
    if (st.departments.size && !st.departments.has(p.department_code)) return false;
    return true;
  }

  function drawPreview() {
    clear(prev);
    if (c && c.status !== 'draft') return drawApplied();
    if (!c) { prev.append(h('div', { class: 'empty-state' }, 'Save the draft to see who it applies to.')); return; }
    const work = workingDays(st.from, st.to, hol, ww());
    const closure = { free_dates: [...st.free].sort(), al_dates: [...st.al].sort() };
    people = D.people.filter(inScope).sort((a, b) => a.full_name.localeCompare(b.full_name));
    const rows = people.map((p) => {
      const o = per.get(p.id) || { mode: 'split', freeCount: closure.free_dates.length, shortfall: 'unpaid', note: '' };
      per.set(p.id, o);
      const e = p.employment || {};
      const part = (e.join_date && e.join_date > st.from) || (e.resigned_date && e.resigned_date < st.to);
      const bal = balancesFor(p, D, st.from).AL.balance;
      return { p, o, bal, part, plan: personPlan(o, closure, work, bal) };
    });
    const tot = rows.reduce((t, r) => { if (['split', 'custom'].includes(r.o.mode)) { t.n += 1; t.free += r.plan.free.length; t.al += r.plan.cover; t.short += r.plan.shortDays; } return t; }, { n: 0, free: 0, al: 0, short: 0 });
    const changed = (fn) => (e) => { fn(e.target.value); drawPreview(); };
    prev.append(h('div', { class: 'panel-head', style: 'padding:1rem 1rem 0' },
      h('h3', { style: 'margin:0' }, `Who it applies to · ${people.length} people`),
      h('p', { class: 'small muted', style: 'margin:.3rem 0 0' }, `Annual leave balance as at ${fmtDate(st.from)} (same rules as Leave balances). AL days are covered by the balance first; a shortfall is unpaid leave unless Admin / Director chooses otherwise.`)),
    h('div', { class: 'table-wrap' }, h('table', { class: 'data' },
      h('thead', {}, h('tr', {}, ['Employee', 'Choice', 'Free', 'AL', 'AL balance', 'Short', 'Shortfall', 'AL after', 'Note'].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map(({ p, o, bal, part, plan }) => {
        const active = ['split', 'custom'].includes(o.mode);
        const sel = (opts, v, on, dis) => h('select', { disabled: dis || !editable, style: 'width:auto' }, opts.map(([k, l]) => h('option', { value: k, selected: k === v }, l)));
        const mode = sel(MODES, o.mode); mode.addEventListener('change', changed((v) => { o.mode = v; }));
        const fc = h('input', { type: 'number', min: 0, max: work.length, step: 1, style: 'width:4.5rem', disabled: !editable, title: 'Free days for this person (the first working days)' });
        fc.value = o.freeCount; fc.addEventListener('change', changed((v) => { o.freeCount = Number(v); }));
        const sh = sel(SHORT, o.shortfall, null, !boss || !plan.shortDays); sh.addEventListener('change', changed((v) => { o.shortfall = v; }));
        if (!boss) sh.title = 'Only Admin or Director can change this';
        const nt = h('input', { type: 'text', style: 'min-width:8rem', disabled: !editable, placeholder: o.mode === 'duty' ? 'e.g. on duty at E10' : '' }); nt.value = o.note || '';
        nt.addEventListener('change', () => { o.note = nt.value; });
        const after = !active || bal == null ? '' : plan.after;
        return h('tr', { class: active ? '' : 'muted' },
          h('td', { style: 'min-width:14rem' }, h('b', {}, p.full_name), h('div', { class: 'small muted' }, [p.emp_id, p.company_name, p.department_code, part ? 'joins / leaves during the closure' : null].filter(Boolean).join(' · '))),
          h('td', {}, mode, o.mode === 'custom' ? h('div', { class: 'small', style: 'margin-top:.3rem' }, fc, ' free') : null),
          h('td', { class: 'num' }, active ? plan.free.length : '—'),
          h('td', { class: 'num' }, active ? plan.cover : '—'),
          h('td', { class: `num ${bal < 0 ? 'neg' : ''}` }, bal ?? '—'),
          h('td', { class: `num ${plan.shortDays && active ? 'neg strong' : ''}` }, active && plan.shortDays ? plan.shortDays : ''),
          h('td', {}, active && plan.shortDays ? sh : ''),
          h('td', { class: `num ${after < 0 ? 'neg' : ''}` }, after === '' ? '' : after, active && o.shortfall === 'borrow' && plan.shortDays ? h('div', { class: 'small muted' }, `−${plan.shortDays} next year`) : null),
          h('td', {}, nt));
      })))),
    h('div', { class: 'panel-foot', style: 'display:flex;gap:1rem;align-items:center;flex-wrap:wrap' },
      h('span', {}, `${tot.n} people · ${tot.free} free day(s) · ${tot.al} AL day(s) · `, h('b', { class: tot.short ? 'neg' : '' }, `${tot.short} shortfall day(s)`)),
      editable ? h('button', { class: 'btn primary', type: 'button', onclick: () => apply(rows) }, 'Apply closure') : null,
      editable ? h('button', { class: 'btn ghost', type: 'button', onclick: cancel }, 'Cancel draft') : null));
  }
  async function apply(rows) {
    const list = rows.map(({ p, o, bal, plan }) => ({ employee_id: p.id, name: p.full_name, mode: o.mode, al_balance: bal, shortfall: plan.shortDays ? o.shortfall : 'unpaid', note: o.note || null,
      free_dates: o.mode === 'custom' ? plan.free : undefined, al_dates: o.mode === 'custom' ? plan.al : undefined }));
    if (!list.length) { toast('No one is in scope.', 'error'); return; }
    const n = list.filter((x) => ['split', 'custom'].includes(x.mode)).length;
    if (!(await confirmDialog('Apply company closure', `Create the closure leave records for ${n} people (${list.length - n} on duty or excluded)? Leave balances update straight away. You can cancel the closure later; its records are then cancelled.`, 'Apply'))) return;
    const { error } = await ctx.sb.rpc('cms_closure_apply', { p_id: c.id, p_people: list });
    if (failed(error, 'Apply')) return;
    toast('Closure applied.'); window.dispatchEvent(new HashChangeEvent('hashchange'));
  }
  function cancel() {
    const ta = h('textarea', { rows: 3, placeholder: 'Reason' });
    openModal({ title: c.status === 'applied' ? 'Cancel this closure' : 'Cancel this draft', body: h('div', { style: 'display:grid;gap:.6rem' },
      h('p', {}, c.status === 'applied' ? 'Every leave record this closure created is marked cancelled, and any borrowed days are reversed. The closure stays in the list as cancelled.' : 'The draft stays in the list as cancelled.'), ta),
    actions: [{ label: 'Cancel closure', danger: true, onClick: async (close) => {
      if (!ta.value.trim()) { toast('Give the reason.', 'error'); return false; }
      const { error } = await ctx.sb.rpc('cms_closure_cancel', { p_id: c.id, p_reason: ta.value.trim() });
      if (failed(error, 'Cancel')) return false;
      close(); toast('Closure cancelled.'); location.hash = '#/leave/closures'; return true;
    } }] });
  }
  function drawApplied() {
    const label = Object.fromEntries(MODES), sl = Object.fromEntries(SHORT);
    prev.append(h('div', { class: 'panel-head', style: 'padding:1rem 1rem 0' }, h('h3', { style: 'margin:0' }, c.status === 'applied' ? `Applied ${fmtDate(c.applied_at)} · ${summaryText(c.applied_summary || {})}` : `Cancelled ${fmtDate(c.cancelled_at)}: ${c.cancel_reason || ''}`)),
      h('div', { class: 'table-wrap' }, applied.length ? h('table', { class: 'data' },
        h('thead', {}, h('tr', {}, ['Employee', 'Choice', 'Free', 'AL days', 'AL balance then', 'Shortfall', 'Note'].map((t) => h('th', {}, t)))),
        h('tbody', {}, applied.map((r) => h('tr', {}, h('td', {}, r.name || r.employee_id), h('td', {}, label[r.mode] || r.mode),
          h('td', {}, (r.free_dates || []).map(short).join(', ') || '—'), h('td', {}, (r.al_dates || []).map(short).join(', ') || '—'),
          h('td', { class: 'num' }, r.al_balance ?? '—'), h('td', {}, Number(r.short_days) ? `${r2(r.short_days)} · ${sl[r.shortfall] || r.shortfall}` : ''), h('td', {}, r.note || '')))))
        : h('div', { class: 'empty-state' }, 'No one was included.')),
      canEdit && c.status === 'applied' ? h('div', { class: 'panel-foot' }, h('button', { class: 'btn ghost', type: 'button', onclick: cancel }, 'Cancel this closure')) : null);
  }
  drawForm(); drawPreview();
}
