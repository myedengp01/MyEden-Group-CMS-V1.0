-- MyEden Group CMS V1.0 · v2026.10.30 · Resignation calculator, working hours and part-time leave rules
-- 1. Record resignation (one record per employment): letter date, notice start (default the letter date), notice end (letter + N weeks,
--    4 / 6 / 12 by service, 4 on probation), last physical day, employment end, annual leave used up (offset) or paid out, who pays for
--    notice not served (employee / company / waived), and the calculation as worked out on the page. Saving keeps the payroll employment
--    (letter date, notice until, last working day, leaving reason) and the Employee Master in step; withdrawing clears them again.
-- 2. Final settlement from the resignation: applied from the issued resignation acceptance letter ("Update records from this letter").
--    Notice not served = basic ÷ the actual days of each month × calendar days; annual leave paid out at basic ÷ 26 (Employment Act s.60I).
-- 3. Working hours: contracted weekly hours, days a week and HR's marking (full time / part time / casual) on the payroll employment.
--    From the 2027 leave year part-timers get the Employment (Part-Time Employees) Regulations 2010 days (AL 6 / 8 / 11, SL 10 / 13 / 15);
--    casual (30 % or less of a full-time week) gets no paid annual or sick leave. Earlier years are unchanged.
-- 4. Reminders, new letter placeholders, the plain acceptance letter switched back on (rewritten) and a new early-release letter (RL_TP3).
-- Additive only.

-- 3 · working hours -------------------------------------------------------------------------------------------------------------
alter table public.eppd_employments add column if not exists work_days_per_week numeric;
alter table public.eppd_employments add column if not exists hours_class text;
alter table public.eppd_employments add column if not exists hours_class_reason text;
alter table public.eppd_employments add column if not exists hours_class_by uuid;
alter table public.eppd_employments add column if not exists hours_class_at timestamptz;
do $m$ begin
  if not exists (select 1 from pg_constraint where conname = 'eppd_employments_hours_class_chk') then
    alter table public.eppd_employments add constraint eppd_employments_hours_class_chk check (hours_class is null or hours_class in ('FT', 'PT', 'CASUAL'));
  end if;
end $m$;
comment on column public.eppd_employments.hours_class is 'HR''s marking for the leave rules: FT, PT or CASUAL. Blank = worked out from weekly_hours (≤30 % casual, ≤70 % part time) or the job status.';

-- policies: merged in, nothing removed
update public.eppd_policies set value = value || jsonb_build_object('from_year', coalesce(value->'from_year', '2027'::jsonb), 'casual_max_pct', coalesce(value->'casual_max_pct', '30'::jsonb),
  'part_time_max_pct', coalesce(value->'part_time_max_pct', '70'::jsonb),
  'al_bands', coalesce(value->'al_bands', '[{"until_months":24,"days":6},{"until_months":60,"days":8},{"until_months":null,"days":11}]'::jsonb),
  'sl_bands', coalesce(value->'sl_bands', '[{"until_years":2,"days":10},{"until_years":5,"days":13},{"until_years":null,"days":15}]'::jsonb))
 where key = 'part_time';
update public.eppd_policies set value = value || jsonb_build_object('notice_rate', 'calendar_month', 'al_rate', 'orp', 'work_days', '[1,2,3,4,5,6]'::jsonb)
 where key = 'settlement';

-- 1 · resignation record ------------------------------------------------------------------------------------------------------
create table if not exists public.cms_resignations (
  id bigint generated always as identity primary key,
  employment_id bigint not null references public.eppd_employments(id),
  person_id uuid references public.employee_master(id),
  status text not null default 'recorded' check (status in ('recorded', 'withdrawn')),
  letter_date date not null,
  received_date date,
  notice_start date not null,
  notice_weeks numeric,
  notice_end date not null,
  notice_agreed boolean not null default false,
  requested_last_day date,
  last_physical_day date not null,
  employment_end date not null,
  al_use text not null default 'payout' check (al_use in ('offset', 'payout', 'none')),
  notice_payer text not null default 'employee' check (notice_payer in ('employee', 'company', 'waived')),
  waived_by text,
  calc jsonb not null default '{}'::jsonb,
  note text,
  withdrawn_reason text, withdrawn_at timestamptz, withdrawn_by uuid,
  created_at timestamptz not null default now(), created_by uuid default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid
);
create unique index if not exists cms_resignations_one_open on public.cms_resignations (employment_id) where status = 'recorded';
create index if not exists cms_resignations_person on public.cms_resignations (person_id);
alter table public.cms_resignations enable row level security;
revoke all on public.cms_resignations from anon, authenticated;

-- the employment a resignation is about: one with an open resignation, else the current one, else the latest
create or replace function private.cms_resign_employment(p_person uuid) returns public.eppd_employments
language sql stable security definer set search_path = public, pg_temp as $f$
  select m.* from public.eppd_employees ee join public.eppd_employments m on m.employee_id = ee.id
   where ee.employee_master_id = p_person
   order by (exists (select 1 from public.cms_resignations r where r.employment_id = m.id and r.status = 'recorded')) desc,
            (m.resigned_date is null or m.resigned_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date) desc, m.join_date desc nulls last
   limit 1;
$f$;
revoke all on function private.cms_resign_employment(uuid) from public, anon, authenticated;

