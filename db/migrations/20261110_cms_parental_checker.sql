-- MyEden Group CMS V1.0 · v2026.11.10 · Maternity & paternity entitlement checker (CLC 10 Nov 2026)
-- Employment Act 1955 as amended (in force 1 Jan 2023): maternity s.37 / s.38 (98 consecutive days; allowance if employed at some time
-- in the 4 months and ≥ 90 days in the 9 months before confinement and fewer than 5 surviving children; start not earlier than 30 days
-- before confinement; notice within the 60 days before the expected confinement); paternity s.60FA (married male, 7 consecutive days,
-- up to 5 confinements, 12 months' service immediately before the leave starts; notice at least 30 days before the expected confinement
-- or as soon as possible after the birth).
-- Company decisions: monthly salary continues during maternity leave; each allowance can be paid or not (chosen per case); paternity is
-- 7 calendar days; the number of surviving children is kept as a number on the payroll profile (no names). HR / Admin only.
-- Additive: one new column, new functions.
alter table public.eppd_employees add column if not exists surviving_children integer;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'eppd_employees_surviving_children_check') then
    alter table public.eppd_employees add constraint eppd_employees_surviving_children_check check (surviving_children is null or surviving_children between 0 and 30); end if;
end $c$;

create or replace function public.cms_parental_check(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare v_emp bigint := (p->>'employee_id')::bigint; v_type text := upper(p->>'type'); v_event date := nullif(p->>'event', '')::date;
        v_start date; v_end date; v_ret date; v_notice date := nullif(p->>'notice', '')::date; v_prior int := coalesce(nullif(p->>'prior_paternity', '')::int, 0);
        ee public.eppd_employees; c jsonb; v_days int; joined date; svc int; prev int; ww jsonb; hol date[]; d date;
        v_basic numeric; v_basis text; v_asg bigint; allw jsonb; v_ovl jsonb; months jsonb;
begin
  if not (public.cms_can('leave', 'V') or public.cms_can('payroll', 'V')) then raise exception 'You do not have access to this.'; end if;
  if v_type not in ('MTL', 'PTL') then raise exception 'Choose maternity or paternity.'; end if;
  if v_event is null then raise exception 'Give the expected (or actual) date of birth.'; end if;
  select * into ee from public.eppd_employees where id = v_emp;
  if ee.id is null then raise exception 'Employee not found.'; end if;
  if ee.employee_master_id is null then raise exception 'This employee is not linked to a CMS person record.'; end if;
  v_days := case when v_type = 'MTL' then 98 else 7 end;
  v_start := coalesce(nullif(p->>'start', '')::date, v_event);
  v_end := v_start + v_days - 1;
  -- first working day after the leave (Mon–Fri, skipping public holidays)
  ww := coalesce((select value from public.eppd_policies where key = 'working_week'), '{"rest_days":[0],"off_days":[6]}'::jsonb);
  hol := array(select holiday_date from public.eppd_holidays where is_active and holiday_date between v_end and v_end + 60);
  v_ret := v_end + 1;
  while extract(dow from v_ret)::int in (select jsonb_array_elements_text(coalesce(ww->'rest_days', '[0]'::jsonb) || coalesce(ww->'off_days', '[6]'::jsonb))::int) or v_ret = any(hol) loop
    v_ret := v_ret + 1; end loop;
  c := private.cms_leave_entitlement_check(ee.employee_master_id, v_type, v_event, v_start);
  -- other leave already recorded over the dates
  v_ovl := coalesce((select jsonb_agg(jsonb_build_object('type', r.leave_type, 'from', r.date_from, 'to', r.date_to, 'days', r.days, 'note', r.note) order by r.date_from)
    from public.eppd_leave_records r where r.employee_id = ee.id and r.status <> 'cancelled' and r.date_from <= v_end and coalesce(r.date_to, r.date_from) >= v_start), '[]'::jsonb);
  -- days of leave in each month
  months := (select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
      'days', (least(v_end, (m + interval '1 month - 1 day')::date) - greatest(v_start, m::date) + 1),
      'cal_days', extract(day from (m + interval '1 month - 1 day'))::int) order by m)
    from generate_series(date_trunc('month', v_start), date_trunc('month', v_end), interval '1 month') g(m));
  -- pay: primary assignment's salary at the start, and the allowances running during the leave (one-off items left out)
  select a.id, s.amount, s.pay_basis into v_asg, v_basic, v_basis
    from public.eppd_salary_history s join public.eppd_assignments a on a.id = s.assignment_id join public.eppd_employments e on e.id = a.employment_id
   where e.employee_id = ee.id and a.is_primary and s.effective_from <= v_start order by s.effective_from desc, s.id desc limit 1;
  allw := coalesce((select jsonb_agg(jsonb_build_object('id', al.id, 'code', pt.code, 'name', pt.name, 'amount', al.amount, 'from', al.start_date, 'to', al.end_date) order by pt.sort_order, pt.name)
    from public.eppd_allowances al join public.eppd_payment_types pt on pt.id = al.payment_type_id
    join public.eppd_assignments a on a.id = al.assignment_id join public.eppd_employments e on e.id = a.employment_id
    where e.employee_id = ee.id and coalesce(pt.is_recurring, true) and pt.code not ilike '%ARREAR%'
      and coalesce(al.start_date, v_start) <= v_end and coalesce(al.end_date, v_end) >= v_start), '[]'::jsonb);
  if v_type = 'PTL' then
    -- s.60FA: 12 months with the employer immediately before the paternity leave starts
    select e.join_date into joined from public.eppd_employments e where e.employee_id = ee.id and e.join_date <= v_start and (e.resigned_date is null or e.resigned_date >= v_start) order by e.join_date desc limit 1;
    svc := case when joined is null then 0 else (extract(year from age(v_start, joined)) * 12 + extract(month from age(v_start, joined)))::integer end;
    prev := coalesce((c->>'previous_paternity')::int, 0) + v_prior;
    c := c || jsonb_build_object('service_months', svc, 'service_ok', svc >= 12, 'join_date', joined, 'previous_paternity_cms', (c->>'previous_paternity')::int,
      'previous_paternity', prev, 'within_limit', prev < 5, 'married', lower(coalesce(ee.marital_status, '')) in ('married', 'm'),
      'marital_status', ee.marital_status,
      'notice_ok', case when v_notice is null then null else v_notice <= v_event - 30 or v_notice >= v_event end,
      'starts_before_birth', v_start < v_event);
    c := c || jsonb_build_object('eligible', (c->>'male')::boolean and (c->>'married')::boolean and svc >= 12 and prev < 5);
  else
    c := c || jsonb_build_object('surviving_children', ee.surviving_children,
      'under5', case when ee.surviving_children is null then null else ee.surviving_children < 5 end,
      'late_start', v_start > v_event + 1,
      'notice_ok', case when v_notice is null then null else v_notice between v_event - 60 and v_event end);
    c := c || jsonb_build_object('eligible', (c->>'eligible_allowance')::boolean and coalesce(ee.surviving_children, 0) < 5);
  end if;
  return c || jsonb_build_object('employee_id', ee.id, 'name', ee.full_name, 'emp_id', ee.emp_id, 'gender', ee.gender, 'days', v_days,
    'leave_from', v_start, 'leave_to', v_end, 'return_date', v_ret, 'notice', v_notice, 'overlaps', v_ovl, 'months', months,
    'basic', v_basic, 'pay_basis', coalesce(v_basis, c->>'pay_basis', 'monthly'), 'allowances', allw,
    'checked_at', now(), 'can_record', public.cms_can('leave', 'E'));
