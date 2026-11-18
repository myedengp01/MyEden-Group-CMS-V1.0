-- PRI-024 phase 1 (v2026.11.18): the offer letter (LOEC) in the HR Letters register, so every letter HR issues is in one place.
-- Additive. The LOEC keeps its own page, wording and format (MEG-EAF V2 "Combined Letter of Offer & Contract of Employment",
-- Version 2.0) and its own record (eaf_loec_records: terms, revisions, signed copy, stamp duty). Each LOEC is mirrored, under the
-- same id, into hr_letter_records as letter type LOEC on the applicant's person record, so HR Letters lists it with the other letters
-- (To do / In progress / Issued) and an e-signature can be applied on issue. The mirror is written only by the LOEC (a guard
-- refuses other changes except the e-signature). Preparing an offer creates the person as Applicant (CLC 18 Nov 2026); hiring turns
-- that same person into the employee.

-- ------------------------------------------------------------------ the LOEC letter type
insert into public.hr_letter_templates (code, title, version, body, active, status, letter_type, format, created_by_name, updated_at)
values ('LOEC', 'Letter of Offer & Contract of Employment (LOEC)', '2.0',
        'Combined Letter of Offer & Contract of Employment, Version 2.0. Prepared, approved and issued on the Offer letter page of the application (Recruitment › Applications).',
        false, 'published', 'LOEC', 'text', 'CMS', now())
on conflict (code) do nothing;

-- ------------------------------------------------------------------ the applicant's person record
create or replace function private.cms_applicant_person(p_application uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; a public.eaf_applications; v_p jsonb; v_code text; v_email text; v_contact text; v_start date;
begin
  select id into v from public.employee_master where source_application_id = p_application order by created_at desc limit 1;
  if v is not null then return v; end if;
  select * into a from public.eaf_applications where id = p_application; if a.id is null then return null; end if;
  v_p := coalesce(a.payload, '{}'::jsonb);
  v_code := private.cms_canon(upper(coalesce(a.company_code, v_p->>'companyCode', 'MEG'))); if v_code not in ('MEG','HD','ABP','MEH') then v_code := 'MEG'; end if;
  if v_p->>'cmsSigningCompany' in ('meg','meh','hds','abn') then v_code := private.cms_canon(upper(v_p->>'cmsSigningCompany')); end if;
  v_email := nullif(btrim(v_p->>'email'), ''); v_contact := nullif(btrim(v_p->>'contact'), '');
  begin v_start := nullif(v_p->>'finalStart', '')::date; exception when others then v_start := null; end;
  insert into public.employee_master (company_code, employee_name, gender_code, start_date, employment_status, confirmation_status, email, contact, department,
         approved_job_title, job_title_level, work_location, reporting_name, reporting_title, employment_type, source_type, source_application_id, source_snapshot, created_by)
  values (v_code, upper(coalesce(nullif(btrim(v_p->>'nameEnglish'), ''), a.applicant_name, 'APPLICANT')),
          case when lower(coalesce(v_p->>'radio_gender', '')) like 'f%' then 'F' when lower(coalesce(v_p->>'radio_gender', '')) like 'm%' then 'M' end,
          v_start, 'applicant', 'unknown', v_email, v_contact, nullif(v_p->>'finalDept', ''),
          coalesce(nullif(v_p->>'v2ResolvedJobTitle', ''), nullif(v_p->>'approvedJobTitle', '')), nullif(v_p->>'jobTitleLevel', ''), nullif(v_p->>'workLocation', ''),
          nullif(v_p->>'reportingName', ''), nullif(v_p->>'reportingTitle', ''), nullif(v_p->>'v2EmploymentType', ''),
          'eaf_handoff', a.id, jsonb_build_object('source', 'cms_offer_letter', 'application_id', a.id), auth.uid())
  returning id into v;
  insert into public.employee_personal_details (employee_id_ref, full_name_chinese, identification_type, identification_no, passport_no, marital_status, residential_address,
         personal_email, personal_contact, source_type, source_payload, created_by, updated_by)
  values (v, nullif(v_p->>'nameChinese', ''), case when coalesce((v_p->>'usingPassport')::boolean, false) then 'Passport' else 'IC' end,
          case when coalesce((v_p->>'usingPassport')::boolean, false) then null else nullif(concat_ws('-', nullif(v_p->>'ic1', ''), nullif(v_p->>'ic2', ''), nullif(v_p->>'ic3', '')), '') end,
          nullif(v_p->>'passport', ''), nullif(v_p->>'radio_marital', ''),
          nullif(concat_ws(', ', nullif(v_p->>'addr1', ''), nullif(v_p->>'addr2', ''), nullif(v_p->>'addr3', ''), nullif(v_p->>'postcodeTown', ''), nullif(v_p->>'addrState', '')), ''),
          v_email, v_contact, 'eaf_handoff', jsonb_build_object('application_id', a.id), auth.uid(), auth.uid())
  on conflict (employee_id_ref) do nothing;
  insert into public.employee_employment_history (employee_id_ref, sequence_no, event_type, company_code, effective_from, department, job_title, note, source_type, source_payload, created_by)
  values (v, 1, 'application', v_code, v_start, nullif(v_p->>'finalDept', ''), coalesce(nullif(v_p->>'v2ResolvedJobTitle', ''), nullif(v_p->>'approvedJobTitle', '')),
          'Applicant record made for the offer letter (CMS)', 'eaf_handoff', jsonb_build_object('application_id', a.id), auth.uid());
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v, 'applicant_created_for_offer', 'Applicant record made for the offer letter', jsonb_build_object('application_id', a.id), auth.uid());
  return v;