create or replace function public.cms_resignation_get(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; m public.eppd_employments; r public.cms_resignations; v_sal boolean; st public.eppd_settlements; v_run text;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'V', co);
  m := private.cms_resign_employment(p_person);
  if m.id is not null then
    select * into r from public.cms_resignations where employment_id = m.id and status = 'recorded';
    select * into st from public.eppd_settlements where employment_id = m.id;
    select pr.status into v_run from public.eppd_pay_runs pr where pr.period = date_trunc('month', coalesce(r.employment_end, m.resigned_date))::date;
  end if;
  v_sal := public.cms_can('people.salary', 'V', co) or public.cms_can('payroll', 'V', co);
  return jsonb_build_object(
    'person', jsonb_build_object('id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', co, 'title', em.approved_job_title),
    'eppd_employee_id', m.employee_id,
    'employment', case when m.id is null then null else jsonb_build_object('id', m.id, 'join_date', m.join_date, 'confirmation_status', m.confirmation_status,
       'confirmed_date', m.confirmed_date, 'job_status', m.job_status, 'weekly_hours', m.weekly_hours, 'work_days_per_week', m.work_days_per_week, 'hours_class', m.hours_class,
       'resigned_date', m.resigned_date, 'notice_until', m.notice_until, 'resignation_letter_date', m.resignation_letter_date, 'leaving_reason', m.leaving_reason,
       'leaving_note', m.leaving_note, 'rehire', m.rehire_eligibility, 'rehire_note', m.rehire_note, 'work_from', m.work_from, 'work_to', m.work_to, 'meal_hours', m.meal_hours) end,
    'record', case when r.id is null then null else to_jsonb(r) end,
    'withdrawn', coalesce((select jsonb_agg(jsonb_build_object('letter_date', x.letter_date, 'at', x.withdrawn_at, 'reason', x.withdrawn_reason) order by x.withdrawn_at)
        from public.cms_resignations x where x.employment_id = m.id and x.status = 'withdrawn'), '[]'::jsonb),
    'salary', case when v_sal and m.id is not null then coalesce((select jsonb_agg(jsonb_build_object('effective_from', h.effective_from, 'amount', h.amount, 'pay_basis', h.pay_basis) order by h.effective_from)
        from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id where a.employment_id = m.id and a.is_primary), '[]'::jsonb) end,
    'policies', (select jsonb_object_agg(key, value) from public.eppd_policies where key in ('notice_period', 'part_time', 'settlement', 'payroll', 'al_entitlement', 'modules')),
    'reasons', (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'note', coalesce((meta->>'needs_note')::boolean, false)) order by sort_order, label)
        from public.eppd_lookups where category = 'leaving_reason' and is_active),
    'settlement', case when st.employment_id is null then null else to_jsonb(st) end,
    'final_run', v_run,
    'letters', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'status', l.status, 'template', l.template_code, 'title', t.title, 'at', coalesce(l.issued_at, l.updated_at, l.created_at)) order by l.created_at desc)
        from public.hr_letter_records l join public.hr_letter_templates t on t.code = l.template_code where l.employee_id = em.id and coalesce(t.letter_type, '') = 'RL'), '[]'::jsonb),
    'can', jsonb_build_object('edit', public.cms_can('people', 'E', co), 'salary', v_sal, 'settle', public.cms_can('payroll.prepare', 'V'), 'letters', public.cms_can('letters', 'V', co)));
end $f$;
revoke all on function public.cms_resignation_get(uuid) from public, anon;
grant execute on function public.cms_resignation_get(uuid) to authenticated;

