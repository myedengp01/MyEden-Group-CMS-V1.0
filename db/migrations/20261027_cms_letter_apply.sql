-- MyEden Group CMS V1.0 · HR letters: "Update records from this letter"
-- Issuing a letter files it; it does not change the person's records. After a letter is issued, its page lists the changes the
-- letter implies, each shown as now → after and ticked by default; HR applies them in one step:
--   confirmation  → Confirmed, confirmation date = the letter's effective date (Employee Master and payroll)
--   salary        → new basic from the effective month in the payroll salary history (the payroll picks it up)
--   promotion     → job title (payroll and Employee Master), level, JD position in Career Paths
--   next review   → interval (12 months by default, can be changed) and next review date
-- A change dated in the future (confirmation, promotion) is kept as scheduled and applied automatically on that date
-- (nightly job). Salary is dated anyway. Each letter is applied once; the result is kept with the letter and on the Timeline.
-- Permissions: People edit (confirmation, promotion), Payroll increments (salary, review), Career Paths edit (JD position).

create table if not exists public.cms_letter_applied (
  letter_id uuid primary key references public.hr_letter_records(id),
  items jsonb not null,
  applied_by uuid default auth.uid(),
  applied_at timestamptz not null default now()
);
alter table public.cms_letter_applied enable row level security;
revoke all on public.cms_letter_applied from anon, authenticated;

