-- MyEden Group CMS V1.0 · Employee ID assigned automatically when a person reaches onboarding (first come, first served)
-- 1. The next group number is reserved the moment an employee record becomes onboarding / active, whatever created it
--    (MEG-EAF V2 Application Summary, CMS Hire, handbook tools, manual entry). Applicants get no number.
-- 2. The full ID (company letter + start MMYY + gender + number) is built as soon as gender and start date are known.
-- 3. If the start date / gender / employer changes before the person's first payslip, the ID is rebuilt with the SAME number;
--    after the first payslip the ID is fixed.
-- 4. Numbers are never reused: a counter remembers the highest number ever issued (also bumped by payroll).
-- 5. People marked legacy_id_exception (e.g. short-term co-partner) never get a number.
-- 6. "Did not join": onboarding cancelled → former, reason "Did not join", number kept (gap explained).

create table if not exists private.cms_id_counter (id boolean primary key default true check (id), last_serial integer not null);
insert into private.cms_id_counter (id, last_serial)
select true, greatest(coalesce((select max(serial_no) from public.employee_master where serial_no <> 1000), 0),
                      coalesce((select max(emp_serial) from public.eppd_employees where emp_serial <> 1000), 0))
on conflict (id) do nothing;

-- next free number (read only): after the highest used or ever issued
create or replace function private.cms_next_serial()
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  select case when n = 1000 then 1001 else n end from (
    select greatest(coalesce((select max(serial_no) from public.employee_master where serial_no is not null and serial_no <> 1000), 0),
                    coalesce((select max(emp_serial) from public.eppd_employees where emp_serial is not null and emp_serial <> 1000), 0),
                    coalesce((select last_serial from private.cms_id_counter), 0)) + 1 as n) x;
$$;

-- take a number (writes the counter, so the same number can never be handed out twice, even within one statement)
create or replace function private.cms_take_serial()
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform pg_advisory_xact_lock(hashtext('eppd_emp_id'));
  n := private.cms_next_serial();
  update private.cms_id_counter set last_serial = n where id;
  return n;
end $$;

-- keep the counter up to date whatever writes a number
create or replace function private.cms_bump_serial_counter(p_serial integer)
returns void language sql security definer set search_path = public, pg_temp as $$
  update private.cms_id_counter set last_serial = greatest(last_serial, p_serial) where id and p_serial is not null and p_serial <> 1000;
$$;

create or replace function private.cms_employee_id_auto()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := private.cms_canon(new.company_code); v_paid boolean;
begin
  if coalesce(new.legacy_id_exception, false) then return new; end if;
  if new.employment_status not in ('onboarding','active') and new.serial_no is null then return new; end if;
  -- 1. reserve the number when the person first reaches onboarding / active
  if new.serial_no is null and new.employee_id is null then
    new.serial_no := private.cms_take_serial();
  elsif new.serial_no is not null then
    perform private.cms_bump_serial_counter(new.serial_no);
  end if;
  if new.serial_no = 1000 then return new; end if;   -- reserved director IDs are never rebuilt
  -- 2. build the ID once gender and start date are known
  if new.employee_id is null then
    if new.gender_code in ('M','F') and new.start_date is not null and v_code in ('MEG','MEH','HD','ABP') then
      new.employee_id := public.format_group_employee_id(v_code, new.start_date, new.gender_code, new.serial_no);
    end if;
    return new;
  end if;
  -- 3. start date / gender / employer changed: rebuild with the same number until the first payslip
  if tg_op = 'UPDATE' and (new.start_date is distinct from old.start_date or new.gender_code is distinct from old.gender_code
                            or new.company_code is distinct from old.company_code)
     and new.employee_id = old.employee_id and new.gender_code in ('M','F') and new.start_date is not null and v_code in ('MEG','MEH','HD','ABP')
     and old.serial_no is not null and old.gender_code in ('M','F') and old.start_date is not null
     and private.cms_canon(old.company_code) in ('MEG','MEH','HD','ABP')
     and new.employee_id = public.format_group_employee_id(private.cms_canon(old.company_code), old.start_date, old.gender_code, old.serial_no) then
    select exists (select 1 from public.eppd_pay_lines l join public.eppd_employees e on e.id = l.employee_id where e.employee_master_id = new.id) into v_paid;
    if not v_paid then
      new.employee_id := public.format_group_employee_id(v_code, new.start_date, new.gender_code, new.serial_no);
      update public.eppd_employees set emp_id = new.employee_id, emp_serial = new.serial_no where employee_master_id = new.id and emp_id is distinct from new.employee_id;
    end if;
  end if;
  return new;
end $$;

create or replace function private.cms_employee_id_logged()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.employee_id is distinct from (case when tg_op = 'UPDATE' then old.employee_id end) and new.employee_id is not null then
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (new.id, 'employee_id_assigned', case when tg_op = 'UPDATE' and old.employee_id is not null then 'Employee ID rebuilt (start date / gender / employer changed before the first payslip)' else 'Employee ID assigned automatically at onboarding' end,
            jsonb_build_object('employee_id', new.employee_id, 'serial_no', new.serial_no, 'previous', case when tg_op = 'UPDATE' then old.employee_id end), auth.uid());
  elsif new.serial_no is not null and new.employee_id is null and (tg_op = 'INSERT' or old.serial_no is null) then
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (new.id, 'employee_number_reserved', 'Group number reserved at onboarding; the Employee ID is completed when gender and start date are entered',
            jsonb_build_object('serial_no', new.serial_no), auth.uid());
  end if;
  return null;
