-- MyEden Group CMS V1.0 · v2026.11.10 · Holiday calendars, company closure days and the replacement-leave check (CLC 10 Nov 2026)
-- 1. Calendars: Staff (public holidays stay in the payroll list, eppd_holidays, used for leave counting and PH overtime; the staff calendar
--    adds events and company closures), Students – E10 (Eden Childcare Center), Tadika Genius Eden (E3) and Tadika Happy Dino (E3+), for
--    reference. Entry types: holiday · term break (only childcare-service students attend) · event · company closure.
-- 2. Dashboard "Upcoming": everything in the next N days (setting calendar.reminder_days, default 7, changed by Admin / Director).
--    Staff see the staff calendar and their own department's student calendar; people with Leave access see all calendars.
-- 3. Company closure days (e.g. 10–14 Feb 2027, students still on holiday): the working days are split into free days (company paid
--    leave, leave type CCL, nothing deducted) and days taken from annual leave. Applying creates the leave records for everyone in scope;
--    per-person exceptions (on duty, excluded, a different split). If the AL balance cannot cover the AL days, the shortfall is unpaid
--    leave by default; Admin / Director may make it free or borrowed from next year's AL. Cancelling a closure cancels its records.
--    PRI-021: a handbook / LOEC clause on compulsory annual leave during company closures is still to be written.
-- 4. Replacement-leave check: per holiday on a rest / off day, HR marks each person granted (adds the replacement leave), already
--    handled or not entitled.
-- 5. Data: the 2026 staff holiday list (as published; the rest-day holidays 22 Mar and 31 May were given as replacement leave),
--    the 2026 student / tadika calendars, and the reminder setting.
-- Additive: new tables and functions; no data is removed.

insert into public.cms_settings (key, value) values ('calendar', '{"reminder_days": 7}'::jsonb) on conflict (key) do nothing;

create or replace function private.cms_is_admin_or_director() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_is_super_admin() or exists (select 1 from public.cms_user_roles where user_id = auth.uid() and is_active and role_code in ('admin', 'director'));
$$;
revoke all on function private.cms_is_admin_or_director() from public, anon, authenticated;

-- ---------------------------------------------------------------- tables
create table if not exists public.cms_closures (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  date_from date not null, date_to date not null,
  scope jsonb not null default '{}'::jsonb,               -- {"companies": [company names], "departments": [codes]}; empty = all staff
  free_dates date[] not null default '{}', al_dates date[] not null default '{}',
  status text not null default 'draft',
  note text,
  applied_at timestamptz, applied_by uuid, applied_summary jsonb,
  cancelled_at timestamptz, cancelled_by uuid, cancel_reason text,
  created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid,
  constraint cms_closures_dates check (date_to >= date_from),
  constraint cms_closures_status check (status in ('draft', 'applied', 'cancelled'))
);
create table if not exists public.cms_closure_people (
  closure_id uuid not null references public.cms_closures(id),
  employee_id bigint not null references public.eppd_employees(id),
  name text,
  mode text not null default 'split',                     -- split · custom · duty · excluded
  free_dates date[] not null default '{}', al_dates date[] not null default '{}',
  al_balance numeric, al_days numeric not null default 0, short_days numeric not null default 0,
  shortfall text not null default 'unpaid',               -- unpaid · borrow · free
  record_ids bigint[] not null default '{}', adjustment_ids bigint[] not null default '{}',
  note text,
  primary key (closure_id, employee_id),
  constraint cms_closure_people_mode check (mode in ('split', 'custom', 'duty', 'excluded')),
  constraint cms_closure_people_short check (shortfall in ('unpaid', 'borrow', 'free'))
);
create table if not exists public.cms_calendar_entries (
  id uuid primary key default gen_random_uuid(),
  calendar text not null,
  kind text not null,
  date_from date not null, date_to date not null,
  title text not null, note text,
  is_active boolean not null default true,
  closure_id uuid references public.cms_closures(id),
  created_at timestamptz not null default now(), created_by uuid default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid,
  constraint cms_calendar_entries_cal check (calendar in ('staff', 'e10', 'e3', 'e3p')),
  constraint cms_calendar_entries_kind check (kind in ('holiday', 'term_break', 'event', 'closure')),
  constraint cms_calendar_entries_dates check (date_to >= date_from)
);
create index if not exists cms_calendar_entries_dates_idx on public.cms_calendar_entries (date_from, date_to);
create table if not exists public.cms_rl_checks (
  holiday_date date not null,
  employee_id bigint not null references public.eppd_employees(id),
  holiday_name text,
  decision text not null,                                 -- granted · handled · not_entitled
  days numeric, effective_date date, adjustment_id bigint,
  note text,
  decided_by uuid default auth.uid(), decided_by_name text, decided_at timestamptz not null default now(),
  primary key (holiday_date, employee_id),
  constraint cms_rl_checks_decision check (decision in ('granted', 'handled', 'not_entitled'))
);
alter table public.cms_closures enable row level security;
alter table public.cms_closure_people enable row level security;
alter table public.cms_calendar_entries enable row level security;
alter table public.cms_rl_checks enable row level security;
revoke all on public.cms_closures, public.cms_closure_people, public.cms_calendar_entries, public.cms_rl_checks from anon;
grant select on public.cms_closures, public.cms_closure_people, public.cms_calendar_entries, public.cms_rl_checks to authenticated;
do $p$ begin
  if not exists (select 1 from pg_policies where tablename = 'cms_closures' and policyname = 'CMS leave read') then
    create policy "CMS leave read" on public.cms_closures for select to authenticated using (public.cms_can('leave', 'V') or public.cms_can('payroll', 'V')); end if;
  if not exists (select 1 from pg_policies where tablename = 'cms_closure_people' and policyname = 'CMS leave read') then
    create policy "CMS leave read" on public.cms_closure_people for select to authenticated using (public.cms_can('leave', 'V') or public.cms_can('payroll', 'V')); end if;
  if not exists (select 1 from pg_policies where tablename = 'cms_rl_checks' and policyname = 'CMS leave read') then
    create policy "CMS leave read" on public.cms_rl_checks for select to authenticated using (public.cms_can('leave', 'V') or public.cms_can('payroll', 'V')); end if;
  if not exists (select 1 from pg_policies where tablename = 'cms_calendar_entries' and policyname = 'Signed-in read') then
    create policy "Signed-in read" on public.cms_calendar_entries for select to authenticated using (auth.uid() is not null); end if;
