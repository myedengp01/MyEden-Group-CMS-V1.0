-- MyEden Group CMS V1.0 · Phase 3 · Recruitment & onboarding (MEG-EAF V2 data, same database)
-- Read functions for Applications, JD Manual, Positions, Offers & Onboarding and Handbook; one Employee ID numbering
-- for EAF, CMS and MyPayroll; and cms_hire: accepted applicant → person record + payroll record in one step.
-- Additive: no table changes. Two existing functions get a new body (same name and arguments):
--   eppd_next_emp_serial()          (MyPayroll)  and  preview_next_employee_serial()  (MEG-EAF V2)
-- both now return the same group-wide next number.

-- ---------------------------------------------------------------- 3.5 one Employee ID numbering
create or replace function private.cms_next_serial()
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  -- next group serial: after the highest used anywhere (person records and payroll); 1000 is reserved
  select case when n = 1000 then 1001 else n end from (
    select greatest(coalesce((select max(serial_no) from public.employee_master where serial_no is not null and serial_no <> 1000), 0),
                    coalesce((select max(emp_serial) from public.eppd_employees where emp_serial is not null and emp_serial <> 1000), 0)) + 1 as n) x;
$$;

create or replace function public.eppd_next_emp_serial()
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  select private.cms_next_serial();
$$;

create or replace function public.preview_next_employee_serial()
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  select private.cms_next_serial();
$$;

