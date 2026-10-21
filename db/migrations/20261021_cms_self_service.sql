-- MyEden Group CMS V1.0 · Phase 4a · Staff self-service: access switches, Reports-to, My Profile, My Payslips, EA forms, salary history
-- Everything is OFF by default. HR / Admin switch each part on per person (Self-service access page);
-- payslips are released per month and EA forms per year, and only finalised payroll months can be seen.
-- Staff only ever reach their own records, through the functions below (tables have RLS on and no policies).

-- ------------------------------------------------------------------ module + permissions
insert into public.cms_modules (code, grp, label, phase, sort_order)
values ('selfservice', 'People & Employment', 'Self-service access', 4, 13)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'selfservice', 'VCEADX'), ('admin', 'selfservice', 'VCEADX'), ('hr', 'selfservice', 'VCE'), ('director', 'selfservice', 'V')
on conflict do nothing;

-- ------------------------------------------------------------------ Reports to
alter table public.employee_master add column if not exists reports_to_id uuid references public.employee_master(id) on delete set null;
create index if not exists employee_master_reports_to_idx on public.employee_master (reports_to_id);

-- ------------------------------------------------------------------ tables
create table if not exists public.cms_self_access (
  person_id uuid not null references public.employee_master(id) on delete cascade,
  part text not null check (part in ('profile','payslips','ea','salary','leave','claims','items','handbook')),
  enabled boolean not null default false,
  changed_by uuid, changed_at timestamptz not null default now(),
  primary key (person_id, part));
alter table public.cms_self_access enable row level security;

create table if not exists public.cms_doc_releases (
  person_id uuid not null references public.employee_master(id) on delete cascade,
  kind text not null check (kind in ('payslip','ea')),
  period date not null,                       -- payslip: first day of the month · EA: 1 January of the year
  released_by uuid, released_at timestamptz not null default now(),
  withdrawn_by uuid, withdrawn_at timestamptz,
  primary key (person_id, kind, period));
alter table public.cms_doc_releases enable row level security;

create table if not exists public.cms_profile_requests (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  changes jsonb not null,                     -- {field: new value}
  previous jsonb not null default '{}'::jsonb, -- the values when the request was made
  note text, attachment text,                 -- small image (data URL) for bank changes
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_by uuid, requested_at timestamptz not null default now(),
  decided_by uuid, decided_at timestamptz, decision_note text);
alter table public.cms_profile_requests enable row level security;
create index if not exists cms_profile_requests_person_idx on public.cms_profile_requests (person_id, status);

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_me()
returns uuid language sql stable security definer set search_path = public, pg_temp as $$
  select employee_master_id from public.cms_user_links where user_id = auth.uid() limit 1;
$$;

create or replace function private.cms_self_on(p_person uuid, p_part text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select enabled from public.cms_self_access where person_id = p_person and part = p_part), false);
$$;

-- the signed-in person, with the part switched on (else an error)
create or replace function private.cms_self_require(p_part text)
returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_me();
begin
  if v is null then raise exception 'This login is not linked to an employee record.'; end if;
  if not private.cms_self_on(v, p_part) then raise exception 'This page has not been switched on for you. Ask HR.'; end if;
  return v;
end $$;

create or replace function private.cms_person_is_director(p_person uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.employee_master where id = p_person and (serial_no = 1000 or approved_job_title ~* '\mdirector\M'));
$$;

-- payroll employee ids of a person
create or replace function private.cms_eppd_ids(p_person uuid)
returns bigint[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(id), '{}') from public.eppd_employees where employee_master_id = p_person;
$$;

-- one finalised pay line, shaped for a payslip
create or replace function private.cms_line_json(l public.eppd_pay_lines, p_period date)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(l) || jsonb_build_object('period', p_period);
$$;

-- ------------------------------------------------------------------ staff: what is switched on
create or replace function public.cms_my_self()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_me(); em public.employee_master;
begin
  if v is null then return null; end if;
  select * into em from public.employee_master where id = v;
  return jsonb_build_object(
    'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
    'title', em.approved_job_title, 'status', em.employment_status,
    'parts', coalesce((select jsonb_agg(part order by part) from public.cms_self_access where person_id = v and enabled), '[]'::jsonb),
    'payslips', (select count(*) from public.cms_doc_releases r where r.person_id = v and r.kind = 'payslip' and r.withdrawn_at is null),
    'profile_pending', (select count(*) from public.cms_profile_requests where person_id = v and status = 'pending'));
