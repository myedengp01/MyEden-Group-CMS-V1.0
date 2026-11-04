-- MyEden Group CMS V1.0 · v2026.11.04 · Statutory switches per person and paying company, from a chosen payroll month
-- (EPF / SOCSO / EIS employee and employer shares, SOCSO NEI opt-out). Needs "Paying companies: edit" for the person's company.
-- From an open month up to the current month: the switches change now, for every month not yet finalised.
-- From a later month: kept as a scheduled change (eppd_assignments.statutory_schedule) that payroll applies from that month.
-- Finalised months never change. Logged in the CMS audit log (and the payroll audit trigger). Additive only.

alter table public.eppd_assignments add column if not exists statutory_schedule jsonb not null default '[]'::jsonb;

create or replace function public.cms_statutory_set(p_assignment bigint, p_from date, p_flags jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.eppd_assignments; co text; who text; v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
  k text; f jsonb := '{}'::jsonb; sched jsonb; v_fin date; ch text[] := '{}';
  keys text[] := array['epf_ee', 'epf_er', 'socso_ee', 'socso_er', 'eis_ee', 'eis_er', 'socso_nei_opt_out'];
begin
  select * into a from public.eppd_assignments where id = p_assignment;
  if a.id is null then raise exception 'Paying company record not found.'; end if;
  select coalesce(private.cms_canon(em.company_code), c.code), coalesce(em.employee_name, ee.full_name) into co, who
    from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id join public.eppd_companies c on c.id = a.company_id
    left join public.employee_master em on em.id = ee.employee_master_id where e.id = a.employment_id;
  perform private.cms_require('payroll.paying', 'E', co);
  if p_from is null or extract(day from p_from) <> 1 then raise exception 'Choose the payroll month the change starts.'; end if;
  select max(r.period) into v_fin from public.eppd_pay_runs r where r.status = 'finalised';
  if v_fin is not null and p_from <= v_fin then raise exception 'Payroll up to % is finalised. Choose a later month; finalised months do not change.', to_char(v_fin, 'Mon YYYY'); end if;
  foreach k in array keys loop
    if jsonb_typeof(p_flags->k) is distinct from 'boolean' then raise exception 'Missing switch: %', k; end if;
    f := f || jsonb_build_object(k, (p_flags->>k)::boolean);
    if (to_jsonb(a)->k) is distinct from (p_flags->k) then ch := array_append(ch, k || (case when (p_flags->>k)::boolean then ' on' else ' off' end)); end if;
  end loop;
  if p_from <= v_month then
    -- now: for every open month; scheduled changes from this month or earlier are replaced by it
    sched := coalesce((select jsonb_agg(x order by x->>'from') from jsonb_array_elements(a.statutory_schedule) x where (x->>'from')::date > p_from), '[]'::jsonb);
    update public.eppd_assignments set epf_ee = (f->>'epf_ee')::boolean, epf_er = (f->>'epf_er')::boolean, socso_ee = (f->>'socso_ee')::boolean,
      socso_er = (f->>'socso_er')::boolean, eis_ee = (f->>'eis_ee')::boolean, eis_er = (f->>'eis_er')::boolean, socso_nei_opt_out = (f->>'socso_nei_opt_out')::boolean,
      statutory_schedule = sched where id = a.id;
  else
    sched := coalesce((select jsonb_agg(x order by x->>'from') from (
        select x from jsonb_array_elements(a.statutory_schedule) x where (x->>'from')::date <> p_from
        union all select jsonb_build_object('from', p_from, 'flags', f, 'note', nullif(btrim(coalesce(p_note, '')), ''), 'by', private.cms_user_name(auth.uid()), 'at', now())) s), '[]'::jsonb);
    update public.eppd_assignments set statutory_schedule = sched where id = a.id;
  end if;
  perform private.cms_log('payroll.statutory', 'eppd_assignments', a.id::text, co,
    who || ': statutory from ' || to_char(p_from, 'Mon YYYY') || case when cardinality(ch) > 0 then ' (' || array_to_string(ch, ', ') || ')' else ' (no change to the current switches)' end
      || coalesce(' · ' || nullif(btrim(coalesce(p_note, '')), ''), ''),
    jsonb_build_object('from', p_from, 'flags', f, 'scheduled', p_from > v_month, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  return jsonb_build_object('assignment_id', a.id, 'from', p_from, 'scheduled', p_from > v_month, 'changed', to_jsonb(ch));
end $f$;
revoke all on function public.cms_statutory_set(bigint, date, jsonb, text) from public, anon;
grant execute on function public.cms_statutory_set(bigint, date, jsonb, text) to authenticated;

-- remove a scheduled change that has not started
create or replace function public.cms_statutory_unschedule(p_assignment bigint, p_from date)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.eppd_assignments; co text;
begin
  select * into a from public.eppd_assignments where id = p_assignment;
  if a.id is null then raise exception 'Paying company record not found.'; end if;
  select coalesce(private.cms_canon(em.company_code), c.code) into co from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id
    join public.eppd_companies c on c.id = a.company_id left join public.employee_master em on em.id = ee.employee_master_id where e.id = a.employment_id;
  perform private.cms_require('payroll.paying', 'E', co);
  update public.eppd_assignments set statutory_schedule = coalesce((select jsonb_agg(x order by x->>'from') from jsonb_array_elements(a.statutory_schedule) x where (x->>'from')::date <> p_from), '[]'::jsonb)
   where id = a.id;
  perform private.cms_log('payroll.statutory', 'eppd_assignments', a.id::text, co, 'Scheduled statutory change from ' || to_char(p_from, 'Mon YYYY') || ' removed', jsonb_build_object('from', p_from));
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.cms_statutory_unschedule(bigint, date) from public, anon;
grant execute on function public.cms_statutory_unschedule(bigint, date) to authenticated;

CREATE OR REPLACE FUNCTION public.cms_paying_companies(p_person uuid DEFAULT NULL::uuid)
 RETURNS TABLE(person_id uuid, employee_id text, previous_id text, name text, employer text, person_status text, employment_id bigint, join_date date, resigned_date date, latest boolean, assignment_id bigint, company_code text, is_main boolean, start_date date, end_date date, state text, salary numeric, pay_basis text, salary_from date, statutory jsonb, months_paid integer, first_paid date, last_paid date, finalised_to date)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
declare v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
begin
  perform private.cms_require('payroll.paying', 'V');
  return query
  select ee.employee_master_id, coalesce(em.employee_id, ee.emp_id)::text, coalesce(em.previous_employee_id, ee.previous_emp_id)::text,
         coalesce(em.employee_name, ee.full_name)::text, private.cms_canon(em.company_code), em.employment_status::text,
         e.id, e.join_date, e.resigned_date,
         not exists (select 1 from public.eppd_employments e2 where e2.employee_id = e.employee_id and e2.join_date > e.join_date),
         a.id, c.code, a.is_primary, a.start_date, a.end_date,
         case when a.end_date is not null and a.end_date < v_month then 'ended'
              when a.start_date is not null and a.start_date > (v_month + interval '1 month' - interval '1 day')::date then 'upcoming'
              when e.resigned_date is not null and e.resigned_date < v_month then 'ended'
              else 'current' end,
         sh.amount, sh.pay_basis, sh.effective_from,
         jsonb_build_object('epf_ee', a.epf_ee, 'epf_er', a.epf_er, 'socso_ee', a.socso_ee, 'socso_er', a.socso_er,
                            'eis_ee', a.eis_ee, 'eis_er', a.eis_er, 'socso_nei_opt_out', a.socso_nei_opt_out, 'schedule', coalesce(a.statutory_schedule, '[]'::jsonb)),
         coalesce(pl.n, 0)::integer, pl.first_p, pl.last_p, pl.fin_p
  from public.eppd_assignments a
  join public.eppd_employments e on e.id = a.employment_id
  join public.eppd_employees ee on ee.id = e.employee_id
  join public.eppd_companies c on c.id = a.company_id
  left join public.employee_master em on em.id = ee.employee_master_id
  left join lateral (select s.amount, s.pay_basis, s.effective_from from public.eppd_salary_history s
                     where s.assignment_id = a.id order by s.effective_from desc nulls last, s.id desc limit 1) sh on true
  left join lateral (select count(distinct r.period) n, min(r.period) first_p, max(r.period) last_p,
                            max(r.period) filter (where r.status = 'finalised') fin_p
                     from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                     where l.assignment_id = a.id and not coalesce(l.excluded, false)) pl on true
  where (p_person is null or ee.employee_master_id = p_person)
    and public.cms_can('payroll.paying', 'V', coalesce(em.company_code, c.code))
  order by coalesce(em.employee_name, ee.full_name), e.join_date desc, a.start_date desc nulls last, a.id desc;
end $function$;