-- ---------------------------------------------------------------- 3.1 applications
create or replace function public.cms_recruit_applications()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('recruitment', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'name', upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)),
      'position', a.position_applied,
      'title', coalesce(nullif(a.payload->>'approvedJobTitle', ''), nullif(a.payload->>'v2ResolvedJobTitle', '')),
      'company', private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg'))),
      'stage', coalesce(a.workflow_stage, 'submitted'), 'decision', a.payload->>'decision',
      'submitted_at', a.submitted_at, 'updated_at', a.updated_at,
      'start', nullif(a.payload->>'finalStart', ''), 'email', a.payload->>'email', 'contact', a.payload->>'contact',
      'handoff', h.handoff_status, 'person_id', em.id, 'employee_id', em.employee_id,
      'in_payroll', exists (select 1 from public.eppd_employees ee where ee.employee_master_id = em.id),
      'loec', (select l.status from public.eaf_loec_records l where l.application_id = a.id and l.status not in ('superseded','cancelled')
               order by l.revision desc limit 1))
      order by a.submitted_at desc nulls last)
    from public.eaf_applications a
    left join public.eaf_onboarding_handoffs h on h.application_id = a.id
    left join public.employee_master em on em.source_application_id = a.id
    where private.cms_can_company('recruitment', 'V', private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg'))))), '[]'::jsonb);
end $$;

create or replace function public.cms_recruit_application(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; v_co text; p jsonb; v_pay boolean;
begin
  select * into a from public.eaf_applications where id = p_id;
  if a.id is null then raise exception 'Application not found'; end if;
  v_co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  perform private.cms_require('recruitment', 'V', v_co);
  p := coalesce(a.payload, '{}'::jsonb);
  v_pay := public.cms_can('recruitment', 'E', v_co);
  return jsonb_build_object(
    'id', a.id, 'name', upper(coalesce(nullif(btrim(p->>'nameEnglish'), ''), a.applicant_name)), 'chinese_name', p->>'nameChinese',
    'company', v_co, 'stage', coalesce(a.workflow_stage, 'submitted'), 'decision', p->>'decision',
    'position', a.position_applied, 'title', coalesce(nullif(p->>'approvedJobTitle', ''), nullif(p->>'v2ResolvedJobTitle', '')),
    'level', p->>'jobTitleLevel', 'jd_ref', coalesce(p->>'v2JdReference', p->>'selectedJdRefs'),
    'submitted_at', a.submitted_at, 'updated_at', a.updated_at, 'email', p->>'email', 'contact', p->>'contact',
    'gender', p->>'radio_gender', 'expected_salary', case when v_pay then p->>'salary' end,
    'available_from', p->>'startDate', 'interviewed_by', concat_ws(', ', nullif(p->>'interviewedBy', ''), nullif(p->>'interviewedBy2', '')),
    'department', p->>'finalDept', 'location', coalesce(nullif(p->>'workLocationOtherText', ''), p->>'workLocation'),
    'start', p->>'finalStart', 'hours', concat_ws(' – ', nullif(p->>'finalFrom', ''), nullif(p->>'finalTo', '')),
    'final_salary', case when v_pay then p->>'finalSalary' end, 'employment_type', p->>'v2EmploymentType', 'pay_basis', p->>'v2PayBasis',
    'probation_months', p->>'v2ProbationMonths', 'reporting', concat_ws(', ', nullif(p->>'reportingName', ''), nullif(p->>'reportingTitle', '')),
    'office_comments', case when v_pay then p->>'officeComments' end,
    'events', coalesce((select jsonb_agg(jsonb_build_object('from', e.from_stage, 'to', e.to_stage, 'at', e.created_at, 'note', e.note,
                 'by', coalesce(pr.full_name, u.email)) order by e.created_at)
               from public.eaf_application_events e left join public.profiles pr on pr.id = e.changed_by left join auth.users u on u.id = e.changed_by
               where e.application_id = a.id), '[]'::jsonb),
    'loec', (select jsonb_build_object('status', l.status, 'revision', l.revision, 'issued_at', l.issued_at, 'stamp_status', l.stamp_status,
                     'stamp_due_date', l.stamp_due_date) from public.eaf_loec_records l where l.application_id = a.id
             order by l.revision desc limit 1),
    'handoff', (select jsonb_build_object('id', h.id, 'status', h.handoff_status, 'imported_at', h.imported_at, 'reference', h.import_reference, 'error', h.last_error)
                from public.eaf_onboarding_handoffs h where h.application_id = a.id),
    'person', (select jsonb_build_object('id', em.id, 'employee_id', em.employee_id, 'status', em.employment_status,
                       'in_payroll', exists (select 1 from public.eppd_employees ee where ee.employee_master_id = em.id))
               from public.employee_master em where em.source_application_id = a.id limit 1));
end $$;

-- company-scoped permission test without raising (for list filters)
create or replace function private.cms_can_company(p_module text, p_action text, p_company text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_can(p_module, p_action, p_company);
$$;

-- ---------------------------------------------------------------- 3.2 JD Manual and positions
create or replace function public.cms_jd()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not (public.cms_can('jd', 'V') or public.cms_can('recruitment', 'V')) then perform private.cms_require('jd', 'V'); end if;
  return jsonb_build_object(
    'entities', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'code', private.cms_canon(e.code), 'name', e.name) order by e.display_order, e.code)
                          from public.jd_entities e where e.is_active), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'entity_id', d.entity_id, 'name', d.name, 'open', d.is_open_for_recruitment)
                             order by d.display_order, d.name) from public.jd_departments d where d.is_active), '[]'::jsonb),
    'positions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'entity_id', p.entity_id, 'department_id', p.department_id, 'reference', p.reference, 'title', p.job_title,
        'level', p.level, 'employment_type', p.employment_type, 'location', p.location, 'status', p.status, 'version', p.version,
        'effective_date', p.effective_date, 'open', p.is_open_for_recruitment, 'reports_to', p.reports_to, 'designation', p.designation_code,
        'staff', (select count(*) from public.employee_master em where em.employment_status in ('active','onboarding')
                   and lower(btrim(em.approved_job_title)) = lower(btrim(p.job_title))
                   and private.cms_canon(em.company_code) = (select private.cms_canon(e.code) from public.jd_entities e where e.id = p.entity_id)),
        'applications', (select count(*) from public.eaf_applications a where a.workflow_stage not in ('rejected','completed','offer_declined')
                          and (a.payload->>'v2JdId' = p.id::text or a.payload->'selectedJdIds' ? p.id::text)))
        order by p.reference) from public.jd_positions p), '[]'::jsonb),
    'can_see_pay', public.cms_can('recruitment', 'E'));
end $$;

