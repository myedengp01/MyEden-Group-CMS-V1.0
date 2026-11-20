-- PRI-026 Company Reward System · Phase 1: Certification Allowance & assessments (v2026.11.20). Additive; nothing is removed.
-- A verified certificate of an eligible type is enrolled by HR, approved by Admin / a Director (the eligibility letter with T&C is
-- issued), and acknowledged by the staff member, who chooses the assessment period (1, 2, 3 … months). From the allowance start
-- (default 1 Jan 2027) each period has an assessment that opens 14 days before the period ends: 20 questions (10 from the
-- certificate's own category, 10 from the others), pass mark 80 %, retake until passed. A period passed (or skipped by a surprise)
-- adds a one-month "Certification Allowance" line (wages: EPF / SOCSO / EIS / PCB) to the person's payroll record; a period not
-- passed by its end is lost. No allowance from the period in which the resignation letter is dated. Staff may practise at any time;
-- mastery of the whole bank can earn surprises (no assessment for n months, a higher allowance for n months) set by Admin / Directors.
-- The existing FIRST_AID / SKM1 / SKM2 allowances (travel treatment) are not touched.

create table if not exists public.cms_rw_settings (key text primary key, value jsonb not null, updated_by uuid, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_categories (code text primary key, name jsonb not null, sort int not null default 0, practical jsonb not null default '[]'::jsonb);
create table if not exists public.cms_rw_questions (
  id uuid primary key default gen_random_uuid(), category text not null references public.cms_rw_categories(code),
  q jsonb not null, options jsonb not null, correct smallint not null check (correct between 0 and 5),
  video_url text, video_search text, sort int not null default 0, retired_at timestamptz,
  created_at timestamptz not null default now(), updated_by uuid, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_cert_rules (
  type_code text primary key references public.cms_cert_types(code), eligible boolean not null default false,
  category text references public.cms_rw_categories(code), amount numeric(10,2), eligible_months int,
  updated_by uuid, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_enrolments (
  id uuid primary key default gen_random_uuid(), person_id uuid not null references public.employee_master(id),
  certificate_id uuid references public.cms_certificates(id), type_code text not null, category text not null,
  amount numeric(10,2) not null, period_months int, start_month date, eligible_until date,
  status text not null default 'pending_approval' check (status in ('pending_approval', 'awaiting_ack', 'active', 'ended', 'declined')),
  ref_no text, tc text, note text, created_by uuid, created_at timestamptz not null default now(),
  approved_by uuid, approved_at timestamptz, decide_note text, acknowledged_at timestamptz, ack_name text,
  ended_on date, end_reason text, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_period_changes (
  id uuid primary key default gen_random_uuid(), enrolment_id uuid not null references public.cms_rw_enrolments(id),
  from_months int, to_months int not null, reason text not null, status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  requested_by uuid, requested_at timestamptz not null default now(), decided_by uuid, decided_at timestamptz, decide_note text);
create table if not exists public.cms_rw_periods (
  id uuid primary key default gen_random_uuid(), enrolment_id uuid not null references public.cms_rw_enrolments(id),
  period_start date not null, period_end date not null, opens_on date not null,
  status text not null default 'open' check (status in ('open', 'passed', 'exempt', 'lost', 'ineligible')),
  amount numeric(10,2), attempt_id uuid, passed_at timestamptz, allowance_id bigint, pay_month date, note text,
  unique (enrolment_id, period_start));
create table if not exists public.cms_rw_attempts (
  id uuid primary key default gen_random_uuid(), person_id uuid not null references public.employee_master(id),
  enrolment_id uuid references public.cms_rw_enrolments(id), period_id uuid references public.cms_rw_periods(id),
  kind text not null check (kind in ('assessment', 'practice')), lang text not null default 'en', category text,
  items jsonb not null, answers jsonb, score int, total int, pass_pct numeric, passed boolean,
  started_at timestamptz not null default now(), submitted_at timestamptz);
create index if not exists cms_rw_attempts_person on public.cms_rw_attempts (person_id, started_at desc);
create table if not exists public.cms_rw_answers (
  attempt_id uuid not null references public.cms_rw_attempts(id), question_id uuid not null references public.cms_rw_questions(id),
  person_id uuid not null, correct boolean not null, answered_at timestamptz not null default now(), primary key (attempt_id, question_id));
create index if not exists cms_rw_answers_person on public.cms_rw_answers (person_id, question_id, answered_at desc);
create table if not exists public.cms_rw_practicals (
  id uuid primary key default gen_random_uuid(), person_id uuid not null references public.employee_master(id),
  category text not null references public.cms_rw_categories(code), done_on date not null, passed boolean not null,
  assessor_name text, note text, recorded_by uuid, created_at timestamptz not null default now(), retired_at timestamptz);
create table if not exists public.cms_rw_rules (
  id uuid primary key default gen_random_uuid(), label text not null, kind text not null check (kind in ('skip', 'rate')),
  mastery_pct numeric not null, months int not null, amount numeric(10,2), auto boolean not null default false,
  active boolean not null default true, sort int not null default 0, updated_by uuid, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_grants (
  id uuid primary key default gen_random_uuid(), person_id uuid not null references public.employee_master(id),
  kind text not null check (kind in ('skip', 'rate')), from_month date not null, to_month date not null, amount numeric(10,2),
  rule_id uuid references public.cms_rw_rules(id), mastery_pct numeric, reason text, granted_by uuid, granted_at timestamptz not null default now(),
  revoked_at timestamptz, revoked_by uuid, revoke_reason text);

do $$ declare t text;
begin
  foreach t in array array['cms_rw_settings','cms_rw_categories','cms_rw_questions','cms_rw_cert_rules','cms_rw_enrolments','cms_rw_period_changes',
    'cms_rw_periods','cms_rw_attempts','cms_rw_answers','cms_rw_practicals','cms_rw_rules','cms_rw_grants'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- seed (only when missing)
insert into public.cms_rw_settings (key, value) values ('cert', jsonb_build_object(
  'amount', 50, 'allowance_from', '2027-01-01', 'periods', jsonb_build_array(1, 2, 3, 6), 'open_days', 14, 'questions', 20, 'own', 10,
  'pass_pct', 80, 'practical_months', 6, 'payment_type', 'CERT_ALLOW',
  'tc', E'1. The Certification Allowance is paid for a certificate approved as related to your own job description, at the amount stated in this letter for each assessment period you pass.\n2. Before the allowance starts you choose your assessment period (for example monthly, every 2 months or quarterly). Changing it later needs a reason and the approval of Admin or a Director.\n3. The assessment for each period opens 14 days before the period ends. You may retake it as many times as needed until you pass. The pass mark is 80%.\n4. If you have not passed by the last day of the period, there is no allowance for that period.\n5. A practical check (for example CPR on a manikin) is done every 6 months.\n6. The allowance is paid with your salary in the payroll month in which the period is passed or ends. It is wages for EPF, SOCSO, EIS and PCB.\n7. The allowance stops from the period in which your resignation letter is dated, whatever your last working day. It also stops if the certificate is no longer valid or when the eligibility period in this letter ends, until it is reviewed.\n8. Every attempt, answer and result is kept on your record. The company may change the amount, the rules and these terms with notice to you.'))
on conflict (key) do nothing;

insert into public.cms_rw_categories (code, name, sort, practical) values
 ('A', '{"en":"First Aid & CPR","zh":"急救与心肺复苏","ms":"Pertolongan Cemas & CPR"}', 1, '["Adult CPR on a manikin for 2 minutes (rate, depth, recoil, 30:2)","Infant CPR on a manikin","Choking: back blows and chest / abdominal thrusts on a manikin","Recovery position on a colleague","Bandage a bleeding wound; arm sling","Use a training AED"]'),
 ('B', '{"en":"Fire Safety & Emergency Evacuation","zh":"消防安全与紧急疏散","ms":"Keselamatan Kebakaran & Pemindahan Kecemasan"}', 2, '["Fire drill role (sweep, headcount, report) during a real drill","Name the extinguisher types and their use; PASS with a training extinguisher","Show the evacuation route and assembly point"]'),
 ('C', '{"en":"Food Handling & Kitchen Hygiene","zh":"食品处理与厨房卫生","ms":"Pengendalian Makanan & Kebersihan Dapur"}', 3, '["Handwash demonstration","Check and record fridge temperature","Correct fridge storage layout"]'),
 ('D', '{"en":"Child Safety & Safeguarding","zh":"儿童安全与保护","ms":"Keselamatan & Perlindungan Kanak-kanak"}', 4, '["Release a child: check the authorised list and ID","Safe-sleep set-up of a cot","Fill in an accident record correctly"]'),
 ('E', '{"en":"Infection Control & Childhood Illness","zh":"感染控制与儿童疾病","ms":"Kawalan Jangkitan & Penyakit Kanak-kanak"}', 5, '["Nappy change with gloves and cleaning","Vomit spill clean-up","Morning health check of a child"]'),
 ('F', '{"en":"Child Transport Safety","zh":"儿童交通安全","ms":"Keselamatan Pengangkutan Kanak-kanak"}', 6, '["Daily vehicle check, recorded","Headcount and end-of-trip walk-through","Fit a child seat correctly"]'),
 ('G', '{"en":"General Workplace Safety","zh":"一般职场安全","ms":"Keselamatan Am Tempat Kerja"}', 7, '["Safe lifting","Spot the hazards in a room (photo or walk-round)"]')
on conflict (code) do nothing;

-- 2024 General Benefit & Award Criteria: First Aid 1 yr, SKM 3 yrs, KAP 1.5 yrs; others off until Admin / a Director turns them on
insert into public.cms_rw_cert_rules (type_code, eligible, category, eligible_months)
select t.code, t.code in ('FIRST_AID', 'PERMATA', 'SKM'),
  case t.code when 'FIRST_AID' then 'A' when 'PERMATA' then 'D' when 'SKM' then 'D' when 'ECCE' then 'D' when 'FOOD_HANDLER' then 'C' when 'TYPHOID' then 'C'
    when 'FIRE' then 'B' when 'DRIVING' then 'F' else 'G' end,
  case t.code when 'FIRST_AID' then 12 when 'PERMATA' then 18 when 'SKM' then 36 end
from public.cms_cert_types t on conflict (type_code) do nothing;

insert into public.cms_rw_rules (label, kind, mastery_pct, months, sort)
select * from (values ('Mastery 80% · no assessment for 3 months', 'skip', 80, 3, 1), ('Mastery 90% · no assessment for 6 months', 'skip', 90, 6, 2),
  ('Mastery 100% · no assessment for 9 months', 'skip', 100, 9, 3)) v(l, k, p, m, s)
where not exists (select 1 from public.cms_rw_rules);

insert into public.eppd_payment_types (code, name, kind, category, subject_epf, subject_socso, subject_eis, subject_pcb, is_recurring, is_system, is_active, sort_order, notes, treatment)
select 'CERT_ALLOW', 'Certification Allowance', 'earning', 'allowance', true, true, true, true, true, true, true,
  coalesce((select max(sort_order) from public.eppd_payment_types), 0) + 1, 'Reward System: one month for each assessment period passed (wages)', 'wages'
where not exists (select 1 from public.eppd_payment_types where code = 'CERT_ALLOW');

insert into public.cms_modules (code, label, grp, phase, sort_order, locked, description, acts, kind, act_labels)
select 'rewards', 'Reward System', 'Performance & Growth', 5, 64, false, 'Certification allowance, assessments and surprises', 'VEA', 'section',
  '{"E":"Enrol certificates, record practical checks, edit the question bank","A":"Approve enrolments, period changes, surprises and settings (Admin / Director)"}'::jsonb
where not exists (select 1 from public.cms_modules where code = 'rewards');
insert into public.cms_role_permissions (role_code, module_code, actions)
select r, 'rewards', a from (values ('super_admin', 'VEA'), ('admin', 'VEA'), ('director', 'VA'), ('hr', 'VE')) v(r, a)
where not exists (select 1 from public.cms_role_permissions where module_code = 'rewards' and role_code = v.r);

-- ---------------------------------------------------------------- helpers
create or replace function private.cms_rw_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $$;
create or replace function private.cms_rw_set() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select value from public.cms_rw_settings where key = 'cert' $$;
create or replace function private.cms_rw_boss() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select private.cms_is_admin_or_director() $$;
create or replace function private.cms_rw_need_boss() returns void language plpgsql stable security definer set search_path = public, pg_temp as $$
begin if not private.cms_rw_boss() then raise exception 'Only Admin or a Director can do this.' using errcode = '42501'; end if; end $$;
create or replace function private.cms_rw_name(p uuid) returns text language sql stable security definer set search_path = public, pg_temp as $$
  select upper(employee_name) from public.employee_master where id = p $$;
create or replace function private.cms_rw_txt(j jsonb, l text) returns text language sql immutable as $$
  select coalesce(nullif(j->>l, ''), j->>'en') $$;

-- mastery of the whole bank: latest answer to each question in use
create or replace function private.cms_rw_mastery(p_person uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with q as (select id from public.cms_rw_questions where retired_at is null),
  last as (select distinct on (a.question_id) a.question_id, a.correct from public.cms_rw_answers a join q on q.id = a.question_id
           where a.person_id = p_person order by a.question_id, a.answered_at desc)
  select jsonb_build_object('total', (select count(*) from q), 'answered', (select count(*) from last), 'correct', (select count(*) from last where correct),
    'pct', case when (select count(*) from q) > 0 and (select count(*) from last) = (select count(*) from q)
      then round(100.0 * (select count(*) from last where correct) / (select count(*) from q), 1) end,
    'progress', case when (select count(*) from q) > 0 then round(100.0 * (select count(*) from last where correct) / (select count(*) from q), 1) else 0 end);
$$;

-- the payroll record (assignment) the allowance goes on, for a payroll month
create or replace function private.cms_rw_assignment(p_person uuid, p_month date) returns bigint language sql stable security definer set search_path = public, pg_temp as $$
  select a.id from public.eppd_assignments a join public.eppd_employments em on em.id = a.employment_id join public.eppd_employees ee on ee.id = em.employee_id
  where ee.employee_master_id = p_person and coalesce(a.start_date, '1900-01-01') <= (p_month + interval '1 month - 1 day')::date
    and (a.end_date is null or a.end_date >= p_month)
  order by a.is_primary desc, a.start_date desc nulls last limit 1 $$;

-- pay one period: a one-month Certification Allowance line in the first payroll month not yet finalised
create or replace function private.cms_rw_pay(p_period uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.cms_rw_periods; e public.cms_rw_enrolments; m date; amt numeric; v_asg bigint; v_type bigint; v_id bigint; n int := 0; lbl text;
begin
  select * into p from public.cms_rw_periods where id = p_period for update;
  if p.id is null or p.allowance_id is not null or p.status not in ('passed', 'exempt') then return; end if;
  select * into e from public.cms_rw_enrolments where id = p.enrolment_id;
  m := date_trunc('month', least(p.period_end, greatest(coalesce(p.passed_at::date, p.period_end), p.period_start)))::date;
  if p.status = 'exempt' then m := date_trunc('month', p.period_end)::date; end if;
  while exists (select 1 from public.eppd_pay_runs where period = m and status = 'finalised') and n < 24 loop m := (m + interval '1 month')::date; n := n + 1; end loop;
  amt := coalesce((select g.amount from public.cms_rw_grants g where g.person_id = e.person_id and g.kind = 'rate' and g.revoked_at is null
           and g.from_month <= m and g.to_month >= m order by g.amount desc limit 1), e.amount);
  select id into v_type from public.eppd_payment_types where code = coalesce(private.cms_rw_set()->>'payment_type', 'CERT_ALLOW');
  v_asg := private.cms_rw_assignment(e.person_id, m);
  select coalesce(t.label, e.type_code) into lbl from public.cms_cert_types t where t.code = e.type_code;
  if v_asg is null or v_type is null then
    update public.cms_rw_periods set amount = amt, pay_month = m, note = 'No payroll record for this month: add the allowance by hand' where id = p.id; return;
  end if;
  insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
  values (v_asg, v_type, amt, m, (m + interval '1 month - 1 day')::date,
    'Certification allowance · ' || coalesce(lbl, '') || ' · ' || to_char(p.period_start, 'DD Mon YYYY') || ' – ' || to_char(p.period_end, 'DD Mon YYYY') || case when p.status = 'exempt' then ' (assessment skipped: surprise)' else '' end)
  returning id into v_id;
  update public.cms_rw_periods set amount = amt, pay_month = m, allowance_id = v_id, note = null where id = p.id;
end $$;

-- bring one enrolment up to date: periods to today, lost / skipped / ineligible, resignation
create or replace function private.cms_rw_sync(p_enrol uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.cms_rw_enrolments; s jsonb := private.cms_rw_set(); v_res date; v_today date := private.cms_rw_today(); v_last date; v_start date; v_end date; i int := 0; r record;
begin
  select * into e from public.cms_rw_enrolments where id = p_enrol for update;
  if e.id is null or e.status <> 'active' or e.period_months is null or e.start_month is null then return; end if;
  select resignation_letter_date into v_res from public.employee_master where id = e.person_id;
  loop
    select max(period_end) into v_last from public.cms_rw_periods where enrolment_id = e.id;
    v_start := coalesce(v_last + 1, e.start_month);
    exit when v_start > v_today or i > 240 or (e.eligible_until is not null and v_start > e.eligible_until) or (v_res is not null and v_start > v_res);
    v_end := (v_start + make_interval(months => e.period_months))::date - 1;
    insert into public.cms_rw_periods (enrolment_id, period_start, period_end, opens_on)
    values (e.id, v_start, v_end, greatest(v_start, v_end - coalesce((s->>'open_days')::int, 14))) on conflict do nothing;
    i := i + 1;
  end loop;
  if v_res is not null then
    update public.cms_rw_periods set status = 'ineligible', note = 'Resignation letter dated ' || to_char(v_res, 'DD Mon YYYY')
     where enrolment_id = e.id and status = 'open' and period_end >= v_res;
    update public.cms_rw_enrolments set status = 'ended', ended_on = v_res, end_reason = 'Resignation letter dated ' || to_char(v_res, 'DD Mon YYYY'), updated_at = now() where id = e.id;
    return;
  end if;
  for r in select pr.id, pr.period_end from public.cms_rw_periods pr where pr.enrolment_id = e.id and pr.status = 'open' loop
    if exists (select 1 from public.cms_rw_grants g where g.person_id = e.person_id and g.kind = 'skip' and g.revoked_at is null
                and g.from_month <= date_trunc('month', r.period_end) and g.to_month >= date_trunc('month', r.period_end)) then
      update public.cms_rw_periods set status = 'exempt', passed_at = now(), note = 'Assessment skipped: surprise' where id = r.id;
      perform private.cms_rw_pay(r.id);
    elsif r.period_end < v_today then
      update public.cms_rw_periods set status = 'lost', note = 'Not passed by the end of the period' where id = r.id;
    end if;
  end loop;
end $$;

create or replace function private.cms_rw_sync_all() returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; begin for r in select id from public.cms_rw_enrolments where status = 'active' loop perform private.cms_rw_sync(r.id); end loop; end $$;

-- mastery surprises: the highest rule reached, when no skip is running
create or replace function private.cms_rw_ready(p_person uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with m as (select private.cms_rw_mastery(p_person) j)
  select (select to_jsonb(x) from (select r.id, r.label, r.kind, r.mastery_pct, r.months, r.amount, r.auto from public.cms_rw_rules r, m
    where r.active and (m.j->>'pct') is not null and (m.j->>'pct')::numeric >= r.mastery_pct
      and not exists (select 1 from public.cms_rw_grants g where g.person_id = p_person and g.kind = r.kind and g.revoked_at is null
                       and g.to_month >= date_trunc('month', private.cms_rw_today()))
    order by r.kind = 'skip' desc, r.mastery_pct desc limit 1) x) $$;

create or replace function private.cms_rw_grant_do(p_person uuid, p_kind text, p_from date, p_months int, p_amount numeric, p_rule uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; f date := date_trunc('month', p_from)::date; t date; mp numeric := (private.cms_rw_mastery(p_person)->>'pct')::numeric; r record;
begin
  if p_months is null or p_months < 1 or p_months > 36 then raise exception 'Months: 1 to 36.'; end if;
  if p_kind = 'rate' and (p_amount is null or p_amount <= 0) then raise exception 'Give the allowance amount for those months.'; end if;
  t := (f + make_interval(months => p_months - 1))::date;
  insert into public.cms_rw_grants (person_id, kind, from_month, to_month, amount, rule_id, mastery_pct, reason, granted_by)
  values (p_person, p_kind, f, t, case when p_kind = 'rate' then round(p_amount, 2) end, p_rule, mp, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid()) returning id into v;
  perform private.cms_log('rewards.surprise', 'cms_rw_grants', v::text, null, private.cms_rw_name(p_person) || ': surprise · ' ||
    case when p_kind = 'skip' then 'no assessment ' else 'allowance RM ' || round(p_amount, 2) || ' ' end || to_char(f, 'Mon YYYY') || ' – ' || to_char(t, 'Mon YYYY'), jsonb_build_object('rule', p_rule, 'mastery', mp));
  for r in select id from public.cms_rw_enrolments where person_id = p_person and status = 'active' loop perform private.cms_rw_sync(r.id); end loop;
  return v;
end $$;

-- ---------------------------------------------------------------- staff (self-service part "certs")
create or replace function private.cms_rw_enrol_json(e public.cms_rw_enrolments) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', e.id, 'person_id', e.person_id, 'name', private.cms_rw_name(e.person_id), 'type', e.type_code,
    'label', (select label from public.cms_cert_types where code = e.type_code), 'category', e.category, 'amount', e.amount,
    'period_months', e.period_months, 'start_month', e.start_month, 'eligible_until', e.eligible_until, 'status', e.status, 'ref_no', e.ref_no, 'tc', e.tc,
    'note', e.note, 'created_at', e.created_at, 'approved_at', e.approved_at, 'approved_by', private.cms_user_name(e.approved_by),
    'decide_note', e.decide_note, 'acknowledged_at', e.acknowledged_at, 'ack_name', e.ack_name, 'ended_on', e.ended_on, 'end_reason', e.end_reason,
    'cert', (select jsonb_build_object('title', c.title, 'issuer', c.issuer, 'no', c.cert_no, 'issued_on', c.issued_on, 'expires_on', c.expires_on) from public.cms_certificates c where c.id = e.certificate_id),
    'person', (select jsonb_build_object('employee_id', m.employee_id, 'company', m.company_code, 'position', m.approved_job_title, 'department', m.department) from public.employee_master m where m.id = e.person_id),
    'current', (select to_jsonb(x) from (select id, period_start, period_end, opens_on, status, amount, pay_month, note from public.cms_rw_periods
                 where enrolment_id = e.id order by period_start desc limit 1) x),
    'periods', coalesce((select jsonb_agg(to_jsonb(x) order by x.period_start desc) from (select id, period_start, period_end, opens_on, status, amount, pay_month, passed_at, note
                 from public.cms_rw_periods where enrolment_id = e.id order by period_start desc limit 24) x), '[]'::jsonb),
    'change', (select to_jsonb(x) from (select id, from_months, to_months, reason, status, requested_at, decided_at, decide_note from public.cms_rw_period_changes
                 where enrolment_id = e.id order by requested_at desc limit 1) x)) $$;

create or replace function public.cms_rw_my() returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); r record; s jsonb := private.cms_rw_set();
begin
  for r in select id from public.cms_rw_enrolments where person_id = v and status = 'active' loop perform private.cms_rw_sync(r.id); end loop;
  return jsonb_build_object('today', private.cms_rw_today(), 'name', private.cms_rw_name(v), 'mastery', private.cms_rw_mastery(v),
    'settings', jsonb_build_object('periods', s->'periods', 'open_days', s->'open_days', 'pass_pct', s->'pass_pct', 'questions', s->'questions', 'amount', s->'amount', 'allowance_from', s->'allowance_from', 'practical_months', s->'practical_months'),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'count', (select count(*) from public.cms_rw_questions q where q.category = c.code and q.retired_at is null)) order by sort) from public.cms_rw_categories c), '[]'::jsonb),
    'enrolments', coalesce((select jsonb_agg(private.cms_rw_enrol_json(e) order by e.created_at desc) from public.cms_rw_enrolments e where e.person_id = v and e.status in ('awaiting_ack', 'active', 'ended')), '[]'::jsonb),
    'attempts', coalesce((select jsonb_agg(to_jsonb(x) order by x.started_at desc) from (select a.id, a.kind, a.lang, a.category, a.score, a.total, a.passed, a.started_at, a.submitted_at,
        (select type_code from public.cms_rw_enrolments where id = a.enrolment_id) type from public.cms_rw_attempts a where a.person_id = v order by a.started_at desc limit 30) x), '[]'::jsonb),
    'grants', coalesce((select jsonb_agg(to_jsonb(x) order by x.from_month) from (select kind, from_month, to_month, amount, reason from public.cms_rw_grants
        where person_id = v and revoked_at is null and to_month >= date_trunc('month', private.cms_rw_today())) x), '[]'::jsonb),
    'practicals', coalesce((select jsonb_agg(to_jsonb(x)) from (select distinct on (category) category, done_on, passed, assessor_name,
        (done_on + make_interval(months => coalesce((s->>'practical_months')::int, 6)))::date due_on from public.cms_rw_practicals where person_id = v and retired_at is null order by category, done_on desc) x), '[]'::jsonb));
end $$;

create or replace function public.cms_rw_acknowledge(p_enrol uuid, p_months int, p_name text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); e public.cms_rw_enrolments; s jsonb := private.cms_rw_set(); st date; c date;
begin
  select * into e from public.cms_rw_enrolments where id = p_enrol and person_id = v for update;
  if e.id is null or e.status <> 'awaiting_ack' then raise exception 'There is no letter waiting for you to acknowledge.'; end if;
  if not (s->'periods') @> to_jsonb(p_months) then raise exception 'Choose one of the assessment periods offered.'; end if;
  if length(btrim(coalesce(p_name, ''))) < 3 then raise exception 'Type your full name to acknowledge.'; end if;
  select issued_on into c from public.cms_certificates where id = e.certificate_id;
  st := greatest(date_trunc('month', private.cms_rw_today() + interval '1 month')::date, coalesce((s->>'allowance_from')::date, '2027-01-01'),
                 coalesce(date_trunc('month', c + interval '1 month')::date, '1900-01-01'));
  update public.cms_rw_enrolments set status = 'active', period_months = p_months, start_month = st, acknowledged_at = now(), ack_name = upper(btrim(p_name)), updated_at = now() where id = e.id;
  perform private.cms_log('rewards.acknowledged', 'cms_rw_enrolments', e.id::text, null, private.cms_rw_name(v) || ': certification allowance letter ' || coalesce(e.ref_no, '') || ' acknowledged; assessment every ' || p_months || ' month(s) from ' || to_char(st, 'Mon YYYY'), '{}'::jsonb);
end $$;

create or replace function public.cms_rw_period_request(p_enrol uuid, p_months int, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); e public.cms_rw_enrolments; s jsonb := private.cms_rw_set(); x uuid;
begin
  select * into e from public.cms_rw_enrolments where id = p_enrol and person_id = v;
  if e.id is null or e.status <> 'active' then raise exception 'This certificate is not active.'; end if;
  if not (s->'periods') @> to_jsonb(p_months) or p_months = e.period_months then raise exception 'Choose a different period from those offered.'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change.'; end if;
  if exists (select 1 from public.cms_rw_period_changes where enrolment_id = e.id and status = 'pending') then raise exception 'A change is already waiting for approval.'; end if;
  insert into public.cms_rw_period_changes (enrolment_id, from_months, to_months, reason, requested_by) values (e.id, e.period_months, p_months, btrim(p_reason), auth.uid()) returning id into x;
  perform private.cms_log('rewards.period_request', 'cms_rw_period_changes', x::text, null, private.cms_rw_name(v) || ': asks to change the assessment period from ' || e.period_months || ' to ' || p_months || ' month(s)', jsonb_build_object('reason', p_reason));
end $$;

-- start (or resume) an attempt. Assessment: the open period of an active certificate (n questions: "own" from the certificate's
-- category, the rest from the others); practice: any time, all categories or one. Option order is shuffled and kept with the attempt;
-- the correct answers are never sent before the attempt is submitted.
create or replace function private.cms_rw_attempt_json(a public.cms_rw_attempts) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', a.id, 'kind', a.kind, 'lang', a.lang, 'category', a.category, 'started_at', a.started_at,
    'type', (select type_code from public.cms_rw_enrolments where id = a.enrolment_id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('n', it.n, 'cat', q.category, 'q', private.cms_rw_txt(q.q, a.lang),
        'o', (select jsonb_agg(private.cms_rw_txt(q.options->(o.v::int)->'t', a.lang) order by o.k) from jsonb_array_elements_text(it.j->'o') with ordinality o(v, k)))
      order by it.n) from jsonb_array_elements(a.items) with ordinality it(j, n) join public.cms_rw_questions q on q.id = (it.j->>'q')::uuid), '[]'::jsonb)) $$;

create or replace function public.cms_rw_start(p_kind text, p_enrol uuid, p_lang text, p_category text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); s jsonb := private.cms_rw_set(); e public.cms_rw_enrolments; p public.cms_rw_periods; a public.cms_rw_attempts;
  n int := coalesce((s->>'questions')::int, 20); own int := coalesce((s->>'own')::int, 10); v_lang text := case when p_lang in ('en', 'zh', 'ms') then p_lang else 'en' end;
  ids uuid[] := '{}'; its jsonb := '[]'::jsonb; r record; t date := private.cms_rw_today();
begin
  if p_kind not in ('assessment', 'practice') then raise exception 'Unknown kind.'; end if;
  if p_kind = 'assessment' then
    select * into e from public.cms_rw_enrolments where id = p_enrol and person_id = v;
    if e.id is null or e.status <> 'active' then raise exception 'This certificate is not active.'; end if;
    perform private.cms_rw_sync(e.id);
    select * into p from public.cms_rw_periods where enrolment_id = e.id order by period_start desc limit 1;
    if p.id is null or p.status <> 'open' then raise exception 'There is no assessment open for this certificate now.'; end if;
    if t < p.opens_on then raise exception 'The assessment for this period opens on %.', to_char(p.opens_on, 'DD Mon YYYY'); end if;
    select * into a from public.cms_rw_attempts where person_id = v and period_id = p.id and submitted_at is null and started_at > now() - interval '24 hours' order by started_at desc limit 1;
  else
    if p_category is not null and not exists (select 1 from public.cms_rw_categories where code = p_category) then raise exception 'Unknown category.'; end if;
    select * into a from public.cms_rw_attempts where person_id = v and kind = 'practice' and submitted_at is null and category is not distinct from p_category and started_at > now() - interval '24 hours' order by started_at desc limit 1;
  end if;
  if a.id is not null then
    if a.lang <> v_lang then update public.cms_rw_attempts set lang = v_lang where id = a.id returning * into a; end if;
    return private.cms_rw_attempt_json(a);
  end if;
  if p_kind = 'assessment' then
    select coalesce(array_agg(id), '{}') into ids from (select id from public.cms_rw_questions where retired_at is null and category = e.category order by random() limit own) x;
    ids := ids || coalesce((select array_agg(id) from (select id from public.cms_rw_questions where retired_at is null and category <> e.category order by random() limit greatest(n - cardinality(ids), 0)) y), '{}');
    if cardinality(ids) < n then ids := ids || coalesce((select array_agg(id) from (select id from public.cms_rw_questions where retired_at is null and id <> all(ids) order by random() limit n - cardinality(ids)) z), '{}'); end if;
  else
    select coalesce(array_agg(id), '{}') into ids from (select id from public.cms_rw_questions where retired_at is null and (p_category is null or category = p_category) order by random() limit n) x;
  end if;
  if cardinality(ids) = 0 then raise exception 'There are no questions in the bank yet.'; end if;
  for r in select q.id, jsonb_array_length(q.options) k from unnest(ids) with ordinality u(id, o) join public.cms_rw_questions q on q.id = u.id order by random() loop
    its := its || jsonb_build_array(jsonb_build_object('q', r.id, 'o', (select jsonb_agg(g order by random()) from generate_series(0, r.k - 1) g)));
  end loop;
  insert into public.cms_rw_attempts (person_id, enrolment_id, period_id, kind, lang, category, items, total, pass_pct)
  values (v, e.id, p.id, p_kind, v_lang, case when p_kind = 'practice' then p_category else e.category end, its, jsonb_array_length(its), coalesce((s->>'pass_pct')::numeric, 80))
  returning * into a;
  return private.cms_rw_attempt_json(a);
end $$;

-- results of a submitted attempt: every option with its explanation, the answer chosen and the right one, and the video
create or replace function private.cms_rw_review_json(a public.cms_rw_attempts) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', a.id, 'kind', a.kind, 'lang', a.lang, 'category', a.category, 'score', a.score, 'total', a.total, 'pass_pct', a.pass_pct, 'passed', a.passed,
    'started_at', a.started_at, 'submitted_at', a.submitted_at, 'type', (select type_code from public.cms_rw_enrolments where id = a.enrolment_id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('n', it.n, 'cat', q.category, 'q', private.cms_rw_txt(q.q, a.lang), 'video', q.video_url,
        'chosen', a.answers->((it.n - 1)::int), 'right', (select (o.k - 1) from jsonb_array_elements_text(it.j->'o') with ordinality o(v, k) where o.v::int = q.correct),
        'o', (select jsonb_agg(jsonb_build_object('t', private.cms_rw_txt(q.options->(o.v::int)->'t', a.lang), 'why', private.cms_rw_txt(q.options->(o.v::int)->'why', a.lang),
                'ok', o.v::int = q.correct) order by o.k) from jsonb_array_elements_text(it.j->'o') with ordinality o(v, k)))
      order by it.n) from jsonb_array_elements(a.items) with ordinality it(j, n) join public.cms_rw_questions q on q.id = (it.j->>'q')::uuid), '[]'::jsonb)) $$;

