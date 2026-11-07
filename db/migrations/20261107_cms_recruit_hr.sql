-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 E1 — MEG-EAF V2 HR page parts in the CMS (CLC 7 Nov 2026)
-- In the application window (Recruitment › Applications / Shortlist & Interviews):
-- 1. Move the stage (same allowed steps as MEG-EAF V2; Shortlisted / Not selected / KIV set the decision as MEG-EAF V2 does), with a note.
-- 2. Office Use and interview: interviewers, decision, final salary, working hours, start date, department, documents received, comments,
--    plus (new) interview date / time, place and notes. Same payload keys as MEG-EAF V2, so both show the same values.
-- 3. Issued offer letter: signed copy upload (PDF, dates, signatory), HR verification, stamp duty (status, dates, reference, physical
--    original), stamp certificate upload. Same record, same rules (the MEG-EAF V2 guard trigger still applies), same storage folder.
--    Files go to <company>/<year>/<reference with / as ->/SIGNED.pdf or STAMP_CERTIFICATE.pdf.
--    New: uploading the signed copy moves the application from Offer issued to Offer accepted.
-- 4. Recruitment open / closed per general job title (shown on the public application form), as in the JD Manual.
-- Permissions: Recruitment (edit) for 1–2 and 4, Recruitment or Onboarding (edit) for 3, for the application's company.
-- Additive: new functions and two storage policies (the MEG-EAF V2 policies stay).

