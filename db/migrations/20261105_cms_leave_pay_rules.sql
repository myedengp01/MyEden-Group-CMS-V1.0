-- MyEden Group CMS V1.0 · v2026.11.05 · Leave and pay rules (CLC 5 Nov 2026; part-time leave confirmed with a JTK officer)
-- 1. eppd_employments.fte_weekly_hours: the full-time week a part-timer is compared with (40 or 45; empty = the policy's 45).
-- 2. eppd_leave_records.hours (unpaid hours, leave type UPH) and .details (maternity / paternity: confinement or birth date, checks, ORP, allowance).
-- 3. cms_leave_requests.details, and the entitlement check shown when staff apply and when it is approved.
-- 4. Payment types UNPAID_HOURS (deduction before statutory) and MATERNITY_ALLOW (earning, wages).
-- 5. Policy minimum_wage (RM1,700 a month, RM8.72 an hour, daily rates by days a week) from 1 Feb 2025.
-- The part-time annual leave method itself is switched on by an Admin in Payroll Settings after the preview. Additive only.

alter table public.eppd_employments add column if not exists fte_weekly_hours numeric(4,1);
alter table public.eppd_leave_records add column if not exists hours numeric(5,2);
alter table public.eppd_leave_records add column if not exists details jsonb;
alter table public.cms_leave_requests add column if not exists details jsonb;

insert into public.eppd_payment_types (code, name, kind, category, treatment, subject_epf, subject_socso, subject_eis, subject_pcb, is_recurring, is_system, is_active, sort_order, notes)
select 'UNPAID_HOURS', 'Unpaid Hours', 'deduction', 'leave', 'unpaid_leave', true, true, true, true, false, true, true, 22,
       'Hours off (unearned wages): basic ÷ calendar days of the month ÷ normal daily hours × hours, at most one day''s pay per date.'
where not exists (select 1 from public.eppd_payment_types where code = 'UNPAID_HOURS');
insert into public.eppd_payment_types (code, name, kind, category, treatment, subject_epf, subject_socso, subject_eis, subject_pcb, is_recurring, is_system, is_active, sort_order, notes)
select 'MATERNITY_ALLOW', 'Maternity Allowance', 'earning', 'leave', 'wages', true, true, true, true, false, true, true, 6,
       'EA s.37: ordinary rate of pay for each day of the 98 days, for staff not paid a monthly salary (monthly salary simply continues).'
where not exists (select 1 from public.eppd_payment_types where code = 'MATERNITY_ALLOW');

insert into public.eppd_policies (key, value, description)
select 'minimum_wage', '{"from": "2025-02-01", "monthly": 1700, "hourly": 8.72, "daily": {"4": 98.08, "5": 78.46, "6": 65.38}}'::jsonb,
       'Minimum Wages Order: checked against basic salary (warning only). Hourly = RM1,700 × 12 ÷ 52 ÷ 45 h.'
where not exists (select 1 from public.eppd_policies where key = 'minimum_wage');

-- entitlement check for maternity (EA s.37) and paternity (s.60FA) leave
create or replace function private.cms_leave_entitlement_check(p_person uuid, p_type text, p_event date, p_start date default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; st date := coalesce(p_start, p_event); d9 integer := 0; emp4 boolean := false; prev integer := 0;
  sal record; basis text; orp numeric; earn numeric := 0; worked integer := 0; m0 date; m1 date; joined date; svc integer;
begin
  select * into em from public.employee_master where id = p_person;
  select * into ee from public.eppd_employees where employee_master_id = p_person order by id limit 1;
  if p_event is null then return null; end if;
  if p_type = 'MTL' then
    -- days employed in the 9 months before confinement, and employed at some time in the 4 months before
    select coalesce(sum(greatest(0, least(coalesce(e.resigned_date, p_event - 1), p_event - 1) - greatest(e.join_date, (p_event - interval '9 months')::date) + 1)), 0)::integer
      into d9 from public.eppd_employments e where e.employee_id = ee.id and e.join_date <= p_event - 1;
    emp4 := exists (select 1 from public.eppd_employments e where e.employee_id = ee.id and e.join_date <= p_event - 1 and coalesce(e.resigned_date, p_event) >= (p_event - interval '4 months')::date);
    select count(*) into prev from public.eppd_leave_records r where r.employee_id = ee.id and r.leave_type = 'MTL' and r.status = 'taken' and r.date_from < st;
    select s.amount, s.pay_basis into sal from public.eppd_salary_history s join public.eppd_assignments a on a.id = s.assignment_id join public.eppd_employments e on e.id = a.employment_id
     where e.employee_id = ee.id and a.is_primary and s.effective_from <= st order by s.effective_from desc, s.id desc limit 1;
    basis := coalesce(sal.pay_basis, 'monthly');
    if basis = 'monthly' then orp := round(coalesce(sal.amount, 0) / 26, 2);
    else
      m1 := date_trunc('month', st)::date; m0 := (m1 - interval '3 months')::date;
      select coalesce(sum((i->>'amount')::numeric), 0) into earn from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id, jsonb_array_elements(l.items) i
       where l.employee_id = ee.id and r.period >= m0 and r.period < m1 and not coalesce(l.excluded, false) and i->>'category' = 'basic';
      select count(distinct t.work_date) into worked from public.eppd_time_entries t where t.employee_id = ee.id and t.category = 'PT_HOURS' and t.work_date >= m0 and t.work_date < m1;
      orp := case when worked >= 5 then round(earn / worked, 2) end;
    end if;
    return jsonb_build_object('type', 'MTL', 'female', em.gender_code = 'F', 'days_employed_9m', d9, 'employed_4m', emp4,
      'eligible_allowance', em.gender_code = 'F' and d9 >= 90 and emp4, 'event', p_event, 'leave_from', st, 'leave_to', st + 97, 'early_start', st < p_event - 30,
      'previous_maternity', prev, 'pay_basis', basis, 'salary', sal.amount, 'orp', orp, 'earned_3m', earn, 'days_worked_3m', worked,
      'orp_basis', case when basis = 'monthly' then 'basic ÷ 26 (monthly salary continues)' else 'basic earned in the 3 months before ÷ days worked' end,
      'allowance', case when orp is not null then round(orp * 98, 2) end);
  elsif p_type = 'PTL' then
    select e.join_date into joined from public.eppd_employments e where e.employee_id = ee.id and e.join_date <= p_event and (e.resigned_date is null or e.resigned_date >= p_event) order by e.join_date desc limit 1;
    svc := case when joined is null then 0 else (extract(year from age(p_event, joined)) * 12 + extract(month from age(p_event, joined)))::integer end;
    select count(*) into prev from public.eppd_leave_records r where r.employee_id = ee.id and r.leave_type = 'PTL' and r.status = 'taken' and r.date_from < st;
    return jsonb_build_object('type', 'PTL', 'male', em.gender_code = 'M', 'service_months', svc, 'service_ok', svc >= 12, 'previous_paternity', prev, 'within_limit', prev < 5,
      'eligible', em.gender_code = 'M' and svc >= 12 and prev < 5, 'event', p_event, 'leave_from', st, 'leave_to', st + 6);
  end if;
  return null;
end $f$;
revoke all on function private.cms_leave_entitlement_check(uuid, text, date, date) from public, anon, authenticated;

create or replace function public.cms_leave_entitlement_check(p_person uuid, p_type text, p_event date, p_start date default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master;
begin
  p_person := coalesce(p_person, private.cms_me());   -- staff checking their own request
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  if not (private.cms_me() = p_person or public.cms_can('leave', 'V', private.cms_canon(em.company_code)) or public.cms_can('payroll', 'V')
          or private.cms_leave_can_decide(p_person)) then raise exception 'You do not have access to this.'; end if;
  return private.cms_leave_entitlement_check(p_person, p_type, p_event, p_start);
end $f$;
revoke all on function public.cms_leave_entitlement_check(uuid, text, date, date) from public, anon;
grant execute on function public.cms_leave_entitlement_check(uuid, text, date, date) to authenticated;

create or replace function public.cms_working_hours_save(p_person uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; m public.eppd_employments; v_cls text := nullif(p->>'hours_class', ''); v_h numeric := nullif(p->>'weekly_hours', '')::numeric;
  v_d numeric := nullif(p->>'work_days', '')::numeric; v_fte numeric := nullif(p->>'fte_weekly_hours', '')::numeric; v_why text := nullif(btrim(coalesce(p->>'reason', '')), '');
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'E', co);
  m := private.cms_resign_employment(p_person);
  if m.id is null then raise exception 'This person has no payroll employment yet.'; end if;
  if v_cls is not null and v_cls not in ('FT', 'PT', 'CASUAL') then raise exception 'Unknown marking.'; end if;
  if v_h is not null and (v_h <= 0 or v_h > 84) then raise exception 'Weekly hours must be between 0 and 84.'; end if;
  if v_d is not null and (v_d <= 0 or v_d > 7) then raise exception 'Working days a week must be between 1 and 7.'; end if;
  if v_fte is not null and (v_fte < 30 or v_fte > 48) then raise exception 'The full-time week must be between 30 and 48 hours.'; end if;
  if v_cls is distinct from m.hours_class and v_cls is not null and coalesce(length(v_why), 0) < 5 then raise exception 'Give the reason for the marking (at least 5 characters).'; end if;
  update public.eppd_employments set weekly_hours = v_h, work_days_per_week = v_d, hours_class = v_cls, fte_weekly_hours = case when p ? 'fte_weekly_hours' then v_fte else fte_weekly_hours end,
    hours_class_reason = case when v_cls is null then null when v_cls is distinct from m.hours_class or v_why is not null then coalesce(v_why, hours_class_reason) else hours_class_reason end,
    hours_class_by = case when v_cls is distinct from m.hours_class then auth.uid() else hours_class_by end,
    hours_class_at = case when v_cls is distinct from m.hours_class then now() else hours_class_at end
   where id = m.id;
  perform private.cms_log('people.working_hours', 'employee_master', em.id::text, co,
    em.employee_name || ': working hours ' || coalesce(v_h::text, '—') || ' h a week, ' || coalesce(v_d::text, '—') || ' days · marked ' || coalesce(v_cls, 'automatically'),
    jsonb_build_object('before', jsonb_build_object('weekly_hours', m.weekly_hours, 'work_days', m.work_days_per_week, 'hours_class', m.hours_class, 'fte_weekly_hours', m.fte_weekly_hours), 'after', p));
  return jsonb_build_object('ok', true);
end $f$;

create or replace function public.cms_working_hours_list()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; m0 date;
begin
  if not (public.cms_can('people', 'V') or public.cms_can('payroll', 'V')) then raise exception 'You do not have access to this.'; end if;
  m0 := (date_trunc('month', today) - interval '3 months')::date;
  return jsonb_build_object('policy', (select value from public.eppd_policies where key = 'part_time'), 'week', (select value->'work_week' from public.eppd_policies where key = 'payroll'), 'from', m0, 'to', (date_trunc('month', today) - interval '1 day')::date,
    'rows', coalesce((select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('person_id', em.id, 'name', coalesce(em.employee_name, ee.full_name), 'employee_id', coalesce(em.employee_id, ee.emp_id), 'company', private.cms_canon(em.company_code),
        'employment_id', m.id, 'job_status', m.job_status, 'weekly_hours', m.weekly_hours, 'work_days', m.work_days_per_week, 'hours_class', m.hours_class,
        'reason', m.hours_class_reason, 'marked_at', m.hours_class_at, 'marked_by', (select employee_name from public.employee_master b join public.cms_user_links ul on ul.employee_master_id = b.id where ul.user_id = m.hours_class_by limit 1),
        'work_from', m.work_from, 'work_to', m.work_to, 'meal_hours', m.meal_hours, 'fte_weekly_hours', m.fte_weekly_hours, 'join_date', m.join_date,
        'actual', (select jsonb_agg(jsonb_build_object('month', to_char(q.period, 'YYYY-MM'), 'hours', q.h) order by q.period) from (
            select r.period, sum((i->>'qty')::numeric) h from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id, jsonb_array_elements(l.items) i
             where l.employee_id = ee.id and not coalesce(l.excluded, false) and r.period >= m0 and r.period < date_trunc('month', today)::date and i->>'unit' = 'hours' and coalesce(i->>'category', '') = 'basic'
             group by r.period) q),
        'can_edit', public.cms_can('people', 'E', private.cms_canon(em.company_code))) x
        from public.eppd_employments m join public.eppd_employees ee on ee.id = m.employee_id left join public.employee_master em on em.id = ee.employee_master_id
       where (m.resigned_date is null or m.resigned_date >= today)
         and (public.cms_can('people', 'V', private.cms_canon(em.company_code)) or public.cms_can('payroll', 'V'))) s), '[]'::jsonb));
end $f$;

create or replace function private.cms_leave_json(r public.cms_leave_requests)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.id, 'person_id', r.person_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'type', r.leave_type, 'type_label', (select label from public.eppd_lookups where category = 'leave_type' and code = r.leave_type limit 1),
    'from', r.date_from, 'to', r.date_to, 'half_day', r.half_day, 'days', r.days, 'reason', r.reason, 'has_attachment', r.attachment is not null,
    'status', r.status, 'requested_at', r.requested_at, 'decided_by', r.decided_by_name, 'decided_at', r.decided_at, 'decision_note', r.decision_note,
    'payroll_done', r.payroll_done, 'payroll_done_at', r.payroll_done_at, 'can_decide', r.status = 'pending' and private.cms_leave_can_decide(r.person_id),
    'details', r.details, 'check', case when r.leave_type in ('MTL', 'PTL') and nullif(r.details->>'event', '') is not null
      then private.cms_leave_entitlement_check(r.person_id, r.leave_type, (r.details->>'event')::date, r.date_from) end)
  from public.employee_master em where em.id = r.person_id;
$$;

create or replace function public.cms_my_leave_apply(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('leave'); f date := nullif(p->>'from', '')::date; t date := nullif(p->>'to', '')::date; d numeric; id_ uuid;
begin
  if not exists (select 1 from public.eppd_lookups where category = 'leave_type' and code = p->>'type' and is_active) then raise exception 'Choose the type of leave.'; end if;
  if f is null then raise exception 'Choose the first day.'; end if;
  t := coalesce(t, f);
  if t < f then raise exception 'The last day is before the first day.'; end if;
  d := coalesce(nullif(p->>'days', '')::numeric, case when coalesce((p->>'half_day')::boolean, false) then 0.5 else (t - f + 1) end);
  if d <= 0 or d > (t - f + 1) then raise exception 'Check the number of days.'; end if;
  if exists (select 1 from public.cms_leave_requests where person_id = v and status in ('pending','approved') and daterange(date_from, date_to, '[]') && daterange(f, t, '[]')) then
    raise exception 'You already have leave on some of these days.';
  end if;
  if p->>'type' in ('SL','HPL') and nullif(p->>'attachment', '') is null then raise exception 'Attach the medical certificate (MC).'; end if;
  if p->>'type' = 'MTL' and nullif(p->'details'->>'event', '') is null then raise exception 'Give the expected date of confinement (due date).'; end if;
  if p->>'type' = 'PTL' and nullif(p->'details'->>'event', '') is null then raise exception 'Give the baby''s date of birth (or the expected date).'; end if;
  insert into public.cms_leave_requests (person_id, leave_type, date_from, date_to, half_day, days, reason, attachment, requested_by, details)
  values (v, p->>'type', f, t, coalesce((p->>'half_day')::boolean, false), d, nullif(btrim(p->>'reason'), ''), private.cms_photo_ok(p->>'attachment'), auth.uid(),
          case when p->>'type' in ('MTL', 'PTL') then p->'details' end)
  returning id into id_;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v, 'leave_requested', 'Leave requested in self-service', jsonb_build_object('request_id', id_, 'type', p->>'type', 'from', f, 'to', t, 'days', d), auth.uid());
  return id_;
end $$;
