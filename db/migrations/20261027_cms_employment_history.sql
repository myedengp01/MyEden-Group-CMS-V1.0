-- MyEden Group CMS V1.0 · Employment history: transfers between companies, past employment periods, pay lines that follow them
-- For people whose path is not one straight line (e.g. part-time at one company, transferred to another, resigned, came back on a
-- temporary contract). On the employee profile, tab "History":
--   * each employment period with its dates, how it ended, full / part time, centre, job title and its paying-company parts
--   * the employer of record over time (master company) — kept in cms_employer_periods; the master company on the Employee Master
--     follows the period that covers today (or the latest one)
--   * Transfer from a date: change the employer of record, the paying company or both (service stays continuous). Salary and
--     allowances carry over to the new paying company.
--   * Add a past employment period (e.g. a temporary rehire that has already ended), with its paying company and employer.
--   * Change how / when a past period ended.
--   * Pay-line check: months whose pay line is not under the paying company of that month; a Super Admin can move them
--     (amounts unchanged, finalised months stay finalised, company totals moved, one audit entry per month).
-- Who: the new permission "Employment history" (people.history; Admin and HR by default, can be given to other roles).
-- Moving pay lines: Super Admin only. Join dates of existing periods stay locked. Every change needs a reason and is logged.
-- The current period's start and leaving still go through Add Person / Rehire / Leaving as before.

insert into public.cms_modules (code, label, grp, phase, sort_order, kind, parent, acts, act_labels, description, from_phase, locked) values
  ('people.history', 'Employment history', 'People & Employment', 4, 1012, 'special', 'people', 'V', '{}'::jsonb,
   'Transfers between companies, past employment periods and how they ended, on the profile', null, false)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions)
select r, 'people.history', 'V' from (values ('admin'), ('hr')) t(r) where exists (select 1 from public.cms_roles where code = t.r)
on conflict (role_code, module_code) do nothing;
insert into public.cms_role_permission_defaults (role_code, module_code, actions)
select role_code, module_code, actions from public.cms_role_permissions where module_code = 'people.history' and actions <> ''
on conflict (role_code, module_code) do nothing;

