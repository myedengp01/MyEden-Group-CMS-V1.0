-- MyEden Group CMS V1.0 · v2026.10.19 (second release of the day)
-- 1. Main paying company by period (needs db/payroll/011_main_company_by_period.sql first, run by hand)
-- 2. Notice period until stored on the payroll employment, filled from the policy; HR may change it
-- 3. Employee names saved in upper case (Employee Master and payroll)
-- 4. People list with confirmation, notice and last working day
-- Additive. The 22 notice dates from the EPPD workbook and the 11 upper-case names were data updates, not kept here.

-- ---------------------------------------------------------------- part A: notice until + upper-case names (applied)
alter table public.eppd_employments add column if not exists notice_until date;
comment on column public.eppd_employments.notice_until is 'Last day of the notice period. Filled from the notice_period policy when a resignation letter date is entered; HR may change it (agreed shorter/longer notice).';

create or replace function public.eppd_notice_until(p_join date, p_letter date, p_probation boolean)
returns date language sql stable security definer set search_path = public, pg_temp as $$
  with pol as (select value v from public.eppd_policies where key = 'notice_period'),
  yrs as (select greatest(0, extract(year from age(p_letter, p_join))::int) y)
  select case when p_letter is null then null else p_letter + 7 * coalesce(
    case when p_probation or p_join is null then (select (v->>'probation_weeks')::int from pol)
         else (select (b->>'weeks')::int from pol, jsonb_array_elements(pol.v->'bands') b, yrs
               where yrs.y >= (b->>'from_years')::int and (b->>'to_years' is null or yrs.y < (b->>'to_years')::int) limit 1) end, 0) end;
$$;

-- a new or changed letter date (or join / confirmed date) recalculates, unless the same save sets notice_until by hand;
-- clearing the letter date clears it
create or replace function public.eppd_employments_notice()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.resignation_letter_date is null then
    if tg_op = 'UPDATE' and old.resignation_letter_date is not null and new.notice_until is not distinct from old.notice_until then new.notice_until := null; end if;
    return new;
  end if;
  if tg_op = 'INSERT' and new.notice_until is null
     or tg_op = 'UPDATE' and (new.resignation_letter_date is distinct from old.resignation_letter_date or new.join_date is distinct from old.join_date
                              or new.confirmed_date is distinct from old.confirmed_date)
        and new.notice_until is not distinct from old.notice_until then
    new.notice_until := public.eppd_notice_until(new.join_date, new.resignation_letter_date,
      new.confirmation_status = 'UP' or (new.confirmed_date is not null and new.confirmed_date > new.resignation_letter_date));
  end if;
  return new;
end $$;
create trigger eppd_employments_notice before insert or update on public.eppd_employments
  for each row execute function public.eppd_employments_notice();

create or replace function public.cms_upper_name()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'employee_master' then new.employee_name := nullif(upper(btrim(new.employee_name)), '');
  else new.full_name := nullif(upper(btrim(new.full_name)), ''); end if;
  return new;
end $$;
create trigger employee_master_upper_name before insert or update of employee_name on public.employee_master
  for each row execute function public.cms_upper_name();
create trigger eppd_employees_upper_name before insert or update of full_name on public.eppd_employees
  for each row execute function public.cms_upper_name();

-- ---------------------------------------------------------------- part B: main company by period (after 011)
-- split a record at a month: the old one ends the day before and keeps its main mark; the copy (same salary,
-- allowances and statutory switches) starts that month with p_main. Returns the record that covers p_from.
create or replace function private.cms_pay_split(p_assignment bigint, p_from date, p_main boolean)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.eppd_assignments; v_new bigint;
begin
  select * into a from public.eppd_assignments where id = p_assignment for update;
  if a.start_date is null or a.start_date >= p_from then
    if a.is_primary is distinct from p_main then update public.eppd_assignments set is_primary = p_main where id = a.id; end if;
    return a.id;
  end if;
  update public.eppd_assignments set end_date = p_from - 1 where id = a.id;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
  values (a.employment_id, a.company_id, p_main, p_from, a.end_date, a.epf_ee, a.epf_er, a.socso_ee, a.socso_er, a.eis_ee, a.eis_er, a.socso_nei_opt_out)
  returning id into v_new;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
  select v_new, effective_from, amount, pay_basis, reason, note from public.eppd_salary_history where assignment_id = a.id;
  insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
  select v_new, payment_type_id, amount, greatest(coalesce(start_date, p_from), p_from), end_date, note
    from public.eppd_allowances where assignment_id = a.id and (end_date is null or end_date >= p_from);
  update public.eppd_allowances set end_date = p_from - 1
   where assignment_id = a.id and (end_date is null or end_date >= p_from) and (start_date is null or start_date < p_from);
  return v_new;
