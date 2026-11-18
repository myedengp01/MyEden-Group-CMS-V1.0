-- MyEden Group CMS V1.0 · v2026.11.18 · Resignation: the Company's decision on the last day, and early release (CLC 18 Nov 2026).
-- · The "Agreed a different notice end" tick box is replaced by one decision: 'contract' (serve the notice in the contract / Employee
--   Handbook), 'requested' (the employee's requested last day) or 'other' (another date agreed with her), with the agreed date kept.
-- · An agreed date EARLIER than the contractual notice end is an early release: the notice end stays the contractual one, employment ends on
--   the agreed date, and the days in between are "notice not served" — waived by the Company by default (approver named), or paid in lieu.
--   A LATER agreed date is a longer notice (as before: it becomes the notice end).
-- · Annual leave in the acceptance letters: entitlement and pro-rating shown per service band ({{al_entitlement_text}}, {{al_prorated}}),
--   e.g. "4/12 × 8 days = 3 days + 7/12 × 12 days = 7 days" when the band changes on the 2-year anniversary during the final year.
-- Additive: two columns (filled for the records already there), cms_resignation_save patched in place (marker-guarded), two placeholders,
-- the three RL templates changed with a version row each.
alter table public.cms_resignations add column if not exists notice_decision text;
alter table public.cms_resignations add column if not exists agreed_last_day date;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'cms_resignations_notice_decision_check') then
    alter table public.cms_resignations add constraint cms_resignations_notice_decision_check check (notice_decision is null or notice_decision in ('contract', 'requested', 'other')); end if;
end $c$;
-- records already there: an accepted longer notice → 'requested'; another agreed notice end → 'other' with that date; else 'contract'
update public.cms_resignations set
  notice_decision = case when extension_decision = 'accepted' then 'requested' when notice_agreed then 'other' else 'contract' end,
  agreed_last_day = case when extension_decision = 'accepted' then requested_last_day when notice_agreed then notice_end end
 where notice_decision is null;

do $m$ declare src text; o1 text; o2 text; o3 text;
begin
  select pg_get_functiondef('public.cms_resignation_save(uuid,jsonb)'::regprocedure) into src;
  if position('notice_decision' in src) > 0 then return; end if;
  o1 := $o$v_calc jsonb := coalesce(p->'calc', '{}'::jsonb);$o$;
  o2 := $o$  if v_reason is null then raise exception 'Choose the reason for leaving.'; end if;$o$;
  o3 := $o$  update public.cms_resignations set requested_notice = v_reqn,$o$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 or position(o3 in src) = 0 then raise exception 'cms_resignation_save has changed'; end if;
  src := replace(src, o1, o1 || $n$ v_nd text := nullif(p->>'notice_decision', ''); v_agreed date := nullif(p->>'agreed_last_day', '')::date;$n$);
  src := replace(src, o2, o2 || $n$
  if v_nd is not null and v_nd not in ('contract', 'requested', 'other') then raise exception 'Unknown decision on the last day.'; end if;
  if v_nd = 'requested' and v_req is null then raise exception 'Enter the last day the employee asked for, or choose another decision.'; end if;
  if v_nd in ('requested', 'other') and v_agreed is null then raise exception 'Enter the agreed last day.'; end if;
  if v_nd = 'requested' and v_agreed <> v_req then raise exception 'The agreed last day must be the day the employee asked for (%).', to_char(v_req, 'DD Mon YYYY'); end if;
  if v_nd in ('requested', 'other') and v_agreed < v_end and v_emp_end > v_agreed then
    raise exception 'Early release: employment must end by the agreed last day (%).', to_char(v_agreed, 'DD Mon YYYY'); end if;
  if v_nd in ('requested', 'other') and v_agreed > v_end then raise exception 'A later agreed last day must be the notice end (%).', to_char(v_agreed, 'DD Mon YYYY'); end if;$n$);
  src := replace(src, o3, $n$  update public.cms_resignations set notice_decision = v_nd, agreed_last_day = case when v_nd in ('requested', 'other') then v_agreed end where id = v_id;
$n$ || o3);
  execute src;
end $m$;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('al_entitlement_text', 'Annual leave entitlement (final year)', 'e.g. "12 days per annum", or one part per service band when the band changes during the year.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_prorated', 'Pro-rated annual leave (final year)', 'e.g. "11/12 × 12 days", or "4/12 × 8 days = 3 days + 7/12 × 12 days = 7 days" when the band changes.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;

do $t$ declare t record; b text; v text;
begin
  for t in select * from public.hr_letter_templates where code in ('RL', 'RL_TP2', 'RL_TP3') and position('{{months_worked}}/12 × {{leave_entitlement}} days' in body) > 0 loop
    b := replace(replace(t.body, '{{months_worked}}/12 × {{leave_entitlement}} days', '{{al_prorated}}'), '{{leave_entitlement}} days per annum', '{{al_entitlement_text}}');
    v := gen_random_uuid()::text;
    update public.hr_letter_templates set body = b, version = v, updated_at = now() where code = t.code;
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason)
    values (t.code, v, t.title, b, null, 'Annual leave entitlement and pro-rating shown per service band (e.g. 8 → 12 days on the 2-year anniversary) — CLC 18 Nov 2026');
  end loop;
end $t$;