create or replace function public.cms_rw_submit(p_attempt uuid, p_answers jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); a public.cms_rw_attempts; pr public.cms_rw_periods; sc int := 0; it record; ch int; ok boolean; rd jsonb; v_out jsonb;
begin
  select * into a from public.cms_rw_attempts where id = p_attempt and person_id = v for update;
  if a.id is null then raise exception 'Attempt not found.'; end if;
  if a.submitted_at is not null then return private.cms_rw_review_json(a); end if;
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> jsonb_array_length(a.items) then raise exception 'Answer every question.'; end if;
  for it in select j, n from jsonb_array_elements(a.items) with ordinality x(j, n) loop
    ch := case when jsonb_typeof(p_answers->((it.n - 1)::int)) = 'number' then (p_answers->>((it.n - 1)::int))::int end;
    ok := ch is not null and ch >= 0 and ch < jsonb_array_length(it.j->'o') and ((it.j->'o')->>ch)::int = (select correct from public.cms_rw_questions where id = (it.j->>'q')::uuid);
    if ok then sc := sc + 1; end if;
    insert into public.cms_rw_answers (attempt_id, question_id, person_id, correct, answered_at) values (a.id, (it.j->>'q')::uuid, v, coalesce(ok, false), clock_timestamp()) on conflict do nothing;
  end loop;
  update public.cms_rw_attempts set answers = p_answers, score = sc, submitted_at = now(), passed = (100.0 * sc / greatest(total, 1)) >= pass_pct where id = a.id returning * into a;
  if a.kind = 'assessment' and a.passed then
    select * into pr from public.cms_rw_periods where id = a.period_id for update;
    if pr.status = 'open' and private.cms_rw_today() <= pr.period_end then
      update public.cms_rw_periods set status = 'passed', passed_at = now(), attempt_id = a.id where id = pr.id;
      perform private.cms_rw_pay(pr.id);
    end if;
  end if;
  perform private.cms_log('rewards.attempt', 'cms_rw_attempts', a.id::text, null, private.cms_rw_name(v) || ': ' || a.kind || ' ' || sc || ' / ' || a.total || case when a.kind = 'assessment' then case when a.passed then ' · passed' else ' · not passed' end else '' end, '{}'::jsonb);
  rd := private.cms_rw_ready(v);
  if rd is not null and (rd->>'auto')::boolean and exists (select 1 from public.cms_rw_enrolments where person_id = v and status = 'active') then
    perform private.cms_rw_grant_do(v, rd->>'kind', (date_trunc('month', private.cms_rw_today()) + interval '1 month')::date, (rd->>'months')::int, (rd->>'amount')::numeric, (rd->>'id')::uuid, 'Automatic: ' || (rd->>'label'));
  end if;
  v_out := private.cms_rw_review_json(a);
  return v_out || jsonb_build_object('mastery', private.cms_rw_mastery(v), 'period', (select to_jsonb(x) from (select status, amount, pay_month from public.cms_rw_periods where id = a.period_id) x));