end $$;
revoke all on function private.cms_pay_split(bigint, date, boolean) from public, anon, authenticated;

-- Transfer: the old company keeps its record and main mark for the months before; the new one takes over from p_from
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
  if v_split then v_new := private.cms_pay_split(a.id, v_from, a.is_primary); else v_new := a.id; end if;
  update public.eppd_assignments set company_id = v_to where id = v_new;
  perform private.cms_log('pay.transfer', 'eppd_assignments', v_new::text, g.company,
    format('%s: paid by %s from %s (was %s)', g.name, v_new_code, to_char(v_from, 'Mon YYYY'), v_old),
    jsonb_build_object('person', g.person_id, 'from_assignment', a.id, 'to_assignment', v_new, 'from_company', v_old, 'to_company', v_new_code,
                       'from_month', v_from, 'split', v_split, 'note', nullif(p_note, '')));
  return v_new;
end $$;

-- End one company of a joint payment after a month. It keeps its main mark for its own months; if it was the main
-- company, the remaining company becomes main from the next month.
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
    raise exception '% is the main company. Set another main company from the next month first, then end this one.', v_code;
  end if;
  if a.is_primary then
    v_fin := private.cms_pay_finalised(v_other, v_end + 1);
    if v_fin is not null then raise exception 'The other company already has finalised months after that month: %.', v_fin; end if;
  end if;
  update public.eppd_assignments set end_date = v_end where id = a.id;
  update public.eppd_allowances set end_date = v_end where assignment_id = a.id and (end_date is null or end_date > v_end) and (start_date is null or start_date <= v_end);
  if a.is_primary then
    perform private.cms_pay_split(v_other, v_end + 1, true);
    select c.code into v_main_to from public.eppd_assignments x join public.eppd_companies c on c.id = x.company_id where x.id = v_other;
  end if;
  perform private.cms_log('pay.end_company', 'eppd_assignments', a.id::text, g.company,
    format('%s: %s stops paying after %s%s', g.name, v_code, to_char(v_end, 'Mon YYYY'),
           coalesce(', main company from ' || to_char(v_end + 1, 'Mon YYYY') || ': ' || v_main_to, '')),
    jsonb_build_object('person', g.person_id, 'assignment', a.id, 'company', v_code, 'end_date', v_end, 'was_end_date', a.end_date,
                       'main_moved_to', v_main_to, 'note', nullif(p_note, '')));
end $$;

