-- MyEden Group CMS V1.0 · HR letters: print a letter before it is issued (with its draft watermark), recorded in the letter's history
-- cms_letter_draft_printed: records who printed a draft / waiting / approved letter and when (letter history and audit log);
--   a new letter not saved yet is recorded in the audit log against the person.
-- cms_letter_history: the letter's history (saved, sent for approval, approved / sent back, draft printed, issued, cancelled).
create or replace function public.cms_letter_draft_printed(p_id uuid, p_person uuid default null, p_template text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.hr_letter_records; em public.employee_master; t public.hr_letter_templates;
begin
  if p_id is not null then
    select * into l from public.hr_letter_records where id = p_id;
    if l.id is null then raise exception 'Letter not found.'; end if;
    if l.status in ('issued', 'void') then return; end if;
  end if;
  select * into em from public.employee_master where id = coalesce(l.employee_id, p_person);
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('letters', 'V', private.cms_canon(em.company_code));
  select * into t from public.hr_letter_templates where code = coalesce(l.template_code, p_template);
  if l.id is not null then
    insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot)
    values (l.id, auth.uid(), 'draft_printed', jsonb_build_object('source', 'cms', 'status', l.status, 'reference', l.reference));
  end if;
  perform private.cms_log('letter.draft_printed', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || coalesce(t.title, 'HR letter') || ' printed before issue (' || coalesce(replace(l.status, '_', ' '), 'not saved') || ')' || coalesce(' · ' || l.reference, ''),
    jsonb_build_object('letter', l.id, 'status', coalesce(l.status, 'new'), 'template', t.code));
end $f$;
revoke all on function public.cms_letter_draft_printed(uuid, uuid, text) from public, anon;
grant execute on function public.cms_letter_draft_printed(uuid, uuid, text) to authenticated;

create or replace function public.cms_letter_history(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare l public.hr_letter_records; em public.employee_master;
begin
  select * into l from public.hr_letter_records where id = p_id;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  perform private.cms_require('letters', 'V', private.cms_canon(em.company_code));
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action,
      'by', coalesce((select e2.employee_name from public.cms_user_links ul join public.employee_master e2 on e2.id = ul.employee_master_id where ul.user_id = a.actor_id limit 1),
                     (select split_part(u.email, '@', 1) from auth.users u where u.id = a.actor_id), ''),
      'status', a.event_snapshot->>'status', 'reason', coalesce(a.event_snapshot->>'reason', a.event_snapshot->>'note')) order by a.created_at)
    from public.hr_letter_audit a where a.letter_id = l.id), '[]'::jsonb);
end $f$;
revoke all on function public.cms_letter_history(uuid) from public, anon;
grant execute on function public.cms_letter_history(uuid) to authenticated;
