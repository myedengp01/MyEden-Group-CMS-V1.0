-- MyEden Group CMS V1.0 · Phase 3 fix: hire from an APPROVED application (what HR actually records in MEG-EAF V2).
-- MEG-EAF V2 has no screen for the "offer accepted" stage or the onboarding handoff, so approved applicants never reached
-- Offers & Onboarding. Now an application counts as ready to hire when its decision is Approved (or it reached offer
-- accepted / ready for onboarding) and the Office Use start date and salary are filled, and nobody has been created from it.
-- cms_hire also accepts application_id: it writes the onboarding handoff itself, then creates the person + payroll record.

create or replace function public.cms_onboarding()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
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
        'handoff_id', h.id, 'handoff', h.handoff_status) order by nullif(a.payload->>'finalStart', '') desc nulls last, a.updated_at desc)
      from public.eaf_applications a left join public.eaf_onboarding_handoffs h on h.application_id = a.id
      where (a.workflow_stage in ('offer_accepted','ready_for_onboarding') or (a.payload->>'decision' = 'Approved' and a.workflow_stage not in ('rejected','offer_declined')))
        and coalesce(h.handoff_status, '') <> 'imported'
        and not exists (select 1 from public.employee_master em where em.source_application_id = a.id)), '[]'::jsonb),
    'to_payroll', coalesce((select jsonb_agg(jsonb_build_object(
        'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
        'status', em.employment_status, 'start', em.start_date, 'title', em.approved_job_title, 'department', em.department,
        'source', em.source_type, 'handoff_id', em.source_handoff_id) order by em.start_date desc nulls last)
      from public.employee_master em
      where em.employment_status in ('onboarding','active')
        and not exists (select 1 from public.eppd_employees ee where ee.employee_master_id = em.id)), '[]'::jsonb),
    'can_see_pay', v_pay);
end $$;

-- prefill straight from an application's Office Use section
create or replace function public.cms_hire_prefill_app(p_application uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; p jsonb; v_gender text; v_base jsonb;
begin
  perform private.cms_require('onboarding', 'E');
  select * into a from public.eaf_applications where id = p_application;
  if a.id is null then raise exception 'Application not found'; end if;
  if exists (select 1 from public.employee_master where source_application_id = a.id) then raise exception 'An employee record already exists for this application.'; end if;
  p := coalesce(a.payload, '{}'::jsonb);
  v_gender := upper(left(coalesce(p->>'radio_gender', ''), 1));
  -- the pick-lists, from the common prefill (any person works: use the pick-list part only)
  select jsonb_build_object(
    'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name) order by c.sort_order, c.id) from public.eppd_companies c where c.is_active), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name', d.name, 'company_id', d.company_id) order by d.sort_order, d.code) from public.eppd_departments d where d.is_active), '[]'::jsonb),
    'titles', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name) from public.eppd_job_titles t where t.is_active), '[]'::jsonb),
    'statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
                          where category = 'confirmation_status' and is_active and coalesce((meta->>'is_active_employment')::boolean, true)), '[]'::jsonb),
    'job_statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
                              where category = 'job_status' and is_active), '[]'::jsonb)) into v_base;
  return v_base || jsonb_build_object(
    'application_id', a.id, 'handoff_id', null, 'person_id', null, 'employee_id', null, 'serial', null,
    'name', upper(coalesce(nullif(btrim(p->>'nameEnglish'), ''), a.applicant_name)),
    'employer', private.cms_canon(upper(coalesce(a.company_code, p->>'companyCode', 'meg'))),
    'gender', case when v_gender in ('M','F') then v_gender end,
    'join_date', nullif(p->>'finalStart', ''), 'title', coalesce(nullif(p->>'approvedJobTitle', ''), nullif(p->>'v2ResolvedJobTitle', '')),
    'level', p->>'jobTitleLevel', 'department', p->>'finalDept',
    'location', coalesce(nullif(p->>'workLocationOtherText', ''), p->>'workLocation'),
    'work_from', nullif(p->>'finalFrom', ''), 'work_to', nullif(p->>'finalTo', ''),
    'salary', nullif(regexp_replace(coalesce(p->>'finalSalary', ''), '[^0-9.]', '', 'g'), ''),
    'pay_basis', coalesce(nullif(p->>'v2PayBasis', ''), 'monthly'), 'employment_type', p->>'v2EmploymentType',
    'email', p->>'email', 'phone', p->>'contact', 'dob', nullif(p->>'dob', ''), 'nric', nullif(concat(p->>'ic1', p->>'ic2', p->>'ic3'), ''),
    'next_serial', private.cms_next_serial());
