-- MyEden Group CMS V1.0 · Super Admin: edit an employee's master record
-- On the employee profile, a Super Admin (only — not a permission that can be given to other roles) can correct:
--   identity: full name, Chinese name, gender, date of birth, NRIC, nationality
--   Employee ID (and its running number) — the ID that matches the company is suggested; the old ID is kept as the previous ID
--   master company (employer of record: MEG / MEH / HD / ABP) — decides the letterhead, {{company_name}}, which company's HR sees them
--   employment: centre / department, job title, employment status (under probation, confirmed, contract, part time, internship),
--               confirmation date, probation end date
-- The join date stays locked. Leaving and rehire keep their own flows. The paying company stays in Payroll.
-- Every save needs a reason, and is logged with each field's old and new value (Audit log + the person's Timeline).
-- The Employee Master and the payroll record are changed together, so the CMS and MyPayroll stay the same.
-- Finalised payslips and issued letters keep the details they were issued with.

-- the automatic Employee ID log line says why an ID changed when a Super Admin changes it
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('private.cms_employee_id_logged()'::regprocedure);
  if strpos(d, 'cms.id_note') > 0 then return; end if;
  n := replace(d, $x$case when tg_op = 'UPDATE' and old.employee_id is not null then 'Employee ID rebuilt (start date / gender / employer changed before the first payslip)' else 'Employee ID assigned automatically at onboarding' end$x$,
    $x$coalesce(nullif(current_setting('cms.id_note', true), ''), case when tg_op = 'UPDATE' and old.employee_id is not null then 'Employee ID rebuilt (start date / gender / employer changed before the first payslip)' else 'Employee ID assigned automatically at onboarding' end)$x$);
  if strpos(n, 'cms.id_note') = 0 then raise exception 'cms_employee_id_logged patch point not found'; end if;
  execute n;
end $m$;

-- what the edit window shows: current values, the lists to choose from and the suggested Employee ID for each company
create or replace function public.cms_person_master(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; m public.eppd_employments; pr public.eppd_employee_private;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change the master record.' using errcode = '42501'; end if;
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is not null then
    select * into m from public.eppd_employments where employee_id = ee.id order by (resigned_date is null) desc, join_date desc nulls last, id desc limit 1;
    select * into pr from public.eppd_employee_private where employee_id = ee.id;
  end if;
  return jsonb_build_object(
    'name', em.employee_name, 'chinese_name', ee.chinese_name, 'gender', coalesce(em.gender_code, ee.gender), 'dob', pr.dob, 'nric', pr.nric,
    'nationality', ee.nationality, 'employee_id', coalesce(em.employee_id, ee.emp_id), 'serial', coalesce(em.serial_no, ee.emp_serial),
    'previous_id', coalesce(em.previous_employee_id, ee.previous_emp_id), 'legacy_id', coalesce(em.legacy_id_exception, false),
    'company', private.cms_canon(em.company_code), 'start', coalesce(em.start_date, m.join_date),
    'department_id', m.department_id, 'job_title_id', m.job_title_id, 'emp_status', m.confirmation_status,
    'confirmation_date', coalesce(em.confirmation_date, m.confirmed_date), 'probation_end', em.probation_end_date,
    'has_payroll', ee.id is not null, 'paid', exists (select 1 from public.eppd_pay_lines l where l.employee_id = ee.id),
    'paying', (select string_agg(c.code, ', ' order by a.is_primary desc) from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
                where a.employment_id = m.id and (a.end_date is null or a.end_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date)),
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name,
                    'suggested_id', case when em.start_date is not null and coalesce(em.gender_code, ee.gender) in ('M', 'F') and coalesce(em.serial_no, ee.emp_serial) is not null
                                         then public.format_group_employee_id(c.code, em.start_date, coalesce(em.gender_code, ee.gender), coalesce(em.serial_no, ee.emp_serial)) end)
                    order by array_position(array['MEG', 'MEH', 'HD', 'ABP'], c.code))
                  from public.cms_companies c where c.code in ('MEG', 'MEH', 'HD', 'ABP')),
    'departments', (select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name', d.name, 'company', c.code) order by d.sort_order, d.code)
                    from public.eppd_departments d left join public.eppd_companies c on c.id = d.company_id where d.is_active or d.id = m.department_id),
    'titles', (select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.sort_order, t.name) from public.eppd_job_titles t where t.is_active or t.id = m.job_title_id),
    'statuses', (select jsonb_agg(jsonb_build_object('code', l.code, 'label', l.label) order by l.sort_order) from public.eppd_lookups l
                 where l.category = 'confirmation_status' and l.code in ('UP', 'C', 'CT', 'PT', 'INT')));
