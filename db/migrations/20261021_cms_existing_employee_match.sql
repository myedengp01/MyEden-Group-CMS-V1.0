-- MyEden Group CMS V1.0 · approved applicants who are already employees
-- Staff imported from the workbook have no link back to their MEG-EAF V2 application, so Offers & Onboarding listed
-- them as "to hire" and Hire would have created a duplicate person, Employee ID and payroll record.
-- 1. An application is matched to an existing employee by email or by name (letters only, case ignored).
-- 2. Offers & Onboarding shows the match ("Already an employee") with "Link" instead of "Hire".
-- 3. cms_hire refuses to create a new person who matches an existing employee.
-- 4. Applications named "... DO NOT PROCESS" (workflow tests) are not listed.
-- 5. One-off: approved applications with exactly one matching employee are linked now.

create or replace function private.cms_norm_name(p text)
returns text language sql immutable as $$ select nullif(regexp_replace(upper(coalesce(p, '')), '[^A-Z]', '', 'g'), '') $$;

-- existing employees matching a name / email (most recent first)
create or replace function private.cms_existing_matches(p_name text, p_email text, p_exclude uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name,
            'status', em.employment_status, 'company', private.cms_canon(em.company_code),
            'by', case when em.email is not null and lower(btrim(em.email)) = lower(btrim(p_email)) then 'email' else 'name' end)
          order by em.start_date desc nulls last), '[]'::jsonb)
    from public.employee_master em
   where (p_exclude is null or em.id <> p_exclude)
     and ((private.cms_norm_name(em.employee_name) = private.cms_norm_name(p_name))
       or (nullif(btrim(p_email), '') is not null and em.email is not null and lower(btrim(em.email)) = lower(btrim(p_email))));
$$;

create or replace function public.cms_onboarding()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $function$
declare v_pay boolean;
begin
  perform private.cms_require('onboarding', 'V');
  v_pay := public.cms_can('onboarding', 'E');
  return jsonb_build_object(
    'can_hire', public.cms_can('onboarding', 'E') and public.cms_can('people', 'E') and public.cms_can('payroll.paying', 'E'),
    'offers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'application_id', l.application_id, 'name', upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)),
        'company', private.cms_canon(upper(l.company_code)), 'document_id', l.document_id, 'revision', l.revision, 'status', l.status,
        'jd_reference', l.jd_reference, 'issued_at', l.issued_at, 'employee_signed', l.employee_signed_date, 'employer_signed', l.employer_signed_date,
        'verified_at', l.verified_at, 'stamp_status', l.stamp_status, 'stamp_due', l.stamp_due_date, 'stamp_done', l.stamp_completed_date,
        'original_received', l.physical_original_received) order by l.created_at desc)
      from public.eaf_loec_records l join public.eaf_applications a on a.id = l.application_id
      where l.status not in ('superseded','cancelled')), '[]'::jsonb),
    'accepted', coalesce((select jsonb_agg(jsonb_build_object(
        'application_id', a.id, 'name', upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)),
        'company', private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg'))), 'stage', a.workflow_stage,
        'decision', a.payload->>'decision',
        'title', coalesce(nullif(a.payload->>'approvedJobTitle', ''), a.position_applied), 'start', nullif(a.payload->>'finalStart', ''),
        'department', a.payload->>'finalDept',
        'ready', nullif(btrim(a.payload->>'finalStart'), '') is not null and nullif(btrim(a.payload->>'finalSalary'), '') is not null,
        'matches', private.cms_existing_matches(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name), a.payload->>'email'),
        'handoff_id', h.id, 'handoff', h.handoff_status) order by nullif(a.payload->>'finalStart', '') desc nulls last, a.updated_at desc)
      from public.eaf_applications a left join public.eaf_onboarding_handoffs h on h.application_id = a.id
      where (a.workflow_stage in ('offer_accepted','ready_for_onboarding') or (a.payload->>'decision' = 'Approved' and a.workflow_stage not in ('rejected','offer_declined')))
        and coalesce(h.handoff_status, '') <> 'imported'
        and upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name, '')) not like '%DO NOT PROCESS%'
        and not exists (select 1 from public.employee_master em where em.source_application_id = a.id)), '[]'::jsonb),
    'to_payroll', coalesce((select jsonb_agg(jsonb_build_object(
        'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
        'status', em.employment_status, 'start', em.start_date, 'title', em.approved_job_title, 'department', em.department,
        'source', em.source_type, 'handoff_id', em.source_handoff_id) order by em.start_date desc nulls last)
      from public.employee_master em
      where em.employment_status in ('onboarding','active')
        and not exists (select 1 from public.eppd_employees ee where ee.employee_master_id = em.id)), '[]'::jsonb),
    'can_see_pay', v_pay);
