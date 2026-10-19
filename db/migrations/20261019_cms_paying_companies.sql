-- MyEden Group CMS V1.0 · Paying-company control (Phase 2)
-- Applied 2026-10-19 in parts (part 1 … part 4). Additive only: no table or column is removed.
--
-- Who pays each person lives in MyPayroll's eppd_assignments (one row per paying company per
-- employment, from start_date to end_date, with is_primary = the main company). These functions let
-- Admin and HR change it from the CMS, by payroll month, with an audit entry for every change:
--   cms_paying_companies(person)   timeline per person (view)
--   cms_pay_transfer(...)          move to another company from a month
--   cms_pay_add_company(...)       joint payment: a second company with its own salary and statutory switches
--   cms_pay_end_company(...)       stop one of several companies after a month
--   cms_pay_set_main(...)          choose the main company
--   cms_pay_correct(...)           fix a wrong record (Admin only once a month using it is finalised)
--   cms_people_list()              People list with the previous ID and "paid by" from payroll
-- Finalised months are never rewritten: pay lines keep the company they were paid under.

-- ---------------------------------------------------------------- part 1: module, permissions, helpers
insert into public.cms_modules (code, label, grp, phase, sort_order)
values ('payroll.paying', 'Paying Companies', 'Payroll', 2, 52)
on conflict (code) do nothing;

insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'payroll.paying', 'VCEADX'), ('admin', 'payroll.paying', 'VCEADX'), ('hr', 'payroll.paying', 'VCE'),
  ('payroll', 'payroll.paying', 'V'), ('finance', 'payroll.paying', 'V'), ('payroll_viewer', 'payroll.paying', 'V'),
  ('director', 'payroll.paying', 'V')
on conflict do nothing;

-- the person behind a paying-company record
create or replace function private.cms_pay_person(p_assignment bigint)
returns table (assignment_id bigint, employment_id bigint, employee_id bigint, person_id uuid, name text, company text, company_id bigint,
               is_primary boolean, start_date date, end_date date, latest boolean, resigned date)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, e.id, ee.id, ee.employee_master_id, coalesce(em.employee_name, ee.full_name)::text,
         private.cms_canon(coalesce(em.company_code, c.code)), a.company_id, a.is_primary, a.start_date, a.end_date,
         not exists (select 1 from public.eppd_employments e2 where e2.employee_id = e.employee_id and e2.join_date > e.join_date),
         e.resigned_date
  from public.eppd_assignments a
  join public.eppd_employments e on e.id = a.employment_id
  join public.eppd_employees ee on ee.id = e.employee_id
  join public.eppd_companies c on c.id = a.company_id
  left join public.employee_master em on em.id = ee.employee_master_id
  where a.id = p_assignment;
$$;

-- an active paying company by CMS code → eppd_companies.id
create or replace function private.cms_pay_company_id(p_code text)
returns bigint language sql stable security definer set search_path = public, pg_temp as $$
  select ec.id from public.eppd_companies ec
  join public.cms_companies cc on cc.code = ec.code and cc.is_active and cc.is_paying
  where ec.code = private.cms_canon(p_code) and ec.is_active;
$$;

-- finalised months already paid under a record, from a month onwards (null = none)
create or replace function private.cms_pay_finalised(p_assignment bigint, p_from date default null, p_to date default null)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select string_agg(to_char(r.period, 'Mon YYYY'), ', ' order by r.period)
  from (select distinct r.period from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
        where l.assignment_id = p_assignment and r.status = 'finalised'
          and (p_from is null or r.period >= p_from) and (p_to is null or r.period <= p_to)) r;
$$;

revoke all on function private.cms_pay_person(bigint), private.cms_pay_company_id(text), private.cms_pay_finalised(bigint, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- part 2: read functions
-- every paying-company record per person (all employments), newest first
create or replace function public.cms_paying_companies(p_person uuid default null)
returns table (person_id uuid, employee_id text, previous_id text, name text, employer text, person_status text,
               employment_id bigint, join_date date, resigned_date date, latest boolean,
               assignment_id bigint, company_code text, is_main boolean, start_date date, end_date date, state text,
               salary numeric, pay_basis text, salary_from date, statutory jsonb,
               months_paid integer, first_paid date, last_paid date, finalised_to date)
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
                            'eis_ee', a.eis_ee, 'eis_er', a.eis_er, 'socso_nei_opt_out', a.socso_nei_opt_out),
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
end $$;