end $$;

create or replace function public.cms_rw_review(p_attempt uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.cms_rw_attempts; me uuid := private.cms_me();
begin
  select * into a from public.cms_rw_attempts where id = p_attempt;
  if a.id is null or a.submitted_at is null then raise exception 'Attempt not found.'; end if;
  if a.person_id is distinct from me and not public.cms_can('rewards', 'V') then raise exception 'You do not have access to this.' using errcode = '42501'; end if;
  return private.cms_rw_review_json(a) || jsonb_build_object('name', private.cms_rw_name(a.person_id));
end $$;

-- ---------------------------------------------------------------- management
create or replace function public.cms_rw_admin() returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare s jsonb;
begin
  perform private.cms_require('rewards', 'V');
  perform private.cms_rw_sync_all();
  s := private.cms_rw_set();
  return jsonb_build_object('today', private.cms_rw_today(), 'settings', s, 'can_edit', public.cms_can('rewards', 'E'), 'can_boss', private.cms_rw_boss(),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'practical', practical, 'count', (select count(*) from public.cms_rw_questions q where q.category = c.code and q.retired_at is null)) order by sort) from public.cms_rw_categories c), '[]'::jsonb),
    'cert_rules', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'eligible', coalesce(r.eligible, false), 'category', r.category, 'amount', r.amount, 'months', r.eligible_months) order by t.sort_order, t.label)
        from public.cms_cert_types t left join public.cms_rw_cert_rules r on r.type_code = t.code where t.is_active), '[]'::jsonb),
    'enrolments', coalesce((select jsonb_agg(private.cms_rw_enrol_json(e) || jsonb_build_object('mastery', private.cms_rw_mastery(e.person_id)) order by e.status = 'pending_approval' desc, e.created_at desc) from public.cms_rw_enrolments e), '[]'::jsonb),
    'eligible', coalesce((select jsonb_agg(jsonb_build_object('certificate_id', c.id, 'person_id', c.person_id, 'name', upper(m.employee_name), 'employee_id', m.employee_id, 'type', c.type_code,
        'label', t.label, 'title', c.title, 'issued_on', c.issued_on, 'expires_on', c.expires_on) order by m.employee_name)
      from public.cms_certificates c join public.cms_rw_cert_rules r on r.type_code = c.type_code and r.eligible join public.cms_cert_types t on t.code = c.type_code
      join public.employee_master m on m.id = c.person_id
      where c.status = 'verified' and (c.expires_on is null or c.expires_on >= private.cms_rw_today()) and m.resignation_letter_date is null and coalesce(m.employment_status, '') not ilike '%former%'
        and not exists (select 1 from public.cms_rw_enrolments e where e.person_id = c.person_id and e.type_code = c.type_code and e.status in ('pending_approval', 'awaiting_ack', 'active'))), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'enrolment_id', x.enrolment_id, 'name', private.cms_rw_name(e.person_id), 'type', e.type_code, 'from', x.from_months, 'to', x.to_months,
        'reason', x.reason, 'status', x.status, 'requested_at', x.requested_at, 'decided_at', x.decided_at, 'decide_note', x.decide_note) order by x.status = 'pending' desc, x.requested_at desc)
      from public.cms_rw_period_changes x join public.cms_rw_enrolments e on e.id = x.enrolment_id), '[]'::jsonb),
    'rules', coalesce((select jsonb_agg(to_jsonb(r) order by r.kind, r.mastery_pct) from public.cms_rw_rules r), '[]'::jsonb),
    'grants', coalesce((select jsonb_agg(to_jsonb(g) || jsonb_build_object('name', private.cms_rw_name(g.person_id), 'by', private.cms_user_name(g.granted_by)) order by g.granted_at desc) from public.cms_rw_grants g), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(x order by x->>'name') from (select jsonb_build_object('person_id', p.pid, 'name', private.cms_rw_name(p.pid), 'mastery', private.cms_rw_mastery(p.pid),
        'ready', private.cms_rw_ready(p.pid), 'enrolled', exists (select 1 from public.cms_rw_enrolments e where e.person_id = p.pid and e.status = 'active'),
        'attempts', (select count(*) from public.cms_rw_attempts a where a.person_id = p.pid and a.submitted_at is not null),
        'last_at', (select max(submitted_at) from public.cms_rw_attempts a where a.person_id = p.pid)) x
      from (select person_id pid from public.cms_rw_attempts union select person_id from public.cms_rw_enrolments where status in ('active', 'awaiting_ack')) p) q), '[]'::jsonb),
    'attempts', coalesce((select jsonb_agg(to_jsonb(x) order by x.submitted_at desc) from (select a.id, a.person_id, private.cms_rw_name(a.person_id) name, a.kind, a.lang, a.category, a.score, a.total, a.passed, a.submitted_at,
        (select type_code from public.cms_rw_enrolments where id = a.enrolment_id) type from public.cms_rw_attempts a where a.submitted_at is not null order by a.submitted_at desc limit 300) x), '[]'::jsonb),
    'practicals', coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('name', private.cms_rw_name(x.person_id)) order by x.done_on desc) from (select id, person_id, category, done_on, passed, assessor_name, note,
        (done_on + make_interval(months => coalesce((s->>'practical_months')::int, 6)))::date due_on from public.cms_rw_practicals where retired_at is null) x), '[]'::jsonb),
    'old_allowances', (select count(*) from public.eppd_allowances a join public.eppd_payment_types t on t.id = a.payment_type_id
        where t.code in ('FIRST_AID', 'SKM1', 'SKM2') and (a.end_date is null or a.end_date >= private.cms_rw_today())));