end $f$;
revoke all on function public.cms_parental_check(jsonb) from public, anon; grant execute on function public.cms_parental_check(jsonb) to authenticated;

create or replace function public.cms_set_surviving_children(p_employee bigint, p_count int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare old int; nm text;
begin
  perform private.cms_require('leave', 'E', null);
  if p_count is not null and (p_count < 0 or p_count > 30) then raise exception 'Give a number from 0 to 30.'; end if;
  select surviving_children, full_name into old, nm from public.eppd_employees where id = p_employee;
  if nm is null then raise exception 'Employee not found.'; end if;
  update public.eppd_employees set surviving_children = p_count, updated_at = now() where id = p_employee;
  perform private.cms_log('person.children', 'eppd_employees', p_employee::text, null, nm || ': number of surviving children ' || coalesce(old::text, '—') || ' → ' || coalesce(p_count::text, '—'),
    jsonb_build_object('from', old, 'to', p_count));
  return jsonb_build_object('surviving_children', p_count);
end $f$;
revoke all on function public.cms_set_surviving_children(bigint, int) from public, anon; grant execute on function public.cms_set_surviving_children(bigint, int) to authenticated;

-- record the checked leave: p = {employee_id, type, event, start, notice, allowance ('paid'|'unpaid'), orp, allowances:[{code,name,amount,pay}], check:{...}, note}
create or replace function public.cms_parental_record(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_emp bigint := (p->>'employee_id')::bigint; v_type text := upper(p->>'type'); v_start date := (p->>'start')::date; v_days int; v_end date; rid bigint; nm text; v_paid text;
begin
  perform private.cms_require('leave', 'E', null);
  if v_type not in ('MTL', 'PTL') or v_start is null or nullif(p->>'event', '') is null then raise exception 'Check the leave first.'; end if;
  select full_name into nm from public.eppd_employees where id = v_emp;
  if nm is null then raise exception 'Employee not found.'; end if;
  v_days := case when v_type = 'MTL' then 98 else 7 end; v_end := v_start + v_days - 1;
  if exists (select 1 from public.eppd_leave_records r where r.employee_id = v_emp and r.leave_type = v_type and r.status <> 'cancelled' and r.date_from <= v_end and coalesce(r.date_to, r.date_from) >= v_start) then
    raise exception '% already has % leave recorded over these dates.', nm, case when v_type = 'MTL' then 'maternity' else 'paternity' end; end if;
  v_paid := case when v_type = 'MTL' then coalesce(nullif(p->>'allowance', ''), 'paid') else 'paid' end;
  insert into public.eppd_leave_records (employee_id, leave_type, date_from, date_to, half_day, days, days_override, status, source, note, created_by, details)
  values (v_emp, v_type, v_start, v_end, 'none', v_days, false, 'taken', 'manual',
          coalesce(nullif(btrim(p->>'note'), ''), case when v_type = 'MTL' then 'Maternity leave' else 'Paternity leave' end || ' (checked with the entitlement checker)'), auth.uid(),
          jsonb_build_object('event', p->>'event', 'notice', nullif(p->>'notice', ''), 'source', 'parental_checker', 'checked_at', now())
          || case when v_type = 'MTL' then jsonb_build_object('under5', coalesce((p->'check'->>'under5')::boolean, true), 'allowance', v_paid,
               'orp', nullif(p->>'orp', '')::numeric, 'allowances', coalesce(p->'allowances', '[]'::jsonb)) else '{}'::jsonb end
          || jsonb_build_object('check', coalesce(p->'check', '{}'::jsonb)))
  returning id into rid;
  perform private.cms_log('leave.parental', 'eppd_leave_records', rid::text, null,
    nm || ': ' || case when v_type = 'MTL' then 'maternity' else 'paternity' end || ' leave ' || to_char(v_start, 'DD Mon YYYY') || ' – ' || to_char(v_end, 'DD Mon YYYY')
      || case when v_type = 'MTL' then ' (' || v_paid || ')' else '' end, p - 'check');
  return jsonb_build_object('id', rid, 'from', v_start, 'to', v_end, 'days', v_days);
end $f$;
revoke all on function public.cms_parental_record(jsonb) from public, anon; grant execute on function public.cms_parental_record(jsonb) to authenticated;
