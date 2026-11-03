// MyPayroll-System-V2.0 · time-forms.js — overtime / hours entry form and the OTCF pull, shared by
// Time & leave › Overtime & hours, Part-time hours and the payroll line window.
import { h, clear, openModal, field, toast, failed, fmtDate } from './ui.js';
import { OT_CATEGORIES, rateHours, normaliseName, nameKeys, sameName, otcfToEntries, hoursBetween } from './engines/ot.js';
export { hoursBetween };
import { todayIso } from './engines/employee.js';
import { mf, megformsConfigured, fetchApprovedOtcf } from './megforms.js';

export const CATS = Object.keys(OT_CATEGORIES);
/** Add or edit one overtime / hours entry. Hours are worked out from From–To (less the break) unless typed. */
export function editTimeEntry(ctx, { people, month, entry: e = null, employeeId = null, category = null, onSaved } = {}) {
  const start = `${month}-01`;
  const current = people.filter((p) => p.status?.key !== 'former' || (e && p.id === e.employee_id) || p.id === employeeId);
  const F = {
    employee_id: field('Employee', { type: 'select', required: true, value: e?.employee_id ?? employeeId ?? '', span2: true,
      options: [['', 'Choose…'], ...current.map((p) => [p.id, `${p.full_name}${p.emp_id ? ` (${p.emp_id})` : ''}`])] }),
    work_date: field('Date', { type: 'date', required: true, value: e?.work_date || (todayIso().startsWith(month) ? todayIso() : start) }),
    category: field('Category', { type: 'select', value: e?.category || category || 'OT_NORMAL', options: CATS.map((c) => [c, OT_CATEGORIES[c].label]) }),
    from_time: field('From', { type: 'time', value: e?.from_time ? String(e.from_time).slice(0, 5) : '' }),
    to_time: field('To', { type: 'time', value: e?.to_time ? String(e.to_time).slice(0, 5) : '' }),
    break_h: field('Break (hours)', { type: 'number', step: '0.25', min: 0, value: 0, hint: 'Taken off the From–To time.' }),
    hours: field('Hours', { type: 'number', step: '0.25', required: true, value: e?.hours ?? '' }),
    note: field('Note', { type: 'textarea', span2: true, value: e?.note }),
  };
  if (employeeId) F.employee_id.input.disabled = true;
  const calc = h('p', { class: 'small muted span-2' });
  let typed = !!e;
  const recalc = () => {
    const hrs = hoursBetween(F.from_time.getValue(), F.to_time.getValue(), F.break_h.getValue());
    if (hrs !== null && !typed) F.hours.input.value = hrs;
    calc.textContent = hrs === null ? 'Fill in From and To to work out the hours, or type the hours.' : `From–To less the break: ${hrs} h${typed && Number(F.hours.getValue()) !== hrs ? ' (you typed your own hours)' : ''}.`;
  };
  ['from_time', 'to_time', 'break_h'].forEach((k) => F[k].input.addEventListener('input', () => { typed = false; recalc(); }));
  F.hours.input.addEventListener('input', () => { typed = true; recalc(); });
  recalc();
  openModal({ title: e ? 'Edit entry' : 'Add overtime or hours', body: h('div', { class: 'form-grid' }, F.employee_id, F.work_date, F.category, F.from_time, F.to_time, F.break_h, F.hours, calc, F.note),
    actions: [{ label: e ? 'Save changes' : 'Add entry', primary: true, onClick: async (close) => {
      const v = { employee_id: Number(employeeId || F.employee_id.getValue()), work_date: F.work_date.getValue(), category: F.category.getValue(),
        from_time: F.from_time.getValue() || null, to_time: F.to_time.getValue() || null, hours: F.hours.getValue(), note: F.note.getValue() || null };
      if (!v.employee_id || !v.work_date || v.hours === null || v.hours === '') { toast('Employee, date and hours are required.', 'error'); return false; }
      const q = e ? ctx.sb.from('eppd_time_entries').update(v).eq('id', e.id) : ctx.sb.from('eppd_time_entries').insert({ ...v, source: 'manual' });
      const { error } = await q; if (failed(error)) return false;
      toast('Saved.'); close(); onSaved?.(); return true;
    } }] });
}