create or replace function public.cms_jd_position(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.jd_positions; v_pay boolean;
begin
  if not (public.cms_can('jd', 'V') or public.cms_can('recruitment', 'V')) then perform private.cms_require('jd', 'V'); end if;
  select * into p from public.jd_positions where id = p_id;
  if p.id is null then raise exception 'Position not found'; end if;
  v_pay := public.cms_can('recruitment', 'E');
  return to_jsonb(p) || jsonb_build_object(
    'entity', (select private.cms_canon(e.code) from public.jd_entities e where e.id = p.entity_id),
    'department', (select d.name from public.jd_departments d where d.id = p.department_id),
    'responsibilities', coalesce((select jsonb_agg(jsonb_build_object('title', r.title, 'description', r.description) order by r.sequence)
                                  from public.jd_responsibilities r where r.position_id = p.id), '[]'::jsonb),
    'kpis', coalesce((select jsonb_agg(jsonb_build_object('area', k.area, 'measure', k.measure, 'frequency', k.review_frequency) order by k.sequence)
                      from public.jd_kpis k where k.position_id = p.id), '[]'::jsonb),
    'competencies', coalesce((select jsonb_agg(c.name order by c.sequence) from public.jd_competencies c where c.position_id = p.id), '[]'::jsonb),
    'core_values', coalesce((select jsonb_agg(jsonb_build_object('value', v.value_name, 'expectation', v.expectation) order by v.sequence)
                             from public.jd_core_values v where v.position_id = p.id), '[]'::jsonb),
    'salary_bands', case when v_pay then coalesce((select jsonb_agg(jsonb_build_object('tier', b.tier, 'min', b.salary_min, 'max', b.salary_max,
                        'range', b.display_range, 'profile', b.typical_profile) order by b.sequence) from public.jd_salary_bands b where b.position_id = p.id), '[]'::jsonb) end);
end $$;

-- ---------------------------------------------------------------- 3.3 offers & onboarding
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
        'title', a.payload->>'approvedJobTitle', 'start', a.payload->>'finalStart', 'department', a.payload->>'finalDept',
        'handoff_id', h.id, 'handoff', h.handoff_status, 'error', h.last_error) order by a.updated_at desc)
      from public.eaf_applications a left join public.eaf_onboarding_handoffs h on h.application_id = a.id
      where a.workflow_stage in ('offer_accepted','ready_for_onboarding') and coalesce(h.handoff_status, '') not in ('imported')), '[]'::jsonb),
    'to_payroll', coalesce((select jsonb_agg(jsonb_build_object(
        'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
        'status', em.employment_status, 'start', em.start_date, 'title', em.approved_job_title, 'department', em.department,
        'source', em.source_type, 'handoff_id', em.source_handoff_id) order by em.start_date desc nulls last)
      from public.employee_master em
      where em.employment_status in ('onboarding','active')
        and not exists (select 1 from public.eppd_employees ee where ee.employee_master_id = em.id)), '[]'::jsonb),
    'can_see_pay', v_pay);
end $$;

-- everything the hire window needs: the handoff or person, plus payroll pick-lists
create or replace function public.cms_hire_prefill(p_handoff uuid default null, p_person uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare h public.eaf_onboarding_handoffs; em public.employee_master; a jsonb := '{}'::jsonb; v_co text; v_gender text; v_dob text; v_nric text;
begin
  perform private.cms_require('onboarding', 'E');
  if p_handoff is not null then
    select * into h from public.eaf_onboarding_handoffs where id = p_handoff;
    if h.id is null then raise exception 'Onboarding handoff not found'; end if;
    select coalesce(payload, '{}'::jsonb) into a from public.eaf_applications where id = h.application_id;
    v_co := private.cms_canon(upper(h.legal_entity_code));
  elsif p_person is not null then
    select * into em from public.employee_master where id = p_person;
    if em.id is null then raise exception 'Person not found'; end if;
    v_co := private.cms_canon(em.company_code);
    if em.source_application_id is not null then select coalesce(payload, '{}'::jsonb) into a from public.eaf_applications where id = em.source_application_id; end if;
  else raise exception 'Choose an accepted applicant or a person.'; end if;
  v_gender := upper(left(coalesce(em.gender_code, a->>'radio_gender', ''), 1));
  v_nric := nullif(concat(a->>'ic1', a->>'ic2', a->>'ic3'), '');
  return jsonb_build_object(
    'handoff_id', h.id, 'person_id', em.id, 'employee_id', em.employee_id, 'serial', em.serial_no,
    'name', upper(coalesce(em.employee_name, h.employee_name)), 'employer', v_co,
    'gender', case when v_gender in ('M','F') then v_gender end,
    'join_date', coalesce(em.start_date, h.start_date), 'title', coalesce(em.approved_job_title, h.approved_job_title),
    'department', coalesce(em.department, h.department), 'location', coalesce(em.work_location, h.work_location),
    'work_from', coalesce(em.working_from, h.working_from), 'work_to', coalesce(em.working_to, h.working_to),
    'salary', coalesce(em.final_salary, h.final_salary), 'pay_basis', coalesce(nullif(a->>'v2PayBasis', ''), 'monthly'),
    'employment_type', a->>'v2EmploymentType', 'email', coalesce(em.email, h.email), 'phone', coalesce(em.contact, h.contact),
    'dob', nullif(a->>'dob', ''), 'nric', v_nric, 'next_serial', private.cms_next_serial(),
    'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name) order by c.sort_order, c.id)
                           from public.eppd_companies c where c.is_active), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name', d.name, 'company_id', d.company_id) order by d.sort_order, d.code)
                             from public.eppd_departments d where d.is_active), '[]'::jsonb),
    'titles', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name) from public.eppd_job_titles t where t.is_active), '[]'::jsonb),
    'statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
                          where category = 'confirmation_status' and is_active and coalesce((meta->>'is_active_employment')::boolean, true)), '[]'::jsonb),
    'job_statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
                              where category = 'job_status' and is_active), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- 3.4 hire: person record + payroll record