-- Main company from a month: earlier months keep the old main company
create or replace function public.cms_pay_set_main(p_assignment bigint, p_from date, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; p record; v_from date := date_trunc('month', p_from)::date; v_code text; v_was text; v_fin text;
begin
  if p_from is null then raise exception 'Choose the first payroll month with the new main company.'; end if;
  select * into g from private.cms_pay_guard(p_assignment, 'E');
  select * into a from public.eppd_assignments where id = p_assignment;
  if a.end_date is not null and a.end_date < v_from then raise exception 'This company no longer pays % in that month.', g.name; end if;
  select string_agg(c.code, ', '), string_agg(private.cms_pay_finalised(x.id, v_from), ', ')
    into v_was, v_fin
    from public.eppd_assignments x join public.eppd_companies c on c.id = x.company_id
   where x.employment_id = a.employment_id and x.id <> a.id and x.is_primary and (x.end_date is null or x.end_date >= v_from);
  v_fin := coalesce(nullif(v_fin, ''), private.cms_pay_finalised(a.id, v_from));
  if v_fin is not null then raise exception 'Months from then are already finalised: %. Choose a later month, or ask an admin to reopen them.', v_fin; end if;
  if a.is_primary and v_was is null then raise exception '% is already the main company from that month.', g.name; end if;
  for p in select x.id from public.eppd_assignments x
            where x.employment_id = a.employment_id and x.id <> a.id and x.is_primary and (x.end_date is null or x.end_date >= v_from) loop
    perform private.cms_pay_split(p.id, v_from, false);
  end loop;
  if not a.is_primary then perform private.cms_pay_split(a.id, v_from, true); end if;
  select code into v_code from public.eppd_companies where id = a.company_id;
  perform private.cms_log('pay.set_main', 'eppd_assignments', a.id::text, g.company,
    format('%s: main paying company %s from %s (was %s)', g.name, v_code, to_char(v_from, 'Mon YYYY'), coalesce(v_was, 'none')),
    jsonb_build_object('person', g.person_id, 'assignment', a.id, 'company', v_code, 'from_month', v_from, 'was', v_was, 'note', nullif(p_note, '')));
end $$;
grant execute on function public.cms_pay_set_main(bigint, date, text) to authenticated;

-- Correct: friendly message when two main records would overlap
create or replace function public.cms_pay_correct(p_assignment bigint, p_company text, p_start date, p_end date,
  p_statutory jsonb default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; a public.eppd_assignments; v_to bigint := private.cms_pay_company_id(p_company); v_code text; v_was text;
        v_start date := p_start; v_end date := p_end;
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
  begin
    update public.eppd_assignments set company_id = v_to, start_date = v_start, end_date = v_end,
      epf_ee = coalesce((s->>'epf_ee')::boolean, epf_ee), epf_er = coalesce((s->>'epf_er')::boolean, epf_er),
      socso_ee = coalesce((s->>'socso_ee')::boolean, socso_ee), socso_er = coalesce((s->>'socso_er')::boolean, socso_er),
      eis_ee = coalesce((s->>'eis_ee')::boolean, eis_ee), eis_er = coalesce((s->>'eis_er')::boolean, eis_er),
      socso_nei_opt_out = coalesce((s->>'socso_nei_opt_out')::boolean, socso_nei_opt_out)
    where id = a.id;
  exception when exclusion_violation then
    raise exception 'With these dates two records would both be the main company in the same months. Shorten one of them, or use Set main from a month.';
  end;
  select to_jsonb(x) - 'created_at' - 'updated_at' into v_after from public.eppd_assignments x where x.id = a.id;
  perform private.cms_log('pay.correct', 'eppd_assignments', a.id::text, g.company,
    format('%s: corrected %s record%s', g.name, v_was, case when v_was <> v_code then ' to ' || v_code else '' end),
    jsonb_build_object('person', g.person_id, 'before', v_before, 'after', v_after, 'reason', btrim(p_reason), 'finalised_months', v_fin));
  return jsonb_build_object('finalised_months', v_fin);
end $$;

-- MyPayroll's employee list: the main company is the current one (ended records may also be marked main)
create or replace view public.eppd_employee_list as
 SELECT e.id, e.emp_id, e.emp_serial, e.full_name, e.chinese_name, e.gender, e.nationality,
    cur.id AS employment_id, cur.join_date, cur.confirmation_status, cur.confirmed_date, cur.job_status,
    cur.resignation_letter_date, cur.resigned_date,
    d.id AS department_id, d.code AS department_code, d.name AS department_name,
    jt.id AS job_title_id, jt.name AS job_title,
    pc.id AS company_id, pc.code AS company_code, COALESCE(pc.short_name, pc.name) AS company_name,
    ( SELECT count(*) FROM eppd_assignments a2 WHERE a2.employment_id = cur.id) AS company_count,
    ( SELECT count(*) FROM eppd_employments m2 WHERE m2.employee_id = e.id) AS employment_count,
    e.updated_at, cur.notice_until
   FROM eppd_employees e
     LEFT JOIN LATERAL ( SELECT m.* FROM eppd_employments m WHERE m.employee_id = e.id
          ORDER BY m.join_date DESC NULLS LAST, m.id DESC LIMIT 1) cur ON true
     LEFT JOIN eppd_departments d ON d.id = cur.department_id
     LEFT JOIN eppd_job_titles jt ON jt.id = cur.job_title_id
     LEFT JOIN LATERAL ( SELECT c.* FROM eppd_assignments a JOIN eppd_companies c ON c.id = a.company_id
          WHERE a.employment_id = cur.id
          ORDER BY (a.end_date IS NULL OR a.end_date >= CURRENT_DATE) DESC, a.is_primary DESC, a.start_date DESC NULLS LAST, a.id DESC
         LIMIT 1) pc ON true;

-- People list: previous ID, who pays now, confirmation, notice and last working day (from the latest payroll employment)
create or replace function public.cms_people_list()
returns table (id uuid, employee_id text, previous_id text, name text, company_code text, paying_company_code text, paid_by text[],
               manual_paying_code text, in_payroll boolean, unit_code text, department text, job_title text, level text, status text,
               start_date date, last_day date, email text, login_email text, source_type text,
               confirmation text, confirmed_date date, letter_date date, notice_until date, serving_notice boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
        v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform private.cms_require('people', 'V');
  return query
  select em.id, em.employee_id::text, em.previous_employee_id::text, em.employee_name::text, private.cms_canon(em.company_code),
         coalesce(pay.codes[1], pp.paying_company_code), pay.codes, pp.paying_company_code, le.id is not null,
         coalesce(pp.unit_code, (select un.code from public.cms_units un where un.code = upper(btrim(em.department)) and un.is_active)),
         em.department::text, em.approved_job_title::text, split_part(coalesce(em.job_title_level, ''), '|', 1),
         em.employment_status::text, em.start_date, coalesce(le.resigned_date, em.actual_last_working_date), em.email::text, u.email::text, em.source_type::text,
         le.confirmation_status, le.confirmed_date, le.resignation_letter_date, le.notice_until,
         le.resignation_letter_date is not null and coalesce(le.resigned_date, le.notice_until, v_today) >= v_today
  from public.employee_master em
  left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
  left join public.cms_user_links l on l.employee_master_id = em.id
  left join auth.users u on u.id = l.user_id
  left join lateral (select e.* from public.eppd_employees ee join public.eppd_employments e on e.employee_id = ee.id
                     where ee.employee_master_id = em.id order by e.join_date desc nulls last, e.id desc limit 1) le on true
  left join lateral (
    select coalesce(
      (select array_agg(c.code order by a.is_primary desc, a.start_date nulls first, a.id)
         from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
        where a.employment_id = le.id and (a.end_date is null or a.end_date >= v_month)
          and (a.start_date is null or a.start_date < (v_month + interval '1 month')::date)),
      (select array[c.code] from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
        where a.employment_id = le.id order by a.end_date desc nulls first, a.start_date desc nulls last, a.id desc limit 1)) codes
  ) pay on le.id is not null
  where public.cms_can('people', 'V', em.company_code)
  order by em.employee_name;
end $$;
grant execute on function public.cms_people_list() to authenticated;

-- MyPayroll's own transfer keeps the old company's main mark for its months too
create or replace function public.eppd_move_paying_company(p_assignment bigint, p_company bigint, p_from date)
returns bigint language plpgsql security definer set search_path = public as $$
declare a public.eppd_assignments; v_from date := date_trunc('month', p_from)::date; v_new bigint; v_paid boolean; v_fin text;
begin
  if not public.eppd_has_role(array['admin','hr']) then raise exception 'Only admin or HR can change paying companies.'; end if;
  select * into a from public.eppd_assignments where id = p_assignment for update;
  if not found then raise exception 'Paying company record not found.'; end if;
  if not exists (select 1 from public.eppd_companies where id = p_company and is_active) then raise exception 'Choose an active paying company.'; end if;
  if a.company_id = p_company then return a.id; end if;
  if a.end_date is not null and a.end_date < v_from then raise exception 'This record already ended on %.', a.end_date; end if;
  select string_agg(to_char(r.period, 'Mon YYYY'), ', ' order by r.period) into v_fin
    from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
   where l.assignment_id = a.id and r.period >= v_from and r.status = 'finalised';
  if v_fin is not null then raise exception 'Already finalised under the current company: %. Choose a later month, or ask an admin to reopen it.', v_fin; end if;
  select exists (select 1 from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                  where l.assignment_id = a.id and r.period < v_from) into v_paid;
  if not v_paid and (a.start_date is null or a.start_date >= v_from or not exists (select 1 from public.eppd_pay_lines where assignment_id = a.id)) then
    update public.eppd_assignments set company_id = p_company where id = a.id;
    return a.id;
  end if;
  -- split: old record ends, new one starts
  -- the old record keeps its main mark for its own months (011)
  update public.eppd_assignments set end_date = v_from - 1 where id = a.id;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
  values (a.employment_id, p_company, a.is_primary, v_from, a.end_date, a.epf_ee, a.epf_er, a.socso_ee, a.socso_er, a.eis_ee, a.eis_er, a.socso_nei_opt_out)
  returning id into v_new;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
  select v_new, effective_from, amount, pay_basis, reason, note from public.eppd_salary_history where assignment_id = a.id;
  insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
  select v_new, payment_type_id, amount, greatest(coalesce(start_date, v_from), v_from), end_date, note
    from public.eppd_allowances where assignment_id = a.id and (end_date is null or end_date >= v_from);
  return v_new;
end $$;
