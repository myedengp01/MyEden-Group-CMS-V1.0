-- MyEden Group CMS V1.0 · PRI-001 Salary increments and review reminders (v2026.10.19)
-- Last increment = the last salary change on the person's main-company records (payroll salary history).
-- Next review = the later of last increment / confirmation / join date + the person's review interval,
-- or a date HR set by hand. Intervals (6, 9, 12 months to start) are a list Admin can change and add to.
-- Additive only.

-- ---------------------------------------------------------------- part 1: tables, permissions
create table if not exists public.cms_review_intervals (
  code        text primary key,
  label       text not null,
  months      integer not null check (months between 1 and 60),
  default_for text[] not null default '{}',     -- confirmation statuses that get this interval by default
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  updated_by  uuid, updated_at timestamptz not null default now()
);
alter table public.cms_review_intervals enable row level security;
insert into public.cms_review_intervals (code, label, months, default_for, sort_order) values
  ('M6', '6 months', 6, '{UP}', 1), ('M9', '9 months', 9, '{}', 2), ('M12', '12 months', 12, '{C,CT,PT,INT}', 3)
on conflict (code) do nothing;

create table if not exists public.cms_employee_review (
  employment_id   bigint primary key,   -- eppd_employments.id (no FK, so payroll can still remove an employment)
  interval_code   text references public.cms_review_intervals(code),
  next_review     date,            -- set by hand; cleared when an increment is recorded
  note            text,
  updated_by      uuid, updated_at timestamptz not null default now()
);
alter table public.cms_employee_review enable row level security;

insert into public.cms_modules (code, label, grp, phase, sort_order)
values ('payroll.increments', 'Increments & Reviews', 'Payroll', 2, 53) on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'payroll.increments', 'VCEADX'), ('admin', 'payroll.increments', 'VCEADX'), ('hr', 'payroll.increments', 'VCE'),
  ('payroll', 'payroll.increments', 'V'), ('finance', 'payroll.increments', 'V'), ('payroll_viewer', 'payroll.increments', 'V'),
  ('director', 'payroll.increments', 'V')
on conflict do nothing;