-- p: { handoff_id | person_id, name, gender, employer (MEG/MEH/HD/ABP), join_date, company_id (paying), department_id,
--      job_title_id | job_title_name, confirmation_status, job_status, work_from, work_to, salary, pay_basis,
--      email, phone, dob, nric, note }
create or replace function public.cms_hire(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare h public.eaf_onboarding_handoffs; em public.employee_master; v_person uuid; v_serial int; v_id text;
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
  -- job title: pick one, or add a new one to the payroll list
  v_title_id := nullif(p->>'job_title_id', '')::bigint;
  if v_title_id is null and nullif(btrim(coalesce(p->>'job_title_name', '')), '') is not null then
    select id into v_title_id from public.eppd_job_titles where lower(name) = lower(btrim(p->>'job_title_name')) limit 1;
    if v_title_id is null then insert into public.eppd_job_titles (name, is_active) values (btrim(p->>'job_title_name'), true) returning id into v_title_id; end if;
  end if;
  select name into v_title from public.eppd_job_titles where id = v_title_id;

  perform pg_advisory_xact_lock(hashtext('eppd_emp_id'));

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

  -- Employee ID: keep an existing one, else the next group number
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
    values (em.id, 1, 'joined', v_employer, v_join, em.department, em.approved_job_title, 'Created in the CMS from the MEG-EAF V2 onboarding handoff', 'eaf_handoff', h.source_snapshot, auth.uid());
    update public.eaf_onboarding_handoffs set handoff_status = 'imported', imported_at = now(), import_reference = v_id, updated_at = now(), last_error = null where id = h.id;
    update public.eaf_applications set workflow_stage = 'completed', updated_at = now() where id = h.application_id and workflow_stage = 'ready_for_onboarding';
  else
    update public.employee_master set
           employee_id = coalesce(employee_id, v_id), serial_no = coalesce(serial_no, v_serial), gender_code = coalesce(gender_code, v_gender),
           start_date = coalesce(start_date, v_join), original_group_join_date = coalesce(original_group_join_date, v_join),
           employment_status = case when employment_status = 'onboarding' and v_join <= v_today then 'active' else employment_status end,
           updated_at = now()
     where id = em.id returning * into em;
  end if;
  v_person := em.id;

  -- payroll record (MyPayroll V2.0)
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
    jsonb_build_object('employee_id', v_id, 'serial', v_serial, 'handoff_id', h.id, 'payroll_employee', v_emp, 'company', v_comp.code,
                       'department', v_dept.code, 'job_title', v_title, 'pay_basis', v_basis));
  return jsonb_build_object('person_id', v_person, 'employee_id', v_id, 'payroll_employee_id', v_emp);
end $$;

-- ---------------------------------------------------------------- 3.6 handbook progress
create or replace function public.cms_handbook_progress()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('handbook', 'V');
  perform private.cms_require('people', 'V');   -- staff may read the handbook, not everyone's progress
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object(
      'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
      'unit', coalesce(pp.unit_code, em.department), 'person_status', em.employment_status,
      'status', a.status, 'assigned_at', a.assigned_at, 'due_at', a.due_at, 'viewed_at', a.first_viewed_at, 'read_at', a.read_at,
      'acknowledged_at', coalesce(a.acknowledged_at, a.receipt_acknowledged_at), 'deemed_at', a.deemed_read_at,
      'version', v.title || ' ' || v.version,
      'progress', case when coalesce(v.required_clause_count, 0) > 0
                       then least(100, round(100.0 * (select count(*) from public.handbook_clause_progress cp where cp.assignment_id = a.id) / v.required_clause_count)) end) x
    from public.employee_master em
    left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
    left join lateral (select * from public.handbook_assignments ha where ha.employee_id = em.id and ha.revoked_at is null
                       order by ha.assigned_at desc nulls last limit 1) a on true
    left join public.handbook_versions v on v.id = a.handbook_version_id
    where em.employment_status in ('active','onboarding')) s), '[]'::jsonb);
end $$;

revoke all on function public.cms_recruit_applications(), public.cms_recruit_application(uuid), public.cms_jd(), public.cms_jd_position(uuid),
  public.cms_onboarding(), public.cms_hire_prefill(uuid, uuid), public.cms_hire(jsonb), public.cms_handbook_progress() from public, anon;
grant execute on function public.cms_recruit_applications(), public.cms_recruit_application(uuid), public.cms_jd(), public.cms_jd_position(uuid),
  public.cms_onboarding(), public.cms_hire_prefill(uuid, uuid), public.cms_hire(jsonb), public.cms_handbook_progress() to authenticated;
revoke all on function private.cms_next_serial(), private.cms_can_company(text, text, text) from public, anon;