end $$;

-- ------------------------------------------------------------------ staff: My Profile
create or replace function private.cms_profile_values(p_person uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'contact', em.contact, 'email', em.email,
    'home_address', pv.home_address, 'emergency_name', pv.emergency_name, 'emergency_relation', pv.emergency_relation, 'emergency_phone', pv.emergency_phone,
    'bank_code', pv.bank_code, 'bank_account_no', pv.bank_account_no)
  from public.employee_master em
  left join lateral (select p.* from public.eppd_employee_private p join public.eppd_employees e on e.id = p.employee_id
                      where e.employee_master_id = em.id order by e.id desc limit 1) pv on true
  where em.id = p_person;
$$;

create or replace function public.cms_my_profile()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('profile'); em public.employee_master; pv public.eppd_employee_private; boss public.employee_master;
begin
  select * into em from public.employee_master where id = v;
  select p.* into pv from public.eppd_employee_private p join public.eppd_employees e on e.id = p.employee_id where e.employee_master_id = v order by e.id desc limit 1;
  select * into boss from public.employee_master where id = em.reports_to_id;
  return jsonb_build_object(
    'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code), 'status', em.employment_status,
    'title', em.approved_job_title, 'department', em.department, 'work_location', em.work_location, 'employment_type', em.employment_type,
    'start', em.start_date, 'group_join', em.original_group_join_date, 'confirmation', em.confirmation_status, 'confirmation_date', em.confirmation_date,
    'probation_end', em.probation_end_date, 'hours', case when em.working_from is not null then to_char(em.working_from, 'HH24:MI') || '–' || to_char(em.working_to, 'HH24:MI') end,
    'reports_to', case when boss.id is not null then boss.employee_name || coalesce(' · ' || boss.approved_job_title, '') else em.reporting_name end,
    'gender', em.gender_code, 'nric', pv.nric, 'passport_no', pv.passport_no, 'dob', pv.dob,
    'epf_no', pv.epf_no, 'socso_no', pv.socso_no, 'tax_no', pv.tax_no,
    'values', private.cms_profile_values(v),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups where category = 'bank' and is_active), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'changes', changes, 'previous', previous, 'note', note, 'status', status,
                  'requested_at', requested_at, 'decided_at', decided_at, 'decision_note', decision_note, 'has_attachment', attachment is not null) order by requested_at desc)
                  from (select * from public.cms_profile_requests where person_id = v order by requested_at desc limit 10) r), '[]'::jsonb));
end $$;