end $p$;
-- the company holiday list is read by everyone signed in (dashboard reminders, calendars)
do $p$ begin
  if not exists (select 1 from pg_policies where tablename = 'eppd_holidays' and policyname = 'CMS signed-in read') then
    create policy "CMS signed-in read" on public.eppd_holidays for select to authenticated using (auth.uid() is not null); end if;
end $p$;

-- ---------------------------------------------------------------- calendars
create or replace function public.cms_calendar(p_year int)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  return jsonb_build_object(
    'year', p_year,
    'holidays', coalesce((select jsonb_agg(jsonb_build_object('date', h.holiday_date, 'name', h.name, 'scope', h.scope) order by h.holiday_date)
                 from public.eppd_holidays h where h.is_active and extract(year from h.holiday_date) = p_year), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.date_from, e.title) from public.cms_calendar_entries e
                 where e.is_active and e.date_from <= make_date(p_year, 12, 31) and e.date_to >= make_date(p_year, 1, 1)), '[]'::jsonb),
    'reminder_days', coalesce((select (value->>'reminder_days')::int from public.cms_settings where key = 'calendar'), 7),
    'can_edit', public.cms_can('leave', 'E'), 'can_settings', private.cms_is_admin_or_director());
end $f$;
revoke all on function public.cms_calendar(int) from public, anon; grant execute on function public.cms_calendar(int) to authenticated;