end $$;

-- writes (or reopens) the onboarding handoff for an approved application; returns its id
create or replace function private.cms_handoff_from_application(p_application uuid, p_employer text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; p jsonb; v_id uuid; v_salary numeric; v_start date; v_from time; v_to time;
begin
  select * into a from public.eaf_applications where id = p_application for update;
  if a.id is null then raise exception 'Application not found.'; end if;
  p := coalesce(a.payload, '{}'::jsonb);
  begin v_salary := nullif(regexp_replace(coalesce(p->>'finalSalary', ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then v_salary := null; end;
  begin v_start := nullif(p->>'finalStart', '')::date; v_from := nullif(p->>'finalFrom', '')::time; v_to := nullif(p->>'finalTo', '')::time;
  exception when others then v_start := null; end;
  insert into public.eaf_onboarding_handoffs (application_id, handoff_status, legal_entity_code, employee_name, email, contact, approved_job_title,
         job_title_level, department, work_location, final_salary, start_date, working_from, working_to, reporting_name, reporting_title,
         source_snapshot, created_by, updated_at, last_error)
  values (a.id, 'pending_import', p_employer, coalesce(nullif(btrim(p->>'nameEnglish'), ''), a.applicant_name), nullif(btrim(p->>'email'), ''),
         nullif(btrim(p->>'contact'), ''), nullif(btrim(p->>'approvedJobTitle'), ''), nullif(btrim(p->>'jobTitleLevel'), ''), nullif(btrim(p->>'finalDept'), ''),
         coalesce(nullif(btrim(p->>'workLocationOtherText'), ''), nullif(btrim(p->>'workLocation'), '')), v_salary, v_start, v_from, v_to,
         nullif(btrim(p->>'reportingName'), ''), nullif(btrim(p->>'reportingTitle'), ''),
         jsonb_build_object('application_id', a.id, 'submitted_at', a.submitted_at, 'applicant_name', a.applicant_name, 'position_applied', a.position_applied,
           'workflow_stage', a.workflow_stage, 'decision', p->>'decision', 'companyCode', p->>'companyCode', 'nameEnglish', p->>'nameEnglish', 'email', p->>'email',
           'contact', p->>'contact', 'dob', p->>'dob', 'radio_gender', p->>'radio_gender', 'approvedJobTitle', p->>'approvedJobTitle',
           'jobTitleLevel', p->>'jobTitleLevel', 'finalDept', p->>'finalDept', 'finalSalary', p->>'finalSalary', 'finalStart', p->>'finalStart',
           'finalFrom', p->>'finalFrom', 'finalTo', p->>'finalTo', 'reportingName', p->>'reportingName', 'reportingTitle', p->>'reportingTitle',
           'prepared_by', 'CMS'),
         auth.uid(), now(), null)
  on conflict (application_id) do update set
    handoff_status = case when public.eaf_onboarding_handoffs.handoff_status = 'imported' then 'imported' else 'pending_import' end,
    legal_entity_code = excluded.legal_entity_code, employee_name = excluded.employee_name, email = excluded.email, contact = excluded.contact,
    approved_job_title = excluded.approved_job_title, job_title_level = excluded.job_title_level, department = excluded.department,
    work_location = excluded.work_location, final_salary = excluded.final_salary, start_date = excluded.start_date,
    working_from = excluded.working_from, working_to = excluded.working_to, reporting_name = excluded.reporting_name,
    reporting_title = excluded.reporting_title, source_snapshot = excluded.source_snapshot, updated_at = now(), last_error = null
  returning id into v_id;
  return v_id;
end $$;
revoke all on function private.cms_handoff_from_application(uuid, text) from public, anon;

create or replace function public.cms_hire(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare h public.eaf_onboarding_handoffs; em public.employee_master; v_person uuid; v_serial int; v_id text; v_hid uuid;
        v_employer text := private.cms_canon(upper(nullif(btrim(p->>'employer'), '')));
        v_gender text := upper(left(coalesce(p->>'gender', ''), 1));
        v_join date := nullif(p->>'join_date', '')::date; v_name text := upper(btrim(coalesce(p->>'name', '')));
        v_comp public.eppd_companies; v_dept public.eppd_departments; v_title_id bigint; v_title text;
        v_emp bigint; v_empl bigint; v_asg bigint; v_salary numeric := nullif(p->>'salary', '')::numeric; v_basis text := coalesce(nullif(p->>'pay_basis', ''), 'monthly');
        v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform private.cms_require('onboarding', 'E', v_employer);
  perform private.cms_require('people', 'E', v_employer);
  perform private.cms_require('payroll.paying', 'E');
  if v_name = '' then raise exception 'Enter the name.'; end if;
  if v_gender not in ('M','F') then raise exception 'Confirm the gender (M or F): the Employee ID is built from it.'; end if;
  if v_join is null then raise exception 'Enter the start date.'; end if;
  if v_employer not in ('MEG','MEH','HD','ABP') then raise exception 'Choose the employer on the contract.'; end if;
  select * into v_comp from public.eppd_companies where id = nullif(p->>'company_id', '')::bigint and is_active;
  if v_comp.id is null then raise exception 'Choose the paying company.'; end if;
  if nullif(p->>'department_id', '') is not null then select * into v_dept from public.eppd_departments where id = (p->>'department_id')::bigint; end if;
  if v_salary is null or v_salary < 0 then raise exception 'Enter the starting salary.'; end if;
  if v_basis not in ('monthly','hourly','daily') then raise exception 'Unknown pay basis.'; end if;
  v_title_id := nullif(p->>'job_title_id', '')::bigint;
  if v_title_id is null and nullif(btrim(coalesce(p->>'job_title_name', '')), '') is not null then
    select id into v_title_id from public.eppd_job_titles where lower(name) = lower(btrim(p->>'job_title_name')) limit 1;
    if v_title_id is null then insert into public.eppd_job_titles (name, is_active) values (btrim(p->>'job_title_name'), true) returning id into v_title_id; end if;
  end if;
  select name into v_title from public.eppd_job_titles where id = v_title_id;

  perform pg_advisory_xact_lock(hashtext('eppd_emp_id'));

  -- from an approved application: write the onboarding handoff first (MEG-EAF V2 has no screen for it)
  if nullif(p->>'application_id', '') is not null and nullif(p->>'handoff_id', '') is null and nullif(p->>'person_id', '') is null then
    if exists (select 1 from public.employee_master where source_application_id = (p->>'application_id')::uuid) then
      raise exception 'An employee record already exists for this application.';
    end if;
    v_hid := private.cms_handoff_from_application((p->>'application_id')::uuid, v_employer);
    p := p || jsonb_build_object('handoff_id', v_hid);
  end if;

  if nullif(p->>'handoff_id', '') is not null then
    select * into h from public.eaf_onboarding_handoffs where id = (p->>'handoff_id')::uuid for update;
    if h.id is null then raise exception 'Onboarding handoff not found.'; end if;
    if h.handoff_status = 'cancelled' then raise exception 'This onboarding handoff was cancelled in MEG-EAF V2.'; end if;
    if h.handoff_status = 'imported' then select * into em from public.employee_master where source_handoff_id = h.id; end if;
  elsif nullif(p->>'person_id', '') is not null then
    select * into em from public.employee_master where id = (p->>'person_id')::uuid for update;
    if em.id is null then raise exception 'Person not found.'; end if;
  else raise exception 'Choose an accepted applicant or a person.'; end if;

  if em.id is not null and exists (select 1 from public.eppd_employees where employee_master_id = em.id) then
    raise exception '% is already in payroll.', em.employee_name;
  end if;

  if em.employee_id is not null then v_id := em.employee_id; v_serial := em.serial_no;
  else
    v_serial := private.cms_next_serial();
    v_id := public.format_group_employee_id(v_employer, v_join, v_gender, v_serial);
  end if;
  if exists (select 1 from public.eppd_employees where upper(emp_id) = upper(v_id)) then raise exception 'Employee ID % is already used in payroll.', v_id; end if;
  if em.id is null and exists (select 1 from public.employee_master where employee_id = v_id) then raise exception 'Employee ID % already exists.', v_id; end if;

  if em.id is null then
    insert into public.employee_master (employee_id, serial_no, company_code, employee_name, gender_code, start_date, original_group_join_date,
           employment_status, confirmation_status, email, contact, department, approved_job_title, job_title_level, work_location, final_salary,
           working_from, working_to, reporting_name, reporting_title, source_type, source_application_id, source_handoff_id, source_snapshot, created_by)
    values (v_id, v_serial, v_employer, v_name, v_gender, v_join, v_join,
           case when v_join <= v_today then 'active' else 'onboarding' end, 'probation',
           nullif(p->>'email', ''), nullif(p->>'phone', ''), coalesce(v_dept.code, h.department), coalesce(v_title, h.approved_job_title), h.job_title_level,
           h.work_location, v_salary, nullif(p->>'work_from', '')::time, nullif(p->>'work_to', '')::time, h.reporting_name, h.reporting_title,
           'eaf_handoff', h.application_id, h.id, h.source_snapshot, auth.uid())
    returning * into em;
    insert into public.employee_employment_history (employee_id_ref, sequence_no, event_type, company_code, effective_from, department, job_title, note, source_type, source_payload, created_by)
    values (em.id, 1, 'joined', v_employer, v_join, em.department, em.approved_job_title, 'Created in the CMS from the MEG-EAF V2 application', 'eaf_handoff', h.source_snapshot, auth.uid());
    update public.eaf_onboarding_handoffs set handoff_status = 'imported', imported_at = now(), import_reference = v_id, updated_at = now(), last_error = null where id = h.id;
    update public.eaf_applications set workflow_stage = 'completed', updated_at = now() where id = h.application_id and workflow_stage <> 'completed';
  else
    update public.employee_master set
           employee_id = coalesce(employee_id, v_id), serial_no = coalesce(serial_no, v_serial), gender_code = coalesce(gender_code, v_gender),
           start_date = coalesce(start_date, v_join), original_group_join_date = coalesce(original_group_join_date, v_join),
           employment_status = case when employment_status = 'onboarding' and v_join <= v_today then 'active' else employment_status end,
           updated_at = now()
     where id = em.id returning * into em;
  end if;
  v_person := em.id;

  insert into public.eppd_employees (emp_id, emp_serial, full_name, gender, email, phone, employee_master_id, remarks)
  values (v_id, v_serial, v_name, v_gender, nullif(p->>'email', ''), nullif(p->>'phone', ''), v_person, nullif(p->>'note', ''))
  returning id into v_emp;
  insert into public.eppd_employee_private (employee_id, nric, dob)
  values (v_emp, nullif(regexp_replace(coalesce(p->>'nric', ''), '\D', '', 'g'), ''), nullif(p->>'dob', '')::date);
  insert into public.eppd_employments (employee_id, join_date, confirmation_status, job_status, department_id, job_title_id,
         work_from, work_to, meal_hours, ot_days, ot_multiplier, notes)
  values (v_emp, v_join, coalesce(nullif(p->>'confirmation_status', ''), 'UP'), nullif(p->>'job_status', ''), v_dept.id, v_title_id,
          nullif(p->>'work_from', '')::time, nullif(p->>'work_to', '')::time, 1, 26, 1.5, 'Hired in the CMS')
  returning id into v_empl;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date) values (v_empl, v_comp.id, true, v_join) returning id into v_asg;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason) values (v_asg, v_join, v_salary, v_basis, 'Starting salary');
  if v_dept.code is not null and exists (select 1 from public.cms_units where code = v_dept.code) then
    insert into public.cms_employee_payroll (employee_master_id, unit_code, updated_by, updated_at) values (v_person, v_dept.code, auth.uid(), now())
    on conflict (employee_master_id) do update set unit_code = excluded.unit_code, updated_by = excluded.updated_by, updated_at = now();
  end if;

  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v_person, 'hired_in_cms', nullif(p->>'note', ''), jsonb_build_object('employee_id', v_id, 'payroll_employee', v_emp, 'handoff_id', h.id), auth.uid());
  perform private.cms_log('person.hire', 'employee_master', v_person::text, v_employer,
    v_name || ': hired from ' || to_char(v_join, 'DD Mon YYYY') || ' as ' || coalesce(v_title, '—') || ', paid by ' || v_comp.name || ', Employee ID ' || v_id,
    jsonb_build_object('employee_id', v_id, 'serial', v_serial, 'handoff_id', h.id, 'application_id', h.application_id, 'payroll_employee', v_emp,
                       'company', v_comp.code, 'department', v_dept.code, 'job_title', v_title, 'pay_basis', v_basis));
  return jsonb_build_object('person_id', v_person, 'employee_id', v_id, 'payroll_employee_id', v_emp);
end $$;

revoke all on function public.cms_hire_prefill_app(uuid) from public, anon;
grant execute on function public.cms_hire_prefill_app(uuid) to authenticated;