create or replace function public.cms_my_profile_request(p_changes jsonb, p_note text default null, p_attachment text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('profile'); cur jsonb; ch jsonb := '{}'::jsonb; k text; nv text; v_id uuid;
        allowed text[] := array['contact','email','home_address','emergency_name','emergency_relation','emergency_phone','bank_code','bank_account_no'];
begin
  cur := private.cms_profile_values(v);
  for k, nv in select key, nullif(btrim(value), '') from jsonb_each_text(coalesce(p_changes, '{}'::jsonb)) loop
    if not k = any(allowed) then raise exception 'Unknown field: %', k; end if;
    if nv is distinct from (cur->>k) then ch := ch || jsonb_build_object(k, nv); end if;
  end loop;
  if ch = '{}'::jsonb then raise exception 'Nothing has changed.'; end if;
  if (ch ? 'bank_code' or ch ? 'bank_account_no') and nullif(p_attachment, '') is null then
    raise exception 'Attach a photo of your bank statement or bank card for a bank change.';
  end if;
  if length(coalesce(p_attachment, '')) > 1500000 then raise exception 'The photo is too large.'; end if;
  if ch ? 'email' and (ch->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if exists (select 1 from public.cms_profile_requests where person_id = v and status = 'pending') then
    raise exception 'You already have a change waiting for HR. Cancel it first to send a new one.';
  end if;
  insert into public.cms_profile_requests (person_id, changes, previous, note, attachment, requested_by)
  values (v, ch, (select jsonb_object_agg(key, cur->key) from jsonb_object_keys(ch) key), nullif(btrim(p_note), ''), nullif(p_attachment, ''), auth.uid())
  returning cms_profile_requests.id into v_id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v, 'profile_change_requested', 'Profile change requested in self-service', jsonb_build_object('request_id', v_id, 'fields', (select jsonb_agg(k2) from jsonb_object_keys(ch) k2)), auth.uid());
  return v_id;
end $$;

create or replace function public.cms_my_profile_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('profile');
begin
  update public.cms_profile_requests set status = 'cancelled', decided_at = now(), decided_by = auth.uid()
   where id = p_id and person_id = v and status = 'pending';
  if not found then raise exception 'Request not found or already decided.'; end if;
end $$;

-- ------------------------------------------------------------------ staff: payslips, EA forms, salary history
create or replace function public.cms_my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_me(); ids bigint[]; ps boolean; ea boolean;
begin
  if v is null then raise exception 'This login is not linked to an employee record.'; end if;
  ps := private.cms_self_on(v, 'payslips'); ea := private.cms_self_on(v, 'ea');
  if not ps and not ea then raise exception 'This page has not been switched on for you. Ask HR.'; end if;
  ids := private.cms_eppd_ids(v);
  return jsonb_build_object(
    'payslips', case when ps then coalesce((select jsonb_agg(x order by x->>'period' desc) from (
        select jsonb_build_object('period', r.period, 'released_at', d.released_at,
               'companies', (select jsonb_agg(distinct coalesce(c.short_name, c.name)) from public.eppd_pay_lines l2 left join public.eppd_companies c on c.id = l2.company_id
                              where l2.run_id = r.id and l2.employee_id = any(ids) and not l2.excluded),
               'gross', (select sum(l2.gross) from public.eppd_pay_lines l2 where l2.run_id = r.id and l2.employee_id = any(ids) and not l2.excluded),
               'net_paid', (select sum(l2.net_paid) from public.eppd_pay_lines l2 where l2.run_id = r.id and l2.employee_id = any(ids) and not l2.excluded)) x
          from public.cms_doc_releases d
          join public.eppd_pay_runs r on r.period = d.period and r.status = 'finalised'
         where d.person_id = v and d.kind = 'payslip' and d.withdrawn_at is null
           and exists (select 1 from public.eppd_pay_lines l where l.run_id = r.id and l.employee_id = any(ids) and not l.excluded)) q), '[]'::jsonb) end,
    'ea', case when ea then coalesce((select jsonb_agg(extract(year from d.period)::int order by d.period desc)
          from public.cms_doc_releases d where d.person_id = v and d.kind = 'ea' and d.withdrawn_at is null
           and exists (select 1 from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                        where r.status = 'finalised' and date_trunc('year', r.period) = d.period and l.employee_id = any(ids) and not l.excluded)), '[]'::jsonb) end);
end $$;

-- everything a payslip / EA form shows about the person, the companies and the employment
create or replace function private.cms_slip_context(p_person uuid, p_period date)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'person', (select jsonb_build_object('name', em.employee_name, 'employee_id', em.employee_id,
        'nric', pv.nric, 'passport_no', pv.passport_no, 'epf_no', pv.epf_no, 'socso_no', pv.socso_no, 'tax_no', pv.tax_no,
        'bank', (select label from public.eppd_lookups where category = 'bank' and code = pv.bank_code limit 1), 'bank_account_no', pv.bank_account_no)
      from public.employee_master em
      left join lateral (select p.* from public.eppd_employee_private p join public.eppd_employees e on e.id = p.employee_id
                          where e.employee_master_id = em.id order by e.id desc limit 1) pv on true
      where em.id = p_person),
    'employment', (select jsonb_build_object('department', d.code, 'department_name', d.name, 'title', t.name, 'join_date', m.join_date, 'resigned_date', m.resigned_date)
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
      left join public.eppd_departments d on d.id = m.department_id left join public.eppd_job_titles t on t.id = m.job_title_id
      where e.employee_master_id = p_person and (m.join_date is null or m.join_date <= (date_trunc('month', p_period) + interval '1 month - 1 day')::date)
      order by (m.resigned_date is null or m.resigned_date >= p_period) desc, m.join_date desc nulls last limit 1),
    'employments', coalesce((select jsonb_agg(jsonb_build_object('join_date', m.join_date, 'resigned_date', m.resigned_date) order by m.join_date)
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = p_person), '[]'::jsonb),
    'companies', coalesce((select jsonb_object_agg(c.id::text, jsonb_build_object('name', c.name, 'short_name', c.short_name, 'registration_no', c.registration_no,
        'address', c.address, 'phone', c.phone, 'email', c.email, 'logo', c.logo, 'tax_employer_no', c.tax_employer_no)) from public.eppd_companies c
        where c.id in (select l.company_id from public.eppd_pay_lines l where l.employee_id = any(private.cms_eppd_ids(p_person)))), '{}'::jsonb));