end $$;

-- ------------------------------------------------------------------ the mirror in hr_letter_records
create or replace function private.cms_loec_sync(p_loec uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.eaf_loec_records; a public.eaf_applications; v_person uuid; v_st text; v_by uuid; t jsonb; f jsonb; s jsonb; i jsonb; v_date date;
begin
  select * into l from public.eaf_loec_records where id = p_loec; if l.id is null then return; end if;
  select * into a from public.eaf_applications where id = l.application_id;
  v_person := private.cms_applicant_person(l.application_id); if v_person is null then return; end if;
  v_st := case when l.status in ('superseded', 'cancelled') then 'void'
               when l.status = 'draft' then case when l.approved_at is not null then 'approved' when l.submitted_at is not null then 'pending_approval' else 'draft' end
               else 'issued' end;
  v_by := coalesce(l.prepared_by, l.updated_by, l.approved_by, l.issued_by,
                   (select user_id from public.cms_user_roles where role_code = 'super_admin' and is_active order by user_id limit 1));
  t := coalesce(l.terms_snapshot, '{}'::jsonb);
  begin v_date := nullif(t->>'letterDate', '')::date; exception when others then v_date := null; end;
  f := t || jsonb_build_object('application_id', l.application_id, 'loec_id', l.id, 'document_id', l.document_id, 'revision', l.revision,
         '_signatory_id', t->>'cmsSignatoryId', 'authorized_signatory', coalesce(t->>'cmsSignatoryName', l.employer_signatory), 'authorized_designation', t->>'cmsSignatoryDesignation');
  s := jsonb_build_object('loec', true, 'loec_id', l.id, 'application_id', l.application_id, 'title', 'Letter of Offer & Contract of Employment (LOEC)',
         'text', 'Combined Letter of Offer & Contract of Employment ' || l.document_id || ' — open it on the Offer letter page.',
         'created_by_name', private.cms_user_name(v_by), 'submitted_at', l.submitted_at, 'approved_by_name', private.cms_user_name(l.approved_by), 'approved_text', '')
       || case when l.return_note is not null and l.status = 'draft' and l.submitted_at is null then jsonb_build_object('rejected', jsonb_build_object('reason', l.return_note, 'by', private.cms_user_name(l.approved_by), 'at', l.updated_at)) else '{}'::jsonb end
       || case when l.status in ('superseded', 'cancelled') then jsonb_build_object('void_reason', coalesce(l.return_note, initcap(l.status))) else '{}'::jsonb end;
  i := case when v_st = 'issued' or (v_st = 'void' and l.issued_at is not null) then jsonb_build_object('text', s->>'text', 'issued_by_name', private.cms_user_name(l.issued_by), 'loec', true, 'format', 'loec') end;
  perform set_config('cms.loec_sync', 'on', true);
  insert into public.hr_letter_records (id, employee_id, company_code, template_code, template_version, status, fields, source_snapshot, issued_snapshot,
         created_by, approved_by, issued_by, created_at, updated_at, approved_at, issued_at, reference, origin, letter_date, signed_path, signed_on, signed_at)
  values (l.id, v_person, private.cms_canon(upper(l.company_code)), 'LOEC', coalesce(l.template_version, '2.0'), v_st, f, s, i,
          v_by, l.approved_by, l.issued_by, l.created_at, now(), case when v_st in ('approved', 'issued') or l.issued_at is not null then coalesce(l.approved_at, l.issued_at) end,
          l.issued_at, l.document_id, 'cms', v_date, l.signed_copy_path, l.employee_signed_date, l.signed_uploaded_at)
  on conflict (id) do update set employee_id = excluded.employee_id, company_code = excluded.company_code, status = excluded.status, fields = excluded.fields,
         source_snapshot = excluded.source_snapshot, issued_snapshot = excluded.issued_snapshot, approved_by = excluded.approved_by, issued_by = excluded.issued_by,
         updated_at = now(), approved_at = excluded.approved_at, issued_at = excluded.issued_at, reference = excluded.reference, letter_date = excluded.letter_date,
         signed_path = excluded.signed_path, signed_on = excluded.signed_on, signed_at = excluded.signed_at,
         esign = case when excluded.status in ('draft', 'pending_approval') then null else public.hr_letter_records.esign end;
  perform set_config('cms.loec_sync', 'off', true);
end $$;

create or replace function private.cms_loec_sync_trg() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform private.cms_loec_sync(new.id); return new; end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'cms_loec_to_letters') then
    create trigger cms_loec_to_letters after insert or update on public.eaf_loec_records for each row execute function private.cms_loec_sync_trg();
  end if;