-- employer of record over time
create table if not exists public.cms_employer_periods (
  id bigint generated always as identity primary key,
  person_id uuid not null references public.employee_master(id) on delete cascade,
  company_code text not null check (company_code in ('MEG', 'MEH', 'HD', 'ABP')),
  start_date date not null,
  end_date date,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index if not exists cms_employer_periods_person on public.cms_employer_periods (person_id, start_date);
alter table public.cms_employer_periods enable row level security;
revoke all on public.cms_employer_periods from anon, authenticated;

-- the master company follows the employer period that covers today, else the latest one
create or replace function private.cms_sync_master_company(p_person uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare v text; d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select company_code into v from public.cms_employer_periods where person_id = p_person
   order by (start_date <= d and (end_date is null or end_date >= d)) desc, start_date desc limit 1;
  if v is not null then update public.employee_master set company_code = v, updated_at = now() where id = p_person and company_code is distinct from v; end if;
end $f$;
revoke all on function private.cms_sync_master_company(uuid) from public, anon, authenticated;

-- first day of service (earliest join) and the employer periods seeded from the master record when there are none yet
create or replace function private.cms_seed_employer_periods(p_person uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; v_start date;
begin
  if exists (select 1 from public.cms_employer_periods where person_id = p_person) then return; end if;
  select * into em from public.employee_master where id = p_person;
  select min(m.join_date) into v_start from public.eppd_employments m join public.eppd_employees ee on ee.id = m.employee_id where ee.employee_master_id = p_person;
  v_start := coalesce(v_start, em.start_date, em.original_group_join_date);
  if v_start is null or private.cms_canon(em.company_code) not in ('MEG', 'MEH', 'HD', 'ABP') then return; end if;
  insert into public.cms_employer_periods (person_id, company_code, start_date, end_date, note)
  values (p_person, private.cms_canon(em.company_code), v_start, null, 'From the master record');
end $f$;
revoke all on function private.cms_seed_employer_periods(uuid) from public, anon, authenticated;

-- the pay line's day of reference: the month end, or the last day of the employment when it ended that month
create or replace function private.cms_expected_assignment(p_emp bigint, p_period date) returns bigint
language sql stable security definer set search_path = public, pg_temp as $f$
  select a.id from public.eppd_employments m join public.eppd_assignments a on a.employment_id = m.id and a.is_primary
   where m.employee_id = p_emp and m.join_date <= (p_period + interval '1 month' - interval '1 day')::date
     and (m.resigned_date is null or m.resigned_date >= p_period)
     and daterange(a.start_date, a.end_date, '[]') @> least((p_period + interval '1 month' - interval '1 day')::date, coalesce(m.resigned_date, 'infinity'::date))
   order by m.join_date desc, a.start_date desc nulls last limit 1 $f$;
revoke all on function private.cms_expected_assignment(bigint, date) from public, anon, authenticated;

-- move one pay line to another assignment / company: amounts unchanged; the month's stored company totals move with it
create or replace function private.cms_payline_move(p_line bigint, p_assignment bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.eppd_pay_lines; ru public.eppd_pay_runs; a public.eppd_assignments; d jsonb; k text; c1 jsonb; c2 jsonb; fco text; tco text;
  keys text[] := array['gross','net','pcb','eis_ee','eis_er','epf_ee','epf_er','net_paid','socso_ee','socso_er','socso_ee_nei','reimbursements','personal_deductions','employer_cost','lines'];
begin
  select * into l from public.eppd_pay_lines where id = p_line for update;
  select * into a from public.eppd_assignments where id = p_assignment;
  if l.id is null or a.id is null then raise exception 'Pay line or paying company not found.'; end if;
  if l.assignment_id = a.id and l.company_id = a.company_id then return null; end if;
  select * into ru from public.eppd_pay_runs where id = l.run_id for update;
  select code into fco from public.eppd_companies where id = l.company_id; select code into tco from public.eppd_companies where id = a.company_id;
  perform set_config('eppd.pay_unlock', 'on', true);
  if l.company_id is distinct from a.company_id and not l.excluded and ru.totals ? 'companies' then
    d := jsonb_build_object('gross', l.gross, 'net', l.net, 'pcb', l.pcb, 'eis_ee', l.eis_ee, 'eis_er', l.eis_er, 'epf_ee', l.epf_ee, 'epf_er', l.epf_er,
      'net_paid', l.net_paid, 'socso_ee', l.socso_ee, 'socso_er', l.socso_er, 'socso_ee_nei', l.socso_ee_nei, 'reimbursements', l.reimbursements,
      'personal_deductions', l.personal_deductions, 'employer_cost', coalesce(l.gross, 0) + coalesce(l.epf_er, 0) + coalesce(l.socso_er, 0) + coalesce(l.eis_er, 0), 'lines', 1);
    c1 := coalesce(ru.totals->'companies'->(coalesce(l.company_id, 0)::text), '{}'); c2 := coalesce(ru.totals->'companies'->(a.company_id::text), '{}');
    foreach k in array keys loop
      c1 := c1 || jsonb_build_object(k, round(coalesce((c1->>k)::numeric, 0) - coalesce((d->>k)::numeric, 0), 2));
      c2 := c2 || jsonb_build_object(k, round(coalesce((c2->>k)::numeric, 0) + coalesce((d->>k)::numeric, 0), 2));
    end loop;
    ru.totals := jsonb_set(jsonb_set(ru.totals, array['companies', coalesce(l.company_id, 0)::text], c1), array['companies', a.company_id::text], c2);
    if (c1->>'lines')::numeric <= 0 then ru.totals := jsonb_set(ru.totals, '{companies}', (ru.totals->'companies') - coalesce(l.company_id, 0)::text); end if;
    update public.eppd_pay_runs set totals = ru.totals where id = ru.id;
  end if;
  update public.eppd_pay_lines set assignment_id = a.id, company_id = a.company_id where id = l.id;
  perform private.cms_log('payroll.correct', 'eppd_pay_runs', ru.id::text, tco,
    l.emp_name || ' ' || to_char(ru.period, 'Mon YYYY') || ': pay line moved' || case when fco is distinct from tco then ' from ' || coalesce(fco, 'no company') || ' to ' || tco else ' to the right paying-company period' end
      || '; amounts unchanged · ' || btrim(p_reason),
    jsonb_build_object('line_id', l.id, 'from', fco, 'to', tco, 'from_assignment', l.assignment_id, 'to_assignment', a.id, 'gross', l.gross, 'run_status', ru.status, 'reason', btrim(p_reason)));
  return jsonb_build_object('line', l.id, 'period', ru.period, 'from', fco, 'to', tco);
end $f$;
revoke all on function private.cms_payline_move(bigint, bigint, text) from public, anon, authenticated;

create or replace function private.cms_history_require(p_person uuid) returns public.employee_master
language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  if not (public.cms_is_super_admin() or (public.cms_can('people.history', 'V') and public.cms_can('people', 'V', private.cms_canon(em.company_code)))) then
    raise exception 'Changing employment history needs "Employment history".' using errcode = '42501'; end if;
  return em;
end $f$;
revoke all on function private.cms_history_require(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------ read
create or replace function public.cms_person_history(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees;
begin
  em := private.cms_history_require(p_person);
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  return jsonb_build_object(
    'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code), 'start', em.start_date, 'status', em.employment_status,
    'has_payroll', ee.id is not null, 'can_move', public.cms_is_super_admin(),
    'employments', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'join', m.join_date, 'end', m.resigned_date, 'end_reason', m.leaving_reason,
        'end_reason_label', (select l.label from public.eppd_lookups l where l.category = 'leaving_reason' and l.code = m.leaving_reason), 'end_note', m.leaving_note,
        'job_status', m.job_status, 'emp_status', m.confirmation_status, 'dept', d.code, 'dept_name', d.name, 'title', t.name,
        'assignments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'company', c.code, 'company_name', c.name, 'from', a.start_date, 'to', a.end_date, 'primary', a.is_primary,
            'salary', (select jsonb_build_object('amount', h.amount, 'basis', h.pay_basis, 'from', h.effective_from) from public.eppd_salary_history h where h.assignment_id = a.id order by h.effective_from desc limit 1))
            order by a.start_date nulls first) from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id where a.employment_id = m.id), '[]'::jsonb))
        order by m.join_date)
      from public.eppd_employments m left join public.eppd_departments d on d.id = m.department_id left join public.eppd_job_titles t on t.id = m.job_title_id
      where m.employee_id = ee.id), '[]'::jsonb),
    'employers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'company', p.company_code, 'from', p.start_date, 'to', p.end_date, 'note', p.note) order by p.start_date)
      from public.cms_employer_periods p where p.person_id = em.id), '[]'::jsonb),
    'pay_check', coalesce((select jsonb_agg(x order by x->>'period') from (
        select jsonb_build_object('line', l.id, 'period', r.period, 'run_status', r.status, 'company', c.code, 'gross', l.gross,
          'expected_assignment', ex.id, 'expected', ec.code, 'ok', (ex.id is null or ex.id = l.assignment_id or
             exists (select 1 from public.eppd_assignments a2 where a2.id = l.assignment_id and a2.company_id = l.company_id
               and daterange(a2.start_date, a2.end_date, '[]') && daterange(r.period, (r.period + interval '1 month')::date, '[)')
               and not a2.is_primary))) x
        from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id left join public.eppd_companies c on c.id = l.company_id
        left join public.eppd_assignments ex on ex.id = private.cms_expected_assignment(ee.id, r.period) left join public.eppd_companies ec on ec.id = ex.company_id
        where l.employee_id = ee.id) q), '[]'::jsonb),
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name) order by array_position(array['MEG', 'MEH', 'HD', 'ABP'], c.code))
                  from public.cms_companies c where c.code in ('MEG', 'MEH', 'HD', 'ABP')),
    'departments', (select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name', d.name) order by d.sort_order, d.code) from public.eppd_departments d where d.is_active),
    'titles', (select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.sort_order, t.name) from public.eppd_job_titles t where t.is_active),
    'job_statuses', (select jsonb_agg(jsonb_build_object('code', l.code, 'label', l.label) order by l.sort_order) from public.eppd_lookups l where l.category = 'job_status' and l.is_active),
    'leaving_reasons', (select jsonb_agg(jsonb_build_object('code', l.code, 'label', l.label, 'needs_note', coalesce((l.meta->>'needs_note')::boolean, false)) order by l.sort_order)
                        from public.eppd_lookups l where l.category = 'leaving_reason' and l.is_active and l.code <> 'NOT_JOINED'));