$$;

create or replace function public.cms_my_payslip(p_period date)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('payslips'); ids bigint[]; per date := date_trunc('month', p_period)::date;
begin
  if not exists (select 1 from public.cms_doc_releases where person_id = v and kind = 'payslip' and period = per and withdrawn_at is null) then
    raise exception 'This payslip has not been released to you.';
  end if;
  if not exists (select 1 from public.eppd_pay_runs where period = per and status = 'finalised') then
    raise exception 'This payroll month is not finalised.';
  end if;
  ids := private.cms_eppd_ids(v);
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  select v, 'payslip_viewed', 'Payslip opened in self-service', jsonb_build_object('period', per), auth.uid()
   where not exists (select 1 from public.employee_events where employee_id_ref = v and event_type = 'payslip_viewed' and payload->>'period' = per::text);
  return private.cms_slip_context(v, per) || jsonb_build_object('period', per,
    'lines', coalesce((select jsonb_agg(private.cms_line_json(l, r.period) order by l.company_id) from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                        where r.period = per and r.status = 'finalised' and l.employee_id = any(ids) and not l.excluded), '[]'::jsonb),
    'ytd', coalesce((select jsonb_agg(private.cms_line_json(l, r.period)) from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                      where r.status = 'finalised' and r.period >= date_trunc('year', per) and r.period <= per and l.employee_id = any(ids) and not l.excluded), '[]'::jsonb));
end $$;

create or replace function public.cms_my_ea(p_year int)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('ea'); ids bigint[]; y date := make_date(p_year, 1, 1);
begin
  if not exists (select 1 from public.cms_doc_releases where person_id = v and kind = 'ea' and period = y and withdrawn_at is null) then
    raise exception 'This EA form has not been released to you.';
  end if;
  ids := private.cms_eppd_ids(v);
  return private.cms_slip_context(v, make_date(p_year, 12, 1)) || jsonb_build_object('year', p_year,
    'signatory', (select value from public.eppd_policies where key = 'ea_signatory'),
    'lines', coalesce((select jsonb_agg(private.cms_line_json(l, r.period)) from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                        where r.status = 'finalised' and date_trunc('year', r.period) = y and l.employee_id = any(ids) and not l.excluded), '[]'::jsonb));
end $$;

create or replace function public.cms_my_salary()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('salary');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('from', h.effective_from, 'amount', h.amount, 'pay_basis', h.pay_basis, 'reason', h.reason,
            'company', coalesce(c.short_name, c.name)) order by h.effective_from desc, h.id desc)
    from public.eppd_salary_history h
    join public.eppd_assignments a on a.id = h.assignment_id
    join public.eppd_employments m on m.id = a.employment_id
    join public.eppd_employees e on e.id = m.employee_id
    left join public.eppd_companies c on c.id = a.company_id
    where e.employee_master_id = v), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------------ HR / Admin: Self-service access page