end $f$;
revoke all on function public.cms_person_master(uuid) from public, anon;
grant execute on function public.cms_person_master(uuid) to authenticated;

create or replace function public.cms_person_master_save(p_person uuid, p jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; m public.eppd_employments; pr public.eppd_employee_private;
        cur jsonb; nxt jsonb := '{}'::jsonb; chg jsonb := '[]'::jsonb; k text; v_label text; v_id text; v_serial int; v_co text; v_g text;
        d public.eppd_departments; t public.eppd_job_titles; v_conf text;
        labels jsonb := '{"name":"Full name","chinese_name":"Chinese name","gender":"Gender","dob":"Date of birth","nric":"NRIC","nationality":"Nationality",
                         "employee_id":"Employee ID","company":"Master company","department_id":"Centre / department","job_title_id":"Job title",
                         "emp_status":"Employment status","confirmation_date":"Confirmation date","probation_end":"Probation end date"}';
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change the master record.' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  if p ? 'start' or p ? 'join_date' then raise exception 'The join date is locked.'; end if;
  cur := public.cms_person_master(p_person);
  select * into em from public.employee_master where id = p_person for update;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1 for update;
  if ee.id is not null then
    select * into m from public.eppd_employments where employee_id = ee.id order by (resigned_date is null) desc, join_date desc nulls last, id desc limit 1 for update;
  end if;

  -- only the fields that really change
  for k in select jsonb_object_keys(labels) loop
    if p ? k and (case when k in ('name', 'employee_id') then upper(nullif(btrim(coalesce(p->>k, '')), '')) else nullif(btrim(coalesce(p->>k, '')), '') end)
               is distinct from (case when k in ('name', 'employee_id') then upper(nullif(btrim(coalesce(cur->>k, '')), '')) else nullif(btrim(coalesce(cur->>k, '')), '') end) then
      nxt := nxt || jsonb_build_object(k, nullif(btrim(coalesce(p->>k, '')), ''));
    end if;
  end loop;
  if nxt = '{}'::jsonb then raise exception 'Nothing was changed.'; end if;
  if (nxt ? 'dob' or nxt ? 'nric') and not public.cms_can('people.ic', 'V') then raise exception 'Changing the NRIC or date of birth needs "See IC and passport numbers".' using errcode = '42501'; end if;
  if ee.id is null and (nxt ?| array['chinese_name', 'dob', 'nric', 'nationality', 'department_id', 'job_title_id', 'emp_status']) then
    raise exception 'This person has no payroll record yet, so only the name, gender, Employee ID, company and dates can be changed.'; end if;

  -- checks
  if nxt ? 'name' and nxt->>'name' is null then raise exception 'The full name cannot be empty.'; end if;
  v_g := coalesce(nxt->>'gender', cur->>'gender');
  if nxt ? 'gender' and v_g not in ('M', 'F') then raise exception 'Choose the gender.'; end if;
  v_co := coalesce(nxt->>'company', cur->>'company');
  if nxt ? 'company' and v_co not in ('MEG', 'MEH', 'HD', 'ABP') then raise exception 'Choose the master company.'; end if;
  if nxt ? 'dob' and (nxt->>'dob') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the date of birth as a date.'; end if;
  if nxt ? 'confirmation_date' and nxt->>'confirmation_date' is not null and (nxt->>'confirmation_date') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the confirmation date as a date.'; end if;
  if nxt ? 'probation_end' and nxt->>'probation_end' is not null and (nxt->>'probation_end') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the probation end date as a date.'; end if;
  if nxt ? 'nric' and nxt->>'nric' is not null and exists (select 1 from public.eppd_employee_private x where x.employee_id <> ee.id
       and regexp_replace(coalesce(x.nric, ''), '\D', '', 'g') = regexp_replace(nxt->>'nric', '\D', '', 'g') and regexp_replace(nxt->>'nric', '\D', '', 'g') <> '') then
    raise exception 'This NRIC is already on another person''s record.'; end if;
  if nxt ? 'department_id' then
    select * into d from public.eppd_departments where id = (nxt->>'department_id')::bigint;
    if d.id is null then raise exception 'Choose the centre / department.'; end if;
  end if;
  if nxt ? 'job_title_id' then
    select * into t from public.eppd_job_titles where id = (nxt->>'job_title_id')::bigint;
    if t.id is null then raise exception 'Choose the job title.'; end if;
  end if;
  if nxt ? 'emp_status' and nxt->>'emp_status' not in ('UP', 'C', 'CT', 'PT', 'INT') then
    raise exception 'Choose the employment status (resigning, termination and dismissal go through Leaving).'; end if;
  if nxt ? 'employee_id' then
    if coalesce(em.legacy_id_exception, false) then raise exception 'This is a fixed director ID and cannot be changed here.'; end if;
    v_id := upper(nxt->>'employee_id');
    if v_id is null or v_id !~ '^[A-Z]{1,4}[0-9]{4}[MF][0-9]{3,4}$' then raise exception 'Employee ID % is not in the usual format (e.g. E0825F0151).', coalesce(v_id, '(empty)'); end if;
    if substring(v_id from '^[A-Z]{1,4}[0-9]{4}([MF])') <> v_g then raise exception 'The gender letter in the Employee ID (%) does not match the gender.', substring(v_id from '^[A-Z]{1,4}[0-9]{4}([MF])'); end if;
    v_serial := substring(v_id from '([0-9]{3,4})$')::int;
    if exists (select 1 from public.employee_master x where upper(x.employee_id) = v_id and x.id <> em.id)
       or exists (select 1 from public.eppd_employees x where upper(x.emp_id) = v_id and x.employee_master_id is distinct from em.id) then
      raise exception 'Employee ID % is already used by someone else.', v_id; end if;
    if v_serial <> 1000 and exists (select 1 from public.employee_master x where x.serial_no = v_serial and x.id <> em.id) then
      raise exception 'Running number % is already used by someone else.', lpad(v_serial::text, 4, '0'); end if;
    nxt := jsonb_set(nxt, '{employee_id}', to_jsonb(v_id));
  elsif nxt ? 'gender' and coalesce(cur->>'employee_id', '') <> '' and substring(cur->>'employee_id' from '^[A-Z]{1,4}[0-9]{4}([MF])') is distinct from v_g then
    raise exception 'The Employee ID % has the gender letter %; change the Employee ID too.', cur->>'employee_id', substring(cur->>'employee_id' from '^[A-Z]{1,4}[0-9]{4}([MF])');
  end if;

  -- what changed, in words (NRIC shown masked in the log)
  for k in select jsonb_object_keys(nxt) loop
    chg := chg || jsonb_build_array(jsonb_build_object('field', k, 'label', labels->>k,
      'from', case when k = 'nric' then regexp_replace(coalesce(cur->>k, ''), '\d(?=\d{4})', '•', 'g')
                   when k = 'department_id' then (select x.code || ' · ' || x.name from public.eppd_departments x where x.id = (cur->>k)::bigint)
                   when k = 'job_title_id' then (select x.name from public.eppd_job_titles x where x.id = (cur->>k)::bigint) else cur->>k end,
      'to', case when k = 'nric' then regexp_replace(coalesce(nxt->>k, ''), '\d(?=\d{4})', '•', 'g') when k = 'department_id' then d.code || ' · ' || d.name
                 when k = 'job_title_id' then t.name else nxt->>k end));
  end loop;

  perform set_config('cms.id_note', 'Employee ID changed by a Super Admin: ' || btrim(p_reason), true);

  -- Employee Master
  v_conf := case nxt->>'emp_status' when 'C' then 'confirmed' when 'UP' then 'probation' else 'not_applicable' end;
  update public.employee_master set
    employee_name = case when nxt ? 'name' then upper(nxt->>'name') else employee_name end,
    gender_code = case when nxt ? 'gender' then v_g else gender_code end,
    company_code = case when nxt ? 'company' then v_co else company_code end,
    employee_id = case when nxt ? 'employee_id' then v_id else employee_id end,
    serial_no = case when nxt ? 'employee_id' then v_serial else serial_no end,
    previous_employee_id = case when nxt ? 'employee_id' then em.employee_id else previous_employee_id end,
    department = case when nxt ? 'department_id' then d.code else department end,
    approved_job_title = case when nxt ? 'job_title_id' then t.name else approved_job_title end,
    confirmation_status = case when nxt ? 'emp_status' then v_conf else confirmation_status end,
    confirmation_date = case when nxt ? 'confirmation_date' then (nxt->>'confirmation_date')::date else confirmation_date end,
    probation_end_date = case when nxt ? 'probation_end' then (nxt->>'probation_end')::date else probation_end_date end,
    updated_at = now()
  where id = em.id;

  -- payroll record (MyPayroll)
  if ee.id is not null then
    update public.eppd_employees set
      full_name = case when nxt ? 'name' then upper(nxt->>'name') else full_name end,
      chinese_name = case when nxt ? 'chinese_name' then nxt->>'chinese_name' else chinese_name end,
      gender = case when nxt ? 'gender' then v_g else gender end,
      nationality = case when nxt ? 'nationality' then nxt->>'nationality' else nationality end,
      emp_id = case when nxt ? 'employee_id' then v_id else emp_id end,
      emp_serial = case when nxt ? 'employee_id' then v_serial else emp_serial end,
      previous_emp_id = case when nxt ? 'employee_id' then ee.emp_id else previous_emp_id end
    where id = ee.id;
    if nxt ? 'dob' or nxt ? 'nric' then
      insert into public.eppd_employee_private (employee_id, nric, dob) values (ee.id, nxt->>'nric', (nxt->>'dob')::date)
      on conflict (employee_id) do update set nric = case when nxt ? 'nric' then excluded.nric else eppd_employee_private.nric end,
        dob = case when nxt ? 'dob' then excluded.dob else eppd_employee_private.dob end, updated_at = now();
    end if;
    if m.id is not null and (nxt ?| array['department_id', 'job_title_id', 'emp_status', 'confirmation_date']) then
      update public.eppd_employments set
        department_id = case when nxt ? 'department_id' then d.id else department_id end,
        job_title_id = case when nxt ? 'job_title_id' then t.id else job_title_id end,
        confirmation_status = case when nxt ? 'emp_status' then nxt->>'emp_status' else confirmation_status end,
        confirmed_date = case when nxt ? 'confirmation_date' then (nxt->>'confirmation_date')::date else confirmed_date end
      where id = m.id;
    end if;
  end if;

  -- logs
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'master_record_changed', (select string_agg((x->>'label') || ': ' || coalesce(x->>'from', '—') || ' → ' || coalesce(x->>'to', '—'), '; ') from jsonb_array_elements(chg) x) || ' · ' || btrim(p_reason),
          jsonb_build_object('changes', chg, 'reason', btrim(p_reason)), auth.uid());
  perform private.cms_log('person.master', 'employee_master', em.id::text, coalesce(private.cms_canon(v_co), private.cms_canon(em.company_code)),
    coalesce(upper(nxt->>'name'), em.employee_name) || ': master record changed (' || (select string_agg(x->>'label', ', ') from jsonb_array_elements(chg) x) || ') · ' || btrim(p_reason),
    jsonb_build_object('changes', chg, 'reason', btrim(p_reason)));
  return jsonb_build_object('changes', chg);
end $f$;
revoke all on function public.cms_person_master_save(uuid, jsonb, text) from public, anon;
grant execute on function public.cms_person_master_save(uuid, jsonb, text) to authenticated;