end $$;

create or replace function public.cms_rw_enrol(p_certificate uuid, p_note text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_certificates; r public.cms_rw_cert_rules; s jsonb := private.cms_rw_set(); v uuid;
begin
  perform private.cms_require('rewards', 'E');
  select * into c from public.cms_certificates where id = p_certificate;
  if c.id is null or c.status <> 'verified' then raise exception 'Only a verified certificate can be enrolled.'; end if;
  select * into r from public.cms_rw_cert_rules where type_code = c.type_code;
  if r.type_code is null or not r.eligible then raise exception 'This certificate type is not set as eligible for the allowance.'; end if;
  if exists (select 1 from public.cms_rw_enrolments where person_id = c.person_id and type_code = c.type_code and status in ('pending_approval', 'awaiting_ack', 'active')) then
    raise exception 'This person is already enrolled for this certificate type.'; end if;
  insert into public.cms_rw_enrolments (person_id, certificate_id, type_code, category, amount, eligible_until, note, created_by)
  values (c.person_id, c.id, c.type_code, coalesce(r.category, 'G'), coalesce(r.amount, (s->>'amount')::numeric, 50),
    case when r.eligible_months is not null then (greatest(coalesce((s->>'allowance_from')::date, '2027-01-01'), date_trunc('month', private.cms_rw_today() + interval '1 month')::date) + make_interval(months => r.eligible_months))::date - 1 end,
    nullif(btrim(coalesce(p_note, '')), ''), auth.uid()) returning id into v;
  perform private.cms_log('rewards.enrol', 'cms_rw_enrolments', v::text, null, private.cms_rw_name(c.person_id) || ': enrolled for the certification allowance (' || c.type_code || '), waiting for approval', '{}'::jsonb);
  return v;
end $$;

-- Admin / a Director: approve (issues the eligibility letter with T&C for the staff member to acknowledge) or decline
create or replace function public.cms_rw_enrol_decide(p_id uuid, p_approve boolean, p_note text, p_amount numeric, p_until date) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.cms_rw_enrolments; n int; ref text; yr text := to_char(private.cms_rw_today(), 'YYYY');
begin
  perform private.cms_rw_need_boss();
  select * into e from public.cms_rw_enrolments where id = p_id for update;
  if e.id is null or e.status <> 'pending_approval' then raise exception 'This enrolment is not waiting for approval.'; end if;
  if e.created_by = auth.uid() and not public.cms_is_super_admin() then raise exception 'Someone other than the person who enrolled it must approve.'; end if;
  if not p_approve then
    if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'Give the reason.'; end if;
    update public.cms_rw_enrolments set status = 'declined', approved_by = auth.uid(), approved_at = now(), decide_note = btrim(p_note), updated_at = now() where id = e.id;
    perform private.cms_log('rewards.enrol_declined', 'cms_rw_enrolments', e.id::text, null, private.cms_rw_name(e.person_id) || ': certification allowance enrolment declined', jsonb_build_object('reason', p_note));
    return;
  end if;
  select count(*) + 1 into n from public.cms_rw_enrolments where ref_no like 'MEG/HR/CA/' || yr || '/%';
  ref := 'MEG/HR/CA/' || yr || '/' || lpad(n::text, 4, '0');
  update public.cms_rw_enrolments set status = 'awaiting_ack', ref_no = ref, tc = private.cms_rw_set()->>'tc', approved_by = auth.uid(), approved_at = now(),
    decide_note = nullif(btrim(coalesce(p_note, '')), ''), amount = coalesce(round(p_amount, 2), amount), eligible_until = coalesce(p_until, eligible_until), updated_at = now() where id = e.id;
  perform private.cms_log('rewards.enrol_approved', 'cms_rw_enrolments', e.id::text, null, private.cms_rw_name(e.person_id) || ': certification allowance letter ' || ref || ' issued for acknowledgement', '{}'::jsonb);
end $$;

create or replace function public.cms_rw_enrol_end(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.cms_rw_enrolments;
begin
  perform private.cms_require('rewards', 'E');
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give the reason.'; end if;
  select * into e from public.cms_rw_enrolments where id = p_id for update;
  if e.id is null or e.status not in ('pending_approval', 'awaiting_ack', 'active') then raise exception 'This enrolment is not running.'; end if;
  perform private.cms_rw_sync(e.id);
  update public.cms_rw_periods set status = 'ineligible', note = 'Enrolment ended: ' || btrim(p_reason) where enrolment_id = e.id and status = 'open';
  update public.cms_rw_enrolments set status = 'ended', ended_on = private.cms_rw_today(), end_reason = btrim(p_reason), updated_at = now() where id = e.id and status <> 'ended';
  perform private.cms_log('rewards.enrol_ended', 'cms_rw_enrolments', e.id::text, null, private.cms_rw_name(e.person_id) || ': certification allowance ended (' || e.type_code || ')', jsonb_build_object('reason', p_reason));
end $$;

-- eligibility review: extend the eligibility period and / or change the amount (Admin / a Director)
create or replace function public.cms_rw_enrol_update(p_id uuid, p_until date, p_amount numeric, p_note text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.cms_rw_enrolments;
begin
  perform private.cms_rw_need_boss();
  select * into e from public.cms_rw_enrolments where id = p_id for update;
  if e.id is null or e.status not in ('awaiting_ack', 'active') then raise exception 'This enrolment is not running.'; end if;
  if p_amount is not null and (p_amount <= 0 or p_amount > 10000) then raise exception 'Amount: more than RM 0.'; end if;
  update public.cms_rw_enrolments set eligible_until = p_until, amount = coalesce(round(p_amount, 2), amount), updated_at = now() where id = e.id;
  perform private.cms_log('rewards.enrol_review', 'cms_rw_enrolments', e.id::text, null, private.cms_rw_name(e.person_id) || ': eligibility to ' || coalesce(to_char(p_until, 'DD Mon YYYY'), 'no end') || ', RM ' || coalesce(round(p_amount, 2), e.amount) || ' a period',
    jsonb_build_object('before', jsonb_build_object('until', e.eligible_until, 'amount', e.amount), 'note', p_note));
  perform private.cms_rw_sync(e.id);
end $$;

create or replace function public.cms_rw_period_decide(p_id uuid, p_approve boolean, p_note text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.cms_rw_period_changes; e public.cms_rw_enrolments;
begin
  perform private.cms_rw_need_boss();
  select * into x from public.cms_rw_period_changes where id = p_id for update;
  if x.id is null or x.status <> 'pending' then raise exception 'This request is not waiting.'; end if;
  select * into e from public.cms_rw_enrolments where id = x.enrolment_id for update;
  update public.cms_rw_period_changes set status = case when p_approve then 'approved' else 'declined' end, decided_by = auth.uid(), decided_at = now(), decide_note = nullif(btrim(coalesce(p_note, '')), '') where id = x.id;
  -- the period running now keeps its length; the new length applies from the next period
  if p_approve then update public.cms_rw_enrolments set period_months = x.to_months, updated_at = now() where id = e.id; end if;
  perform private.cms_log('rewards.period_change', 'cms_rw_period_changes', x.id::text, null, private.cms_rw_name(e.person_id) || ': assessment period ' || x.from_months || ' → ' || x.to_months || ' month(s) ' || case when p_approve then 'approved' else 'declined' end, '{}'::jsonb);
end $$;

create or replace function public.cms_rw_practical_add(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; pid uuid := (p->>'person_id')::uuid;
begin
  perform private.cms_require('rewards', 'E');
  if not exists (select 1 from public.employee_master where id = pid) then raise exception 'Choose the person.'; end if;
  if not exists (select 1 from public.cms_rw_categories where code = p->>'category') then raise exception 'Choose the category.'; end if;
  if nullif(p->>'done_on', '') is null or (p->>'done_on')::date > private.cms_rw_today() then raise exception 'Give the date of the check (not in the future).'; end if;
  insert into public.cms_rw_practicals (person_id, category, done_on, passed, assessor_name, note, recorded_by)
  values (pid, p->>'category', (p->>'done_on')::date, coalesce((p->>'passed')::boolean, false), nullif(btrim(coalesce(p->>'assessor', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid()) returning id into v;
  perform private.cms_log('rewards.practical', 'cms_rw_practicals', v::text, null, private.cms_rw_name(pid) || ': practical check ' || (p->>'category') || ' ' || case when coalesce((p->>'passed')::boolean, false) then 'passed' else 'not passed' end, '{}'::jsonb);
  return v;
end $$;

create or replace function public.cms_rw_practical_retire(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'E');
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_practicals set retired_at = now(), note = coalesce(note || ' · ', '') || 'Withdrawn: ' || btrim(p_reason) where id = p_id and retired_at is null;
  if not found then raise exception 'Not found.'; end if;
  perform private.cms_log('rewards.practical_withdrawn', 'cms_rw_practicals', p_id::text, null, 'Practical check record withdrawn', jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.cms_rw_grant(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_rw_need_boss();
  if p->>'kind' not in ('skip', 'rate') then raise exception 'Choose the kind of surprise.'; end if;
  if not exists (select 1 from public.employee_master where id = (p->>'person_id')::uuid) then raise exception 'Choose the person.'; end if;
  return private.cms_rw_grant_do((p->>'person_id')::uuid, p->>'kind', coalesce(nullif(p->>'from', '')::date, (date_trunc('month', private.cms_rw_today()) + interval '1 month')::date),
    (p->>'months')::int, nullif(p->>'amount', '')::numeric, nullif(p->>'rule_id', '')::uuid, p->>'reason');
end $$;

create or replace function public.cms_rw_grant_revoke(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.cms_rw_grants;
begin
  perform private.cms_rw_need_boss();
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_grants set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason) where id = p_id and revoked_at is null returning * into g;
  if g.id is null then raise exception 'Not found.'; end if;
  perform private.cms_log('rewards.surprise_withdrawn', 'cms_rw_grants', g.id::text, null, private.cms_rw_name(g.person_id) || ': surprise withdrawn (periods already paid stay paid)', jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.cms_rw_rule_save(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := nullif(p->>'id', '')::uuid;
begin
  perform private.cms_rw_need_boss();
  if length(btrim(coalesce(p->>'label', ''))) < 3 then raise exception 'Give the surprise a name.'; end if;
  if p->>'kind' not in ('skip', 'rate') then raise exception 'Choose the kind.'; end if;
  if coalesce((p->>'pct')::numeric, -1) not between 1 and 100 then raise exception 'Mastery: 1 to 100 %%.'; end if;
  if coalesce((p->>'months')::int, 0) not between 1 and 36 then raise exception 'Months: 1 to 36.'; end if;
  if p->>'kind' = 'rate' and coalesce((p->>'amount')::numeric, 0) <= 0 then raise exception 'Give the allowance amount.'; end if;
  if v is null then
    insert into public.cms_rw_rules (label, kind, mastery_pct, months, amount, auto, active, sort, updated_by)
    values (btrim(p->>'label'), p->>'kind', (p->>'pct')::numeric, (p->>'months')::int, case when p->>'kind' = 'rate' then round((p->>'amount')::numeric, 2) end,
      coalesce((p->>'auto')::boolean, false), coalesce((p->>'active')::boolean, true), coalesce((select max(sort) from public.cms_rw_rules), 0) + 1, auth.uid()) returning id into v;
  else
    update public.cms_rw_rules set label = btrim(p->>'label'), kind = p->>'kind', mastery_pct = (p->>'pct')::numeric, months = (p->>'months')::int,
      amount = case when p->>'kind' = 'rate' then round((p->>'amount')::numeric, 2) end, auto = coalesce((p->>'auto')::boolean, false), active = coalesce((p->>'active')::boolean, true),
      updated_by = auth.uid(), updated_at = now() where id = v;
    if not found then raise exception 'Not found.'; end if;
  end if;
  perform private.cms_log('rewards.rule', 'cms_rw_rules', v::text, null, 'Surprise rule saved: ' || btrim(p->>'label'), p);
  return v;
end $$;

create or replace function public.cms_rw_settings_set(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare o jsonb := private.cms_rw_set(); n jsonb; k text; per jsonb;
begin
  perform private.cms_rw_need_boss();
  n := o;
  foreach k in array array['amount', 'open_days', 'questions', 'own', 'pass_pct', 'practical_months'] loop
    if p ? k then n := jsonb_set(n, array[k], to_jsonb((p->>k)::numeric)); end if;
  end loop;
  if p ? 'allowance_from' then n := jsonb_set(n, '{allowance_from}', to_jsonb(date_trunc('month', (p->>'allowance_from')::date)::date)); end if;
  if p ? 'tc' then n := jsonb_set(n, '{tc}', to_jsonb(btrim(p->>'tc'))); end if;
  if p ? 'periods' then
    select jsonb_agg(distinct (x)::int order by (x)::int) into per from jsonb_array_elements_text(p->'periods') x where (x)::int between 1 and 24;
    if per is null then raise exception 'Offer at least one assessment period.'; end if; n := jsonb_set(n, '{periods}', per);
  end if;
  if (n->>'amount')::numeric <= 0 then raise exception 'Amount: more than RM 0.'; end if;
  if (n->>'pass_pct')::numeric not between 1 and 100 then raise exception 'Pass mark: 1 to 100 %%.'; end if;
  if (n->>'questions')::int not between 5 and 100 or (n->>'own')::int not between 0 and (n->>'questions')::int then raise exception 'Questions: 5 to 100; own category: 0 to the number of questions.'; end if;
  if (n->>'open_days')::int not between 1 and 60 then raise exception 'Opens: 1 to 60 days before the end.'; end if;
  if (n->>'practical_months')::int not between 1 and 36 then raise exception 'Practical check: every 1 to 36 months.'; end if;
  if length(coalesce(n->>'tc', '')) < 20 then raise exception 'The terms & conditions are too short.'; end if;
  update public.cms_rw_settings set value = n, updated_by = auth.uid(), updated_at = now() where key = 'cert';
  perform private.cms_log('rewards.settings', 'cms_rw_settings', 'cert', null, 'Certification allowance settings saved', jsonb_build_object('before', o - 'tc', 'after', n - 'tc', 'tc_changed', o->>'tc' is distinct from n->>'tc'));
  return n;
end $$;

create or replace function public.cms_rw_cert_rule_save(p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_rw_need_boss();
  if not exists (select 1 from public.cms_cert_types where code = p->>'code') then raise exception 'Unknown certificate type.'; end if;
  if nullif(p->>'category', '') is not null and not exists (select 1 from public.cms_rw_categories where code = p->>'category') then raise exception 'Unknown category.'; end if;
  insert into public.cms_rw_cert_rules (type_code, eligible, category, amount, eligible_months, updated_by)
  values (p->>'code', coalesce((p->>'eligible')::boolean, false), nullif(p->>'category', ''), round(nullif(p->>'amount', '')::numeric, 2), nullif(p->>'months', '')::int, auth.uid())
  on conflict (type_code) do update set eligible = excluded.eligible, category = excluded.category, amount = excluded.amount, eligible_months = excluded.eligible_months, updated_by = auth.uid(), updated_at = now();
  perform private.cms_log('rewards.cert_rule', 'cms_rw_cert_rules', p->>'code', null, 'Certification allowance rule saved: ' || (p->>'code'), p);
end $$;

-- question bank (HR and above: view and edit; changes are logged)
create or replace function public.cms_rw_questions() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'category', q.category, 'q', q.q, 'options', q.options, 'correct', q.correct, 'video_url', q.video_url, 'video_search', q.video_search,
    'retired', q.retired_at is not null, 'answered', (select count(*) from public.cms_rw_answers a where a.question_id = q.id),
    'right_pct', (select round(100.0 * count(*) filter (where a.correct) / nullif(count(*), 0)) from public.cms_rw_answers a where a.question_id = q.id)) order by q.category, q.sort, q.created_at) from public.cms_rw_questions q), '[]'::jsonb);
end $$;

create or replace function public.cms_rw_question_save(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := nullif(p->>'id', '')::uuid; o jsonb := p->'options'; i int; l text;
begin
  perform private.cms_require('rewards', 'E');
  if not exists (select 1 from public.cms_rw_categories where code = p->>'category') then raise exception 'Choose the category.'; end if;
  if length(btrim(coalesce(p->'q'->>'en', ''))) < 5 then raise exception 'Give the question in English.'; end if;
  if jsonb_typeof(o) <> 'array' or jsonb_array_length(o) <> 3 then raise exception 'Give 3 answers.'; end if;
  for i in 0..2 loop
    if length(btrim(coalesce(o->i->'t'->>'en', ''))) = 0 then raise exception 'Answer % needs English text.', chr(65 + i); end if;
  end loop;
  if coalesce((p->>'correct')::int, -1) not between 0 and 2 then raise exception 'Mark the correct answer.'; end if;
  if nullif(btrim(coalesce(p->>'video_url', '')), '') is not null and p->>'video_url' !~* '^https://' then raise exception 'The video link must start with https://'; end if;
  if v is null then
    insert into public.cms_rw_questions (category, q, options, correct, video_url, video_search, sort, updated_by)
    values (p->>'category', p->'q', o, (p->>'correct')::int, nullif(btrim(coalesce(p->>'video_url', '')), ''), nullif(btrim(coalesce(p->>'video_search', '')), ''),
      coalesce((select max(sort) from public.cms_rw_questions where category = p->>'category'), 0) + 1, auth.uid()) returning id into v;
  else
    update public.cms_rw_questions set category = p->>'category', q = p->'q', options = o, correct = (p->>'correct')::int,
      video_url = nullif(btrim(coalesce(p->>'video_url', '')), ''), video_search = nullif(btrim(coalesce(p->>'video_search', '')), ''), updated_by = auth.uid(), updated_at = now() where id = v;
    if not found then raise exception 'Question not found.'; end if;
  end if;
  perform private.cms_log('rewards.question', 'cms_rw_questions', v::text, null, 'Question ' || case when p ? 'id' and nullif(p->>'id', '') is not null then 'saved' else 'added' end || ': ' || left(p->'q'->>'en', 80), '{}'::jsonb);
  return v;
end $$;

create or replace function public.cms_rw_question_retire(p_id uuid, p_retire boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'E');
  update public.cms_rw_questions set retired_at = case when p_retire then now() end, updated_by = auth.uid(), updated_at = now() where id = p_id;
  if not found then raise exception 'Question not found.'; end if;
  perform private.cms_log('rewards.question', 'cms_rw_questions', p_id::text, null, 'Question ' || case when p_retire then 'taken out of use' else 'back in use' end, '{}'::jsonb);
end $$;

-- import questions from a file (the review pack's bank and later additions): [{c, q:{en,zh,ms}, o:[{t:{…}, why:{…}} ×3], k, v}]
-- a question already in the bank (same category and English text) is skipped, so a file can be imported again safely
create or replace function public.cms_rw_question_import(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare it jsonb; added int := 0; skipped int := 0; bad int := 0; i int; ok boolean;
begin
  perform private.cms_require('rewards', 'E');
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then raise exception 'The file has no questions.'; end if;
  if jsonb_array_length(p) > 1000 then raise exception 'At most 1000 questions in one file.'; end if;
  for it in select value from jsonb_array_elements(p) loop
    ok := jsonb_typeof(it) = 'object' and exists (select 1 from public.cms_rw_categories where code = it->>'c') and length(btrim(coalesce(it->'q'->>'en', ''))) >= 5
      and jsonb_typeof(it->'o') = 'array' and jsonb_array_length(it->'o') = 3 and coalesce((it->>'k')::int, -1) between 0 and 2;
    if ok then for i in 0..2 loop if length(btrim(coalesce(it->'o'->i->'t'->>'en', ''))) = 0 then ok := false; end if; end loop; end if;
    if not ok then bad := bad + 1; continue; end if;
    if exists (select 1 from public.cms_rw_questions where category = it->>'c' and lower(btrim(q->>'en')) = lower(btrim(it->'q'->>'en'))) then skipped := skipped + 1; continue; end if;
    insert into public.cms_rw_questions (category, q, options, correct, video_url, video_search, sort, updated_by)
    values (it->>'c', it->'q', it->'o', (it->>'k')::int, case when it->>'url' ~* '^https://' then it->>'url' end, nullif(btrim(coalesce(it->>'v', '')), ''),
      coalesce((select max(sort) from public.cms_rw_questions where category = it->>'c'), 0) + 1, auth.uid());
    added := added + 1;
  end loop;
  perform private.cms_log('rewards.question_import', 'cms_rw_questions', null, null, 'Question bank import: ' || added || ' added, ' || skipped || ' already there, ' || bad || ' not valid', '{}'::jsonb);
  return jsonb_build_object('added', added, 'skipped', skipped, 'bad', bad);
end $$;
revoke all on function public.cms_rw_question_import(jsonb) from public, anon;
grant execute on function public.cms_rw_question_import(jsonb) to authenticated;

-- reminders for the bell: staff (letter to acknowledge, assessment open) and management (to approve)
create or replace function public.cms_rw_pending() returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me(); t date := private.cms_rw_today(); rr record; mine jsonb := '[]'::jsonb;
begin
  if me is not null and private.cms_self_on(me, 'certs') then
    for rr in select id from public.cms_rw_enrolments where person_id = me and status = 'active' loop perform private.cms_rw_sync(rr.id); end loop;
    mine := coalesce((select jsonb_agg(jsonb_build_object('kind', 'ack', 'label', (select label from public.cms_cert_types where code = e.type_code))) from public.cms_rw_enrolments e where e.person_id = me and e.status = 'awaiting_ack'), '[]'::jsonb)
         || coalesce((select jsonb_agg(jsonb_build_object('kind', 'open', 'label', (select label from public.cms_cert_types where code = e.type_code), 'closes', p.period_end))
              from public.cms_rw_enrolments e join public.cms_rw_periods p on p.enrolment_id = e.id where e.person_id = me and e.status = 'active' and p.status = 'open' and t >= p.opens_on), '[]'::jsonb);
  end if;
  return jsonb_build_object('mine', mine,
    'to_approve', case when private.cms_rw_boss() then (select count(*) from public.cms_rw_enrolments where status = 'pending_approval') + (select count(*) from public.cms_rw_period_changes where status = 'pending') else 0 end,
    'to_enrol', case when public.cms_can('rewards', 'E') then (select count(*) from public.cms_certificates c join public.cms_rw_cert_rules r on r.type_code = c.type_code and r.eligible
        join public.employee_master m on m.id = c.person_id where c.status = 'verified' and (c.expires_on is null or c.expires_on >= t) and m.resignation_letter_date is null
        and not exists (select 1 from public.cms_rw_enrolments e where e.person_id = c.person_id and e.type_code = c.type_code and e.status in ('pending_approval', 'awaiting_ack', 'active'))) else 0 end);
end $$;

-- ---------------------------------------------------------------- grants and the daily run
do $$ declare f text;
begin
  foreach f in array array['public.cms_rw_my()', 'public.cms_rw_acknowledge(uuid, int, text)', 'public.cms_rw_period_request(uuid, int, text)', 'public.cms_rw_start(text, uuid, text, text)',
    'public.cms_rw_submit(uuid, jsonb)', 'public.cms_rw_review(uuid)', 'public.cms_rw_admin()', 'public.cms_rw_enrol(uuid, text)', 'public.cms_rw_enrol_decide(uuid, boolean, text, numeric, date)',
    'public.cms_rw_enrol_end(uuid, text)', 'public.cms_rw_enrol_update(uuid, date, numeric, text)', 'public.cms_rw_period_decide(uuid, boolean, text)', 'public.cms_rw_practical_add(jsonb)',
    'public.cms_rw_practical_retire(uuid, text)', 'public.cms_rw_grant(jsonb)', 'public.cms_rw_grant_revoke(uuid, text)', 'public.cms_rw_rule_save(jsonb)', 'public.cms_rw_settings_set(jsonb)',
    'public.cms_rw_cert_rule_save(jsonb)', 'public.cms_rw_questions()', 'public.cms_rw_question_save(jsonb)', 'public.cms_rw_question_retire(uuid, boolean)', 'public.cms_rw_pending()'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['private.cms_rw_today()', 'private.cms_rw_set()', 'private.cms_rw_boss()', 'private.cms_rw_need_boss()', 'private.cms_rw_name(uuid)', 'private.cms_rw_txt(jsonb, text)',
    'private.cms_rw_mastery(uuid)', 'private.cms_rw_assignment(uuid, date)', 'private.cms_rw_pay(uuid)', 'private.cms_rw_sync(uuid)', 'private.cms_rw_sync_all()', 'private.cms_rw_ready(uuid)',
    'private.cms_rw_grant_do(uuid, text, date, int, numeric, uuid, text)', 'private.cms_rw_enrol_json(public.cms_rw_enrolments)', 'private.cms_rw_attempt_json(public.cms_rw_attempts)',
    'private.cms_rw_review_json(public.cms_rw_attempts)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
  end loop;
end $$;

-- every day 00:10 Malaysia time: periods brought up to date (lost, skipped, ineligible) even when nobody opens the pages
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and not exists (select 1 from cron.job where jobname = 'cms-rw-sync') then
    perform cron.schedule('cms-rw-sync', '10 16 * * *', 'select private.cms_rw_sync_all()');
  end if;
end $$;