create or replace function public.cms_self_service()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('selfservice', 'V');
  return jsonb_build_object(
    'can_edit', public.cms_can('selfservice', 'E'),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
        'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
        'status', em.employment_status, 'title', em.approved_job_title, 'department', em.department,
        'director', private.cms_person_is_director(em.id),
        'login', (select u.email from public.cms_user_links ul join auth.users u on u.id = ul.user_id where ul.employee_master_id = em.id limit 1),
        'parts', coalesce((select jsonb_agg(part) from public.cms_self_access where person_id = em.id and enabled), '[]'::jsonb),
        'payslips', coalesce((select jsonb_agg(to_char(period, 'YYYY-MM') order by period) from public.cms_doc_releases where person_id = em.id and kind = 'payslip' and withdrawn_at is null), '[]'::jsonb),
        'ea', coalesce((select jsonb_agg(extract(year from period)::int order by period) from public.cms_doc_releases where person_id = em.id and kind = 'ea' and withdrawn_at is null), '[]'::jsonb),
        'paid', coalesce((select jsonb_agg(distinct to_char(r.period, 'YYYY-MM')) from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                           join public.eppd_employees e on e.id = l.employee_id where e.employee_master_id = em.id and r.status = 'finalised' and not l.excluded), '[]'::jsonb),
        'reports_to_id', em.reports_to_id, 'reporting_name', em.reporting_name,
        'pending', (select count(*) from public.cms_profile_requests where person_id = em.id and status = 'pending'))
      order by em.employee_name)
      from public.employee_master em
      where em.employment_status in ('active','onboarding')
         or exists (select 1 from public.cms_self_access s where s.person_id = em.id and s.enabled)
         or (em.employment_status = 'former' and em.actual_last_working_date >= (now() - interval '15 months')::date)), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(to_char(period, 'YYYY-MM') order by period desc) from public.eppd_pay_runs where status = 'finalised'), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'person_id', q.person_id, 'name', em.employee_name, 'employee_id', em.employee_id,
        'changes', q.changes, 'previous', q.previous, 'note', q.note, 'requested_at', q.requested_at, 'has_attachment', q.attachment is not null) order by q.requested_at)
      from public.cms_profile_requests q join public.employee_master em on em.id = q.person_id where q.status = 'pending'), '[]'::jsonb),
    'banks', coalesce((select jsonb_object_agg(code, label) from public.eppd_lookups where category = 'bank'), '{}'::jsonb));
end $$;

create or replace function public.cms_self_set(p_people uuid[], p_part text, p_enabled boolean)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; p uuid; em public.employee_master;
begin
  perform private.cms_require('selfservice', 'E');
  if p_part not in ('profile','payslips','ea','salary','leave','claims','items','handbook') then raise exception 'Unknown part %', p_part; end if;
  foreach p in array coalesce(p_people, '{}') loop
    select * into em from public.employee_master where id = p;
    continue when em.id is null;
    perform private.cms_require('selfservice', 'E', private.cms_canon(em.company_code));
    if private.cms_self_on(p, p_part) = p_enabled then continue; end if;
    insert into public.cms_self_access (person_id, part, enabled, changed_by, changed_at) values (p, p_part, p_enabled, auth.uid(), now())
    on conflict (person_id, part) do update set enabled = excluded.enabled, changed_by = excluded.changed_by, changed_at = excluded.changed_at;
    perform private.cms_log(case when p_enabled then 'selfservice.on' else 'selfservice.off' end, 'employee_master', p::text, private.cms_canon(em.company_code),
      em.employee_name || ': self-service ' || p_part || case when p_enabled then ' switched on' else ' switched off' end, jsonb_build_object('part', p_part));
    n := n + 1;
  end loop;
  return n;
end $$;

-- release (or withdraw) payslips for a month / EA forms for a year
create or replace function public.cms_self_release(p_people uuid[], p_kind text, p_period date, p_release boolean default true)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; skipped int := 0; p uuid; em public.employee_master; per date; has boolean;
begin
  perform private.cms_require('selfservice', 'E');
  if p_kind not in ('payslip','ea') then raise exception 'Unknown document'; end if;
  per := case when p_kind = 'ea' then date_trunc('year', p_period)::date else date_trunc('month', p_period)::date end;
  if p_kind = 'payslip' and p_release and not exists (select 1 from public.eppd_pay_runs where period = per and status = 'finalised') then
    raise exception 'Only a finalised payroll month can be released.';
  end if;
  foreach p in array coalesce(p_people, '{}') loop
    select * into em from public.employee_master where id = p;
    continue when em.id is null;
    perform private.cms_require('selfservice', 'E', private.cms_canon(em.company_code));
    if p_release then
      select exists (select 1 from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                      where r.status = 'finalised' and not l.excluded and l.employee_id = any(private.cms_eppd_ids(p))
                        and (case when p_kind = 'ea' then date_trunc('year', r.period) = per else r.period = per end)) into has;
      if not has then skipped := skipped + 1; continue; end if;
      if exists (select 1 from public.cms_doc_releases where person_id = p and kind = p_kind and period = per and withdrawn_at is null) then continue; end if;
      insert into public.cms_doc_releases (person_id, kind, period, released_by, released_at)
      values (p, p_kind, per, auth.uid(), now())
      on conflict (person_id, kind, period) do update set released_by = excluded.released_by, released_at = now(), withdrawn_by = null, withdrawn_at = null;
    else
      update public.cms_doc_releases set withdrawn_by = auth.uid(), withdrawn_at = now() where person_id = p and kind = p_kind and period = per and withdrawn_at is null;
      continue when not found;
    end if;
    perform private.cms_log(case when p_release then 'selfservice.release' else 'selfservice.withdraw' end, 'employee_master', p::text, private.cms_canon(em.company_code),
      em.employee_name || ': ' || case when p_kind = 'ea' then 'EA form ' || extract(year from per) else 'payslip ' || to_char(per, 'Mon YYYY') end
      || case when p_release then ' released' else ' withdrawn' end, jsonb_build_object('kind', p_kind, 'period', per));
    n := n + 1;
  end loop;
  return jsonb_build_object('done', n, 'skipped', skipped);