create or replace function public.cms_resignation_save(p_person uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; m public.eppd_employments; r public.cms_resignations; v_id bigint; v_old date; v_run text;
  v_letter date := nullif(p->>'letter_date', '')::date; v_recv date := nullif(p->>'received_date', '')::date;
  v_start date; v_end date := nullif(p->>'notice_end', '')::date; v_last date := nullif(p->>'last_physical_day', '')::date;
  v_emp_end date := nullif(p->>'employment_end', '')::date; v_req date := nullif(p->>'requested_last_day', '')::date;
  v_use text := coalesce(nullif(p->>'al_use', ''), 'payout'); v_payer text := coalesce(nullif(p->>'notice_payer', ''), 'employee');
  v_reason text := nullif(p->>'leaving_reason', ''); v_rehire text := nullif(p->>'rehire', ''); v_calc jsonb := coalesce(p->'calc', '{}'::jsonb);
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'E', co);
  m := private.cms_resign_employment(p_person);
  if m.id is null then raise exception 'This person has no payroll employment yet.'; end if;
  v_start := coalesce(nullif(p->>'notice_start', '')::date, v_letter);
  if v_letter is null then raise exception 'Enter the resignation letter date.'; end if;
  if m.join_date is not null and v_letter < m.join_date then raise exception 'The letter date is before the date joined (%).', to_char(m.join_date, 'DD Mon YYYY'); end if;
  if v_end is null or v_last is null or v_emp_end is null then raise exception 'The notice end, the last physical working day and the employment end date are needed.'; end if;
  if v_start < v_letter then raise exception 'The notice cannot start before the letter date.'; end if;
  if v_last < v_letter then raise exception 'The last physical working day is before the letter date.'; end if;
  if v_last > v_end then raise exception 'The last physical working day is after the end of the notice. Change the agreed notice end instead.'; end if;
  if v_emp_end < v_last or v_emp_end > v_end then raise exception 'The employment end date must be between the last physical working day and the end of the notice.'; end if;
  if v_use not in ('offset', 'payout', 'none') or v_payer not in ('employee', 'company', 'waived') then raise exception 'Unknown arrangement.'; end if;
  if v_payer = 'waived' and v_emp_end < v_end and length(btrim(coalesce(p->>'waived_by', ''))) < 3 then raise exception 'Name who approved waiving the notice not served.'; end if;
  if v_reason is null then raise exception 'Choose the reason for leaving.'; end if;
  if v_rehire is not null and v_rehire <> 'eligible' and length(btrim(coalesce(p->>'rehire_note', ''))) < 3 then raise exception 'Add a rehire note: the conditions, or why not eligible.'; end if;
  v_old := m.resigned_date;
  if v_old is distinct from v_emp_end then
    select status into v_run from public.eppd_pay_runs
     where period in (date_trunc('month', v_emp_end)::date, date_trunc('month', coalesce(v_old, v_emp_end))::date) and status = 'finalised' limit 1;
    if v_run is not null then raise exception 'The payroll month of the last day is already finalised. Reopen it in Payroll first.'; end if;
  end if;

  select * into r from public.cms_resignations where employment_id = m.id and status = 'recorded' for update;
  if r.id is null then
    insert into public.cms_resignations (employment_id, person_id, letter_date, received_date, notice_start, notice_weeks, notice_end, notice_agreed, requested_last_day,
      last_physical_day, employment_end, al_use, notice_payer, waived_by, calc, note, created_by, updated_by)
    values (m.id, em.id, v_letter, v_recv, v_start, nullif(p->>'notice_weeks', '')::numeric, v_end, coalesce((p->>'notice_agreed')::boolean, false), v_req,
      v_last, v_emp_end, v_use, v_payer, nullif(btrim(coalesce(p->>'waived_by', '')), ''), v_calc, nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid(), auth.uid())
    returning id into v_id;
  else
    update public.cms_resignations set letter_date = v_letter, received_date = v_recv, notice_start = v_start, notice_weeks = nullif(p->>'notice_weeks', '')::numeric,
      notice_end = v_end, notice_agreed = coalesce((p->>'notice_agreed')::boolean, false), requested_last_day = v_req, last_physical_day = v_last, employment_end = v_emp_end,
      al_use = v_use, notice_payer = v_payer, waived_by = nullif(btrim(coalesce(p->>'waived_by', '')), ''), calc = v_calc, note = nullif(btrim(coalesce(p->>'note', '')), ''),
      updated_at = now(), updated_by = auth.uid()
     where id = r.id;
    v_id := r.id;
  end if;

  -- payroll employment: letter date, last working day (= employment end), leaving reason; then the notice end on its own (the notice trigger
  -- recalculates from the letter date unless notice_until changes in a separate update)
  update public.eppd_employments set resignation_letter_date = v_letter, resigned_date = v_emp_end, leaving_reason = v_reason,
    leaving_note = nullif(btrim(coalesce(p->>'leaving_note', '')), ''), rehire_eligibility = v_rehire, rehire_note = nullif(btrim(coalesce(p->>'rehire_note', '')), '')
   where id = m.id;
  update public.eppd_employments set notice_until = v_end where id = m.id and notice_until is distinct from v_end;
  update public.eppd_assignments set end_date = v_emp_end where employment_id = m.id and (end_date is null or end_date = v_old);
  update public.employee_master set resignation_letter_date = v_letter, required_last_working_date = v_end, actual_last_working_date = v_last,
    notice_period_value = nullif(p->>'notice_weeks', '')::numeric, notice_period_unit = 'weeks', annual_leave_offset_days = nullif(v_calc->>'offset_days', '')::numeric,
    notice_served = case when v_emp_end >= v_end then 'Served in full' when v_payer = 'waived' then 'Waived (' || (v_end - v_emp_end) || ' day(s))'
                         else 'Short by ' || (v_end - v_emp_end) || ' day(s), ' || case v_payer when 'company' then 'paid by the company' else 'paid by the employee' end end,
    updated_at = now()
   where id = em.id;
  -- a hand-over opened by the leaving date is due by the last physical working day
  update public.cms_handovers set deadline = v_last, updated_at = now() where person_id = em.id and status = 'open' and (deadline is null or deadline > v_last);
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'resignation_recorded', 'Resignation letter ' || to_char(v_letter, 'DD Mon YYYY') || ' · notice to ' || to_char(v_end, 'DD Mon YYYY')
    || ' · last physical day ' || to_char(v_last, 'DD Mon YYYY') || ' · employment ends ' || to_char(v_emp_end, 'DD Mon YYYY'), jsonb_build_object('resignation', v_id), auth.uid());
  perform private.cms_log('resignation.saved', 'employee_master', em.id::text, co,
    em.employee_name || ': resignation recorded (letter ' || to_char(v_letter, 'DD Mon YYYY') || ', employment ends ' || to_char(v_emp_end, 'DD Mon YYYY') || ')', p - 'calc');
  return public.cms_resignation_get(p_person);
end $f$;
revoke all on function public.cms_resignation_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_resignation_save(uuid, jsonb) to authenticated;