create or replace function public.cms_calendar_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare r public.cms_calendar_entries; v_id uuid := nullif(p->>'id', '')::uuid; v_from date := (p->>'date_from')::date; v_to date := coalesce(nullif(p->>'date_to', '')::date, (p->>'date_from')::date);
begin
  perform private.cms_require('leave', 'E', null);
  if v_id is not null then select * into r from public.cms_calendar_entries where id = v_id; if r.id is null then raise exception 'Entry not found.'; end if;
    if r.kind = 'closure' then raise exception 'Company closures are changed on the Company closures page.'; end if; end if;
  if coalesce(p->>'active', 'true') = 'false' then
    update public.cms_calendar_entries set is_active = false, updated_at = now(), updated_by = auth.uid() where id = v_id;
    perform private.cms_log('calendar.remove', 'cms_calendar_entries', v_id::text, null, 'Calendar entry removed: ' || r.title || ' (' || r.calendar || ', ' || r.date_from || ')', to_jsonb(r));
    return jsonb_build_object('id', v_id, 'removed', true);
  end if;
  if (p->>'calendar') not in ('staff', 'e10', 'e3', 'e3p') then raise exception 'Choose a calendar.'; end if;
  if (p->>'kind') not in ('holiday', 'term_break', 'event') then raise exception 'Choose holiday, term break or event.'; end if;
  if p->>'calendar' = 'staff' and p->>'kind' <> 'event' then raise exception 'Staff public holidays are kept in the payroll holiday list (Public holidays page), which leave counting and overtime use.'; end if;
  if v_from is null or nullif(btrim(p->>'title'), '') is null then raise exception 'Give the date and a title.'; end if;
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_id is null then
    insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title, note)
    values (p->>'calendar', p->>'kind', v_from, v_to, btrim(p->>'title'), nullif(btrim(p->>'note'), '')) returning * into r;
  else
    update public.cms_calendar_entries set calendar = p->>'calendar', kind = p->>'kind', date_from = v_from, date_to = v_to, title = btrim(p->>'title'),
           note = nullif(btrim(p->>'note'), ''), updated_at = now(), updated_by = auth.uid() where id = v_id returning * into r;
  end if;
  perform private.cms_log('calendar.save', 'cms_calendar_entries', r.id::text, null, 'Calendar entry: ' || r.title || ' (' || r.calendar || ', ' || r.date_from || case when r.date_to > r.date_from then ' – ' || r.date_to else '' end || ')', to_jsonb(r));
  return to_jsonb(r);
end $f$;
revoke all on function public.cms_calendar_save(jsonb) from public, anon; grant execute on function public.cms_calendar_save(jsonb) to authenticated;

-- copy the year's payroll holiday list into a student / tadika calendar (consecutive days with the same name become one entry);
-- holidays already on that calendar (same start date and title) are skipped
create or replace function public.cms_calendar_copy_holidays(p_calendar text, p_year int)
returns int language plpgsql security definer set search_path = public, pg_temp as $f$
declare n int;
begin
  perform private.cms_require('leave', 'E', null);
  if p_calendar not in ('e10', 'e3', 'e3p') then raise exception 'Choose a student or tadika calendar.'; end if;
  with h as (select holiday_date d, name from public.eppd_holidays where is_active and extract(year from holiday_date) = p_year),
       g as (select name, d, d - (row_number() over (partition by name order by d))::int grp from h),
       r as (select name, min(d) f, max(d) t from g group by name, grp)
  insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title)
  select p_calendar, 'holiday', r.f, r.t, r.name from r
  where not exists (select 1 from public.cms_calendar_entries e where e.calendar = p_calendar and e.is_active and e.date_from = r.f and e.title = r.name);
  get diagnostics n = row_count;
  perform private.cms_log('calendar.copy', 'cms_calendar_entries', p_calendar, null, n || ' staff holiday(s) of ' || p_year || ' copied to calendar ' || p_calendar, jsonb_build_object('calendar', p_calendar, 'year', p_year, 'count', n));
  return n;
end $f$;
revoke all on function public.cms_calendar_copy_holidays(text, int) from public, anon; grant execute on function public.cms_calendar_copy_holidays(text, int) to authenticated;

create or replace function public.cms_calendar_settings_set(p_days int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not private.cms_is_admin_or_director() then raise exception 'Only Admin or Director can change the reminder days.'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then raise exception 'Reminder days: 1 to 90.'; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by) values ('calendar', jsonb_build_object('reminder_days', p_days), now(), auth.uid())
  on conflict (key) do update set value = public.cms_settings.value || jsonb_build_object('reminder_days', p_days), updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('settings.calendar', 'cms_settings', 'calendar', null, 'Upcoming reminders: ' || p_days || ' days ahead', jsonb_build_object('reminder_days', p_days));
  return jsonb_build_object('reminder_days', p_days);
end $f$;
revoke all on function public.cms_calendar_settings_set(int) from public, anon; grant execute on function public.cms_calendar_settings_set(int) to authenticated;

-- dashboard reminders: the next N days (today included)
create or replace function public.cms_upcoming()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare n int := coalesce((select (value->>'reminder_days')::int from public.cms_settings where key = 'calendar'), 7);
        d0 date := (now() at time zone 'Asia/Kuala_Lumpur')::date; d1 date; dept text; cals text[];