create or replace function private.cms_app_company(p_app uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg'))) from public.eaf_applications a where a.id = p_app;
$$;
revoke all on function private.cms_app_company(uuid) from public, anon, authenticated;

-- the HR part of one application: Office Use / interview values, stage and next steps, active offer letter record
create or replace function public.cms_app_hr(p_app uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare a public.eaf_applications; co text; l public.eaf_loec_records;
  keys text[] := array['interviewedBy', 'interviewedBy2', 'decision', 'finalSalary', 'finalFrom', 'finalTo', 'finalStart', 'finalDept', 'cb_doc', 'docOther',
                       'officeComments', 'cmsInterviewAt', 'cmsInterviewPlace', 'cmsInterviewNotes'];
begin
  select * into a from public.eaf_applications where id = p_app;
  if a.id is null then raise exception 'Application not found.'; end if;
  co := private.cms_app_company(p_app);
  if not (public.cms_can('recruitment', 'V', co) or public.cms_can('onboarding', 'V', co)) then raise exception 'You do not have access to this application.'; end if;
  select * into l from public.eaf_loec_records where application_id = p_app and status not in ('superseded', 'cancelled') order by revision desc limit 1;
  return jsonb_build_object(
    'company', co, 'eaf_company', lower(coalesce(a.company_code, a.payload->>'companyCode', 'meg')), 'stage', a.workflow_stage,
    'next', (select coalesce(jsonb_agg(s order by o), '[]'::jsonb) from unnest(array['under_review', 'kiv', 'shortlisted', 'offer_preparation', 'offer_issued', 'offer_accepted',
               'offer_declined', 'ready_for_onboarding', 'completed', 'rejected']) with ordinality x(s, o)
             where s <> a.workflow_stage and public.eaf_workflow_transition_allowed(a.workflow_stage, s)),
    'office', (select coalesce(jsonb_object_agg(k, a.payload->k), '{}'::jsonb) from unnest(keys) k where a.payload ? k),
    'can_edit', public.cms_can('recruitment', 'E', co),
    'can_offer', public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co),
    'loec', case when l.id is null then null else jsonb_build_object('id', l.id, 'document_id', l.document_id, 'revision', l.revision, 'status', l.status,
      'issued_at', l.issued_at, 'signed_copy_path', l.signed_copy_path, 'signed_uploaded_at', l.signed_uploaded_at, 'employee_signed_date', l.employee_signed_date,
      'employer_signed_date', l.employer_signed_date, 'employer_signatory', l.employer_signatory, 'physical_original_received', l.physical_original_received,
      'physical_original_location', l.physical_original_location, 'verified_at', l.verified_at, 'verified_by_name', private.cms_user_name(l.verified_by),
      'stamp_status', l.stamp_status, 'stamp_due_date', l.stamp_due_date, 'stamp_submitted_date', l.stamp_submitted_date, 'stamp_completed_date', l.stamp_completed_date,
      'stamp_reference', l.stamp_reference, 'stamp_certificate_path', l.stamp_certificate_path, 'company_code', l.company_code) end);
end $f$;
revoke all on function public.cms_app_hr(uuid) from public, anon;
grant execute on function public.cms_app_hr(uuid) to authenticated;

-- 1 · stage
create or replace function public.cms_app_set_stage(p_app uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare cur text; co text := private.cms_app_company(p_app); dec text;
begin
  if co is null then raise exception 'Application not found.'; end if;
  if not public.cms_can('recruitment', 'E', co) then raise exception 'You cannot change applications for this company.'; end if;
  select workflow_stage into cur from public.eaf_applications where id = p_app for update;
  if cur = p_to then return; end if;
  if not public.eaf_workflow_transition_allowed(cur, p_to) then raise exception 'This step is not allowed: % → %', cur, p_to; end if;
  dec := case p_to when 'shortlisted' then 'Approved' when 'rejected' then 'Disapproved' when 'kiv' then 'KIV' end;
  update public.eaf_applications set workflow_stage = p_to,
         payload = case when dec is not null then jsonb_set(coalesce(payload, '{}'::jsonb), '{decision}', to_jsonb(dec), true) else payload end, updated_at = now()
   where id = p_app;
  if nullif(btrim(coalesce(p_note, '')), '') is not null then
    update public.eaf_application_events set note = btrim(p_note)
     where id = (select id from public.eaf_application_events where application_id = p_app and to_stage = p_to order by created_at desc limit 1);
  end if;
  perform private.cms_log('application.stage', 'eaf_applications', p_app::text, co, 'Application moved from ' || cur || ' to ' || p_to, jsonb_build_object('note', p_note));
end $f$;
revoke all on function public.cms_app_set_stage(uuid, text, text) from public, anon;
grant execute on function public.cms_app_set_stage(uuid, text, text) to authenticated;

-- 2 · Office Use and interview (only these keys; values as MEG-EAF V2 stores them)
create or replace function public.cms_app_office_save(p_app uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare co text := private.cms_app_company(p_app); patch jsonb;
  keys text[] := array['interviewedBy', 'interviewedBy2', 'decision', 'finalSalary', 'finalFrom', 'finalTo', 'finalStart', 'finalDept', 'cb_doc', 'docOther',
                       'officeComments', 'cmsInterviewAt', 'cmsInterviewPlace', 'cmsInterviewNotes'];
begin
  if co is null then raise exception 'Application not found.'; end if;
  if not public.cms_can('recruitment', 'E', co) then raise exception 'You cannot change applications for this company.'; end if;
  if p ? 'decision' and coalesce(p->>'decision', '') not in ('', 'Approved', 'Disapproved', 'KIV', 'Others') then raise exception 'Unknown decision.'; end if;
  if p ? 'cb_doc' and jsonb_typeof(p->'cb_doc') <> 'array' then raise exception 'Documents must be a list.'; end if;
  select coalesce(jsonb_object_agg(k, case when jsonb_typeof(p->k) = 'string' then to_jsonb(btrim(p->>k)) else p->k end), '{}'::jsonb) into patch
    from unnest(keys) k where p ? k;
  update public.eaf_applications set payload = coalesce(payload, '{}'::jsonb) || patch, updated_at = now() where id = p_app;
  perform private.cms_log('application.office', 'eaf_applications', p_app::text, co, 'Office Use / interview updated', jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(patch) k)));
end $f$;
revoke all on function public.cms_app_office_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_app_office_save(uuid, jsonb) to authenticated;

-- 3 · issued offer letter: signed copy, verification, stamp duty (MEG-EAF V2 rules; the guard trigger checks the lifecycle)
-- p_action: 'signed' {path, employee_signed_date, employer_signed_date, employer_signatory, stamp_due_date}
--           'verify' {} · 'stamp_cert' {path} · 'meta' {physical_original_received, physical_original_location, stamp_status, stamp_due_date,
--           stamp_submitted_date, stamp_completed_date, stamp_reference, and the signature fields while no signed copy is stored}
create or replace function public.cms_loec_record_update(p_loec uuid, p_action text, p jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.eaf_loec_records; co text; st text; ver boolean; sub date; comp date; pre text;
begin
  select * into l from public.eaf_loec_records where id = p_loec for update;
  if l.id is null then raise exception 'Offer letter not found.'; end if;
  co := private.cms_app_company(l.application_id);
  if not (public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co)) then raise exception 'You cannot update offer letters for this company.'; end if;
  if l.status in ('superseded', 'cancelled') then raise exception 'This revision is closed.'; end if;
  pre := lower(l.company_code) || '/[0-9]{4}/' || replace(l.document_id, '/', '-') || '/';   -- the folder name cannot hold '/' (CMS references do)
  if p_action = 'signed' then
    if l.status <> 'issued' then raise exception 'The letter must be issued before the signed copy is uploaded.'; end if;
    if l.signed_copy_path is not null then raise exception 'A signed copy is already stored for this revision.'; end if;
    if coalesce(p->>'path', '') !~ ('^' || pre || 'SIGNED\.pdf$') then raise exception 'The signed copy is not in the expected folder.'; end if;
    if nullif(p->>'employee_signed_date', '') is null or nullif(p->>'employer_signed_date', '') is null or nullif(btrim(coalesce(p->>'employer_signatory', '')), '') is null then
      raise exception 'Enter the employee signed date, employer signed date and employer signatory.'; end if;
    update public.eaf_loec_records set signed_copy_path = p->>'path', status = 'signed_uploaded', signed_uploaded_at = now(),
      employee_signed_date = (p->>'employee_signed_date')::date, employer_signed_date = (p->>'employer_signed_date')::date, employer_signatory = btrim(p->>'employer_signatory'),
      stamp_due_date = coalesce(nullif(p->>'stamp_due_date', '')::date, greatest((p->>'employee_signed_date')::date, (p->>'employer_signed_date')::date) + 30),
      updated_by = auth.uid() where id = l.id;
    perform private.cms_app_stage(l.application_id, 'offer_accepted', 'Signed offer letter ' || l.document_id || ' uploaded in the CMS');
  elsif p_action = 'verify' then
    if l.status <> 'signed_uploaded' or l.signed_copy_path is null then raise exception 'Only a newly uploaded signed copy can be verified.'; end if;
    update public.eaf_loec_records set status = 'stamp_pending', verified_at = now(), verified_by = auth.uid(), updated_by = auth.uid() where id = l.id;
  elsif p_action = 'stamp_cert' then
    if l.stamp_certificate_path is not null then raise exception 'A stamp certificate is already stored for this revision.'; end if;
    if l.verified_at is null then raise exception 'HR must verify the signed copy before the stamp certificate is uploaded.'; end if;
    if coalesce(p->>'path', '') !~ ('^' || pre || 'STAMP_CERTIFICATE\.pdf$') then raise exception 'The stamp certificate is not in the expected folder.'; end if;
    update public.eaf_loec_records set stamp_certificate_path = p->>'path', stamp_status = 'stamped', stamp_completed_date = coalesce(stamp_completed_date, (now() at time zone 'Asia/Kuala_Lumpur')::date),
      status = 'completed', updated_by = auth.uid() where id = l.id;
  elsif p_action = 'meta' then
    st := coalesce(nullif(p->>'stamp_status', ''), l.stamp_status, 'pending');
    if st not in ('pending', 'submitted', 'stamped', 'not_required') then raise exception 'Unknown stamp status.'; end if;
    ver := l.verified_at is not null;
    sub := coalesce(nullif(p->>'stamp_submitted_date', '')::date, case when st = 'submitted' then (now() at time zone 'Asia/Kuala_Lumpur')::date end);
    comp := coalesce(nullif(p->>'stamp_completed_date', '')::date, case when st = 'stamped' then (now() at time zone 'Asia/Kuala_Lumpur')::date end);
    update public.eaf_loec_records set
      status = case when ver and st in ('pending', 'submitted') then 'stamp_pending' when ver and st in ('stamped', 'not_required') then 'completed' else status end,
      employee_signed_date = case when signed_copy_path is null and p ? 'employee_signed_date' then nullif(p->>'employee_signed_date', '')::date else employee_signed_date end,
      employer_signed_date = case when signed_copy_path is null and p ? 'employer_signed_date' then nullif(p->>'employer_signed_date', '')::date else employer_signed_date end,
      employer_signatory = case when signed_copy_path is null and p ? 'employer_signatory' then nullif(btrim(p->>'employer_signatory'), '') else employer_signatory end,
      physical_original_received = coalesce((p->>'physical_original_received')::boolean, physical_original_received),
      physical_original_location = case when p ? 'physical_original_location' then nullif(btrim(p->>'physical_original_location'), '') else physical_original_location end,
      stamp_status = st, stamp_due_date = case when p ? 'stamp_due_date' then nullif(p->>'stamp_due_date', '')::date else stamp_due_date end,
      stamp_submitted_date = sub, stamp_completed_date = comp,
      stamp_reference = case when p ? 'stamp_reference' then nullif(btrim(p->>'stamp_reference'), '') else stamp_reference end,
      updated_by = auth.uid() where id = l.id;
  else
    raise exception 'Unknown action %', p_action;
  end if;
  perform private.cms_log('loec.' || p_action, 'eaf_loec_records', l.id::text, co, 'Offer letter ' || l.document_id || ': ' ||
    case p_action when 'signed' then 'signed copy uploaded' when 'verify' then 'signed copy verified' when 'stamp_cert' then 'stamp certificate uploaded' else 'stamp duty details saved' end, coalesce(p, '{}'::jsonb));
end $f$;
revoke all on function public.cms_loec_record_update(uuid, text, jsonb) from public, anon;
grant execute on function public.cms_loec_record_update(uuid, text, jsonb) to authenticated;

-- signed copies and stamp certificates in the same storage folder MEG-EAF V2 uses, for CMS users with Recruitment / Onboarding edit
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms_loec_storage_insert') then
    create policy cms_loec_storage_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'eaf-loec' and name ~ '^(meg|meh|hds|abn)/[0-9]{4}/[^/]+/(SIGNED|STAMP_CERTIFICATE)\.pdf$'
                  and (public.cms_can('recruitment', 'E') or public.cms_can('onboarding', 'E')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms_loec_storage_select') then
    create policy cms_loec_storage_select on storage.objects for select to authenticated
      using (bucket_id = 'eaf-loec' and (public.cms_can('recruitment', 'V') or public.cms_can('onboarding', 'V')));
  end if;
end $p$;

-- 4 · recruitment open / closed per general job title
create or replace function public.cms_recruit_families()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when public.cms_can('recruitment', 'V') then coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'entity', e.code, 'entity_name', e.name,
      'company', private.cms_canon(e.code), 'open', coalesce(d.is_open_for_recruitment, false),
      'approved', (select count(*) from public.jd_positions p where p.department_id = d.id and p.entity_id = d.entity_id and lower(coalesce(p.status::text, '')) = 'approved'),
      'can_edit', public.cms_can('recruitment', 'E', private.cms_canon(e.code)))
      order by e.code, d.display_order nulls last, d.name)
    from public.jd_departments d join public.jd_entities e on e.id = d.entity_id where coalesce(d.is_active, true)), '[]'::jsonb) end;