create or replace function public.cms_resignation_withdraw(p_person uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; m public.eppd_employments; r public.cms_resignations; v_run text;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'E', co);
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason (at least 5 characters).'; end if;
  m := private.cms_resign_employment(p_person);
  select * into r from public.cms_resignations where employment_id = m.id and status = 'recorded' for update;
  if r.id is null then raise exception 'No resignation is recorded for this person.'; end if;
  if m.resigned_date is not null then
    select status into v_run from public.eppd_pay_runs where period = date_trunc('month', m.resigned_date)::date and status = 'finalised';
    if v_run is not null then raise exception 'The payroll month of the last day is already finalised. Reopen it in Payroll first.'; end if;
  end if;
  update public.eppd_employments set resignation_letter_date = null, resigned_date = null, leaving_reason = null, leaving_note = null, rehire_eligibility = null, rehire_note = null
   where id = m.id;
  update public.eppd_employments set notice_until = null where id = m.id and notice_until is not null;
  if m.resigned_date is not null then update public.eppd_assignments set end_date = null where employment_id = m.id and end_date = m.resigned_date; end if;
  update public.employee_master set resignation_letter_date = null, required_last_working_date = null, actual_last_working_date = null, notice_served = null,
    annual_leave_offset_days = null, notice_period_value = null, notice_period_unit = null, updated_at = now() where id = em.id;
  update public.eppd_settlements set al_mode = 'auto', al_days = null, al_amount = null, notice_mode = 'none', notice_days = null, notice_amount = null,
    note = 'Resignation withdrawn ' || to_char((now() at time zone 'Asia/Kuala_Lumpur')::date, 'DD Mon YYYY') where employment_id = m.id;
  update public.cms_resignations set status = 'withdrawn', withdrawn_reason = btrim(p_reason), withdrawn_at = now(), withdrawn_by = auth.uid(), updated_at = now(), updated_by = auth.uid() where id = r.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'resignation_withdrawn', 'Resignation of ' || to_char(r.letter_date, 'DD Mon YYYY') || ' withdrawn: ' || btrim(p_reason), jsonb_build_object('resignation', r.id), auth.uid());
  perform private.cms_log('resignation.withdrawn', 'employee_master', em.id::text, co, em.employee_name || ': resignation withdrawn — ' || btrim(p_reason), jsonb_build_object('resignation', r.id));
  return public.cms_resignation_get(p_person);
end $f$;
revoke all on function public.cms_resignation_withdraw(uuid, text) from public, anon;
grant execute on function public.cms_resignation_withdraw(uuid, text) to authenticated;

-- 2 · final settlement from the resignation record --------------------------------------------------------------------------------
create or replace function private.cms_settlement_from_resignation(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $f$
declare r public.cms_resignations; v_pay numeric; v_short numeric; v_mode text; v_al text; v_run text;
begin
  select * into r from public.cms_resignations where id = p_id and status = 'recorded';
  if r.id is null then raise exception 'No resignation is recorded.'; end if;
  select status into v_run from public.eppd_pay_runs where period = date_trunc('month', r.employment_end)::date and status = 'finalised';
  if v_run is not null then raise exception 'The payroll month of the last day is already finalised. Reopen it in Payroll first.'; end if;
  v_pay := nullif(r.calc->>'payout_days', '')::numeric; v_short := coalesce(nullif(r.calc->>'short_days', '')::numeric, 0);
  v_al := case when coalesce(v_pay, 0) = 0 then 'none' else 'custom' end;
  v_mode := case when v_short > 0 and r.notice_payer = 'employee' then 'employee_pays' when v_short > 0 and r.notice_payer = 'company' then 'employer_pays' else 'none' end;
  insert into public.eppd_settlements (employment_id, al_mode, al_days, al_amount, notice_mode, notice_days, notice_amount, recover_loans, note)
  values (r.employment_id, v_al, case when v_al = 'custom' then v_pay end, case when v_al = 'custom' then nullif(r.calc->>'al_amount', '')::numeric end,
    v_mode, case when v_mode <> 'none' then v_short end, case when v_mode <> 'none' then nullif(r.calc->>'notice_amount', '')::numeric end, true,
    'From the resignation of ' || to_char(r.letter_date, 'DD Mon YYYY') || case when r.notice_payer = 'waived' and v_short > 0 then ' · notice not served waived by ' || coalesce(r.waived_by, '?') else '' end)
  on conflict (employment_id) do update set al_mode = excluded.al_mode, al_days = excluded.al_days, al_amount = excluded.al_amount, notice_mode = excluded.notice_mode,
    notice_days = excluded.notice_days, notice_amount = excluded.notice_amount, note = excluded.note, updated_at = now();
  return jsonb_build_object('al_mode', v_al, 'al_days', v_pay, 'notice_mode', v_mode, 'notice_days', v_short, 'net', r.calc->'net');
end $f$;
revoke all on function private.cms_settlement_from_resignation(bigint) from public, anon, authenticated;

-- "Update records from this letter" for a resignation acceptance letter: the final settlement from the resignation record
do $m$
declare src text; fn text;
begin
  src := pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure);
  if strpos(src, 'cms_resignations') = 0 then
    if strpos(src, 'rv public.cms_employee_review;') = 0 or strpos(src, '  return jsonb_build_object(''letter'', l.id,') = 0 then raise exception 'cms_letter_apply_preview: patch point not found'; end if;
    src := replace(src, 'rv public.cms_employee_review;', 'rv public.cms_employee_review; rs public.cms_resignations;');
    src := replace(src, '  return jsonb_build_object(''letter'', l.id,', $p$  if v_type like 'RL%' then
    select * into rs from public.cms_resignations where person_id = em.id and status = 'recorded' order by created_at desc limit 1;
    if rs.id is null then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'note', 'label', 'Resignation', 'allowed', false, 'now', 'Not recorded',
        'after', 'Record the resignation on the profile (Employment tab) first; the final settlement is then taken from it.'));
    else
      items := items || jsonb_build_array(jsonb_build_object('kind', 'settlement', 'label', 'Final settlement', 'allowed', public.cms_can('payroll.prepare', 'V'),
        'module_on', coalesce((select (value->>'settlement')::boolean from public.eppd_policies where key = 'modules'), false),
        'now', coalesce((select concat_ws(' · ', case s.al_mode when 'custom' then 'Leave ' || coalesce(s.al_days::text, '?') || ' day(s) RM ' || coalesce(to_char(s.al_amount, 'FM999,990.00'), '?') when 'none' then 'Leave not paid' else 'Leave: default' end,
                 case s.notice_mode when 'employee_pays' then 'Employee pays notice RM ' || coalesce(to_char(s.notice_amount, 'FM999,990.00'), '?') when 'employer_pays' then 'Company pays notice RM ' || coalesce(to_char(s.notice_amount, 'FM999,990.00'), '?') else 'No notice pay' end)
                 from public.eppd_settlements s where s.employment_id = rs.employment_id), 'Not set'),
        'after', concat_ws(' · ', 'Leave ' || coalesce(rs.calc->>'payout_days', '0') || ' day(s) RM ' || to_char(coalesce((rs.calc->>'al_amount')::numeric, 0), 'FM999,990.00'),
                 case when coalesce((rs.calc->>'short_days')::numeric, 0) > 0 then case rs.notice_payer when 'employee' then 'employee pays ' when 'company' then 'company pays ' else 'waived ' end
                   || (rs.calc->>'short_days') || ' day(s) notice RM ' || to_char(coalesce((rs.calc->>'notice_amount')::numeric, 0), 'FM999,990.00') else 'notice served in full' end,
                 'net RM ' || to_char(coalesce((rs.calc->>'net')::numeric, 0), 'FM999,990.00'), 'employment ends ' || to_char(rs.employment_end, 'DD Mon YYYY'))));
    end if;
  end if;
  return jsonb_build_object('letter', l.id,$p$);
    execute src;
  end if;

  fn := pg_get_functiondef('public.cms_letter_apply(uuid, jsonb)'::regprocedure);
  if strpos(fn, '''settlement''') = 0 then
    if strpos(fn, '    else raise exception ''Unknown change %.'', it->>''kind'';') = 0 then raise exception 'cms_letter_apply: patch point not found'; end if;
    fn := replace(fn, '    else raise exception ''Unknown change %.'', it->>''kind'';', $p$    when 'settlement' then
      if not public.cms_can('payroll.prepare', 'V') then raise exception 'Saving the final settlement needs "Prepare payroll".'; end if;
      done := done || jsonb_build_array(jsonb_build_object('kind', 'settlement') || private.cms_settlement_from_resignation(
        (select r.id from public.cms_resignations r where r.person_id = em.id and r.status = 'recorded' order by r.created_at desc limit 1)));
    else raise exception 'Unknown change %.', it->>'kind';$p$);
    execute fn;
  end if;