end $f$;
revoke all on function public.cms_person_history(uuid) from public, anon;
grant execute on function public.cms_person_history(uuid) to authenticated;

-- ------------------------------------------------------------------ transfer from a date (employer, paying company, or both)
create or replace function public.cms_person_transfer(p_person uuid, p jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; m public.eppd_employments; a public.eppd_assignments; na bigint; v_date date; v_end date;
        v_pay text; v_emp text; pc public.eppd_companies; ep public.cms_employer_periods; done text[] := '{}'; s public.eppd_salary_history; al record;
begin
  em := private.cms_history_require(p_person);
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  v_date := nullif(p->>'date', '')::date; if v_date is null then raise exception 'Choose the date the transfer takes effect.'; end if;
  v_pay := nullif(p->>'paying', ''); v_emp := nullif(p->>'employer', '');
  if v_pay is null and v_emp is null then raise exception 'Choose the new employer of record, the new paying company, or both.'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is null then raise exception 'This person has no payroll record yet.'; end if;
  select * into m from public.eppd_employments where employee_id = ee.id and join_date <= v_date and (resigned_date is null or resigned_date >= v_date) order by join_date desc limit 1 for update;
  if m.id is null then raise exception 'No employment period covers %. Add the period first.', to_char(v_date, 'DD Mon YYYY'); end if;
  if v_date <= m.join_date then raise exception 'A transfer takes effect after the first day of the period (the period starts %).', to_char(m.join_date, 'DD Mon YYYY'); end if;

  if v_pay is not null then
    select * into pc from public.eppd_companies where code = v_pay; if pc.id is null then raise exception 'Choose the paying company.'; end if;
    select * into a from public.eppd_assignments where employment_id = m.id and is_primary and daterange(start_date, end_date, '[]') @> v_date for update;
    if a.id is null then raise exception 'No main paying company on % to transfer from.', to_char(v_date, 'DD Mon YYYY'); end if;
    if a.company_id = pc.id then raise exception 'Already paid by % on that date.', pc.name; end if;
    v_end := a.end_date;
    update public.eppd_assignments set end_date = v_date - 1 where id = a.id;
    insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
    values (m.id, pc.id, true, v_date, v_end, a.epf_ee, a.epf_er, a.socso_ee, a.socso_er, a.eis_ee, a.eis_er, a.socso_nei_opt_out) returning id into na;
    -- salary: later changes move with the new paying company; the salary in force on the date is carried over
    update public.eppd_salary_history set assignment_id = na where assignment_id = a.id and effective_from >= v_date;
    if not exists (select 1 from public.eppd_salary_history where assignment_id = na and effective_from <= v_date) then
      select * into s from public.eppd_salary_history where assignment_id = a.id and effective_from < v_date order by effective_from desc limit 1;
      if s.id is not null then insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
        values (na, v_date, s.amount, s.pay_basis, 'Carried over on transfer', 'Transfer to ' || pc.name || ' · ' || btrim(p_reason)); end if;
    end if;
    -- allowances: running ones continue under the new paying company
    for al in select * from public.eppd_allowances where assignment_id = a.id and (end_date is null or end_date >= v_date) loop
      if al.start_date is not null and al.start_date >= v_date then update public.eppd_allowances set assignment_id = na where id = al.id;
      else
        update public.eppd_allowances set end_date = v_date - 1 where id = al.id;
        insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note) values (na, al.payment_type_id, al.amount, v_date, al.end_date, al.note);
      end if;
    end loop;
    done := done || ('paid by ' || pc.code);
  end if;

  if v_emp is not null then
    if v_emp not in ('MEG', 'MEH', 'HD', 'ABP') then raise exception 'Choose the employer of record.'; end if;
    perform private.cms_seed_employer_periods(em.id);
    select * into ep from public.cms_employer_periods where person_id = em.id and start_date <= v_date and (end_date is null or end_date >= v_date) order by start_date desc limit 1 for update;
    if ep.id is null then
      insert into public.cms_employer_periods (person_id, company_code, start_date, end_date, note) values (em.id, v_emp, v_date, m.resigned_date, btrim(p_reason));
    elsif ep.company_code = v_emp then raise exception 'Already employed by % on that date.', v_emp;
    elsif ep.start_date = v_date then update public.cms_employer_periods set company_code = v_emp, note = btrim(p_reason) where id = ep.id;
    else
      update public.cms_employer_periods set end_date = v_date - 1 where id = ep.id;
      insert into public.cms_employer_periods (person_id, company_code, start_date, end_date, note) values (em.id, v_emp, v_date, ep.end_date, btrim(p_reason));
    end if;
    perform private.cms_sync_master_company(em.id);
    done := done || ('employer ' || v_emp);
  end if;

  -- what the person does from the transfer (the period keeps one current value)
  if nullif(p->>'job_status', '') is not null or nullif(p->>'title_id', '') is not null or nullif(p->>'dept_id', '') is not null then
    update public.eppd_employments set job_status = coalesce(nullif(p->>'job_status', ''), job_status), job_title_id = coalesce(nullif(p->>'title_id', '')::bigint, job_title_id),
      department_id = coalesce(nullif(p->>'dept_id', '')::bigint, department_id) where id = m.id;
    if m.resigned_date is null then
      update public.employee_master set approved_job_title = coalesce((select name from public.eppd_job_titles where id = nullif(p->>'title_id', '')::bigint), approved_job_title),
        department = coalesce((select code from public.eppd_departments where id = nullif(p->>'dept_id', '')::bigint), department), updated_at = now() where id = em.id;
    end if;
    done := done || 'job details'::text;
  end if;

  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'transferred', 'From ' || to_char(v_date, 'DD Mon YYYY') || ': ' || array_to_string(done, ', ') || ' · ' || btrim(p_reason), p || jsonb_build_object('reason', btrim(p_reason)), auth.uid());
  perform private.cms_log('person.transfer', 'employee_master', em.id::text, private.cms_canon((select company_code from public.employee_master where id = em.id)),
    em.employee_name || ': transfer from ' || to_char(v_date, 'DD Mon YYYY') || ' (' || array_to_string(done, ', ') || ') · ' || btrim(p_reason), p || jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('done', done);
end $f$;
revoke all on function public.cms_person_transfer(uuid, jsonb, text) from public, anon;
grant execute on function public.cms_person_transfer(uuid, jsonb, text) to authenticated;

-- ------------------------------------------------------------------ add a past employment period (already ended)
create or replace function public.cms_person_period_add(p_person uuid, p jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; v_start date; v_end date; pc public.eppd_companies; v_emp text; nm bigint; na bigint; last public.eppd_assignments;
begin
  em := private.cms_history_require(p_person);
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is null then raise exception 'This person has no payroll record yet.'; end if;
  v_start := nullif(p->>'start', '')::date; v_end := nullif(p->>'end', '')::date;
  if v_start is null or v_end is null then raise exception 'Give the first and last day of the period (a period still running is added with Rehire).'; end if;
  if v_end < v_start then raise exception 'The last day is before the first day.'; end if;
  if v_end > (now() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'Only a period that has already ended can be added here; for a current one use Rehire.'; end if;
  if nullif(p->>'end_reason', '') is null then raise exception 'Choose how the period ended.'; end if;
  if exists (select 1 from public.eppd_employments m where m.employee_id = ee.id and daterange(m.join_date, m.resigned_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'This period overlaps another employment period. Change that one first.'; end if;
  select * into pc from public.eppd_companies where code = p->>'paying'; if pc.id is null then raise exception 'Choose the paying company.'; end if;
  v_emp := coalesce(nullif(p->>'employer', ''), pc.code); if v_emp not in ('MEG', 'MEH', 'HD', 'ABP') then raise exception 'Choose the employer of record.'; end if;
  select a.* into last from public.eppd_assignments a join public.eppd_employments m on m.id = a.employment_id where m.employee_id = ee.id order by a.start_date desc nulls last limit 1;

  perform private.cms_seed_employer_periods(em.id);
  insert into public.eppd_employments (employee_id, join_date, resigned_date, job_status, job_title_id, department_id, confirmation_status, leaving_reason, leaving_note,
                                       work_from, work_to, meal_hours, ot_days, ot_multiplier, weekly_hours)
  select ee.id, v_start, v_end, nullif(p->>'job_status', ''), nullif(p->>'title_id', '')::bigint, nullif(p->>'dept_id', '')::bigint,
         case when p->>'end_reason' in ('TERM_PERF', 'TERM_MISC') then 'TR' when p->>'end_reason' = 'DISMISSED' then 'DM' else 'R' end, p->>'end_reason', nullif(btrim(coalesce(p->>'end_note', '')), ''),
         x.work_from, x.work_to, x.meal_hours, x.ot_days, x.ot_multiplier, x.weekly_hours
    from (select * from public.eppd_employments where employee_id = ee.id order by join_date desc limit 1) x
  union all select ee.id, v_start, v_end, nullif(p->>'job_status', ''), nullif(p->>'title_id', '')::bigint, nullif(p->>'dept_id', '')::bigint,
         'R', p->>'end_reason', nullif(btrim(coalesce(p->>'end_note', '')), ''), null, null, null, null, null, null
   where not exists (select 1 from public.eppd_employments where employee_id = ee.id)
  returning id into nm;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
  values (nm, pc.id, true, v_start, v_end, coalesce(last.epf_ee, true), coalesce(last.epf_er, true), coalesce(last.socso_ee, true), coalesce(last.socso_er, true),
          coalesce(last.eis_ee, true), coalesce(last.eis_er, true), coalesce(last.socso_nei_opt_out, false)) returning id into na;
  if nullif(p->>'salary', '') is not null then
    insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
    values (na, v_start, replace(p->>'salary', ',', '')::numeric, coalesce(nullif(p->>'basis', ''), 'monthly'), 'Salary for this period', btrim(p_reason));
  end if;
  -- the employer of record for those dates
  update public.cms_employer_periods set end_date = v_start - 1 where person_id = em.id and start_date < v_start and (end_date is null or end_date >= v_start);
  if exists (select 1 from public.cms_employer_periods where person_id = em.id and daterange(start_date, end_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'The employer of record already has a period inside these dates. Change it with Transfer.'; end if;
  insert into public.cms_employer_periods (person_id, company_code, start_date, end_date, note) values (em.id, v_emp, v_start, v_end, btrim(p_reason));
  update public.employee_master set actual_last_working_date = greatest(coalesce(actual_last_working_date, v_end), v_end), updated_at = now()
   where id = em.id and employment_status = 'former';
  perform private.cms_sync_master_company(em.id);
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'employment_period_added', to_char(v_start, 'DD Mon YYYY') || ' – ' || to_char(v_end, 'DD Mon YYYY') || ', paid by ' || pc.code || ', employer ' || v_emp || ' · ' || btrim(p_reason),
          p || jsonb_build_object('reason', btrim(p_reason)), auth.uid());
  perform private.cms_log('person.period', 'employee_master', em.id::text, v_emp,
    em.employee_name || ': employment period added ' || to_char(v_start, 'DD Mon YYYY') || ' – ' || to_char(v_end, 'DD Mon YYYY') || ' · ' || btrim(p_reason), p || jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('employment', nm, 'assignment', na);
end $f$;
revoke all on function public.cms_person_period_add(uuid, jsonb, text) from public, anon;
grant execute on function public.cms_person_period_add(uuid, jsonb, text) to authenticated;

-- ------------------------------------------------------------------ change how / when a past period ended
create or replace function public.cms_person_period_end(p_person uuid, p_employment bigint, p jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; m public.eppd_employments; v_end date;
begin
  em := private.cms_history_require(p_person);
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  select * into m from public.eppd_employments where id = p_employment and employee_id = ee.id for update;
  if m.id is null then raise exception 'Employment period not found.'; end if;
  if m.resigned_date is null then raise exception 'This period is still running: use Leaving to end it.'; end if;
  v_end := coalesce(nullif(p->>'end', '')::date, m.resigned_date);
  if v_end < m.join_date then raise exception 'The last day is before the first day of the period.'; end if;
  if exists (select 1 from public.eppd_employments x where x.employee_id = ee.id and x.id <> m.id and daterange(x.join_date, x.resigned_date, '[]') && daterange(m.join_date, v_end, '[]')) then
    raise exception 'The new last day overlaps the next employment period.'; end if;
  update public.eppd_employments set resigned_date = v_end, leaving_reason = coalesce(nullif(p->>'end_reason', ''), leaving_reason),
    leaving_note = case when p ? 'end_note' then nullif(btrim(p->>'end_note'), '') else leaving_note end where id = m.id;
  update public.eppd_assignments set end_date = v_end where employment_id = m.id and end_date = m.resigned_date;
  update public.cms_employer_periods set end_date = v_end where person_id = em.id and end_date = m.resigned_date;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'employment_period_changed', 'Period from ' || to_char(m.join_date, 'DD Mon YYYY') || ' now ends ' || to_char(v_end, 'DD Mon YYYY') || ' · ' || btrim(p_reason),
          p || jsonb_build_object('employment', m.id, 'previous_end', m.resigned_date, 'reason', btrim(p_reason)), auth.uid());
  perform private.cms_log('person.period', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': period from ' || to_char(m.join_date, 'DD Mon YYYY') || ' ends ' || to_char(v_end, 'DD Mon YYYY') || ' · ' || btrim(p_reason), p || jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('end', v_end);
end $f$;
revoke all on function public.cms_person_period_end(uuid, bigint, jsonb, text) from public, anon;
grant execute on function public.cms_person_period_end(uuid, bigint, jsonb, text) to authenticated;

-- ------------------------------------------------------------------ Super Admin: move pay lines to the paying company of their month
create or replace function public.cms_person_paylines_move(p_person uuid, p_lines bigint[], p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; l record; ex bigint; out jsonb := '[]'::jsonb; r jsonb;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can move pay lines.' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  select * into em from public.employee_master where id = p_person;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is null then raise exception 'Person not found.'; end if;
  for l in select pl.id, r0.period from public.eppd_pay_lines pl join public.eppd_pay_runs r0 on r0.id = pl.run_id where pl.employee_id = ee.id and pl.id = any(p_lines) order by r0.period loop
    ex := private.cms_expected_assignment(ee.id, l.period);
    if ex is null then raise exception 'No paying company covers %; fix the history first.', to_char(l.period, 'Mon YYYY'); end if;
    r := private.cms_payline_move(l.id, ex, p_reason); if r is not null then out := out || jsonb_build_array(r); end if;
  end loop;
  return jsonb_build_object('moved', out);
end $f$;
revoke all on function public.cms_person_paylines_move(uuid, bigint[], text) from public, anon;
grant execute on function public.cms_person_paylines_move(uuid, bigint[], text) to authenticated;

-- the master company of someone with an employer history is changed through Transfer, not Edit master record
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.cms_person_master_save(uuid,jsonb,text)'::regprocedure);
  if strpos(d, 'cms_employer_periods') > 0 then return; end if;
  n := replace(d, $x$  v_co := coalesce(nxt->>'company', cur->>'company');$x$,
    $x$  v_co := coalesce(nxt->>'company', cur->>'company');
  if nxt ? 'company' and exists (select 1 from public.cms_employer_periods where person_id = p_person) then
    raise exception 'This person has an employer history: change the master company with Transfer in the History tab.'; end if;$x$);
  if n = d then raise exception 'cms_person_master_save patch point not found'; end if;
  execute n;
end $m$;