-- ---------------------------------------------------------------- part 2: reads
-- salary changes on an employment's main-company records (a transfer copies the history, so dates are de-duplicated)
create or replace function private.cms_salary_steps(p_employment bigint)
returns table (effective_from date, amount numeric, pay_basis text, prev numeric, company text, reason text, note text, assignment_id bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  with s as (
    select distinct on (sh.effective_from) sh.effective_from, sh.amount, sh.pay_basis, c.code company, sh.reason, sh.note, a.id aid
    from public.eppd_salary_history sh
    join public.eppd_assignments a on a.id = sh.assignment_id
    join public.eppd_companies c on c.id = a.company_id
    where a.employment_id = p_employment
      and (a.is_primary or not exists (select 1 from public.eppd_assignments p where p.employment_id = p_employment and p.is_primary))
    order by sh.effective_from, (sh.effective_from between coalesce(a.start_date, '-infinity') and coalesce(a.end_date, 'infinity')) desc, a.id desc)
  select effective_from, amount, pay_basis, lag(amount) over (order by effective_from), company, reason, note, aid from s;
$$;
revoke all on function private.cms_salary_steps(bigint) from public, anon, authenticated;

create or replace function public.cms_increments(p_person uuid default null)
returns table (person_id uuid, employee_id text, name text, employer text, paid_by text, person_status text, confirmation text,
               join_date date, confirmed_date date, resigned_date date, employment_id bigint,
               pay_basis text, current_salary numeric, last_change_date date, last_change numeric, last_change_from numeric, changes integer,
               interval_code text, interval_label text, interval_months integer, interval_is_default boolean,
               base_date date, next_review date, next_review_set boolean, review_note text, state text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
        v_month date := date_trunc('month', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
begin
  perform private.cms_require('payroll.increments', 'V');
  return query
  with p as (
    select em.id pid, coalesce(em.employee_id, ee.emp_id)::text eid, coalesce(em.employee_name, ee.full_name)::text nm,
           private.cms_canon(em.company_code) employer, em.employment_status::text st, e.*
    from public.eppd_employees ee
    join lateral (select x.* from public.eppd_employments x where x.employee_id = ee.id order by x.join_date desc nulls last, x.id desc limit 1) e on true
    left join public.employee_master em on em.id = ee.employee_master_id
    where (p_person is null and (e.resigned_date is null or e.resigned_date >= v_today)
           and coalesce(em.employment_status, 'active') <> 'former')
       or ee.employee_master_id = p_person),
  calc as (
    select p.*, pay.payer, cur.amount cur, cur.pay_basis basis, lc.effective_from lcd, lc.amount - lc.prev lca, lc.prev lcp, nchg.n,
           r.interval_code rcode, r.next_review rnext, r.note rnote
    from p
    left join lateral (select c.code payer from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
                        where a.employment_id = p.id and a.is_primary and (a.end_date is null or a.end_date >= v_month)
                        order by a.start_date desc nulls last limit 1) pay on true
    left join lateral (select s.amount, s.pay_basis from private.cms_salary_steps(p.id) s where s.effective_from <= v_today
                        order by s.effective_from desc limit 1) cur on true
    left join lateral (select s.effective_from, s.amount, s.prev from private.cms_salary_steps(p.id) s
                        where s.prev is not null and s.amount <> s.prev order by s.effective_from desc limit 1) lc on true
    left join lateral (select count(*)::int n from private.cms_salary_steps(p.id) s where s.prev is not null and s.amount <> s.prev) nchg on true
    left join public.cms_employee_review r on r.employment_id = p.id),
  iv as (
    select calc.*,
      coalesce((select i.code from public.cms_review_intervals i where i.code = calc.rcode),
               (select i.code from public.cms_review_intervals i where i.is_active and calc.confirmation_status = any(i.default_for) order by i.sort_order limit 1),
               (select i.code from public.cms_review_intervals i where i.is_active order by i.months desc limit 1)) icode,
      greatest(calc.lcd, calc.confirmed_date, calc.join_date) base
    from calc),
  fin as (
    select iv.*, i.code, i.label, i.months, coalesce(iv.rnext, (iv.base + make_interval(months => i.months))::date) nxt
    from iv left join public.cms_review_intervals i on i.code = iv.icode)
  select fin.pid, fin.eid, fin.nm, fin.employer, fin.payer, fin.st, fin.confirmation_status, fin.join_date, fin.confirmed_date, fin.resigned_date, fin.id,
         fin.basis, fin.cur, fin.lcd, fin.lca, fin.lcp, coalesce(fin.n, 0),
         fin.code, fin.label, fin.months, fin.rcode is null, fin.base, fin.nxt, fin.rnext is not null, fin.rnote,
         case when fin.nxt is null then 'unknown' when fin.nxt < v_month then 'overdue'
              when fin.nxt < (v_month + interval '1 month')::date then 'due'
              when fin.nxt < (v_month + interval '3 months')::date then 'soon' else 'later' end
  from fin
  where public.cms_can('payroll.increments', 'V', fin.employer)
  order by fin.nxt nulls last, fin.nm;
end $$;

create or replace function public.cms_salary_changes(p_employment bigint)
returns table (effective_from date, amount numeric, pay_basis text, change numeric, company text, reason text, note text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_co text;
begin
  select private.cms_canon(coalesce(em.company_code, 'MEG')) into v_co from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id
    left join public.employee_master em on em.id = ee.employee_master_id where e.id = p_employment;
  perform private.cms_require('payroll.increments', 'V', v_co);
  return query select s.effective_from, s.amount, s.pay_basis, s.amount - s.prev, s.company, s.reason, s.note
    from private.cms_salary_steps(p_employment) s order by s.effective_from desc;
end $$;

create or replace function public.cms_review_intervals()
returns setof public.cms_review_intervals language sql stable security definer set search_path = public, pg_temp as $$
  select * from public.cms_review_intervals where public.cms_can('payroll.increments', 'V') order by sort_order, months;
$$;

-- ---------------------------------------------------------------- part 3: changes
-- HR/Admin: a person's review interval and/or a hand-set next review date (null interval = back to the default)
create or replace function public.cms_set_review(p_employment bigint, p_interval text, p_next date, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_co text; v_name text; v_before jsonb;
begin
  select private.cms_canon(em.company_code), coalesce(em.employee_name, ee.full_name) into v_co, v_name
    from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id
    left join public.employee_master em on em.id = ee.employee_master_id where e.id = p_employment;
  if v_name is null then raise exception 'Employment not found.'; end if;
  perform private.cms_require('payroll.increments', 'E', v_co);
  if p_interval is not null and not exists (select 1 from public.cms_review_intervals where code = p_interval and is_active) then
    raise exception 'Choose an active review interval.';
  end if;
  select to_jsonb(r) into v_before from public.cms_employee_review r where employment_id = p_employment;
  insert into public.cms_employee_review (employment_id, interval_code, next_review, note, updated_by, updated_at)
  values (p_employment, p_interval, p_next, nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), now())
  on conflict (employment_id) do update set interval_code = excluded.interval_code, next_review = excluded.next_review,
    note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  perform private.cms_log('pay.review', 'cms_employee_review', p_employment::text, v_co,
    format('%s: review every %s%s', v_name, coalesce((select label from public.cms_review_intervals where code = p_interval), 'default interval'),
           coalesce(', next review ' || to_char(p_next, 'DD Mon YYYY'), '')),
    jsonb_build_object('before', v_before, 'interval', p_interval, 'next_review', p_next, 'note', p_note));
end $$;

-- HR/Admin: record an increment (new salary from a payroll month) on the main company
create or replace function public.cms_record_increment(p_employment bigint, p_from date, p_salary numeric, p_reason text default 'Increment', p_note text default null)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare v_co text; v_name text; v_from date := date_trunc('month', p_from)::date; v_a bigint; v_code text; v_prev record; v_fin text; v_id bigint;
begin
  if p_from is null then raise exception 'Choose the first payroll month with the new salary.'; end if;
  if p_salary is null or p_salary <= 0 then raise exception 'Enter the new salary.'; end if;
  select private.cms_canon(em.company_code), coalesce(em.employee_name, ee.full_name) into v_co, v_name
    from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id
    left join public.employee_master em on em.id = ee.employee_master_id where e.id = p_employment;
  if v_name is null then raise exception 'Employment not found.'; end if;
  perform private.cms_require('payroll.increments', 'C', v_co);
  select a.id, c.code into v_a, v_code from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
   where a.employment_id = p_employment and a.is_primary
     and (a.start_date is null or a.start_date < (v_from + interval '1 month')::date) and (a.end_date is null or a.end_date >= v_from)
   order by a.start_date desc nulls last limit 1;
  if v_a is null then raise exception '% has no main paying company in that month.', v_name; end if;
  v_fin := private.cms_pay_finalised(v_a, v_from);
  if v_fin is not null then raise exception 'Already finalised from that month: %. Choose a later month, or ask an admin to reopen it.', v_fin; end if;
  if exists (select 1 from public.eppd_salary_history where assignment_id = v_a and effective_from = v_from) then
    raise exception 'A salary change from % is already recorded for %. Change it in payroll instead.', to_char(v_from, 'Mon YYYY'), v_name;
  end if;
  select amount, pay_basis into v_prev from public.eppd_salary_history where assignment_id = v_a and effective_from < v_from
   order by effective_from desc limit 1;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
  values (v_a, v_from, round(p_salary, 2), coalesce(v_prev.pay_basis, 'monthly'), coalesce(nullif(btrim(p_reason), ''), 'Increment'), nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  update public.cms_employee_review set next_review = null, updated_by = auth.uid(), updated_at = now() where employment_id = p_employment and next_review is not null;
  perform private.cms_log('pay.increment', 'eppd_salary_history', v_id::text, v_co,
    format('%s: salary %s from %s (%s)', v_name, to_char(round(p_salary, 2), 'FM999,990.00'), to_char(v_from, 'Mon YYYY'), v_code),
    jsonb_build_object('employment', p_employment, 'assignment', v_a, 'from_month', v_from, 'old', v_prev.amount, 'new', round(p_salary, 2),
                       'reason', p_reason, 'note', p_note));
  return v_id;
end $$;

-- Admin: add or change a review interval
create or replace function public.cms_review_interval_save(p_code text, p_label text, p_months integer, p_default_for text[], p_active boolean default true, p_sort integer default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := upper(nullif(btrim(coalesce(p_code, '')), '')); v_before jsonb;
begin
  perform private.cms_require('payroll.increments', 'A');
  if p_months is null or p_months < 1 or p_months > 60 then raise exception 'Months must be between 1 and 60.'; end if;
  v_code := coalesce(v_code, 'M' || p_months);
  select to_jsonb(i) into v_before from public.cms_review_intervals i where code = v_code;
  insert into public.cms_review_intervals (code, label, months, default_for, is_active, sort_order, updated_by, updated_at)
  values (v_code, coalesce(nullif(btrim(p_label), ''), p_months || ' months'), p_months, coalesce(p_default_for, '{}'), coalesce(p_active, true),
          coalesce(p_sort, (select coalesce(max(sort_order), 0) + 1 from public.cms_review_intervals)), auth.uid(), now())
  on conflict (code) do update set label = excluded.label, months = excluded.months, default_for = excluded.default_for,
    is_active = excluded.is_active, sort_order = coalesce(p_sort, public.cms_review_intervals.sort_order), updated_by = excluded.updated_by, updated_at = now();
  -- a status can be the default of one interval only
  update public.cms_review_intervals set default_for = array(select unnest(default_for) except select unnest(coalesce(p_default_for, '{}')))
   where code <> v_code and default_for && coalesce(p_default_for, '{}');
  perform private.cms_log('pay.review_interval', 'cms_review_intervals', v_code, null,
    format('Review interval %s: %s months%s', v_code, p_months, case when coalesce(p_active, true) then '' else ' (inactive)' end),
    jsonb_build_object('before', v_before, 'label', p_label, 'months', p_months, 'default_for', p_default_for, 'active', p_active));
  return v_code;
end $$;

grant execute on function public.cms_increments(uuid), public.cms_salary_changes(bigint), public.cms_review_intervals(),
  public.cms_set_review(bigint, text, date, text), public.cms_record_increment(bigint, date, numeric, text, text),
  public.cms_review_interval_save(text, text, integer, text[], boolean, integer) to authenticated;