begin
  if auth.uid() is null then return null; end if;
  d1 := d0 + n;
  if public.cms_can('leave', 'V') or private.cms_is_admin_or_director() then cals := array['staff', 'e10', 'e3', 'e3p'];
  else
    select upper(btrim(coalesce(nullif(em.department, ''), pp.unit_code))) into dept from public.employee_master em
      left join public.cms_employee_payroll pp on pp.employee_master_id = em.id where em.id = private.cms_me();
    cals := array['staff'] || case when dept in ('E10', 'E11') then array['e10'] when dept = 'E3' then array['e3'] when dept = 'E3+' then array['e3p'] else array[]::text[] end;
  end if;
  return jsonb_build_object('days', n, 'from', d0, 'to', d1, 'items', coalesce((select jsonb_agg(x order by x->>'date_from', x->>'calendar') from (
      select jsonb_build_object('calendar', 'staff', 'kind', 'holiday', 'date_from', min(h.holiday_date), 'date_to', max(h.holiday_date), 'title', h.name) x
        from public.eppd_holidays h where h.is_active and h.holiday_date between d0 and d1 group by h.name
      union all
      select jsonb_build_object('calendar', e.calendar, 'kind', e.kind, 'date_from', e.date_from, 'date_to', e.date_to, 'title', e.title, 'note', e.note)
        from public.cms_calendar_entries e where e.is_active and e.calendar = any(cals) and e.date_from <= d1 and e.date_to >= d0) s), '[]'::jsonb));
end $f$;
revoke all on function public.cms_upcoming() from public, anon; grant execute on function public.cms_upcoming() to authenticated;

-- ---------------------------------------------------------------- company closures
create or replace function public.cms_closure_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare c public.cms_closures; v_id uuid := nullif(p->>'id', '')::uuid; v_from date := (p->>'date_from')::date; v_to date := (p->>'date_to')::date;
        v_free date[] := coalesce((select array_agg(x::date order by x::date) from jsonb_array_elements_text(coalesce(p->'free_dates', '[]'::jsonb)) x), '{}');
        v_al date[] := coalesce((select array_agg(x::date order by x::date) from jsonb_array_elements_text(coalesce(p->'al_dates', '[]'::jsonb)) x), '{}');
begin
  perform private.cms_require('leave', 'E', null);
  if nullif(btrim(p->>'title'), '') is null or v_from is null or v_to is null then raise exception 'Give a title and the closure dates.'; end if;
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if exists (select 1 from unnest(v_free || v_al) d where d < v_from or d > v_to) then raise exception 'Free and AL days must be inside the closure dates.'; end if;
  if v_free && v_al then raise exception 'A day cannot be both free and annual leave.'; end if;
  if v_id is not null then
    select * into c from public.cms_closures where id = v_id;
    if c.id is null then raise exception 'Closure not found.'; end if;
    if c.status <> 'draft' then raise exception 'This closure has been applied; cancel it first to change it.'; end if;
    update public.cms_closures set title = btrim(p->>'title'), date_from = v_from, date_to = v_to, scope = coalesce(p->'scope', '{}'::jsonb),
           free_dates = v_free, al_dates = v_al, note = nullif(btrim(p->>'note'), ''), updated_at = now(), updated_by = auth.uid() where id = v_id returning * into c;
    update public.cms_calendar_entries set title = c.title, date_from = c.date_from, date_to = c.date_to, updated_at = now(), updated_by = auth.uid() where closure_id = c.id;
  else
    insert into public.cms_closures (title, date_from, date_to, scope, free_dates, al_dates, note)
    values (btrim(p->>'title'), v_from, v_to, coalesce(p->'scope', '{}'::jsonb), v_free, v_al, nullif(btrim(p->>'note'), '')) returning * into c;
    insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title, note, closure_id)
    values ('staff', 'closure', c.date_from, c.date_to, c.title, 'Company closure (draft)', c.id);
  end if;
  perform private.cms_log('closure.save', 'cms_closures', c.id::text, null, 'Company closure ' || c.title || ' (' || c.date_from || ' – ' || c.date_to || '): ' || cardinality(c.free_dates) || ' free, ' || cardinality(c.al_dates) || ' AL', to_jsonb(c));
  return to_jsonb(c);
end $f$;
revoke all on function public.cms_closure_save(jsonb) from public, anon; grant execute on function public.cms_closure_save(jsonb) to authenticated;