-- People list (replaces cms_people on the People page): adds the previous ID and who pays now, from payroll
create or replace function public.cms_people_list()
returns table (id uuid, employee_id text, previous_id text, name text, company_code text, paying_company_code text, paid_by text[],
               manual_paying_code text, in_payroll boolean, unit_code text, department text, job_title text, level text, status text,
               start_date date, last_day date, email text, login_email text, source_type text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
begin
  perform private.cms_require('people', 'V');
  return query
  select em.id, em.employee_id::text, em.previous_employee_id::text, em.employee_name::text, private.cms_canon(em.company_code),
         coalesce(pay.codes[1], pp.paying_company_code), pay.codes, pp.paying_company_code, pay.codes is not null,
         coalesce(pp.unit_code, (select un.code from public.cms_units un where un.code = upper(btrim(em.department)) and un.is_active)),
         em.department::text, em.approved_job_title::text, split_part(coalesce(em.job_title_level, ''), '|', 1),
         em.employment_status::text, em.start_date, em.actual_last_working_date, em.email::text, u.email::text, em.source_type::text
  from public.employee_master em
  left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
  left join public.cms_user_links l on l.employee_master_id = em.id
  left join auth.users u on u.id = l.user_id
  left join lateral (
    -- latest employment: companies paying this month (main first); if none, the last company that paid
    select coalesce(
      (select array_agg(c.code order by a.is_primary desc, a.start_date nulls first, a.id)
         from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
        where a.employment_id = le.id and (a.end_date is null or a.end_date >= v_month)
          and (a.start_date is null or a.start_date < (v_month + interval '1 month')::date)),
      (select array[c.code] from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
        where a.employment_id = le.id order by a.end_date desc nulls first, a.start_date desc nulls last, a.id desc limit 1)) codes
    from (select e.id from public.eppd_employees ee join public.eppd_employments e on e.employee_id = ee.id
          where ee.employee_master_id = em.id order by e.join_date desc nulls last, e.id desc limit 1) le
  ) pay on true
  where public.cms_can('people', 'V', em.company_code)
  order by em.employee_name;
end $$;

grant execute on function public.cms_paying_companies(uuid), public.cms_people_list() to authenticated;

-- ---------------------------------------------------------------- part 3: changes (Admin and HR)
-- shared checks for a change: permission on the employer company, latest employment, not a past record
create or replace function private.cms_pay_guard(p_assignment bigint, p_action text default 'E')
returns table (assignment_id bigint, employment_id bigint, person_id uuid, name text, company text, company_id bigint,
               is_primary boolean, start_date date, end_date date, resigned date)
language plpgsql security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare r record;
begin
  select * into r from private.cms_pay_person(p_assignment);
  if r.assignment_id is null then raise exception 'Paying-company record not found.'; end if;
  perform private.cms_require('payroll.paying', p_action, r.company);
  if not r.latest then raise exception 'This record belongs to an earlier employment of %. Only the latest employment can be changed.', r.name; end if;
  perform 1 from public.eppd_assignments a where a.id = p_assignment for update;
  return query select r.assignment_id, r.employment_id, r.person_id, r.name, r.company, r.company_id, r.is_primary, r.start_date, r.end_date, r.resigned;
end $$;

-- Transfer: from a payroll month the person is paid by another company. Months before stay with the old company.
create or replace function public.cms_pay_transfer(p_assignment bigint, p_company text, p_from date, p_note text default null)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; v_from date := date_trunc('month', p_from)::date; v_to bigint := private.cms_pay_company_id(p_company);
        v_new bigint; v_fin text; v_old text; v_new_code text; v_split boolean;
begin
  if p_from is null then raise exception 'Choose the first payroll month under the new company.'; end if;
  select * into g from private.cms_pay_guard(p_assignment, 'E');
  if v_to is null then raise exception 'Choose an active paying company.'; end if;
  select * into a from public.eppd_assignments where id = p_assignment;
  select code into v_old from public.eppd_companies where id = a.company_id;
  select code into v_new_code from public.eppd_companies where id = v_to;
  if a.company_id = v_to then raise exception '% is already paid by %.', g.name, v_old; end if;
  if a.end_date is not null and a.end_date < v_from then raise exception 'This record already ended on %.', to_char(a.end_date, 'DD Mon YYYY'); end if;
  if exists (select 1 from public.eppd_assignments x where x.employment_id = a.employment_id and x.id <> a.id and x.company_id = v_to
             and (x.end_date is null or x.end_date >= v_from)) then
    raise exception '% is already paid by % from that month (joint payment). End one of the two instead.', g.name, v_new_code;
  end if;
  v_fin := private.cms_pay_finalised(a.id, v_from);
  if v_fin is not null then raise exception 'Already finalised under %: %. Choose a later month, or ask an admin to reopen it.', v_old, v_fin; end if;
  v_split := exists (select 1 from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id where l.assignment_id = a.id and r.period < v_from)
             or (a.start_date is not null and a.start_date < v_from);
  if not v_split then
    update public.eppd_assignments set company_id = v_to where id = a.id;
    v_new := a.id;
  else
    update public.eppd_assignments set is_primary = false, end_date = v_from - 1 where id = a.id;
    insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
    values (a.employment_id, v_to, a.is_primary, v_from, a.end_date, a.epf_ee, a.epf_er, a.socso_ee, a.socso_er, a.eis_ee, a.eis_er, a.socso_nei_opt_out)
    returning id into v_new;
    insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
    select v_new, effective_from, amount, pay_basis, reason, note from public.eppd_salary_history where assignment_id = a.id;
    insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
    select v_new, payment_type_id, amount, greatest(coalesce(start_date, v_from), v_from), end_date, note
      from public.eppd_allowances where assignment_id = a.id and (end_date is null or end_date >= v_from);
    update public.eppd_allowances set end_date = v_from - 1
     where assignment_id = a.id and (end_date is null or end_date >= v_from) and (start_date is null or start_date < v_from);
  end if;
  perform private.cms_log('pay.transfer', 'eppd_assignments', v_new::text, g.company,
    format('%s: paid by %s from %s (was %s)', g.name, v_new_code, to_char(v_from, 'Mon YYYY'), v_old),
    jsonb_build_object('person', g.person_id, 'from_assignment', a.id, 'to_assignment', v_new, 'from_company', v_old, 'to_company', v_new_code,
                       'from_month', v_from, 'split', v_split, 'note', nullif(p_note, '')));
  return v_new;
end $$;

-- Joint payment: a second company also pays from a month, with its own salary and statutory switches
create or replace function public.cms_pay_add_company(p_employment bigint, p_company text, p_from date, p_salary numeric,
  p_pay_basis text default 'monthly', p_statutory jsonb default null, p_note text default null)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; v_from date := date_trunc('month', p_from)::date; v_to bigint := private.cms_pay_company_id(p_company);
        v_code text; v_new bigint; v_any bigint; s jsonb := coalesce(p_statutory, '{}'::jsonb); v_main boolean;
begin
  if p_from is null then raise exception 'Choose the first payroll month for this company.'; end if;
  if p_salary is null or p_salary < 0 then raise exception 'Enter the salary this company pays (0 if it pays allowances only).'; end if;
  if coalesce(p_pay_basis, 'monthly') not in ('monthly', 'hourly') then raise exception 'Pay basis must be monthly or hourly.'; end if;
  select a.id into v_any from public.eppd_assignments a where a.employment_id = p_employment order by a.id limit 1;
  if v_any is null then raise exception 'Employment not found, or it has no paying company yet.'; end if;
  select * into g from private.cms_pay_guard(v_any, 'C');
  if v_to is null then raise exception 'Choose an active paying company.'; end if;
  select code into v_code from public.eppd_companies where id = v_to;
  if g.resigned is not null and g.resigned < v_from then raise exception '% left on %.', g.name, to_char(g.resigned, 'DD Mon YYYY'); end if;
  if exists (select 1 from public.eppd_assignments x where x.employment_id = p_employment and x.company_id = v_to
             and (x.end_date is null or x.end_date >= v_from)) then
    raise exception '% is already paid by % in that month.', g.name, v_code;
  end if;
  v_main := not exists (select 1 from public.eppd_assignments x where x.employment_id = p_employment and x.is_primary
                        and (x.end_date is null or x.end_date >= v_from));
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
  values (p_employment, v_to, v_main, v_from, null,
          coalesce((s->>'epf_ee')::boolean, true), coalesce((s->>'epf_er')::boolean, true), coalesce((s->>'socso_ee')::boolean, true),
          coalesce((s->>'socso_er')::boolean, true), coalesce((s->>'eis_ee')::boolean, true), coalesce((s->>'eis_er')::boolean, true),
          coalesce((s->>'socso_nei_opt_out')::boolean, false))
  returning id into v_new;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
  values (v_new, v_from, p_salary, coalesce(p_pay_basis, 'monthly'), 'Joint payment', nullif(p_note, ''));
  perform private.cms_log('pay.add_company', 'eppd_assignments', v_new::text, g.company,
    format('%s: also paid by %s from %s (joint payment)', g.name, v_code, to_char(v_from, 'Mon YYYY')),
    jsonb_build_object('person', g.person_id, 'employment', p_employment, 'assignment', v_new, 'company', v_code, 'from_month', v_from,
                       'salary', p_salary, 'pay_basis', coalesce(p_pay_basis, 'monthly'), 'statutory', s, 'main', v_main, 'note', nullif(p_note, '')));
  return v_new;
end $$;

-- End one company of a joint payment after a month (the person keeps at least one paying company)
create or replace function public.cms_pay_end_company(p_assignment bigint, p_last_month date, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; v_end date := (date_trunc('month', p_last_month) + interval '1 month' - interval '1 day')::date;
        v_code text; v_fin text; v_other bigint; v_others int; v_main_to text;
begin
  if p_last_month is null then raise exception 'Choose the last payroll month this company pays.'; end if;
  select * into g from private.cms_pay_guard(p_assignment, 'E');
  select * into a from public.eppd_assignments where id = p_assignment;
  select code into v_code from public.eppd_companies where id = a.company_id;
  if a.end_date is not null and a.end_date <= v_end then raise exception 'This record already ends on %.', to_char(a.end_date, 'DD Mon YYYY'); end if;
  if a.start_date is not null and v_end < a.start_date then raise exception 'The last month is before this company started paying (%). Use Correct a mistake instead.', to_char(a.start_date, 'Mon YYYY'); end if;
  v_fin := private.cms_pay_finalised(a.id, v_end + 1);
  if v_fin is not null then raise exception 'Already finalised under % after that month: %.', v_code, v_fin; end if;
  select count(*), min(x.id) into v_others, v_other from public.eppd_assignments x
   where x.employment_id = a.employment_id and x.id <> a.id and (x.end_date is null or x.end_date > v_end);
  if v_others = 0 then
    raise exception '% is the only company paying %. Use Transfer to move to another company; leaving the group is recorded with the last working day.', v_code, g.name;
  end if;
  if a.is_primary and v_others > 1 then
    raise exception '% is the main company. Set another main company first, then end this one.', v_code;
  end if;
  update public.eppd_assignments set end_date = v_end, is_primary = false where id = a.id;
  update public.eppd_allowances set end_date = v_end where assignment_id = a.id and (end_date is null or end_date > v_end) and (start_date is null or start_date <= v_end);
  if a.is_primary then
    if v_others = 1 then
      update public.eppd_assignments set is_primary = true where id = v_other;
      select c.code into v_main_to from public.eppd_assignments x join public.eppd_companies c on c.id = x.company_id where x.id = v_other;
    end if;
  end if;
  perform private.cms_log('pay.end_company', 'eppd_assignments', a.id::text, g.company,
    format('%s: %s stops paying after %s%s', g.name, v_code, to_char(v_end, 'Mon YYYY'), coalesce(', main company now ' || v_main_to, '')),
    jsonb_build_object('person', g.person_id, 'assignment', a.id, 'company', v_code, 'end_date', v_end, 'was_end_date', a.end_date,
                       'main_moved_to', v_main_to, 'note', nullif(p_note, '')));
end $$;

-- Main company: the one listed first and used where payroll needs a single company
create or replace function public.cms_pay_set_main(p_assignment bigint, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; v_code text; v_was text;
        v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
begin
  select * into g from private.cms_pay_guard(p_assignment, 'E');
  select * into a from public.eppd_assignments where id = p_assignment;
  if a.end_date is not null and a.end_date < v_month then raise exception 'This company no longer pays %.', g.name; end if;
  if a.is_primary then return; end if;
  select string_agg(c.code, ', ') into v_was from public.eppd_assignments x join public.eppd_companies c on c.id = x.company_id
   where x.employment_id = a.employment_id and x.is_primary and x.id <> a.id and (x.end_date is null or x.end_date >= v_month);
  update public.eppd_assignments set is_primary = false
   where employment_id = a.employment_id and id <> a.id and is_primary and (end_date is null or end_date >= v_month);
  update public.eppd_assignments set is_primary = true where id = a.id;
  select code into v_code from public.eppd_companies where id = a.company_id;
  perform private.cms_log('pay.set_main', 'eppd_assignments', a.id::text, g.company,
    format('%s: main paying company %s (was %s)', g.name, v_code, coalesce(v_was, 'none')),
    jsonb_build_object('person', g.person_id, 'assignment', a.id, 'company', v_code, 'was', v_was, 'note', nullif(p_note, '')));
end $$;

-- Correct a mistake in a record: company, start, end (exact dates) and statutory switches. Reason required.
-- If a finalised month was paid under this record, only Admin can correct it, and the finalised months stay
-- as they were paid until payroll reopens and re-finalises them.
create or replace function public.cms_pay_correct(p_assignment bigint, p_company text, p_start date, p_end date,
  p_statutory jsonb default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; v_to bigint := private.cms_pay_company_id(p_company); v_code text; v_was text;
        v_start date := p_start; v_end date := p_end;  -- exact dates: a start can be a mid-month join date
        v_fin text; s jsonb := coalesce(p_statutory, '{}'::jsonb); v_after jsonb; v_before jsonb;
begin
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the correction.'; end if;
  if v_to is null then raise exception 'Choose an active paying company.'; end if;
  if v_end is not null and v_start is not null and v_end < v_start then raise exception 'The end date is before the start date.'; end if;
  select * into a from public.eppd_assignments where id = p_assignment;
  v_fin := private.cms_pay_finalised(p_assignment);
  select * into g from private.cms_pay_guard(p_assignment, case when v_fin is null then 'E' else 'A' end);
  select code into v_was from public.eppd_companies where id = a.company_id;
  select code into v_code from public.eppd_companies where id = v_to;
  if exists (select 1 from public.eppd_assignments x where x.employment_id = a.employment_id and x.id <> a.id and x.company_id = v_to
             and (x.end_date is null or v_start is null or x.end_date >= v_start) and (v_end is null or x.start_date is null or x.start_date <= v_end)) then
    raise exception 'Another record already has % paying in those months.', v_code;
  end if;
  v_before := to_jsonb(a) - 'created_at' - 'updated_at';
  update public.eppd_assignments set company_id = v_to, start_date = v_start, end_date = v_end,
    epf_ee = coalesce((s->>'epf_ee')::boolean, epf_ee), epf_er = coalesce((s->>'epf_er')::boolean, epf_er),
    socso_ee = coalesce((s->>'socso_ee')::boolean, socso_ee), socso_er = coalesce((s->>'socso_er')::boolean, socso_er),
    eis_ee = coalesce((s->>'eis_ee')::boolean, eis_ee), eis_er = coalesce((s->>'eis_er')::boolean, eis_er),
    socso_nei_opt_out = coalesce((s->>'socso_nei_opt_out')::boolean, socso_nei_opt_out)
  where id = a.id;
  select to_jsonb(x) - 'created_at' - 'updated_at' into v_after from public.eppd_assignments x where x.id = a.id;
  perform private.cms_log('pay.correct', 'eppd_assignments', a.id::text, g.company,
    format('%s: corrected %s record%s', g.name, v_was, case when v_was <> v_code then ' to ' || v_code else '' end),
    jsonb_build_object('person', g.person_id, 'before', v_before, 'after', v_after, 'reason', btrim(p_reason), 'finalised_months', v_fin));
  return jsonb_build_object('finalised_months', v_fin);
end $$;

revoke all on function private.cms_pay_guard(bigint, text) from public, anon, authenticated;
grant execute on function public.cms_pay_transfer(bigint, text, date, text), public.cms_pay_add_company(bigint, text, date, numeric, text, jsonb, text),
  public.cms_pay_end_company(bigint, date, text), public.cms_pay_set_main(bigint, text), public.cms_pay_correct(bigint, text, date, date, jsonb, text)
  to authenticated;

-- ---------------------------------------------------------------- part 4: correction keeps exact dates
-- (cms_pay_correct above is the final version; part 4 re-created it without rounding to whole months)