end $m$;

-- 3 · working hours list and marking ----------------------------------------------------------------------------------------------
create or replace function public.cms_working_hours_list()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; m0 date;
begin
  if not (public.cms_can('people', 'V') or public.cms_can('payroll', 'V')) then raise exception 'You do not have access to this.'; end if;
  m0 := (date_trunc('month', today) - interval '3 months')::date;
  return jsonb_build_object('policy', (select value from public.eppd_policies where key = 'part_time'), 'from', m0, 'to', (date_trunc('month', today) - interval '1 day')::date,
    'rows', coalesce((select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('person_id', em.id, 'name', coalesce(em.employee_name, ee.full_name), 'employee_id', coalesce(em.employee_id, ee.emp_id), 'company', private.cms_canon(em.company_code),
        'employment_id', m.id, 'job_status', m.job_status, 'weekly_hours', m.weekly_hours, 'work_days', m.work_days_per_week, 'hours_class', m.hours_class,
        'reason', m.hours_class_reason, 'marked_at', m.hours_class_at, 'marked_by', (select employee_name from public.employee_master b join public.cms_user_links ul on ul.employee_master_id = b.id where ul.user_id = m.hours_class_by limit 1),
        'work_from', m.work_from, 'work_to', m.work_to, 'join_date', m.join_date,
        'actual', (select jsonb_agg(jsonb_build_object('month', to_char(q.period, 'YYYY-MM'), 'hours', q.h) order by q.period) from (
            select r.period, sum((i->>'qty')::numeric) h from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id, jsonb_array_elements(l.items) i
             where l.employee_id = ee.id and not coalesce(l.excluded, false) and r.period >= m0 and r.period < date_trunc('month', today)::date and i->>'unit' = 'hours' and coalesce(i->>'category', '') = 'basic'
             group by r.period) q),
        'can_edit', public.cms_can('people', 'E', private.cms_canon(em.company_code))) x
        from public.eppd_employments m join public.eppd_employees ee on ee.id = m.employee_id left join public.employee_master em on em.id = ee.employee_master_id
       where (m.resigned_date is null or m.resigned_date >= today) and (m.job_status <> 'FT' or m.weekly_hours is not null or m.hours_class is not null)
         and (public.cms_can('people', 'V', private.cms_canon(em.company_code)) or public.cms_can('payroll', 'V'))) s), '[]'::jsonb));
end $f$;
revoke all on function public.cms_working_hours_list() from public, anon;
grant execute on function public.cms_working_hours_list() to authenticated;

