-- MyEden Group CMS V1.0 · v2026.11.03 · Hourly rate on the Employment Act cap, 5-day week (CLC 3 Nov 2026)
-- 1. Payroll rule "Hours used for the hourly rate": each person's normal hours, at most 8 a day, from the October 2026 payroll.
--    Months before October and finalised months are not recalculated.
-- 2. Working week: 5 days, 45 hours (Saturday off day, Sunday rest day, as already set).
-- 3. Resignation: leave is offset on Monday–Friday (was Monday–Saturday).
-- 4. Working hours list shows everyone (full time too), with the meal break, so a week over 45 hours can be flagged.
-- Additive only: policy values are merged, no rows removed.

update public.eppd_policies set value = coalesce(value, '{}'::jsonb)
  || jsonb_build_object('hours_rule', jsonb_build_object('mode', 'cap', 'cap', 8, 'from', '2026-10'))
  || jsonb_build_object('work_week', jsonb_build_object('days', 5, 'max_hours', 45))
 where key = 'payroll';
update public.eppd_policies set value = coalesce(value, '{}'::jsonb) || jsonb_build_object('work_days', jsonb_build_array(1, 2, 3, 4, 5))
 where key = 'settlement';

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
        'work_from', m.work_from, 'work_to', m.work_to, 'meal_hours', m.meal_hours, 'join_date', m.join_date,
        'actual', (select jsonb_agg(jsonb_build_object('month', to_char(q.period, 'YYYY-MM'), 'hours', q.h) order by q.period) from (
            select r.period, sum((i->>'qty')::numeric) h from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id, jsonb_array_elements(l.items) i
             where l.employee_id = ee.id and not coalesce(l.excluded, false) and r.period >= m0 and r.period < date_trunc('month', today)::date and i->>'unit' = 'hours' and coalesce(i->>'category', '') = 'basic'
             group by r.period) q),
        'can_edit', public.cms_can('people', 'E', private.cms_canon(em.company_code))) x
        from public.eppd_employments m join public.eppd_employees ee on ee.id = m.employee_id left join public.employee_master em on em.id = ee.employee_master_id
       where (m.resigned_date is null or m.resigned_date >= today)
         and (public.cms_can('people', 'V', private.cms_canon(em.company_code)) or public.cms_can('payroll', 'V'))) s), '[]'::jsonb));
end $f$;