-- p_people: [{employee_id, name, mode, free_dates[], al_dates[], al_balance, shortfall, note}] as worked out on the page (the leave
-- balance comes from the same leave engine as Leave Balances). AL days are covered by the balance first (in date order); the rest follow
-- the shortfall choice: unpaid (UPL), free (CCL) or borrow (AL now, with next year's AL reduced by the same days).
create or replace function public.cms_closure_apply(p_id uuid, p_people jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare c public.cms_closures; it jsonb; v_emp bigint; v_mode text; v_short text; v_free date[]; v_al date[]; v_bal numeric; v_cover numeric; v_left numeric;
        d date; t text; rid bigint; rids bigint[]; aids bigint[]; aid bigint; v_y int; n_people int := 0; n_free numeric := 0; n_al numeric := 0; n_upl numeric := 0; n_borrow numeric := 0; n_freed numeric := 0;
        boss boolean := private.cms_is_admin_or_director(); v_note text;
begin
  perform private.cms_require('leave', 'E', null);
  select * into c from public.cms_closures where id = p_id for update;
  if c.id is null then raise exception 'Closure not found.'; end if;
  if c.status <> 'draft' then raise exception 'This closure is already %.', c.status; end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_array_length(p_people) = 0 then raise exception 'No one to apply the closure to.'; end if;
  v_y := extract(year from c.date_from)::int;
  v_note := 'Company closure: ' || c.title;
  for it in select * from jsonb_array_elements(p_people) loop
    v_emp := (it->>'employee_id')::bigint; v_mode := coalesce(nullif(it->>'mode', ''), 'split'); v_short := coalesce(nullif(it->>'shortfall', ''), 'unpaid');
    if not exists (select 1 from public.eppd_employees where id = v_emp) then raise exception 'Employee % not found.', v_emp; end if;
    if v_mode not in ('split', 'custom', 'duty', 'excluded') then raise exception 'Unknown choice % for %.', v_mode, it->>'name'; end if;
    if v_short not in ('unpaid', 'borrow', 'free') then raise exception 'Unknown shortfall choice % for %.', v_short, it->>'name'; end if;
    if v_short <> 'unpaid' and not boss then raise exception 'Only Admin or Director can make a shortfall free or borrowed (%).', it->>'name'; end if;
    if v_mode = 'split' then v_free := c.free_dates; v_al := c.al_dates;
    elsif v_mode = 'custom' then
      v_free := coalesce((select array_agg(x::date order by x::date) from jsonb_array_elements_text(coalesce(it->'free_dates', '[]'::jsonb)) x), '{}');
      v_al := coalesce((select array_agg(x::date order by x::date) from jsonb_array_elements_text(coalesce(it->'al_dates', '[]'::jsonb)) x), '{}');
      if exists (select 1 from unnest(v_free || v_al) x where x < c.date_from or x > c.date_to) or v_free && v_al then raise exception 'Check the days chosen for %.', it->>'name'; end if;
    else v_free := '{}'; v_al := '{}'; end if;
    v_bal := nullif(it->>'al_balance', '')::numeric;
    v_cover := least(cardinality(v_al), greatest(0, floor(coalesce(v_bal, cardinality(v_al)))));
    v_left := cardinality(v_al) - v_cover;
    rids := '{}'; aids := '{}';
    foreach d in array v_free loop
      insert into public.eppd_leave_records (employee_id, leave_type, date_from, date_to, half_day, days, status, source, note, created_by, details)
      values (v_emp, 'CCL', d, d, 'none', 1, 'taken', 'manual', v_note || ' (free day)', auth.uid(), jsonb_build_object('closure_id', c.id, 'part', 'free')) returning id into rid;
      rids := rids || rid; n_free := n_free + 1;
    end loop;
    for i in 1 .. cardinality(v_al) loop
      d := v_al[i];
      t := case when i <= v_cover then 'AL' when v_short = 'unpaid' then 'UPL' when v_short = 'free' then 'CCL' else 'AL' end;
      insert into public.eppd_leave_records (employee_id, leave_type, date_from, date_to, half_day, days, status, source, note, created_by, details)
      values (v_emp, t, d, d, 'none', 1, 'taken', 'manual',
              v_note || case when i <= v_cover then ' (annual leave)' when v_short = 'unpaid' then ' (unpaid: not enough annual leave)' when v_short = 'free' then ' (free: not enough annual leave)' else ' (annual leave borrowed from ' || (v_y + 1) || ')' end,
              auth.uid(), jsonb_build_object('closure_id', c.id, 'part', case when i <= v_cover then 'al' else v_short end)) returning id into rid;
      rids := rids || rid;
      if i <= v_cover then n_al := n_al + 1; elsif v_short = 'unpaid' then n_upl := n_upl + 1; elsif v_short = 'free' then n_freed := n_freed + 1; else n_borrow := n_borrow + 1; end if;
    end loop;
    if v_short = 'borrow' and v_left > 0 then
      insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, source, note, created_by)
      values (v_emp, 'AL', v_y, 'manual', v_left, c.date_from, 'manual', v_note || ': ' || v_left || ' day(s) borrowed from ' || (v_y + 1), auth.uid()) returning id into aid;
      aids := aids || aid;
      insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, source, note, created_by)
      values (v_emp, 'AL', v_y + 1, 'manual', -v_left, make_date(v_y + 1, 1, 1), 'manual', v_note || ': ' || v_left || ' day(s) lent to ' || v_y, auth.uid()) returning id into aid;
      aids := aids || aid;
    end if;
    insert into public.cms_closure_people (closure_id, employee_id, name, mode, free_dates, al_dates, al_balance, al_days, short_days, shortfall, record_ids, adjustment_ids, note)
    values (c.id, v_emp, it->>'name', v_mode, v_free, v_al, v_bal, cardinality(v_al), v_left, v_short, rids, aids, nullif(btrim(it->>'note'), ''))
    on conflict (closure_id, employee_id) do update set name = excluded.name, mode = excluded.mode, free_dates = excluded.free_dates, al_dates = excluded.al_dates,
      al_balance = excluded.al_balance, al_days = excluded.al_days, short_days = excluded.short_days, shortfall = excluded.shortfall,
      record_ids = excluded.record_ids, adjustment_ids = excluded.adjustment_ids, note = excluded.note;
    n_people := n_people + 1;
  end loop;
  update public.cms_closures set status = 'applied', applied_at = now(), applied_by = auth.uid(),
         applied_summary = jsonb_build_object('people', n_people, 'free', n_free, 'al', n_al, 'unpaid', n_upl, 'borrowed', n_borrow, 'made_free', n_freed)
   where id = c.id returning * into c;
  update public.cms_calendar_entries set note = 'Company closure', updated_at = now(), updated_by = auth.uid() where closure_id = c.id;
  perform private.cms_log('closure.apply', 'cms_closures', c.id::text, null, 'Company closure applied: ' || c.title || ' · ' || n_people || ' people · ' || n_free || ' free, ' || n_al || ' AL, '
          || n_upl || ' unpaid, ' || n_borrow || ' borrowed, ' || n_freed || ' made free', c.applied_summary);
  return to_jsonb(c);