end $function$;

-- link an approved application to the employee it already became
create or replace function public.cms_link_application(p_application uuid, p_person uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; em public.employee_master;
begin
  select * into a from public.eaf_applications where id = p_application;
  if a.id is null then raise exception 'Application not found.'; end if;
  select * into em from public.employee_master where id = p_person for update;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('onboarding', 'E', private.cms_canon(em.company_code));
  if em.source_application_id is not null and em.source_application_id <> a.id then
    raise exception '% is already linked to another application.', em.employee_name;
  end if;
  if exists (select 1 from public.employee_master where source_application_id = a.id and id <> em.id) then
    raise exception 'This application is already linked to another employee.';
  end if;
  update public.employee_master set source_application_id = a.id, updated_at = now() where id = em.id;
  update public.eaf_applications set workflow_stage = 'completed', updated_at = now() where id = a.id and workflow_stage is distinct from 'completed';
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'application_linked', 'MEG-EAF V2 application linked to the existing employee record',
          jsonb_build_object('application_id', a.id), auth.uid());
  perform private.cms_log('person.application_linked', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || coalesce(' (' || em.employee_id || ')', '') || ': MEG-EAF V2 application linked', jsonb_build_object('application_id', a.id));
end $$;
revoke all on function public.cms_link_application(uuid, uuid) from public, anon;
grant execute on function public.cms_link_application(uuid, uuid) to authenticated;
revoke all on function private.cms_existing_matches(text, text, uuid) from public, anon;

-- Hire never creates a second record for someone who is already an employee
do $m$ declare d text := pg_get_functiondef('public.cms_hire(jsonb)'::regprocedure); n text;
begin
  if position('cms_existing_matches' in d) > 0 then return; end if;
  n := replace(d, $x$  if em.id is null then
    insert into public.employee_master$x$, $x$  if em.id is null and jsonb_array_length(private.cms_existing_matches(v_name, p->>'email')) > 0 then
    raise exception '% is already an employee (%). Use "Link" on Offers & Onboarding, or Rehire in Former Staff.', v_name,
      (select string_agg(coalesce(x->>'employee_id', 'no Employee ID') || ' · ' || (x->>'status'), ', ')
         from jsonb_array_elements(private.cms_existing_matches(v_name, p->>'email')) x);
  end if;
  if em.id is null then
    insert into public.employee_master$x$);
  if n = d then raise exception 'cms_hire patch point not found'; end if;
  execute n;
end $m$;

-- one-off: approved applications with exactly one matching employee are linked now (audit-logged per person)
do $o$ declare r record;
begin
  for r in
    select a.id app, (m->0->>'person_id')::uuid person, upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)) nm
      from public.eaf_applications a
      cross join lateral (select private.cms_existing_matches(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name), a.payload->>'email') m) x
     where (a.workflow_stage in ('offer_accepted','ready_for_onboarding') or (a.payload->>'decision' = 'Approved' and a.workflow_stage not in ('rejected','offer_declined')))
       and not exists (select 1 from public.employee_master em where em.source_application_id = a.id)
       and jsonb_array_length(m) = 1
  loop
    if exists (select 1 from public.employee_master where id = r.person and source_application_id is null) then
      update public.employee_master set source_application_id = r.app, updated_at = now() where id = r.person;
      update public.eaf_applications set workflow_stage = 'completed', updated_at = now() where id = r.app and workflow_stage is distinct from 'completed';
      insert into public.employee_events (employee_id_ref, event_type, note, payload)
      values (r.person, 'application_linked', 'MEG-EAF V2 application linked to the existing employee record (one-off clean-up)', jsonb_build_object('application_id', r.app));
    end if;
  end loop;
end $o$;