end $$;

create or replace trigger cms_employee_id_auto before insert or update on public.employee_master
  for each row execute function private.cms_employee_id_auto();
create or replace trigger cms_employee_id_logged after insert or update on public.employee_master
  for each row execute function private.cms_employee_id_logged();

-- payroll numbers also move the counter (MyPayroll "Add employee" / generate ID)
create or replace function private.cms_eppd_serial_bump()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_bump_serial_counter(new.emp_serial);
  return new;
end $$;
create or replace trigger cms_eppd_serial_bump after insert or update of emp_serial on public.eppd_employees
  for each row execute function private.cms_eppd_serial_bump();

-- ---------------------------------------------------------------- "Did not join"
insert into public.eppd_lookups (category, code, label, meta, is_active, sort_order)
values ('leaving_reason', 'NOT_JOINED', 'Did not join (onboarding cancelled)', '{}', true, 15)
on conflict do nothing;

create or replace function public.cms_not_joined(p_person uuid, p_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master;
begin
  select * into em from public.employee_master where id = p_person for update;
  if em.id is null then raise exception 'Person not found'; end if;
  perform private.cms_require('onboarding', 'E', private.cms_canon(em.company_code));
  if em.employment_status <> 'onboarding' then raise exception 'Only someone still onboarding can be marked "Did not join".'; end if;
  if exists (select 1 from public.eppd_pay_lines l join public.eppd_employees e on e.id = l.employee_id where e.employee_master_id = em.id) then
    raise exception '% already has a payslip: record a resignation in MyPayroll instead.', em.employee_name;
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give a short note (why the person did not join).'; end if;
  update public.employee_master set employment_status = 'former', exit_reason = 'Did not join', exit_notes = btrim(p_note),
         actual_last_working_date = coalesce(start_date, (now() at time zone 'Asia/Kuala_Lumpur')::date), updated_at = now()
   where id = em.id;
  update public.eppd_employments m set resigned_date = coalesce(m.join_date, (now() at time zone 'Asia/Kuala_Lumpur')::date),
         leaving_reason = 'NOT_JOINED', leaving_note = btrim(p_note), confirmation_status = 'R'
    from public.eppd_employees e where e.id = m.employee_id and e.employee_master_id = em.id and m.resigned_date is null;
  update public.eppd_assignments a set end_date = coalesce(a.start_date, (now() at time zone 'Asia/Kuala_Lumpur')::date)
    from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
   where a.employment_id = m.id and e.employee_master_id = em.id and a.end_date is null;
  update public.handbook_assignments set revoked_at = now(), revoked_reason = 'Did not join', updated_at = now()
   where employee_id = em.id and revoked_at is null;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'did_not_join', btrim(p_note), jsonb_build_object('employee_id', em.employee_id, 'serial_no', em.serial_no), auth.uid());
  perform private.cms_log('person.not_joined', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': did not join' || coalesce(' (Employee ID ' || em.employee_id || ' kept, not reused)', ''), jsonb_build_object('note', p_note));
end $$;
revoke all on function public.cms_not_joined(uuid, text) from public, anon;
grant execute on function public.cms_not_joined(uuid, text) to authenticated;
revoke all on function private.cms_take_serial(), private.cms_bump_serial_counter(integer) from public, anon;

-- reminders: number reserved but ID incomplete (gender / start date missing)
create or replace function public.cms_id_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('people', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('person_id', id, 'name', employee_name, 'serial', serial_no, 'status', employment_status,
            'company', private.cms_canon(company_code), 'missing', array_remove(array[case when gender_code is null then 'gender' end, case when start_date is null then 'start date' end], null))
          order by serial_no)
    from public.employee_master where employee_id is null and serial_no is not null and not coalesce(legacy_id_exception, false)), '[]'::jsonb);
end $$;
revoke all on function public.cms_id_pending() from public, anon;
grant execute on function public.cms_id_pending() to authenticated;

-- CMS hire keeps a number reserved at onboarding (and takes a new one through the counter otherwise)
do $m$ declare d text := pg_get_functiondef('public.cms_hire(jsonb)'::regprocedure); n text;
begin
  n := replace(d, $x$    v_serial := private.cms_next_serial();
    v_id := public.format_group_employee_id(v_employer, v_join, v_gender, v_serial);$x$,
               $x$    v_serial := coalesce(em.serial_no, private.cms_take_serial());   -- keep a number reserved at onboarding
    v_id := public.format_group_employee_id(v_employer, v_join, v_gender, v_serial);$x$);
  if n <> d then execute n; end if;
end $m$;

-- one-off (21 Oct 2026, already run): the one person then onboarding received the next number; one short-term co-partner was
-- marked legacy_id_exception (no Employee ID); the test record is removed with db/payroll/012_remove_test_employee.sql.