end $f$;
revoke all on function public.cms_closure_apply(uuid, jsonb) from public, anon; grant execute on function public.cms_closure_apply(uuid, jsonb) to authenticated;

create or replace function public.cms_closure_cancel(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare c public.cms_closures; cp record; a public.eppd_leave_adjustments; n int := 0;
begin
  perform private.cms_require('leave', 'E', null);
  if nullif(btrim(p_reason), '') is null then raise exception 'Give the reason for cancelling.'; end if;
  select * into c from public.cms_closures where id = p_id for update;
  if c.id is null then raise exception 'Closure not found.'; end if;
  if c.status = 'cancelled' then raise exception 'Already cancelled.'; end if;
  if c.status = 'applied' then
    update public.eppd_leave_records set status = 'cancelled', note = coalesce(note, '') || ' · cancelled: ' || btrim(p_reason), updated_at = now()
     where details->>'closure_id' = c.id::text and status <> 'cancelled';
    get diagnostics n = row_count;
    -- borrowed days: reverse both adjustments (kept, with a counter entry)
    for cp in select * from public.cms_closure_people where closure_id = c.id and cardinality(adjustment_ids) > 0 loop
      for a in select * from public.eppd_leave_adjustments where id = any(cp.adjustment_ids) loop
        insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, source, note, created_by)
        values (a.employee_id, a.leave_type, a.year, 'manual', -a.days, a.effective_date, 'manual', 'Reversal (closure cancelled): ' || coalesce(a.note, ''), auth.uid());
      end loop;
    end loop;
  end if;
  update public.cms_closures set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = btrim(p_reason) where id = c.id returning * into c;
  update public.cms_calendar_entries set is_active = false, updated_at = now(), updated_by = auth.uid() where closure_id = c.id;
  perform private.cms_log('closure.cancel', 'cms_closures', c.id::text, null, 'Company closure cancelled: ' || c.title || ' (' || n || ' leave record(s) cancelled) · ' || btrim(p_reason), jsonb_build_object('records', n, 'reason', p_reason));
  return to_jsonb(c);