create or replace function public.cms_working_hours_save(p_person uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; m public.eppd_employments; v_cls text := nullif(p->>'hours_class', ''); v_h numeric := nullif(p->>'weekly_hours', '')::numeric;
  v_d numeric := nullif(p->>'work_days', '')::numeric; v_why text := nullif(btrim(coalesce(p->>'reason', '')), '');
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
  if v_cls is distinct from m.hours_class and v_cls is not null and coalesce(length(v_why), 0) < 5 then raise exception 'Give the reason for the marking (at least 5 characters).'; end if;
  update public.eppd_employments set weekly_hours = v_h, work_days_per_week = v_d, hours_class = v_cls,
    hours_class_reason = case when v_cls is null then null when v_cls is distinct from m.hours_class or v_why is not null then coalesce(v_why, hours_class_reason) else hours_class_reason end,
    hours_class_by = case when v_cls is distinct from m.hours_class then auth.uid() else hours_class_by end,
    hours_class_at = case when v_cls is distinct from m.hours_class then now() else hours_class_at end
   where id = m.id;
  perform private.cms_log('people.working_hours', 'employee_master', em.id::text, co,
    em.employee_name || ': working hours ' || coalesce(v_h::text, '—') || ' h a week, ' || coalesce(v_d::text, '—') || ' days · marked ' || coalesce(v_cls, 'automatically'),
    jsonb_build_object('before', jsonb_build_object('weekly_hours', m.weekly_hours, 'work_days', m.work_days_per_week, 'hours_class', m.hours_class), 'after', p));
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.cms_working_hours_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_working_hours_save(uuid, jsonb) to authenticated;

-- 4 · reminders: resignation without an acceptance letter, last day close with items still to hand over, leavers without a final settlement
create or replace function public.cms_resignation_tasks()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_mod boolean;
begin
  v_mod := coalesce((select (value->>'settlement')::boolean from public.eppd_policies where key = 'modules'), false);
  return jsonb_build_object(
    'no_letter', coalesce((select jsonb_agg(jsonb_build_object('person_id', r.person_id, 'name', em.employee_name, 'since', r.created_at::date))
       from public.cms_resignations r join public.employee_master em on em.id = r.person_id
      where r.status = 'recorded' and r.employment_end >= today and r.created_at < now() - interval '3 days' and public.cms_can('letters', 'V', private.cms_canon(em.company_code))
        and not exists (select 1 from public.hr_letter_records l join public.hr_letter_templates t on t.code = l.template_code
                         where l.employee_id = r.person_id and coalesce(t.letter_type, '') = 'RL' and l.status <> 'void' and l.created_at >= r.created_at - interval '30 days')), '[]'::jsonb),
    'handover', coalesce((select jsonb_agg(jsonb_build_object('person_id', r.person_id, 'name', em.employee_name, 'last_day', r.last_physical_day))
       from public.cms_resignations r join public.employee_master em on em.id = r.person_id
      where r.status = 'recorded' and r.last_physical_day between today and today + 7 and public.cms_can('people', 'V', private.cms_canon(em.company_code))
        and exists (select 1 from public.cms_handovers h where h.person_id = r.person_id and h.status = 'open')), '[]'::jsonb),
    'no_settlement', case when not v_mod or not public.cms_can('payroll.prepare', 'V') then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('person_id', r.person_id, 'name', em.employee_name, 'end', r.employment_end))
       from public.cms_resignations r join public.employee_master em on em.id = r.person_id
      where r.status = 'recorded' and r.employment_end >= date_trunc('month', today)::date and r.employment_end < (date_trunc('month', today) + interval '2 months')::date
        and not exists (select 1 from public.eppd_settlements s where s.employment_id = r.employment_id and (s.al_mode = 'custom' or s.notice_mode <> 'none' or s.al_mode = 'none'))), '[]'::jsonb) end);
end $f$;
revoke all on function public.cms_resignation_tasks() from public, anon;
grant execute on function public.cms_resignation_tasks() to authenticated;

-- 4 · letter placeholders filled by the resignation calculator --------------------------------------------------------------------
insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, required, editable, protected, active) values
  ('notice_start_date', 'Notice starts', 'First day of the notice period (the resignation letter date unless HR set another)', 'text', 'manual', '', true, true, false, true),
  ('notice_weeks', 'Notice weeks', 'Weeks of notice by service (4 / 6 / 12; 4 on probation)', 'text', 'manual', '', true, true, false, true),
  ('employment_end_date', 'Employment end date', 'Official last day of employment (after any leave used up)', 'text', 'manual', '', true, true, false, true),
  ('employment_end_day', 'Employment end day', 'Day of the week of the employment end date', 'text', 'manual', '', true, true, false, true),
  ('al_offset_days', 'Annual leave used during notice', 'Days of annual leave used up on the last working days of the notice', 'text', 'manual', '', true, true, false, true),
  ('al_payout_days', 'Annual leave paid out', 'Days of annual leave paid in the final salary (negative = deducted)', 'text', 'manual', '', true, true, false, true),
  ('al_payout_amount', 'Annual leave amount', 'Annual leave paid out × daily rate (basic ÷ 26)', 'text', 'manual', '', true, true, false, true),
  ('daily_rate', 'Daily rate', 'Ordinary rate of pay: basic ÷ 26 (Employment Act s.60I)', 'text', 'manual', '', true, true, false, true),
  ('short_notice_days', 'Notice not served (days)', 'Calendar days of notice not served', 'text', 'manual', '', true, true, false, true),
  ('notice_in_lieu_amount', 'Payment in lieu of notice', 'Basic ÷ the days of each month × the calendar days not served', 'text', 'manual', '', true, true, false, true),
  ('notice_in_lieu_terms', 'Notice in lieu — terms', 'The sentence on the notice not served: who pays, how much, or waived', 'paragraph', 'manual', '', true, true, false, true),
  ('net_settlement', 'Net settlement', 'Annual leave paid / deducted and notice in lieu together (− = deducted from the final salary)', 'text', 'manual', '', true, true, false, true)