create table if not exists public.cms_scheduled_changes (
  id bigint generated always as identity primary key,
  person_id uuid not null references public.employee_master(id) on delete cascade,
  kind text not null check (kind in ('confirm', 'position')),
  apply_on date not null,
  payload jsonb not null default '{}'::jsonb,
  source_letter uuid references public.hr_letter_records(id),
  status text not null default 'pending' check (status in ('pending', 'applied', 'cancelled')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
create index if not exists cms_scheduled_changes_due on public.cms_scheduled_changes (status, apply_on);
alter table public.cms_scheduled_changes enable row level security;
revoke all on public.cms_scheduled_changes from anon, authenticated;

-- a date written in a letter ("01 November 2026", "1 Nov 2026", "2026-11-01", "01/11/2026")
create or replace function private.cms_parse_date(t text) returns date language plpgsql immutable as $f$
declare s text := btrim(coalesce(t, ''));
begin
  if s = '' then return null; end if;
  if s ~ '^\d{4}-\d{2}-\d{2}$' then return s::date; end if;
  if s ~ '^\d{1,2}/\d{1,2}/\d{4}$' then return to_date(s, 'DD/MM/YYYY'); end if;
  if s ~* '^\d{1,2}\s+[a-z]+\s+\d{4}$' then return to_date(s, 'DD Month YYYY'); end if;
  return null;
exception when others then return null;
end $f$;

create or replace function private.cms_money(t text) returns numeric language plpgsql immutable as $f$
begin return nullif(regexp_replace(coalesce(t, ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then return null; end $f$;

-- confirmation and promotion, applied now or on their date
create or replace function private.cms_apply_confirm(p_person uuid, p_date date) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  update public.employee_master set confirmation_status = 'confirmed', confirmation_date = p_date,
    probation_end_date = coalesce(probation_end_date, p_date - 1), updated_at = now() where id = p_person;
  update public.eppd_employments m set confirmation_status = 'C', confirmed_date = p_date
   where m.id = (select m2.id from public.eppd_employments m2 join public.eppd_employees ee on ee.id = m2.employee_id
                 where ee.employee_master_id = p_person and m2.resigned_date is null order by m2.join_date desc limit 1);
end $f$;
revoke all on function private.cms_apply_confirm(uuid, date) from public, anon, authenticated;

create or replace function private.cms_apply_position(p_person uuid, p jsonb, p_date date) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_title text := nullif(btrim(coalesce(p->>'title', '')), ''); v_tid bigint; v_level text := nullif(btrim(coalesce(p->>'level', '')), '');
begin
  if v_title is not null then
    select id into v_tid from public.eppd_job_titles where lower(name) = lower(v_title) order by is_active desc limit 1;
    if v_tid is null then insert into public.eppd_job_titles (name, is_active, sort_order) values (v_title, true, 999) returning id into v_tid; end if;
    update public.eppd_employments m set job_title_id = v_tid
     where m.id = (select m2.id from public.eppd_employments m2 join public.eppd_employees ee on ee.id = m2.employee_id
                   where ee.employee_master_id = p_person and m2.resigned_date is null order by m2.join_date desc limit 1);
    update public.employee_master set approved_job_title = v_title, job_title_level = case when v_level is not null then v_level || '|' || v_title else job_title_level end,
      updated_at = now() where id = p_person;
  end if;
  if nullif(p->>'position_id', '') is not null then
    insert into public.cms_person_position (person_id, position_id, since, note, set_by, set_at)
    values (p_person, (p->>'position_id')::uuid, p_date, nullif(p->>'note', ''), auth.uid(), now())
    on conflict (person_id) do update set position_id = excluded.position_id, since = excluded.since, note = excluded.note, set_by = excluded.set_by, set_at = now();
  end if;
end $f$;
revoke all on function private.cms_apply_position(uuid, jsonb, date) from public, anon, authenticated;

-- nightly: scheduled changes that are due
create or replace function private.cms_apply_scheduled() returns int
language plpgsql security definer set search_path = public, pg_temp as $f$
declare s record; n int := 0; d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  for s in select * from public.cms_scheduled_changes where status = 'pending' and apply_on <= d order by apply_on, id for update loop
    if s.kind = 'confirm' then perform private.cms_apply_confirm(s.person_id, s.apply_on);
    elsif s.kind = 'position' then perform private.cms_apply_position(s.person_id, s.payload, s.apply_on); end if;
    update public.cms_scheduled_changes set status = 'applied', applied_at = now() where id = s.id;
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (s.person_id, 'scheduled_change_applied', case s.kind when 'confirm' then 'Confirmed from ' || to_char(s.apply_on, 'DD Mon YYYY')
              else 'Position from ' || to_char(s.apply_on, 'DD Mon YYYY') || ': ' || coalesce(s.payload->>'title', '') end || coalesce(' (letter ' || (s.payload->>'reference') || ')', ''),
            to_jsonb(s), s.created_by);
    n := n + 1;
  end loop;
  return n;
end $f$;
revoke all on function private.cms_apply_scheduled() from public, anon, authenticated;

do $c$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and not exists (select 1 from cron.job where jobname = 'cms-scheduled-changes') then
    perform cron.schedule('cms-scheduled-changes', '5 16 * * *', 'select private.cms_apply_scheduled()');   -- 00:05 Malaysia time
  end if;
end $c$;

-- what the letter would change: one item per change, now → after
create or replace function public.cms_letter_apply_preview(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare l public.hr_letter_records; t public.hr_letter_templates; em public.employee_master; ee public.eppd_employees; m public.eppd_employments;
        f jsonb; v_date date; v_type text; items jsonb := '[]'::jsonb; cur_sal numeric; new_sal numeric; v_title text; v_pos public.jd_positions; ap public.cms_letter_applied;
        co text; v_can_people boolean; v_can_pay boolean; v_can_career boolean; rv public.cms_employee_review;
begin
  select * into l from public.hr_letter_records where id = p_id;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id; co := private.cms_canon(em.company_code);
  perform private.cms_require('letters', 'V', co);
  select * into t from public.hr_letter_templates where code = l.template_code; v_type := coalesce(t.letter_type, split_part(t.code, '_TP', 1));
  select * into ap from public.cms_letter_applied where letter_id = l.id;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  select * into m from public.eppd_employments where employee_id = ee.id and resigned_date is null order by join_date desc limit 1;
  select * into rv from public.cms_employee_review where employment_id = m.id;
  f := l.fields; v_date := coalesce(private.cms_parse_date(f->>'effective_date'), private.cms_parse_date(f->>'confirmation_date'));
  v_can_people := public.cms_can('people', 'E', co); v_can_pay := public.cms_can('payroll.increments', 'C', co); v_can_career := public.cms_can('careers', 'E', co);

  if v_type like 'LOC%' then
    items := items || jsonb_build_array(jsonb_build_object('kind', 'confirm', 'label', 'Confirmation', 'date', v_date, 'allowed', v_can_people,
      'now', concat_ws(' · ', case em.confirmation_status when 'confirmed' then 'Confirmed' when 'probation' then 'On probation' when 'extended' then 'Probation extended' else 'Not recorded' end,
                       case when em.confirmation_date is not null then 'from ' || to_char(em.confirmation_date, 'DD Mon YYYY') end),
      'after', 'Confirmed from ' || coalesce(to_char(v_date, 'DD Mon YYYY'), '?')));
  end if;
  new_sal := private.cms_money(f->>'revised_basic');
  if new_sal is not null and new_sal > 0 and m.id is not null then
    select h.amount into cur_sal from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id
     where a.employment_id = m.id and a.is_primary order by h.effective_from desc limit 1;
    items := items || jsonb_build_array(jsonb_build_object('kind', 'salary', 'label', 'Basic salary', 'date', date_trunc('month', coalesce(v_date, current_date))::date, 'amount', new_sal,
      'allowed', v_can_pay, 'now', 'RM ' || to_char(coalesce(cur_sal, 0), 'FM999,990.00'),
      'after', 'RM ' || to_char(new_sal, 'FM999,990.00') || ' from ' || to_char(date_trunc('month', coalesce(v_date, current_date)), 'Mon YYYY') || ' payroll'));
    items := items || jsonb_build_array(jsonb_build_object('kind', 'review', 'label', 'Next salary review', 'interval', 'M12',
      'next', (date_trunc('month', coalesce(v_date, current_date)) + interval '12 months')::date, 'allowed', public.cms_can('payroll.increments', 'E', co),
      'now', coalesce('every ' || (select label from public.cms_review_intervals where code = rv.interval_code), 'default interval') || coalesce(', next ' || to_char(rv.next_review, 'DD Mon YYYY'), ''),
      'after', 'Every 12 months, next review ' || to_char((date_trunc('month', coalesce(v_date, current_date)) + interval '12 months')::date, 'DD Mon YYYY'),
      'intervals', (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'months', months) order by sort_order) from public.cms_review_intervals where is_active)));
  end if;
  v_title := nullif(btrim(coalesce(f->>'new_position', f->>'revised_position', '')), '');
  if v_title is not null then
    select p.* into v_pos from public.jd_positions p join public.jd_entities e on e.id = p.entity_id
     where e.code = co and p.status = 'approved' and (p.reference = f->>'jd_reference' or (nullif(f->>'jd_reference', '') is null and private.cms_jd_key(p.job_title) = private.cms_jd_key(v_title)))
     order by p.effective_date desc nulls last limit 1;
    items := items || jsonb_build_array(jsonb_build_object('kind', 'position', 'label', 'Position', 'date', v_date, 'title', v_title,
      'level', coalesce(nullif(f->>'jd_level', ''), v_pos.level), 'position_id', v_pos.id, 'reference', v_pos.reference, 'allowed', v_can_people and (v_pos.id is null or v_can_career),
      'now', concat_ws(' · ', coalesce(em.approved_job_title, '—'), nullif(split_part(coalesce(em.job_title_level, ''), '|', 1), ''),
                       (select t2.name from public.eppd_job_titles t2 where t2.id = m.job_title_id and t2.name is distinct from em.approved_job_title) || ' (payroll)',
                       (select 'Career Paths ' || p2.reference from public.cms_person_position pp join public.jd_positions p2 on p2.id = pp.position_id where pp.person_id = em.id)),
      'after', concat_ws(' · ', v_title, coalesce(nullif(f->>'jd_level', ''), v_pos.level), case when v_pos.id is not null then 'Career Paths ' || v_pos.reference end,
                         'from ' || coalesce(to_char(v_date, 'DD Mon YYYY'), '?'))));
  end if;
  return jsonb_build_object('letter', l.id, 'status', l.status, 'reference', l.reference, 'person', em.employee_name, 'type', v_type, 'items', items,
    'applied', case when ap.letter_id is not null then jsonb_build_object('at', ap.applied_at, 'by', (select coalesce(u.raw_user_meta_data->>'full_name', u.email) from auth.users u where u.id = ap.applied_by), 'items', ap.items) end,
    'scheduled', coalesce((select jsonb_agg(jsonb_build_object('kind', s.kind, 'on', s.apply_on, 'status', s.status) order by s.apply_on) from public.cms_scheduled_changes s where s.source_letter = l.id), '[]'::jsonb));
end $f$;
revoke all on function public.cms_letter_apply_preview(uuid) from public, anon;
grant execute on function public.cms_letter_apply_preview(uuid) to authenticated;

-- apply the ticked items (values as shown, or as changed on the page)
create or replace function public.cms_letter_apply(p_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.hr_letter_records; em public.employee_master; ee public.eppd_employees; m public.eppd_employments; it jsonb; done jsonb := '[]'::jsonb; d date;
        today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; co text; ref text;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  if l.status <> 'issued' then raise exception 'Only an issued letter can update the records.'; end if;
  if exists (select 1 from public.cms_letter_applied where letter_id = l.id) then raise exception 'The records were already updated from this letter.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Tick at least one change.'; end if;
  select * into em from public.employee_master where id = l.employee_id; co := private.cms_canon(em.company_code); ref := coalesce(l.reference, l.id::text);
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  select * into m from public.eppd_employments where employee_id = ee.id and resigned_date is null order by join_date desc limit 1;
  for it in select * from jsonb_array_elements(p_items) loop
    d := nullif(it->>'date', '')::date;
    case it->>'kind'
    when 'confirm' then
      perform private.cms_require('people', 'E', co);
      if d is null then raise exception 'Give the confirmation date.'; end if;
      if d <= today then perform private.cms_apply_confirm(em.id, d);
      else insert into public.cms_scheduled_changes (person_id, kind, apply_on, payload, source_letter) values (em.id, 'confirm', d, jsonb_build_object('reference', ref), l.id); end if;
      done := done || jsonb_build_array(jsonb_build_object('kind', 'confirm', 'date', d, 'scheduled', d > today));
    when 'salary' then
      if m.id is null then raise exception 'No current employment in payroll for the salary.'; end if;
      perform public.cms_record_increment(m.id, d, (it->>'amount')::numeric, 'Letter ' || ref, nullif(it->>'note', ''));
      done := done || jsonb_build_array(jsonb_build_object('kind', 'salary', 'date', d, 'amount', (it->>'amount')::numeric));
    when 'review' then
      if m.id is null then raise exception 'No current employment in payroll for the review.'; end if;
      perform public.cms_set_review(m.id, nullif(it->>'interval', ''), nullif(it->>'next', '')::date, 'From letter ' || ref);
      done := done || jsonb_build_array(jsonb_build_object('kind', 'review', 'interval', it->>'interval', 'next', it->>'next'));
    when 'position' then
      perform private.cms_require('people', 'E', co);
      if nullif(it->>'position_id', '') is not null then perform private.cms_require('careers', 'E', co); end if;
      if d is null then raise exception 'Give the date of the new position.'; end if;
      if d <= today then perform private.cms_apply_position(em.id, it || jsonb_build_object('note', 'Letter ' || ref), d);
      else insert into public.cms_scheduled_changes (person_id, kind, apply_on, payload, source_letter)
           values (em.id, 'position', d, jsonb_build_object('title', it->>'title', 'level', it->>'level', 'position_id', it->>'position_id', 'note', 'Letter ' || ref, 'reference', ref), l.id); end if;
      done := done || jsonb_build_array(jsonb_build_object('kind', 'position', 'date', d, 'title', it->>'title', 'level', it->>'level', 'scheduled', d > today));
    else raise exception 'Unknown change %.', it->>'kind';
    end case;
  end loop;
  insert into public.cms_letter_applied (letter_id, items) values (l.id, done);
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'letter_applied', 'Records updated from letter ' || ref || ': ' || (select string_agg(x->>'kind', ', ') from jsonb_array_elements(done) x), jsonb_build_object('letter', l.id, 'items', done), auth.uid());
  perform private.cms_log('letter.applied', 'employee_master', em.id::text, co, em.employee_name || ': records updated from letter ' || ref, jsonb_build_object('letter', l.id, 'items', done));
  return jsonb_build_object('items', done);
end $f$;
revoke all on function public.cms_letter_apply(uuid, jsonb) from public, anon;
grant execute on function public.cms_letter_apply(uuid, jsonb) to authenticated;

-- a cancelled letter: its scheduled changes that have not happened yet are cancelled too (changes already applied stay; HR is reminded)
create or replace function private.cms_letter_void_scheduled() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if new.status = 'void' and old.status is distinct from 'void' then
    update public.cms_scheduled_changes set status = 'cancelled' where source_letter = new.id and status = 'pending';
  end if;
  return null;
end $f$;
revoke all on function private.cms_letter_void_scheduled() from public, anon, authenticated;
do $m$ begin
  if not exists (select 1 from pg_trigger where tgname = 'hr_letters_void_scheduled' and tgrelid = 'public.hr_letter_records'::regclass) then
    create trigger hr_letters_void_scheduled after update of status on public.hr_letter_records for each row execute function private.cms_letter_void_scheduled();
  end if;
end $m$;