end $f$;
revoke all on function public.cms_closure_cancel(uuid, text) from public, anon; grant execute on function public.cms_closure_cancel(uuid, text) to authenticated;

-- ---------------------------------------------------------------- replacement-leave check
-- p: {items: [{holiday_date, holiday_name, employee_id, decision, days, effective_date, note}]}
create or replace function public.cms_rl_check_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare it jsonb; v_emp bigint; v_d date; v_dec text; v_days numeric; v_eff date; old public.cms_rl_checks; aid bigint; n int := 0; g int := 0; who text;
begin
  perform private.cms_require('leave', 'E', null);
  who := (select coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'), ''), u.email) from auth.users u where u.id = auth.uid());
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    v_emp := (it->>'employee_id')::bigint; v_d := (it->>'holiday_date')::date; v_dec := it->>'decision';
    if v_dec not in ('granted', 'handled', 'not_entitled') then raise exception 'Unknown decision %.', v_dec; end if;
    select * into old from public.cms_rl_checks where holiday_date = v_d and employee_id = v_emp;
    if old.decision = 'granted' then raise exception 'Replacement leave for % was already granted (%). To undo it, correct it in Leave balances.', v_d, coalesce(it->>'name', v_emp::text); end if;
    aid := null; v_days := null; v_eff := null;
    if v_dec = 'granted' then
      v_days := coalesce(nullif(it->>'days', '')::numeric, 1); v_eff := coalesce(nullif(it->>'effective_date', '')::date, v_d);
      if v_days <= 0 then raise exception 'Days must be more than 0.'; end if;
      insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, source, note, created_by)
      values (v_emp, 'RL', extract(year from v_eff)::int, 'earned', v_days, v_eff, 'manual',
              'Replacement leave for ' || coalesce(nullif(it->>'holiday_name', ''), 'holiday') || ' (' || to_char(v_d, 'DD Mon YYYY') || ', rest/off day)' || coalesce(' · ' || nullif(btrim(it->>'note'), ''), ''), auth.uid())
      returning id into aid;
      g := g + 1;
    end if;
    insert into public.cms_rl_checks (holiday_date, employee_id, holiday_name, decision, days, effective_date, adjustment_id, note, decided_by, decided_by_name, decided_at)
    values (v_d, v_emp, it->>'holiday_name', v_dec, v_days, v_eff, aid, nullif(btrim(it->>'note'), ''), auth.uid(), who, now())
    on conflict (holiday_date, employee_id) do update set holiday_name = excluded.holiday_name, decision = excluded.decision, days = excluded.days, effective_date = excluded.effective_date,
      adjustment_id = excluded.adjustment_id, note = excluded.note, decided_by = excluded.decided_by, decided_by_name = excluded.decided_by_name, decided_at = now();
    n := n + 1;
  end loop;
  if n > 0 then perform private.cms_log('leave.rl_check', 'cms_rl_checks', null, null, 'Replacement-leave check: ' || n || ' decision(s), ' || g || ' granted', p); end if;
  return jsonb_build_object('saved', n, 'granted', g);
end $f$;
revoke all on function public.cms_rl_check_set(jsonb) from public, anon; grant execute on function public.cms_rl_check_set(jsonb) to authenticated;

-- ---------------------------------------------------------------- data: 2026 lists (CLC 10 Nov 2026)
insert into public.eppd_holidays (holiday_date, name, scope, is_active) values
  ('2026-02-15', 'Chinese New Year', 'Johor', true), ('2026-02-16', 'Chinese New Year', 'Johor', true), ('2026-02-17', 'Chinese New Year', 'Johor', true),
  ('2026-02-18', 'Chinese New Year', 'Johor', true), ('2026-02-19', 'Chinese New Year', 'Johor', true), ('2026-02-20', 'Chinese New Year', 'Johor', true),
  ('2026-02-21', 'Chinese New Year', 'Johor', true),
  ('2026-03-21', 'Hari Raya Aidilfitri', 'Johor', true), ('2026-03-22', 'Hari Raya Aidilfitri', 'Johor', true),
  ('2026-03-23', 'Sultan of Johor''s Birthday', 'Johor', true),
  ('2026-04-03', 'Good Friday', 'Johor', true),
  ('2026-05-01', 'Labour Day', 'Johor', true),
  ('2026-05-27', 'Hari Raya Haji', 'Johor', true),
  ('2026-05-31', 'Wesak Day', 'Johor', true),
  ('2026-06-01', 'Agong''s Birthday', 'Johor', true),
  ('2026-08-31', 'Merdeka Day', 'Johor', true),
  ('2026-09-16', 'Malaysia Day', 'Johor', true),
  ('2026-11-08', 'Deepavali', 'Johor', true), ('2026-11-09', 'Deepavali (replacement holiday)', 'Johor', true),
  ('2026-12-25', 'Christmas Day', 'Johor', true)