on conflict (key) do nothing;

-- the plain acceptance letter, rewritten for a notice served in full and switched back on; and the early-release letter
do $m$
declare v text := gen_random_uuid()::text; v_body text; v3 text := gen_random_uuid()::text; v_body3 text;
begin
  v_body := $t$Date: {{letter_date}}
PRIVATE & CONFIDENTIAL

To:
{{employee_name}}
{{address_line1}}
{{address_line2}}
{{postcode_town}}
{{state}}

Dear {{employee_name}},

Subject: Acceptance of Resignation and Confirmation of Last Working Day

We refer to your resignation letter dated [b]{{resignation_date}}[/b], concerning your position as [b]{{current_position}}[/b] with {{company_name}}.
The Company hereby acknowledges and accepts your resignation, subject to the following terms and arrangements.

[b]1. Notice Period and Last Working Day[/b]
Based on your length of service, your notice period is [b]{{notice_period}}[/b], counted from [b]{{notice_start_date}}[/b]. You will serve your notice in full, and your last working day and official employment end date shall be [b]{{last_notice_date}} ({{lastnotice_day}})[/b].

[b]2. Accrued Annual Leave[/b]
Based on your employment period from [b]{{start_datetime}}[/b] to [b]{{last_notice_date}}[/b], your annual leave for the final year has been calculated as follows:

Description | Details
Annual Leave Entitlement | {{leave_entitlement}} days per annum
Pro-rated Annual Leave | {{months_worked}}/12 × {{leave_entitlement}} days
Total Accrued Annual Leave | {{calculated_leaves}} days
Annual Leave Taken (as of {{al_asofdate}}) | {{al_taken}} days
Balance Annual Leave | {{al_balance}} days

Any accrued annual leave not taken by your last working day shall be paid in your final salary at your ordinary rate of pay ({{daily_rate}} a day), in accordance with Sections 60E and 60I of the Employment Act 1955. Annual leave taken in excess of your accrued entitlement shall be deducted at the same rate.

[b]3. Duties and Responsibilities During Notice Period[/b]
Until your last working day, you are required to:
• Continue performing your assigned duties responsibly and professionally.
• Complete all outstanding assignments and responsibilities.
• Ensure a proper and comprehensive handover of all ongoing projects, documents, records and work-related matters.
• Cooperate with Management and designated personnel to ensure a smooth transition.
All handover responsibilities must be completed on or before [b]{{last_notice_date}}[/b], unless otherwise mutually agreed in writing.

[b]4. Return of Company Property[/b]
You are required to return all Company property in your possession or under your responsibility on or before your last working day, including but not limited to:
• Employee Handbook and Company documents.
• Company uniforms, identification cards, keys and access devices, where applicable.
• Company equipment, electronic devices and other assigned assets.
• Work-related files, records, documents and materials.
• Any other property belonging to {{company_name}} or its related companies.
You must also ensure that all Company-related information, electronic records and access credentials are properly handed over to the authorised personnel.

[b]5. Confidentiality and Post-Employment Obligations[/b]
You are reminded that all confidential Company information, including business operations, financial information, customer records, employee information, business strategies and proprietary materials, must remain strictly confidential.
You shall not disclose, retain, reproduce or misuse such information after the termination of your employment, except as permitted by law or authorised by the Company.
You are also required to comply with all applicable post-employment obligations under your employment agreement, including any legally enforceable confidentiality and non-solicitation obligations.

[b]6. Final Salary and Employment Settlement[/b]
Your final salary and any other employment entitlements payable up to [b]{{last_notice_date}}[/b] shall be calculated and processed in accordance with your employment contract, Company policies and applicable Malaysian employment laws.
The final settlement shall include, where applicable:
• Salary earned up to the official employment end date.
• Payment for unused accrued annual leave, or a deduction for annual leave taken in excess, as set out above.
• Applicable statutory contributions and deductions.
• Any other lawful payments or deductions arising from your employment.
All outstanding duties, handover arrangements and return of Company property must be completed as required. Any outstanding clearance matters shall be addressed separately without prejudice to the Employee's statutory entitlement to timely payment of wages.

[b]7. Changes to the Agreed Arrangement[/b]
Should either party request a change to the confirmed last working day or official employment end date, the proposed change must be communicated and mutually agreed upon in writing.
No unilateral change shall be made to the agreed arrangement, except where otherwise permitted or required by applicable law. Any mutually agreed revision shall be documented and acknowledged by both parties.

[b]8. Acknowledgement and Appreciation[/b]
The Company appreciates your contributions and services during your employment with {{company_name}}.
We thank you for your efforts and wish you success in your future endeavours.

Yours sincerely,
For and on behalf of {{company_name}}
Name: {{authorized_signatory}}
Designation: {{authorized_designation}}

Employee Acknowledgement
I, {{employee_name}}, hereby acknowledge receipt of this Resignation Acceptance Letter and the arrangements stated herein concerning my notice period, last working day, accrued annual leave and handover obligations.

