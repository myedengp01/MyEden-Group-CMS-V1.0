-- MyEden Group CMS V1.0 · Former Staff: leaving reason and rehire from the CMS (PRI-002, part 2).
-- cms_person_exit   : one person's employment periods, the leaving-reason list and the pick-lists for a rehire
-- cms_set_leaving   : HR / Admin record the reason for leaving and rehire eligibility (on the latest payroll period)
-- cms_rehire        : HR / Admin start a new employment period, same Employee ID; "not eligible" needs Admin + reason
-- Quick fill: people whose payroll status is Dismissed get the reason "Dismissed".

create or replace function public.cms_person_exit(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_co text; v_ee bigint; v_sal boolean;
begin
  select private.cms_canon(company_code) into v_co from public.employee_master where id = p_person;
  if not found then raise exception 'Person not found'; end if;
  perform private.cms_require('people', 'V', v_co);
  select id into v_ee from public.eppd_employees where employee_master_id = p_person;
  v_sal := public.cms_can('payroll.increments', 'V', v_co);
  return jsonb_build_object(
    'in_payroll', v_ee is not null,
    'can_edit', public.cms_can('people', 'E', v_co),
    'can_override', public.cms_can('people', 'A', v_co),
    'periods', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'join_date', m.join_date, 'resigned_date', m.resigned_date, 'letter_date', m.resignation_letter_date,
        'notice_until', m.notice_until, 'short_notice', m.notice_until is not null and m.resigned_date < m.notice_until,
        'status', m.confirmation_status, 'position', jt.name, 'centre', d.code,
        'company', (select string_agg(coalesce(c.short_name, c.name), ', ' order by a.is_primary desc) from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id where a.employment_id = m.id),
        'last_salary', case when v_sal then (select s.amount from public.eppd_salary_history s join public.eppd_assignments a on a.id = s.assignment_id
                                              where a.employment_id = m.id order by s.effective_from desc limit 1) end,
        'leaving_reason', m.leaving_reason, 'leaving_label', lk.label, 'leaving_note', m.leaving_note,
        'rehire', m.rehire_eligibility, 'rehire_note', m.rehire_note)
        order by m.join_date desc nulls last, m.id desc)
      from public.eppd_employments m
      left join public.eppd_job_titles jt on jt.id = m.job_title_id
      left join public.eppd_departments d on d.id = m.department_id
      left join public.eppd_lookups lk on lk.category = 'leaving_reason' and lk.code = m.leaving_reason
      where m.employee_id = v_ee), '[]'::jsonb),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'needs_note', coalesce((meta->>'needs_note')::boolean, false)) order by sort_order, label)
      from public.eppd_lookups where category = 'leaving_reason' and is_active), '[]'::jsonb),
    'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by sort_order, id) from public.eppd_companies where is_active), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'company_id', company_id) order by sort_order, code) from public.eppd_departments where is_active), '[]'::jsonb),
    'titles', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from public.eppd_job_titles where is_active), '[]'::jsonb),
    'statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
      where category = 'confirmation_status' and is_active and coalesce((meta->>'is_active_employment')::boolean, true)), '[]'::jsonb),
    'job_statuses', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups
      where category = 'job_status' and is_active), '[]'::jsonb));
end $$;