on conflict (holiday_date, scope) do nothing;

do $d$ declare cal text; begin
  -- student / tadika calendars: the staff holidays, as published on their own lists
  foreach cal in array array['e10', 'e3', 'e3p'] loop
    insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title)
    select cal, 'holiday', f::date, t::date, n from (values
      ('2026-02-15', '2026-02-21', 'Chinese New Year'), ('2026-03-21', '2026-03-22', 'Hari Raya Aidilfitri'), ('2026-03-23', '2026-03-23', 'Sultan of Johor''s Birthday'),
      ('2026-04-03', '2026-04-03', 'Good Friday'), ('2026-05-01', '2026-05-01', 'Labour Day'), ('2026-05-27', '2026-05-27', 'Hari Raya Haji'), ('2026-05-31', '2026-05-31', 'Wesak Day'),
      ('2026-06-01', '2026-06-01', 'Agong''s Birthday'), ('2026-08-31', '2026-08-31', 'Merdeka Day'), ('2026-09-16', '2026-09-16', 'Malaysia Day'),
      ('2026-11-08', '2026-11-09', 'Deepavali'), ('2026-12-25', '2026-12-25', 'Christmas Day')) v(f, t, n)
    where not exists (select 1 from public.cms_calendar_entries e where e.calendar = cal and e.date_from = v.f::date and e.title = v.n);
  end loop;
  insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title, note)
  select c, k, f::date, t::date, n, nt from (values
    ('staff', 'event', '2026-12-07', '2026-12-24', 'K2P1 preparatory class', null),
    ('staff', 'event', '2026-12-30', '2026-12-31', 'Spring cleaning (大扫除)', null),
    ('e10', 'event', '2026-06-13', '2026-06-13', 'Parent''s Day', null),
    ('e10', 'event', '2026-12-05', '2026-12-05', 'Parent''s Day', null),
    ('e10', 'event', '2026-12-07', '2026-12-24', 'K2P1 preparatory class', null),
    ('e10', 'event', '2026-12-30', '2026-12-31', 'Spring cleaning (大扫除)', null),
    ('e3', 'term_break', '2026-05-25', '2026-05-29', 'Term Break 1', 'Only childcare-service students attend'),
    ('e3', 'event', '2026-06-02', '2026-06-05', 'Exam week', null),
    ('e3', 'event', '2026-06-13', '2026-06-13', 'Parent''s Day', null),
    ('e3', 'term_break', '2026-11-16', '2026-11-20', 'Term Break 2', 'Only childcare-service students attend'),
    ('e3', 'event', '2026-11-23', '2026-11-27', 'Exam week', null),
    ('e3', 'event', '2026-12-05', '2026-12-05', 'Parent''s Day', null),
    ('e3', 'event', '2026-12-19', '2026-12-19', 'Graduation', null),
    ('e3', 'event', '2026-12-30', '2026-12-31', 'Spring cleaning (大扫除)', null),
    ('e3p', 'term_break', '2026-05-25', '2026-05-29', 'Term Break 1', 'Only childcare-service students attend'),
    ('e3p', 'event', '2026-06-02', '2026-06-05', 'Exam week', null),
    ('e3p', 'event', '2026-06-13', '2026-06-13', 'Parent''s Day', null),
    ('e3p', 'term_break', '2026-11-16', '2026-11-20', 'Term Break 2', 'Only childcare-service students attend'),
    ('e3p', 'event', '2026-11-23', '2026-11-27', 'Exam week', null),
    ('e3p', 'event', '2026-12-05', '2026-12-05', 'Parent''s Day', null),
    ('e3p', 'event', '2026-12-19', '2026-12-19', 'Graduation', null),
    ('e3p', 'event', '2026-12-30', '2026-12-31', 'Spring cleaning (大扫除)', null)) v(c, k, f, t, n, nt)
  where not exists (select 1 from public.cms_calendar_entries e where e.calendar = v.c and e.date_from = v.f::date and e.title = v.n);
end $d$;
