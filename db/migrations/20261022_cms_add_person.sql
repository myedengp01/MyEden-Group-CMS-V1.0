-- MyEden Group CMS V1.0 · People › Add Person inside the CMS
-- Until now "Add Person" only linked to MyPayroll V2.0, whose Add employee creates the payroll record but not the person in the
-- Employee Master. The CMS hire function now also takes a person typed in by HR (no MEG-EAF V2 application), and creates both
-- at once, the same way as hiring an applicant: Employee Master person + payroll employee, identity (NRIC, date of birth),
-- employment, paying company and starting salary, with the next Employee ID (or an existing ID typed in for someone who
-- already has one). Needs People "add" for the employer, People "edit" and Paying Companies "edit".
-- Duplicates are refused: the same name / email (use Rehire in Former Staff instead), or the same NRIC.

do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.cms_hire(jsonb)'::regprocedure); n := d;

  -- 1. who may: "Add Person" needs People add; hiring an applicant still needs Offers & Onboarding edit
  n := replace(n, $x$  perform private.cms_require('onboarding', 'E', v_employer);$x$,
    $x$  if coalesce((p->>'manual')::boolean, false) then perform private.cms_require('people', 'C', v_employer);
  else perform private.cms_require('onboarding', 'E', v_employer); end if;$x$);

  -- 2. a person typed in by HR (no application, no existing person)
  n := replace(n, $x$  else raise exception 'Choose an accepted applicant or a person.'; end if;$x$,
    $x$  elsif coalesce((p->>'manual')::boolean, false) then
    if nullif(regexp_replace(coalesce(p->>'nric', ''), '\D', '', 'g'), '') is not null and exists (select 1 from public.eppd_employee_private x
         where regexp_replace(coalesce(x.nric, ''), '\D', '', 'g') = regexp_replace(p->>'nric', '\D', '', 'g')) then
      raise exception 'This NRIC is already on record (%). For someone coming back, use Rehire in Former Staff.',
        (select string_agg(coalesce(e.emp_id, 'no ID') || ' ' || e.full_name, ', ') from public.eppd_employee_private x join public.eppd_employees e on e.id = x.employee_id
          where regexp_replace(coalesce(x.nric, ''), '\D', '', 'g') = regexp_replace(p->>'nric', '\D', '', 'g'));
    end if;
  else raise exception 'Choose an accepted applicant or a person.'; end if;$x$);

  -- 3. an existing Employee ID typed in (staff who already have one)
  n := replace(n, $x$  if em.employee_id is not null then v_id := em.employee_id; v_serial := em.serial_no;$x$,
    $x$  if em.id is null and nullif(btrim(coalesce(p->>'employee_id', '')), '') is not null then
    v_id := upper(btrim(p->>'employee_id')); v_serial := nullif(substring(v_id from '(\d+)$'), '')::int;
    if v_id !~ '^[A-Z]{1,4}[0-9]{4}[MF][0-9]{3,4}$' then raise exception 'Employee ID % is not in the usual format (e.g. M0325F0118).', v_id; end if;
  elsif em.employee_id is not null then v_id := em.employee_id; v_serial := em.serial_no;$x$);

  -- 4. record where the person came from, and their confirmation status
  n := replace(n, $x$case when v_join <= v_today then 'active' else 'onboarding' end, 'probation',$x$,
    $x$case when v_join <= v_today then 'active' else 'onboarding' end, case when p->>'confirmation_status' = 'C' then 'confirmed' else 'probation' end,$x$);
  n := replace(n, $x$           'eaf_handoff', h.application_id, h.id, h.source_snapshot, auth.uid())$x$,
    $x$           case when h.id is null then 'manual_entry' else 'eaf_handoff' end, h.application_id, h.id, h.source_snapshot, auth.uid())$x$);
  n := replace(n, $x$'Created in the CMS from the MEG-EAF V2 application', 'eaf_handoff', h.source_snapshot, auth.uid());$x$,
    $x$case when h.id is null then 'Added in the CMS (People › Add Person)' else 'Created in the CMS from the MEG-EAF V2 application' end,
           case when h.id is null then 'manual_entry' else 'eaf_handoff' end, h.source_snapshot, auth.uid());$x$);

  n := replace(n, $x$h.source_snapshot, auth.uid()$x$, $x$coalesce(h.source_snapshot, jsonb_build_object('source', 'manual_entry')), auth.uid()$x$);

  -- 5. Chinese name and nationality on the payroll record
  n := replace(n, $x$  insert into public.eppd_employees (emp_id, emp_serial, full_name, gender, email, phone, employee_master_id, remarks)
  values (v_id, v_serial, v_name, v_gender, nullif(p->>'email', ''), nullif(p->>'phone', ''), v_person, nullif(p->>'note', ''))$x$,
    $x$  insert into public.eppd_employees (emp_id, emp_serial, full_name, gender, email, phone, employee_master_id, remarks, chinese_name, nationality)
  values (v_id, v_serial, v_name, v_gender, nullif(p->>'email', ''), nullif(p->>'phone', ''), v_person, nullif(p->>'note', ''),
          nullif(btrim(coalesce(p->>'chinese_name', '')), ''), coalesce(nullif(p->>'nationality', ''), 'MALAYSIAN'))$x$);

  -- 6. the log line
  n := replace(n, $x$v_name || ': hired from ' ||$x$, $x$v_name || case when h.id is null then ': added from ' else ': hired from ' end ||$x$);

  if strpos(n, 'manual_entry') = 0 or strpos(n, $x$perform private.cms_require('people', 'C', v_employer)$x$) = 0 or strpos(n, 'This NRIC is already on record') = 0
     or strpos(n, $x$v_id := upper(btrim(p->>'employee_id'))$x$) = 0 or strpos(n, 'chinese_name, nationality') = 0 or strpos(n, ': added from ') = 0
     or strpos(n, $x$when p->>'confirmation_status' = 'C' then 'confirmed'$x$) = 0 or strpos(n, 'Added in the CMS (People') = 0 or strpos(n, $x$jsonb_build_object('source', 'manual_entry')$x$) = 0 then
    raise exception 'cms_hire patch points not found';
  end if;
  execute n;
end $m$;

-- the Add Person window uses the same lists as the hire window (companies, centres, titles, statuses, next number)
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.cms_hire_prefill(uuid,uuid)'::regprocedure); n := d;
  n := replace(n, $x$  perform private.cms_require('onboarding', 'E');$x$,
    $x$  if p_handoff is null and p_person is null then perform private.cms_require('people', 'C');
  else perform private.cms_require('onboarding', 'E'); end if;$x$);
  n := replace(n, $x$  else raise exception 'Choose an accepted applicant or a person.'; end if;$x$, $x$  else v_co := null; end if;$x$);
  n := replace(n, $x$    'job_statuses', coalesce($x$, $x$    'nationalities', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
                               where category = 'nationality' and is_active), '[]'::jsonb),
    'job_statuses', coalesce($x$);
  if strpos(n, $x$perform private.cms_require('people', 'C');$x$) = 0 or strpos(n, 'else v_co := null; end if;') = 0 or strpos(n, $x$'nationalities'$x$) = 0 then
    raise exception 'cms_hire_prefill patch points not found';
  end if;
  execute n;
end $m$;