end $$;

-- the LOEC row in HR Letters is changed only through the offer letter (the e-signature on issue is the one exception)
create or replace function private.cms_loec_guard() returns trigger language plpgsql as $$
begin
  if old.template_code = 'LOEC' and coalesce(current_setting('cms.loec_sync', true), '') <> 'on'
     and (to_jsonb(new) - 'esign' - 'updated_at') is distinct from (to_jsonb(old) - 'esign' - 'updated_at') then
    raise exception 'Offer letters (LOEC) are changed on the Offer letter page of the application.';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'cms_loec_guard') then
    create trigger cms_loec_guard before update on public.hr_letter_records for each row execute function private.cms_loec_guard();
  end if;
end $$;

-- ------------------------------------------------------------------ patches (each guarded by a marker, so running twice changes nothing)
do $$ declare d text;
begin
  -- the offer letter keeps the signatory chosen for the Company (name, designation, signatory list id)
  d := pg_get_functiondef('public.cms_loec_save(uuid, jsonb)'::regprocedure);
  if strpos(d, 'cmsSignatoryId') = 0 then
    d := replace(d, '''cmsClauseOt'',''cmsClauseAlProrate'',''cmsClauseAlExcess''];', '''cmsClauseOt'',''cmsClauseAlProrate'',''cmsClauseAlExcess'',''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation''];');
    d := replace(d, 'where source_application_id = a.id) then raise exception ''This applicant is already hired', 'where source_application_id = a.id and employment_status <> ''applicant'') then raise exception ''This applicant is already hired');
    if strpos(d, 'cmsSignatoryId') = 0 or strpos(d, 'employment_status <> ''applicant''') = 0 then raise exception 'cms_loec_save: marker not found'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.cms_loec_get(uuid)'::regprocedure);
  if strpos(d, 'cmsSignatoryId') = 0 then
    d := replace(d, '''cmsClauseOt'',''cmsClauseAlProrate'',''cmsClauseAlExcess'']) k where p ? k)', '''cmsClauseOt'',''cmsClauseAlProrate'',''cmsClauseAlExcess'',''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation'']) k where p ? k)');
    d := replace(d, '''issued_by'', private.cms_user_name(l.issued_by))', '''issued_by'', private.cms_user_name(l.issued_by), ''esign'', (select r.esign from public.hr_letter_records r where r.id = l.id))');
    if strpos(d, 'cmsSignatoryId') = 0 or strpos(d, 'r.esign') = 0 then raise exception 'cms_loec_get: marker not found'; end if;
    execute d;
  end if;
  -- the HR Letters bell does not count offer letters twice (they have their own reminder)
  d := pg_get_functiondef('public.cms_letters_pending()'::regprocedure);
  if strpos(d, 'LOEC') = 0 then
    d := replace(d, 'where status = ''pending_approval'' and created_by is distinct from auth.uid())', 'where status = ''pending_approval'' and created_by is distinct from auth.uid() and template_code <> ''LOEC'')');
    d := replace(d, 'where status = ''approved'')', 'where status = ''approved'' and template_code <> ''LOEC'')');
    if (select count(*) from regexp_matches(d, 'LOEC', 'g')) <> 2 then raise exception 'cms_letters_pending: marker not found'; end if;
    execute d;
  end if;
  -- Offers & Onboarding: an applicant with an offer is still to be hired, and is not a "match" with themself
  d := pg_get_functiondef('public.cms_onboarding()'::regprocedure);
  if strpos(d, 'em.employment_status <> ''applicant''') = 0 then
    d := replace(d, 'and not exists (select 1 from public.employee_master em where em.source_application_id = a.id)), ''[]''::jsonb),',
                    'and not exists (select 1 from public.employee_master em where em.source_application_id = a.id and em.employment_status <> ''applicant'')), ''[]''::jsonb),');
    d := replace(d, '''matches'', private.cms_existing_matches(coalesce(nullif(btrim(a.payload->>''nameEnglish''), ''''), a.applicant_name), a.payload->>''email''),',
                    '''matches'', private.cms_existing_matches(coalesce(nullif(btrim(a.payload->>''nameEnglish''), ''''), a.applicant_name), a.payload->>''email'', (select x.id from public.employee_master x where x.source_application_id = a.id and x.employment_status = ''applicant'' limit 1)),');
    if strpos(d, 'em.employment_status <> ''applicant''') = 0 or strpos(d, 'x.employment_status = ''applicant''') = 0 then raise exception 'cms_onboarding: marker not found'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.cms_hire_prefill_app(uuid)'::regprocedure);
  if strpos(d, 'employment_status <> ''applicant''') = 0 then
    d := replace(d, 'if exists (select 1 from public.employee_master where source_application_id = a.id) then raise exception', 'if exists (select 1 from public.employee_master where source_application_id = a.id and employment_status <> ''applicant'') then raise exception');
    if strpos(d, 'employment_status <> ''applicant''') = 0 then raise exception 'cms_hire_prefill_app: marker not found'; end if;
    execute d;
  end if;
  -- hiring from the application: the applicant's own person record becomes the employee
  d := pg_get_functiondef('public.cms_hire(jsonb)'::regprocedure);
  if strpos(d, 'v_pre') = 0 then
    d := replace(d, 'v_today date := (now() at time zone ''Asia/Kuala_Lumpur'')::date;', 'v_today date := (now() at time zone ''Asia/Kuala_Lumpur'')::date; v_pre boolean := false; v_app_person public.employee_master;');
    d := replace(d, '    if exists (select 1 from public.employee_master where source_application_id = (p->>''application_id'')::uuid) then',
                    '    select * into v_app_person from public.employee_master where source_application_id = (p->>''application_id'')::uuid and employment_status = ''applicant'' order by created_at desc limit 1;
    if exists (select 1 from public.employee_master where source_application_id = (p->>''application_id'')::uuid and employment_status <> ''applicant'') then');
    d := replace(d, '  if em.id is not null and exists (select 1 from public.eppd_employees where employee_master_id = em.id) then',
                    '  if em.id is null and v_app_person.id is not null then select * into em from public.employee_master where id = v_app_person.id for update; v_pre := true; end if;
  if em.id is not null and exists (select 1 from public.eppd_employees where employee_master_id = em.id) then');
    d := replace(d, '  if em.id is null then
    insert into public.employee_master (employee_id, serial_no, company_code,',
                    '  if em.id is null or v_pre then
    if v_pre then
    update public.employee_master set employee_id = v_id, serial_no = v_serial, company_code = v_employer, employee_name = v_name, gender_code = v_gender,
           start_date = v_join, original_group_join_date = v_join, employment_status = case when v_join <= v_today then ''active'' else ''onboarding'' end,
           confirmation_status = case when p->>''confirmation_status'' = ''C'' then ''confirmed'' else ''probation'' end,
           email = coalesce(nullif(p->>''email'', ''''), email), contact = coalesce(nullif(p->>''phone'', ''''), contact), department = coalesce(v_dept.code, h.department, department),
           approved_job_title = coalesce(v_title, h.approved_job_title, approved_job_title), job_title_level = coalesce(h.job_title_level, job_title_level),
           work_location = coalesce(h.work_location, work_location), final_salary = v_salary, working_from = nullif(p->>''work_from'', '''')::time, working_to = nullif(p->>''work_to'', '''')::time,
           reporting_name = coalesce(h.reporting_name, reporting_name), reporting_title = coalesce(h.reporting_title, reporting_title), source_handoff_id = coalesce(h.id, source_handoff_id), updated_at = now()
     where id = em.id returning * into em;
    else
    insert into public.employee_master (employee_id, serial_no, company_code,');
    d := replace(d, '    returning * into em;
    insert into public.employee_employment_history (employee_id_ref, sequence_no, event_type,', '    returning * into em;
    end if;
    insert into public.employee_employment_history (employee_id_ref, sequence_no, event_type,');
    d := replace(d, 'values (em.id, 1, ''joined'',', 'values (em.id, (select coalesce(max(x.sequence_no), 0) + 1 from public.employee_employment_history x where x.employee_id_ref = em.id), ''joined'',');
    if (select count(*) from regexp_matches(d, 'v_pre', 'g')) < 4 or strpos(d, 'v_app_person.id is not null') = 0 or strpos(d, 'end if;
    insert into public.employee_employment_history') = 0 or strpos(d, 'max(x.sequence_no)') = 0 then raise exception 'cms_hire: marker not found'; end if;
    execute d;
  end if;
end $$;

-- ------------------------------------------------------------------ the offer letters already made
do $$ declare r record; begin
  for r in select id from public.eaf_loec_records order by created_at loop perform private.cms_loec_sync(r.id); end loop;
end $$;