/** Pull approved OTCF claims for a month (optionally for one person only). */
export async function pullOtcf(ctx, { month, people, entries, onlyEmployeeId = null, onSaved }) {
  if (!megformsConfigured) { toast('OTCF is not connected.', 'error'); return; }
  const { data: s } = await mf.auth.getSession();
  if (!s.session) return signIn();
  const byId = new Map(people.map((p) => [p.id, p]));
  let payPol = {};   // payroll rules: the hours a day is split by for rest days and public holidays (EA cap from Oct 2026)
  const holder = h('div', { class: 'loading' }, 'Reading approved claims from OTCF…');
  const close = openModal({ title: `Pull OTCF claims · ${month}`, wide: true, body: holder, actions: [] });
  try {
    const [subs, linksRes, polRes] = await Promise.all([fetchApprovedOtcf(Number(month.slice(0, 4)), Number(month.slice(5, 7))),
      ctx.sb.from('eppd_otcf_links').select('otcf_name,employee_id'), ctx.sb.from('eppd_policies').select('value').eq('key', 'payroll').maybeSingle()]);
    payPol = polRes?.data?.value || {};
    // who each claim is for: the person chosen in the OTCF form, and the person behind the claimant's login (for suggestions)
    let who = { users: [], people: [] };
    try { const r = await ctx.sb.rpc('cms_otcf_claimants', { p_users: [...new Set(subs.map((x) => x.submitted_by).filter(Boolean))], p_people: [...new Set(subs.map((x) => x.person_id).filter(Boolean))] }); if (!r.error && r.data) who = r.data; } catch { /* suggestions are optional */ }
    close(); review(subs, linksRes.data || [], s.session.user.email, who);
  } catch (err) { close(); toast(`Could not read OTCF: ${err.message || err}. Your account needs OTCF admin or approver access.`, 'error', 8000); }

  function signIn() {
    const email = field('Email', { type: 'email', required: true, value: ctx.me.email });
    const pw = field('Password', { type: 'password', required: true });
    openModal({ title: 'Sign in to MEG-FORMS', body: h('div', { style: 'display:grid;gap:.8rem' },
      h('p', { class: 'small muted' }, 'OTCF claims live in MEG-FORMS. Sign in with the account you use to approve OTCF claims.'), email, pw),
      actions: [{ label: 'Sign in and continue', primary: true, onClick: async (cl) => {
        const { error } = await mf.auth.signInWithPassword({ email: email.getValue(), password: pw.input.value });
        if (error) { toast(error.message === 'Invalid login credentials' ? 'Email or password is incorrect.' : error.message, 'error'); return false; }
        cl(); pullOtcf(ctx, { month, people, entries, onlyEmployeeId, onSaved }); return true;
      } }] });
  }
  function review(subs, links, mfEmail, who = { users: [], people: [] }) {
    const linkMap = new Map(links.map((l) => [l.otcf_name, l.employee_id]));
    const keysOf = (name) => nameKeys(name);
    const peopleKeys = people.map((p) => ({ p, k: keysOf(p.full_name) }));
    const byName = (name) => { const k = keysOf(name); const hit = peopleKeys.filter((x) => sameName(x.k, k)); return hit.length === 1 ? hit[0].p : null; };
    const bySubset = (name) => { const k = keysOf(name); if (k.tokens.length < 2) return null; const hit = peopleKeys.filter((x) => k.tokens.every((t) => x.k.tokens.includes(t))); return hit.length === 1 ? hit[0].p : null; };
    const formPerson = new Map((who.people || []).map((x) => [x.person_id, x.employee_id]));
    const loginPerson = new Map((who.users || []).map((x) => [x.user_id, x.employee_id]));
    const picks = new Map();           // name key → employee id, confirmed in this window (remembered on save)
    const subOf = new Map(subs.map((x) => [String(x.id), x]));
    // per claim: the employee and how it was found ('form' | 'link' | 'name' | 'picked'), or a suggestion to confirm ('login' | 'similar')
    const decide = (x) => {
      const k = normaliseName(x.emp_name);
      const f = x.person_id && formPerson.get(x.person_id); if (f && byId.get(Number(f))) return { emp: byId.get(Number(f)), how: 'form' };
      if (picks.has(k)) return { emp: byId.get(Number(picks.get(k))) || null, how: 'picked' };
      if (linkMap.has(k) && byId.get(Number(linkMap.get(k)))) return { emp: byId.get(Number(linkMap.get(k))), how: 'link' };
      const n = byName(x.emp_name); if (n) return { emp: n, how: 'name' };
      const l = x.submitted_by && loginPerson.get(x.submitted_by); if (l && byId.get(Number(l))) return { emp: null, suggest: byId.get(Number(l)), how: 'login' };
      const t = bySubset(x.emp_name); if (t) return { emp: null, suggest: t, how: 'similar' };
      return { emp: null, how: null };
    };
    const pulled = new Set(entries.filter((e) => e.otcf_submission_id).map((e) => e.otcf_submission_id));
    const fresh = subs.filter((x) => !pulled.has(String(x.id)));
    const box = h('div', {});
    const HOW = { form: 'chosen in the OTCF form', link: 'matched before', name: 'same name', picked: 'you matched it' };
    const drawReview = () => {
      const D = new Map(fresh.map((x) => [String(x.id), decide(x)]));
      const res = otcfToEntries(fresh, (name, sub) => D.get(String(sub.id))?.emp || null, (p) => rateHours(p.employment, payPol, month, p.salary?.pay_basis || p.pay_basis).hours);
      const only = onlyEmployeeId ? byId.get(onlyEmployeeId) : null;
      if (onlyEmployeeId) res.entries = res.entries.filter((e) => e.employee_id === onlyEmployeeId);
      const open = fresh.filter((x) => !D.get(String(x.id)).emp);
      const mine = only ? fresh.filter((x) => D.get(String(x.id)).emp?.id === only.id) : [];
      const hrs = (x) => Number(x.total_hours ?? (x.line_items || []).reduce((a, li) => a + (Number(li.actualHrs ?? li.totalHrs) || 0), 0)) || 0;
      const claimLine = (x, d) => h('li', {}, h('b', {}, x.serial_no || x.id), ` · ${hrs(x)} h · typed as “${x.emp_name}”`, d?.emp ? h('span', { class: 'small muted' }, ` · ${d.emp.full_name}, ${HOW[d.how] || ''}`) : null);
      // claims not matched yet: suggestion pre-filled, HR confirms with the tick
      const openRows = open.map((x) => {
        const d = D.get(String(x.id)); const k = normaliseName(x.emp_name);
        const sel = h('select', { 'aria-label': `Employee for ${x.emp_name}` }, h('option', { value: '' }, 'Leave this claim out'),
          people.filter((p) => p.status?.key !== 'former' || p.id === d.suggest?.id).map((p) => h('option', { value: p.id, selected: d.suggest?.id === p.id }, `${p.full_name}${p.emp_id ? ` (${p.emp_id})` : ''}`)));
        const ok = h('input', { type: 'checkbox', 'aria-label': `Confirm ${x.emp_name}` });
        const apply = () => { if (ok.checked && sel.value) picks.set(k, Number(sel.value)); else picks.delete(k); drawReview(); };
        sel.addEventListener('change', () => { ok.checked = !!sel.value; apply(); }); ok.addEventListener('change', apply);
        return h('div', { class: 'check-row', style: 'margin-bottom:.5rem;flex-wrap:wrap;gap:.5rem' }, h('b', { style: 'min-width:15rem' }, `“${x.emp_name}”`),
          h('span', { class: 'small muted', style: 'min-width:9rem' }, `${x.serial_no || ''} · ${hrs(x)} h`), sel, h('label', { class: 'check-row small' }, ok, 'This is the right person'),
          d.suggest ? h('span', { class: 'tag info' }, d.how === 'login' ? 'Suggested from the login that submitted it' : 'Suggested: similar name') : h('span', { class: 'tag warn' }, 'Choose the employee'));
      });
      clear(box).append(
        h('p', {}, `Signed in as ${mfEmail}. ${subs.length} approved claim${subs.length === 1 ? '' : 's'} for ${month}; ${subs.length - fresh.length} already pulled.${only ? ` Showing ${only.full_name} only.` : ''}`),
        only ? h('div', { class: 'block', style: 'margin:.6rem 0' }, h('h3', {}, mine.length ? `${mine.length} approved claim${mine.length === 1 ? '' : 's'} for ${only.full_name}` : `No claim matched to ${only.full_name} yet`),
          mine.length ? h('ul', { class: 'small' }, mine.map((x) => claimLine(x, D.get(String(x.id))))) : h('p', { class: 'small muted' }, open.length ? 'If one of the claims below is hers / his, choose the name and tick it.' : 'No approved OTCF claim for this month.')) : null,
        openRows.length ? h('div', { class: 'block', style: 'margin:.8rem 0' }, h('h3', {}, `Claims to match (${openRows.length})`),
          h('p', { class: 'small muted', style: 'margin:.3rem 0 .6rem' }, 'The name in OTCF did not match the payroll name. Check the suggestion, or choose the employee, and tick. Your choice is remembered for next time.'), openRows) : null,
        res.entries.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'data' },
          h('thead', {}, h('tr', {}, ['Employee', 'Date', 'Category', 'Hours', 'Claim'].map((t) => h('th', {}, t)))),
          h('tbody', {}, res.entries.map((e) => h('tr', {}, h('td', {}, byId.get(e.employee_id)?.full_name), h('td', {}, fmtDate(e.work_date)),
            h('td', {}, OT_CATEGORIES[e.category].label), h('td', { class: 'num' }, e.hours), h('td', { class: 'small muted' }, `${e.otcf_serial || e.otcf_submission_id}${subOf.get(e.otcf_submission_id)?.emp_name ? ` · “${subOf.get(e.otcf_submission_id).emp_name}”` : ''}`))))))
          : h('p', { class: 'empty-state' }, fresh.length ? (only ? `Nothing to add for ${only.full_name} yet.` : 'Match the claims above to see the lines.') : 'Nothing new to pull for this month.'),
        res.skipped ? h('p', { class: 'small muted' }, `${res.skipped} line(s) had hours but no usable claim type or date and were left out.`) : null);
      box.result = res;
    };
    drawReview();
    openModal({ title: `Pull OTCF claims · ${month}`, wide: true, body: box,
      actions: [{ label: 'Add these entries', primary: true, onClick: async (cl) => {
        const res = box.result;
        if (!res.entries.length) { toast('Nothing to add.', 'error'); return false; }
        const newLinks = [...picks.entries()].map(([otcf_name, employee_id]) => ({ otcf_name, employee_id }));
        const { data, error } = await ctx.sb.rpc('eppd_save_otcf_pull', { p: { month, links: newLinks, entries: res.entries } });
        if (failed(error, 'Save')) return false;
        toast(`${data.entries_added} entries added from OTCF.`); cl(); onSaved?.(); return true;
      } }] });
  }
}