end $$;

create or replace function public.cms_set_reports_to(p_person uuid, p_manager uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; boss public.employee_master;
begin
  select * into em from public.employee_master where id = p_person for update;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('selfservice', 'E', private.cms_canon(em.company_code));
  if p_manager is not null then
    select * into boss from public.employee_master where id = p_manager;
    if boss.id is null then raise exception 'Choose who this person reports to.'; end if;
    if p_manager = p_person then raise exception 'A person cannot report to themselves.'; end if;
    if exists (with recursive up(id, depth) as (select p_manager, 0 union all
                 select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
               select 1 from up where id = p_person) then
      raise exception '% already reports (directly or through others) to %.', boss.employee_name, em.employee_name;
    end if;
  end if;
  update public.employee_master set reports_to_id = p_manager,
         reporting_name = coalesce(boss.employee_name, reporting_name), reporting_title = coalesce(boss.approved_job_title, reporting_title), updated_at = now()
   where id = em.id;
  perform private.cms_log('person.reports_to', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ' reports to ' || coalesce(boss.employee_name, '(nobody)'), jsonb_build_object('manager', p_manager));
end $$;

create or replace function public.cms_profile_attachment(p_id uuid)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare q public.cms_profile_requests;
begin
  select * into q from public.cms_profile_requests where id = p_id;
  if q.id is null then raise exception 'Request not found.'; end if;
  if q.person_id is distinct from private.cms_me() then perform private.cms_require('selfservice', 'E'); end if;
  return q.attachment;
end $$;

create or replace function public.cms_profile_decide(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare q public.cms_profile_requests; em public.employee_master; eid bigint; ch jsonb;
begin
  select * into q from public.cms_profile_requests where id = p_id for update;
  if q.id is null or q.status <> 'pending' then raise exception 'Request not found or already decided.'; end if;
  select * into em from public.employee_master where id = q.person_id;
  perform private.cms_require('selfservice', 'E', private.cms_canon(em.company_code));
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give the reason for rejecting.'; end if;
  ch := q.changes;
  if p_approve then
    if not exists (select 1 from public.eppd_employees where employee_master_id = em.id) and ch ?| array['bank_code','bank_account_no','home_address','emergency_name','emergency_relation','emergency_phone'] then
      raise exception '% has no payroll record yet: add them to payroll first, then approve.', em.employee_name;
    end if;
    update public.employee_master set contact = case when ch ? 'contact' then ch->>'contact' else contact end,
           email = case when ch ? 'email' then ch->>'email' else email end, updated_at = now() where id = em.id;
    update public.eppd_employees set phone = case when ch ? 'contact' then ch->>'contact' else phone end,
           email = case when ch ? 'email' then ch->>'email' else email end, updated_at = now() where employee_master_id = em.id;
    if ch ?| array['home_address','emergency_name','emergency_relation','emergency_phone','bank_code','bank_account_no'] then
      for eid in select id from public.eppd_employees where employee_master_id = em.id loop
        insert into public.eppd_employee_private (employee_id) values (eid) on conflict (employee_id) do nothing;
        update public.eppd_employee_private set
          home_address = case when ch ? 'home_address' then ch->>'home_address' else home_address end,
          emergency_name = case when ch ? 'emergency_name' then ch->>'emergency_name' else emergency_name end,
          emergency_relation = case when ch ? 'emergency_relation' then ch->>'emergency_relation' else emergency_relation end,
          emergency_phone = case when ch ? 'emergency_phone' then ch->>'emergency_phone' else emergency_phone end,
          bank_code = case when ch ? 'bank_code' then ch->>'bank_code' else bank_code end,
          bank_account_no = case when ch ? 'bank_account_no' then ch->>'bank_account_no' else bank_account_no end,
          updated_at = now()
        where employee_id = eid;
      end loop;
    end if;
  end if;
  update public.cms_profile_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), '') where id = q.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, case when p_approve then 'profile_change_approved' else 'profile_change_rejected' end, coalesce(nullif(btrim(p_note), ''), 'Profile change ' || case when p_approve then 'approved' else 'rejected' end),
          jsonb_build_object('request_id', q.id, 'fields', (select jsonb_agg(k) from jsonb_object_keys(ch) k)), auth.uid());
  perform private.cms_log(case when p_approve then 'profile.approved' else 'profile.rejected' end, 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': profile change ' || case when p_approve then 'approved' else 'rejected' end || ' (' || (select string_agg(k, ', ') from jsonb_object_keys(ch) k) || ')',
    jsonb_build_object('request_id', q.id));