Employee Signature: __________________________
Name: {{employee_name}}
NRIC: __________________________
Date: __________________________$t$;
  if exists (select 1 from public.hr_letter_templates where code = 'RL' and strpos(body, '{{notice_start_date}}') = 0) then
    update public.hr_letter_templates set title = 'Resignation Acceptance Letter — Full Notice', body = v_body, version = v, active = true, status = 'published', updated_at = now() where code = 'RL';
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason)
    values ('RL', v, 'Resignation Acceptance Letter — Full Notice', v_body, auth.uid(), 'Rewritten for a notice served in full and switched back on (resignation calculator)');
  end if;

  v_body3 := $t$Date: {{letter_date}}
PRIVATE & CONFIDENTIAL

To:
{{employee_name}}
{{address_line1}}
{{address_line2}}
{{postcode_town}}
{{state}}

Dear {{employee_name}},

Subject: Acceptance of Resignation and Early Release from Notice Period

We refer to your resignation letter dated [b]{{resignation_date}}[/b], concerning your position as [b]{{current_position}}[/b] with {{company_name}}.
The Company hereby acknowledges and accepts your resignation, subject to the following terms and arrangements.

[b]1. Notice Period[/b]
Based on your length of service, your notice period is [b]{{notice_period}}[/b], counted from [b]{{notice_start_date}}[/b] and ending on [b]{{last_notice_date}} ({{lastnotice_day}})[/b].

[b]2. Early Release and Employment End Date[/b]
The Company agrees that you will leave before the end of your notice period, as follows:

Description | Details
Notice Period | {{notice_period}}, ending {{last_notice_date}} ({{lastnotice_day}})
Final Physical Working Day | {{last_working_day}} ({{lastday_day}})
Annual Leave Used Before the End Date | {{al_offset_days}} days ({{al_offset_period}})
Official Employment End Date | {{employment_end_date}} ({{employment_end_day}})
Notice Not Served | {{short_notice_days}} calendar days

[b]3. Notice Not Served[/b]
{{notice_in_lieu_terms}}

[b]4. Accrued Annual Leave[/b]
Based on your employment period from [b]{{start_datetime}}[/b] to [b]{{employment_end_date}}[/b], your annual leave for the final year has been calculated as follows:

Description | Details
Annual Leave Entitlement | {{leave_entitlement}} days per annum
Pro-rated Annual Leave | {{months_worked}}/12 × {{leave_entitlement}} days
Total Accrued Annual Leave | {{calculated_leaves}} days
Annual Leave Taken (as of {{al_asofdate}}) | {{al_taken}} days
Balance Annual Leave | {{al_balance}} days
Used Before the End Date | {{al_offset_days}} days
Paid in Final Salary | {{al_payout_days}} days × {{daily_rate}} = {{al_payout_amount}}

Unused accrued annual leave is paid at your ordinary rate of pay (monthly basic salary ÷ 26), in accordance with Sections 60E and 60I of the Employment Act 1955. A negative figure means annual leave taken in excess of your accrued entitlement, which is deducted at the same rate.

[b]5. Final Settlement Summary[/b]
Description | Amount
Annual leave paid / (deducted) | {{al_payout_amount}}
Notice not served | {{notice_in_lieu_amount}}
Net amount added to / (deducted from) your final salary | {{net_settlement}}

Your final salary up to [b]{{employment_end_date}}[/b] and the amounts above, together with the applicable statutory contributions and deductions, shall be processed in accordance with your employment contract, Company policies and applicable Malaysian employment laws. Should the amount due from you exceed the final salary payable, the Company will inform you in writing of the balance and how it is to be settled.

[b]6. Duties, Handover and Company Property[/b]
Until your final physical working day, you are required to continue performing your duties, complete outstanding assignments, and hand over all ongoing work, documents, records and access credentials to the authorised personnel.
All Company property in your possession, including documents, uniforms, identification cards, keys, access devices, equipment and work materials, must be returned on or before [b]{{last_working_day}}[/b].

[b]7. Confidentiality and Post-Employment Obligations[/b]
All confidential Company information must remain strictly confidential. You shall not disclose, retain, reproduce or misuse such information after the termination of your employment, except as permitted by law or authorised by the Company. You are also required to comply with all applicable post-employment obligations under your employment agreement.

[b]8. Changes to the Agreed Arrangement[/b]
Any change to the final physical working day, the annual leave arrangement or the official employment end date must be mutually agreed upon in writing by both parties.

[b]9. Acknowledgement and Appreciation[/b]
The Company appreciates your contributions and services during your employment with {{company_name}} and wishes you success in your future endeavours.

Yours sincerely,
For and on behalf of {{company_name}}
Name: {{authorized_signatory}}
Designation: {{authorized_designation}}

Employee Acknowledgement
I, {{employee_name}}, hereby acknowledge receipt of this letter and agree to the early release, the employment end date, the annual leave arrangement and the final settlement stated herein.

Employee Signature: __________________________
Name: {{employee_name}}
NRIC: __________________________
Date: __________________________$t$;
  if not exists (select 1 from public.hr_letter_templates where code = 'RL_TP3') then
    insert into public.hr_letter_templates (code, title, version, body, active, status, letter_type, format)
    values ('RL_TP3', 'Resignation Acceptance Letter — Early Release (Notice in Lieu)', v3, v_body3, true, 'published', 'RL', 'text');
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason)
    values ('RL_TP3', v3, 'Resignation Acceptance Letter — Early Release (Notice in Lieu)', v_body3, auth.uid(), 'New: early release with notice in lieu (resignation calculator)');
  end if;
end $m$;