create or replace function public.cms_set_leaving(p_person uuid, p_reason text, p_note text, p_rehire text, p_rehire_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_co text; v_name text; v_ee bigint; v_em record; v_label text; v_needs boolean;
begin
  select private.cms_canon(company_code), employee_name into v_co, v_name from public.employee_master where id = p_person;
  if v_name is null then raise exception 'Person not found'; end if;
  perform private.cms_require('people', 'E', v_co);
  select id into v_ee from public.eppd_employees where employee_master_id = p_person;
  if v_ee is null then raise exception 'This person has no payroll record yet.'; end if;
  select * into v_em from public.eppd_employments where employee_id = v_ee and resigned_date is not null
   order by join_date desc nulls last, id desc limit 1;
  if v_em.id is null then raise exception 'No employment period with a last working day.'; end if;
  select label, coalesce((meta->>'needs_note')::boolean, false) into v_label, v_needs from public.eppd_lookups where category = 'leaving_reason' and code = p_reason;
  if v_label is null then raise exception 'Choose the reason for leaving.'; end if;
  if v_needs and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give the details for "Other".'; end if;
  if nullif(p_rehire, '') is not null and p_rehire not in ('eligible', 'conditional', 'not_eligible') then raise exception 'Unknown rehire choice.'; end if;
  if p_rehire in ('conditional', 'not_eligible') and nullif(btrim(coalesce(p_rehire_note, '')), '') is null then
    raise exception 'Add a rehire note: the conditions, or why not eligible.'; end if;
  update public.eppd_employments set leaving_reason = p_reason, leaving_note = nullif(btrim(coalesce(p_note, '')), ''),
         rehire_eligibility = nullif(p_rehire, ''), rehire_note = nullif(btrim(coalesce(p_rehire_note, '')), '')
   where id = v_em.id;
  update public.employee_master set exit_reason = v_label, exit_notes = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
   where id = p_person and employment_status = 'former';
  perform private.cms_log('person.leaving', 'employee_master', p_person::text, v_co,
    v_name || ': reason for leaving ' || v_label || coalesce(', rehire ' || nullif(p_rehire, ''), ''),
    jsonb_build_object('before', jsonb_build_object('leaving_reason', v_em.leaving_reason, 'leaving_note', v_em.leaving_note, 'rehire', v_em.rehire_eligibility, 'rehire_note', v_em.rehire_note),
                       'after', jsonb_build_object('leaving_reason', p_reason, 'leaving_note', p_note, 'rehire', p_rehire, 'rehire_note', p_rehire_note)));
end $$;

-- p: { person, join_date, company_id, department_id, job_title_id, confirmation_status, job_status, note, override_reason }
create or replace function public.cms_rehire(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_person uuid := (p->>'person')::uuid; v_co text; v_name text; v_master record; v_ee bigint; v_last record;
        v_join date := (p->>'join_date')::date; v_comp record; v_dept_id bigint; v_dept_code text; v_title text; v_conf text := coalesce(nullif(p->>'confirmation_status', ''), 'UP');
        v_override text := nullif(btrim(coalesce(p->>'override_reason', '')), ''); v_notes text; v_new bigint;
begin
  select * into v_master from public.employee_master where id = v_person;
  if v_master.id is null then raise exception 'Person not found'; end if;
  v_co := private.cms_canon(v_master.company_code); v_name := v_master.employee_name;
  perform private.cms_require('people', 'E', v_co);
  select id into v_ee from public.eppd_employees where employee_master_id = v_person;
  if v_ee is null then raise exception 'This person has no payroll record, so there is no earlier period to rehire from.'; end if;
  select * into v_last from public.eppd_employments where employee_id = v_ee order by join_date desc nulls last, id desc limit 1;
  if v_last.id is not null and v_last.resigned_date is null then raise exception '% is still employed: no last working day on the latest period.', v_name; end if;
  if v_join is null then raise exception 'Date joined is required.'; end if;
  if v_last.resigned_date is not null and v_join <= v_last.resigned_date then
    raise exception 'The new join date must be after the last working day (%).', to_char(v_last.resigned_date, 'DD Mon YYYY'); end if;
  select * into v_comp from public.eppd_companies where id = (p->>'company_id')::bigint and is_active;
  if v_comp.id is null then raise exception 'Choose the paying company.'; end if;
  if nullif(p->>'department_id', '') is not null then
    select id, code into v_dept_id, v_dept_code from public.eppd_departments where id = (p->>'department_id')::bigint;
  end if;
  if nullif(p->>'job_title_id', '') is not null then select name into v_title from public.eppd_job_titles where id = (p->>'job_title_id')::bigint; end if;
  if exists (select 1 from public.eppd_employments where employee_id = v_ee and rehire_eligibility = 'not_eligible') then
    if not public.cms_can('people', 'A', v_co) then raise exception 'Marked not eligible for rehire: only an Admin can rehire, with an override reason.'; end if;
    if v_override is null then raise exception 'Marked not eligible for rehire: give the override reason.'; end if;
  end if;
  v_notes := concat_ws(E'\n', case when v_override is not null then 'Rehire override (not eligible): ' || v_override end,
                       nullif(btrim(coalesce(p->>'note', '')), ''), 'Rehired from the CMS');
  insert into public.eppd_employments (employee_id, join_date, confirmation_status, job_status, department_id, job_title_id,
         work_from, work_to, meal_hours, ot_days, ot_multiplier, weekly_hours, notes)
  values (v_ee, v_join, v_conf, coalesce(nullif(p->>'job_status', ''), v_last.job_status), v_dept_id, nullif(p->>'job_title_id', '')::bigint,
          v_last.work_from, v_last.work_to, coalesce(v_last.meal_hours, 1), coalesce(v_last.ot_days, 26), coalesce(v_last.ot_multiplier, 1.5),
          case when coalesce(nullif(p->>'job_status', ''), v_last.job_status) = 'PT' then v_last.weekly_hours end, v_notes)
  returning id into v_new;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date) values (v_new, v_comp.id, true, v_join);
  update public.employee_master set
         employment_status = 'active',
         original_group_join_date = coalesce(original_group_join_date, start_date),
         start_date = v_join,
         company_code = case when v_comp.code in ('MEG', 'HD', 'ABP', 'MEH') then v_comp.code else company_code end,
         department = coalesce(v_dept_code, department),
         approved_job_title = coalesce(v_title, approved_job_title),
         confirmation_status = case when v_conf = 'C' then 'confirmed' else 'probation' end,
         confirmation_date = null, resignation_letter_date = null, required_last_working_date = null, actual_last_working_date = null,
         notice_served = null, exit_reason = null, exit_notes = null, final_payroll_status = null, clearance_status = null,
         updated_at = now()
   where id = v_person;
  update public.cms_employee_payroll set unit_code = v_dept_code, updated_by = auth.uid(), updated_at = now()
   where employee_master_id = v_person and v_dept_code is not null and exists (select 1 from public.cms_units where code = v_dept_code);
  perform private.cms_log('person.rehire', 'employee_master', v_person::text, v_co,
    v_name || ': rehired from ' || to_char(v_join, 'DD Mon YYYY') || ', paid by ' || v_comp.name || coalesce(', ' || v_dept_code, '') || coalesce(' · override: ' || v_override, ''),
    jsonb_build_object('employment_id', v_new, 'previous_employment_id', v_last.id, 'join_date', v_join, 'company', v_comp.code,
                       'department', v_dept_code, 'job_title', v_title, 'override_reason', v_override));
  return jsonb_build_object('employment_id', v_new, 'employee_id', v_master.employee_id);
end $$;

revoke all on function public.cms_person_exit(uuid), public.cms_set_leaving(uuid, text, text, text, text), public.cms_rehire(jsonb) from public, anon;
grant execute on function public.cms_person_exit(uuid), public.cms_set_leaving(uuid, text, text, text, text), public.cms_rehire(jsonb) to authenticated;

-- quick fill: payroll status Dismissed -> reason "Dismissed"
update public.eppd_employments set leaving_reason = 'DISMISSED'
 where confirmation_status = 'DM' and resigned_date is not null and leaving_reason is null;
update public.employee_master em set exit_reason = 'Dismissed'
  from public.eppd_employees ee join public.eppd_employments m on m.employee_id = ee.id
 where ee.employee_master_id = em.id and m.leaving_reason = 'DISMISSED' and em.employment_status = 'former' and em.exit_reason is null;