end $$;

-- ------------------------------------------------------------------ grants
do $g$ declare f text;
begin
  foreach f in array array['cms_my_self()','cms_my_profile()','cms_my_profile_request(jsonb, text, text)','cms_my_profile_cancel(uuid)','cms_my_payslips()',
    'cms_my_payslip(date)','cms_my_ea(integer)','cms_my_salary()','cms_self_service()','cms_self_set(uuid[], text, boolean)',
    'cms_self_release(uuid[], text, date, boolean)','cms_set_reports_to(uuid, uuid)','cms_profile_attachment(uuid)','cms_profile_decide(uuid, boolean, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;

-- ------------------------------------------------------------------ one-off: Reports to pre-filled from the "reporting to" text
-- (a name that matches exactly one current employee; the rest are left for HR to choose)
update public.employee_master em set reports_to_id = b.id
  from public.employee_master b
 where em.reports_to_id is null and em.reporting_name is not null and b.id <> em.id
   and b.employment_status in ('active','onboarding')
   and private.cms_norm_name(b.employee_name) = private.cms_norm_name(em.reporting_name)
   and (select count(*) from public.employee_master b2 where b2.employment_status in ('active','onboarding')
         and private.cms_norm_name(b2.employee_name) = private.cms_norm_name(em.reporting_name)) = 1;

-- ------------------------------------------------------------------ reminders (bell)
-- staff: payslips released but not opened yet, profile changes decided in the last 14 days
create or replace function public.cms_my_self()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_me(); em public.employee_master;
begin
  if v is null then return null; end if;
  select * into em from public.employee_master where id = v;
  return jsonb_build_object(
    'person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
    'title', em.approved_job_title, 'status', em.employment_status,
    'parts', coalesce((select jsonb_agg(part order by part) from public.cms_self_access where person_id = v and enabled), '[]'::jsonb),
    'payslips', (select count(*) from public.cms_doc_releases r where r.person_id = v and r.kind = 'payslip' and r.withdrawn_at is null),
    'new_payslips', case when private.cms_self_on(v, 'payslips') then coalesce((select jsonb_agg(to_char(r.period, 'YYYY-MM') order by r.period)
        from public.cms_doc_releases r join public.eppd_pay_runs pr on pr.period = r.period and pr.status = 'finalised'
        where r.person_id = v and r.kind = 'payslip' and r.withdrawn_at is null
          and not exists (select 1 from public.employee_events e where e.employee_id_ref = v and e.event_type = 'payslip_viewed' and e.payload->>'period' = r.period::text)), '[]'::jsonb) else '[]'::jsonb end,
    'profile_pending', (select count(*) from public.cms_profile_requests where person_id = v and status = 'pending'),
    'profile_decided', case when private.cms_self_on(v, 'profile') then coalesce((select jsonb_agg(jsonb_build_object('status', status, 'at', decided_at) order by decided_at desc)
        from public.cms_profile_requests where person_id = v and status in ('approved','rejected') and decided_at > now() - interval '14 days'), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- HR: profile changes waiting
create or replace function public.cms_self_pending()
returns int language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.cms_can('selfservice', 'E') then return 0; end if;
  return (select count(*) from public.cms_profile_requests where status = 'pending');
end $$;
revoke all on function public.cms_self_pending() from public, anon;
grant execute on function public.cms_self_pending() to authenticated;
