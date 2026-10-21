-- MyEden Group CMS V1.0 · Phase 5d · Employee Documents, HR Letters, offboarding checklist
-- Documents: the existing employee_documents register + "employee-documents" storage bucket (shared with MEG-EAF V2);
--   CMS users with Employee Documents rights can view / upload / replace / remove (soft) files per person.
-- HR Letters: the MEG-EAF V2 letter templates ({{placeholders}}) filled from the person's records (name, position, company,
--   address, salary, probation and appraisal details) plus fields HR types; draft → issued (stored word for word, reprintable),
--   on the company letterhead; a probation extension letter issued from an appraisal marks that appraisal's letter as issued.
-- Hand-over: a checklist of the non-item offboarding steps (final pay, exit interview, resignation acceptance letter, access
--   removed, documents returned), each ticked with who and when; approving with steps open needs a reason.

-- ------------------------------------------------------------------ storage access for CMS users
create policy "CMS documents read" on storage.objects for select to authenticated
  using (bucket_id = 'employee-documents' and public.cms_can('documents', 'V'));
create policy "CMS documents upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'employee-documents' and public.cms_can('documents', 'C')
              and exists (select 1 from public.employee_master e where e.id::text = (storage.foldername(name))[1]));

-- ------------------------------------------------------------------ documents
create or replace function public.cms_documents(p_person uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('documents', 'V');
  return jsonb_build_object('can_edit', public.cms_can('documents', 'C'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'person_id', d.employee_id_ref, 'name', em.employee_name, 'employee_id', em.employee_id,
          'type', d.document_type, 'label', d.document_label, 'file_name', d.file_name, 'path', d.storage_path, 'mime', d.mime_type, 'size', d.file_size_bytes,
          'date', d.document_date, 'expiry', d.expiry_date, 'current', d.is_current, 'note', d.note, 'uploaded_at', d.uploaded_at, 'superseded_at', d.superseded_at)
        order by em.employee_name, d.uploaded_at desc)
      from public.employee_documents d join public.employee_master em on em.id = d.employee_id_ref
      where d.removed_at is null and (p_person is null or d.employee_id_ref = p_person)
        and private.cms_can_company('documents', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'person_id', l.employee_id, 'name', em.employee_name, 'template', l.template_code, 'title', t.title,
          'status', l.status, 'issued_at', l.issued_at, 'created_at', l.created_at) order by l.created_at desc)
      from public.hr_letter_records l join public.employee_master em on em.id = l.employee_id left join public.hr_letter_templates t on t.code = l.template_code
      where (p_person is null or l.employee_id = p_person) and l.status <> 'void' and private.cms_can_company('documents', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'status', em.employment_status) order by em.employee_name)
      from public.employee_master em where (em.employment_status in ('active','onboarding') or exists (select 1 from public.employee_documents d where d.employee_id_ref = em.id and d.removed_at is null))
        and private.cms_can_company('documents', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $$;

create or replace function public.cms_document_add(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; v uuid; old uuid := nullif(p->>'replaces', '')::uuid;
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('documents', 'C', private.cms_canon(em.company_code));
  if nullif(p->>'path', '') is null or split_part(p->>'path', '/', 1) <> em.id::text then raise exception 'Upload the file first.'; end if;
  insert into public.employee_documents (employee_id_ref, document_type, document_label, file_name, storage_path, mime_type, file_size_bytes, document_date, expiry_date,
         is_current, note, source_type, uploaded_by, uploaded_at)
  values (em.id, coalesce(nullif(p->>'type', ''), 'other'), nullif(btrim(p->>'label'), ''), p->>'file_name', p->>'path', p->>'mime', nullif(p->>'size', '')::bigint,
          nullif(p->>'date', '')::date, nullif(p->>'expiry', '')::date, true, nullif(btrim(p->>'note'), ''), 'manual_entry', auth.uid(), now())
  returning id into v;
  if old is not null then
    update public.employee_documents set is_current = false, superseded_at = now(), superseded_by = v where id = old and employee_id_ref = em.id;
  end if;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, case when old is null then 'employee_document_added' else 'employee_document_superseded' end, coalesce(nullif(btrim(p->>'label'), ''), p->>'file_name'),
          jsonb_build_object('document_id', v, 'type', p->>'type', 'replaces', old), auth.uid());
  perform private.cms_log('document.added', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': document ' || coalesce(nullif(btrim(p->>'label'), ''), p->>'file_name') || case when old is not null then ' (replaces an older copy)' else '' end, jsonb_build_object('document_id', v));
  return v;
end $$;

create or replace function public.cms_document_remove(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.employee_documents; em public.employee_master;
begin
  select * into d from public.employee_documents where id = p_id for update;
  if d.id is null or d.removed_at is not null then raise exception 'Document not found.'; end if;
  select * into em from public.employee_master where id = d.employee_id_ref;
  perform private.cms_require('documents', 'E', private.cms_canon(em.company_code));
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  update public.employee_documents set removed_at = now(), removed_by = auth.uid(), removal_reason = btrim(p_reason), is_current = false where id = d.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'employee_document_removed', btrim(p_reason), jsonb_build_object('document_id', d.id), auth.uid());
  perform private.cms_log('document.removed', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': document removed (' || btrim(p_reason) || ')', jsonb_build_object('document_id', d.id));
end $$;

-- ------------------------------------------------------------------ HR letters
-- everything a letter can fill in by itself for a person
create or replace function private.cms_letter_context(p_person uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with em as (select * from public.employee_master where id = p_person),
  pv as (select p.* from public.eppd_employee_private p join public.eppd_employees e on e.id = p.employee_id where e.employee_master_id = p_person order by e.id desc limit 1),
  co as (select c.* from public.eppd_companies c, em where private.cms_canon(c.code) = private.cms_canon(em.company_code) order by c.is_primary desc nulls last limit 1),
  pe as (select * from private.cms_probation_end(p_person)),
  sal as (select private.cms_person_salary(p_person) s),
  ap as (select * from public.cms_appraisals a where a.person_id = p_person and a.status = 'approved' order by a.approved_at desc limit 1),
  boss as (select b.employee_name from public.employee_master b, em where b.id = em.reports_to_id)
  select jsonb_build_object(
    'letter_date', to_char((now() at time zone 'Asia/Kuala_Lumpur')::date, 'FMDD FMMonth YYYY'),
    'employee_name', em.employee_name, 'employee_id', em.employee_id,
    'company_name', coalesce((select name from co), em.company_code),
    'position', em.approved_job_title, 'current_position', em.approved_job_title,
    'department', em.department, 'current_department', em.department,
    'current_manager', (select employee_name from boss), 'current_reporting_manager', (select employee_name from boss), 'review_manager', (select employee_name from boss),
    'current_basic', case when (select s from sal) is not null then to_char(((select s from sal)->>'amount')::numeric, 'FM999,999,990.00') end,
    '_home_address', (select home_address from pv),
    'current_probation_end_date', to_char((select end_date from pe), 'FMDD FMMonth YYYY'),
    'confirmation_date', to_char(coalesce(em.confirmation_date, (select end_date from pe)), 'FMDD FMMonth YYYY'),
    'review_date', to_char((select reviewed_at from ap)::date, 'FMDD FMMonth YYYY'),
    'revised_probation_end_date', to_char((select rec_extend_to from ap), 'FMDD FMMonth YYYY'),
    'next_review_date', to_char((select rec_extend_to from ap), 'FMDD FMMonth YYYY'),
    'improvement_areas', (select improvements from ap), 'performance_objectives', (select goals from ap),
    'authorized_signatory', (select value->>'name' from public.eppd_policies where key = 'ea_signatory'),
    'authorized_designation', (select value->>'position' from public.eppd_policies where key = 'ea_signatory'),
    'last_working_day', to_char(em.actual_last_working_date, 'FMDD FMMonth YYYY'), 'resignation_date', to_char(em.resignation_letter_date, 'FMDD FMMonth YYYY'))
  from em;
$$;

create or replace function public.cms_letters()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('letters', 'V');
  return jsonb_build_object('can_edit', public.cms_can('letters', 'C'),
    'templates', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'title', title, 'version', version, 'body', body, 'active', active) order by title) from public.hr_letter_templates), '[]'::jsonb),
    'placeholders', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'kind', kind, 'source', source, 'required', required, 'default', default_value)) from public.hr_letter_placeholders where active), '[]'::jsonb),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'person_id', l.employee_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
          'template', l.template_code, 'title', t.title, 'status', l.status, 'fields', l.fields, 'text', l.issued_snapshot->>'text', 'issued_at', l.issued_at, 'created_at', l.created_at,
          'issued_by', l.issued_snapshot->>'issued_by_name') order by l.created_at desc)
      from public.hr_letter_records l join public.employee_master em on em.id = l.employee_id left join public.hr_letter_templates t on t.code = l.template_code
      where private.cms_can_company('letters', 'V', private.cms_canon(em.company_code)) and l.status <> 'void'), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code), 'status', em.employment_status) order by em.employee_name)
      from public.employee_master em where em.employment_status in ('active','onboarding','former') and private.cms_can_company('letters', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $$;

create or replace function public.cms_letter_context(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare em public.employee_master;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('letters', 'V', private.cms_canon(em.company_code));
  return private.cms_letter_context(p_person) || jsonb_build_object('_company', (select to_jsonb(c) - 'logo' || jsonb_build_object('logo', c.logo) from public.eppd_companies c
      where private.cms_canon(c.code) = private.cms_canon(em.company_code) order by c.is_primary desc nulls last limit 1));
end $$;

-- save a draft, or issue (the text is stored exactly as printed)
create or replace function public.cms_letter_save(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; t public.hr_letter_templates; v uuid := nullif(p->>'id', '')::uuid; iss boolean := coalesce((p->>'issue')::boolean, false); ap uuid := nullif(p->>'appraisal_id', '')::uuid;
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('letters', 'C', private.cms_canon(em.company_code));
  select * into t from public.hr_letter_templates where code = p->>'template';
  if t.code is null then raise exception 'Choose the letter.'; end if;
  if iss and nullif(p->>'text', '') is null then raise exception 'Nothing to issue.'; end if;
  if iss and (p->>'text') ~ '\{\{[a-z0-9_]+\}\}' then raise exception 'Fill in every field before issuing (some {{…}} are still empty).'; end if;
  if v is null then
    insert into public.hr_letter_records (employee_id, company_code, template_code, template_version, status, fields, source_snapshot, issued_snapshot, created_by, approved_by, issued_by, approved_at, issued_at)
    values (em.id, private.cms_canon(em.company_code), t.code, t.version, case when iss then 'issued' else 'draft' end, coalesce(p->'fields', '{}'::jsonb),
            jsonb_build_object('source', 'cms', 'appraisal_id', ap),
            case when iss then jsonb_build_object('text', p->>'text', 'issued_by_name', private.cms_my_name(), 'company', p->'company') end,
            auth.uid(), case when iss then auth.uid() end, case when iss then auth.uid() end, case when iss then now() end, case when iss then now() end)
    returning id into v;
  else
    update public.hr_letter_records set fields = coalesce(p->'fields', fields), template_code = t.code, template_version = t.version,
           status = case when iss then 'issued' else status end,
           issued_snapshot = case when iss then jsonb_build_object('text', p->>'text', 'issued_by_name', private.cms_my_name(), 'company', p->'company') else issued_snapshot end,
           approved_by = case when iss then auth.uid() else approved_by end, approved_at = case when iss then now() else approved_at end,
           issued_by = case when iss then auth.uid() else issued_by end, issued_at = case when iss then now() else issued_at end, updated_at = now()
     where id = v and employee_id = em.id and status = 'draft';
    if not found then raise exception 'Only a draft can be changed.'; end if;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (v, auth.uid(), case when iss then 'issued' else 'draft_saved' end, jsonb_build_object('source', 'cms'));
  if iss then
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (em.id, 'hr_letter_issued', t.title, jsonb_build_object('letter_id', v, 'template', t.code), auth.uid());
    perform private.cms_log('letter.issued', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || t.title || ' issued', jsonb_build_object('letter_id', v));
    -- a probation extension letter from an appraisal: that appraisal's letter is now issued
    if ap is not null and t.code = 'PEL' then
      update public.cms_appraisals set letter_issued_at = now(), letter_ref = v::text, letter_by = auth.uid(), updated_at = now()
       where id = ap and person_id = em.id and recommendation = 'extend' and letter_issued_at is null;
    end if;
  end if;
  return v;
end $$;

create or replace function public.cms_letter_void(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.hr_letter_records; em public.employee_master;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  perform private.cms_require('letters', 'E', private.cms_canon(em.company_code));
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  update public.hr_letter_records set status = 'void', updated_at = now() where id = l.id;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'void', jsonb_build_object('reason', p_reason, 'source', 'cms'));
  perform private.cms_log('letter.void', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': letter cancelled (' || btrim(p_reason) || ')', jsonb_build_object('letter_id', l.id));
end $$;

-- ------------------------------------------------------------------ hand-over checklist (non-item steps)
alter table public.cms_handovers add column if not exists checklist jsonb not null default
  '[{"key":"resignation_letter","label":"Resignation acceptance letter issued"},{"key":"access","label":"System and email access removed"},{"key":"documents","label":"Company documents and files returned"},{"key":"exit_interview","label":"Exit interview done"},{"key":"final_pay","label":"Final pay settled (notice, leave, loans, deductions)"}]'::jsonb;

create or replace function public.cms_handover_step(p_id uuid, p_key text, p_done boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare h public.cms_handovers; em public.employee_master;
begin
  select * into h from public.cms_handovers where id = p_id for update;
  if h.id is null or h.status <> 'open' then raise exception 'Hand-over not found or closed.'; end if;
  select * into em from public.employee_master where id = h.person_id;
  perform private.cms_require('assets', 'E', private.cms_canon(em.company_code));
  update public.cms_handovers set checklist = (select jsonb_agg(case when x->>'key' = p_key then
           (x - 'done' - 'by' - 'at' - 'note') || case when p_done then jsonb_build_object('done', true, 'by', private.cms_my_name(), 'at', now(), 'note', nullif(btrim(p_note), '')) else '{}'::jsonb end
         else x end) from jsonb_array_elements(h.checklist) x), updated_at = now()
   where id = h.id;
  perform private.cms_log('handover.step', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': hand-over step ' || p_key || case when p_done then ' done' else ' reopened' end, jsonb_build_object('note', p_note));
end $$;

do $m$ declare d text; n text;
begin
  -- the checklist travels with the hand-over (HR page and My Items)
  d := pg_get_functiondef('public.cms_items_admin()'::regprocedure);
  n := replace(d, $x$'approve_note', h.approve_note,$x$, $x$'approve_note', h.approve_note, 'checklist', h.checklist,$x$);
  if n = d then raise exception 'cms_items_admin patch point not found'; end if;
  execute n;
  -- approving with checklist steps open needs a reason, like items still out
  d := pg_get_functiondef('public.cms_handover_approve(uuid, text, boolean)'::regprocedure);
  n := replace(d, $x$  select count(*) into n from public.cms_items where person_id = h.person_id and status in ('issued','held');$x$,
                  $x$  select count(*) into n from public.cms_items where person_id = h.person_id and status in ('issued','held');
  if nullif(btrim(coalesce(p_note, '')), '') is null and exists (select 1 from jsonb_array_elements(h.checklist) x where not coalesce((x->>'done')::boolean, false)) then
    raise exception 'Some hand-over steps are not done yet — tick them, or give the reason for approving anyway.';
  end if;$x$);
  if n = d then raise exception 'cms_handover_approve patch point not found'; end if;
  execute n;
end $m$;

do $g$ declare f text;
begin
  foreach f in array array['cms_documents(uuid)','cms_document_add(jsonb)','cms_document_remove(uuid, text)','cms_letters()','cms_letter_context(uuid)',
    'cms_letter_save(jsonb)','cms_letter_void(uuid, text)','cms_handover_step(uuid, text, boolean, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;

-- position / department fall back to the payroll record when the Employee Master has none
do $m$ declare d text := pg_get_functiondef('private.cms_letter_context(uuid)'::regprocedure); n text;
begin
  if position('job as (' in d) > 0 then return; end if;
  n := replace(d, $x$  boss as (select b.employee_name from public.employee_master b, em where b.id = em.reports_to_id)$x$,
                  $x$  boss as (select b.employee_name from public.employee_master b, em where b.id = em.reports_to_id),
  job as (select t.name title, dp.name dept from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
            left join public.eppd_job_titles t on t.id = m.job_title_id left join public.eppd_departments dp on dp.id = m.department_id
           where e.employee_master_id = p_person order by (m.resigned_date is null) desc, m.join_date desc nulls last limit 1)$x$);
  n := replace(n, $x$'position', em.approved_job_title, 'current_position', em.approved_job_title,
    'department', em.department, 'current_department', em.department,$x$,
    $x$'position', coalesce(em.approved_job_title, (select title from job)), 'current_position', coalesce(em.approved_job_title, (select title from job)),
    'department', coalesce(em.department, (select dept from job)), 'current_department', coalesce(em.department, (select dept from job)),$x$);
  execute n;
end $m$;