$$;
revoke all on function public.cms_recruit_families() from public, anon;
grant execute on function public.cms_recruit_families() to authenticated;

create or replace function public.cms_recruit_family_open(p_department uuid, p_open boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare d public.jd_departments; co text;
begin
  select * into d from public.jd_departments where id = p_department and coalesce(is_active, true);
  if d.id is null then raise exception 'General job title not found.'; end if;
  co := private.cms_canon((select code from public.jd_entities where id = d.entity_id));
  if not public.cms_can('recruitment', 'E', co) then raise exception 'You cannot open or close posts for this company.'; end if;
  if coalesce(p_open, false) and not exists (select 1 from public.jd_positions p where p.department_id = d.id and p.entity_id = d.entity_id and lower(coalesce(p.status::text, '')) = 'approved') then
    raise exception 'A general job title can be opened only when it has at least one approved JD level.'; end if;
  update public.jd_departments set is_open_for_recruitment = coalesce(p_open, false) where id = d.id;
  perform private.cms_log('recruitment.open', 'jd_departments', d.id::text, co, d.name || case when p_open then ' opened' else ' closed' end || ' for applications', '{}'::jsonb);
end $f$;
revoke all on function public.cms_recruit_family_open(uuid, boolean) from public, anon;
grant execute on function public.cms_recruit_family_open(uuid, boolean) to authenticated;
