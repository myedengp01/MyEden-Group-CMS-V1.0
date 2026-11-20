-- PRI-026 Company Reward System · Phase 2: Full Attendance and Referral incentives (v2026.11.20). Additive; nothing is removed.
-- Full Attendance: a staff member applies (self-service, My Rewards) for a block of 3 finished calendar months; each month is checked
-- from the payroll leave records (any leave fails the month), employment for the whole month and the resignation letter; confirmed and
-- full-time staff only by default. HR confirms no late arrival / early leave and attendance at the monthly meetings and trainings;
-- Admin / a Director approves the amount (blank by default) and a one-month FULL_ATT line goes to payroll. Blocks never overlap; after
-- a block (passed or not) the next starts fresh.
-- Referral: a staff member refers a candidate (or HR records it); HR links the new hire; Admin / a Director approves the milestone
-- amounts (2024: RM 300 / 400 / 500 at the end of the new hire's 3rd / 7th / 10th month; blank by default). Each milestone is paid as a
-- REFERRAL line when due, if both are still employed (no resignation letter by then); it is held until the referrer is confirmed.

create table if not exists public.cms_rw_att_claims (
  id uuid primary key default gen_random_uuid(), person_id uuid not null references public.employee_master(id),
  start_month date not null, months int not null, words text, detail jsonb,
  status text not null default 'submitted' check (status in ('submitted', 'checked', 'approved', 'declined', 'withdrawn')),
  checks jsonb, checked_by uuid, checked_at timestamptz, check_note text, decided_by uuid, decided_at timestamptz, decide_note text,
  amount numeric(10,2), allowance_id bigint, pay_month date, created_by uuid, created_at timestamptz not null default now());
create index if not exists cms_rw_att_claims_person on public.cms_rw_att_claims (person_id, start_month);
create table if not exists public.cms_rw_referrals (
  id uuid primary key default gen_random_uuid(), referrer_id uuid not null references public.employee_master(id),
  new_hire_id uuid references public.employee_master(id), candidate_name text, candidate_contact text, position text, note text,
  status text not null default 'submitted' check (status in ('submitted', 'linked', 'approved', 'declined', 'ended')),
  created_by uuid, created_at timestamptz not null default now(), linked_by uuid, linked_at timestamptz,
  decided_by uuid, decided_at timestamptz, decide_note text, ended_at timestamptz, end_reason text);
create table if not exists public.cms_rw_ref_payments (
  id uuid primary key default gen_random_uuid(), referral_id uuid not null references public.cms_rw_referrals(id),
  milestone int not null, due_on date not null, amount numeric(10,2) not null,
  status text not null default 'waiting' check (status in ('waiting', 'held', 'paid', 'lost')),
  allowance_id bigint, pay_month date, note text, unique (referral_id, milestone));
do $$ declare t text;
begin
  foreach t in array array['cms_rw_att_claims', 'cms_rw_referrals', 'cms_rw_ref_payments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

insert into public.cms_rw_settings (key, value) values ('incentives', jsonb_build_object(
  'att', jsonb_build_object('amount', null, 'months', 3, 'allow_probation', false, 'allow_part_time', false,
    'checks', jsonb_build_array('No late arrival and no early leave in these months', 'Attended every monthly meeting and training')),
  'ref', jsonb_build_object('milestones', jsonb_build_array(jsonb_build_object('month', 3, 'amount', null), jsonb_build_object('month', 7, 'amount', null), jsonb_build_object('month', 10, 'amount', null)),
    'hold_until_confirmed', true, 'hint', '2024 rules: RM 300 / 400 / 500 (RM 1,200)')))
on conflict (key) do nothing;

-- ---------------------------------------------------------------- helpers
create or replace function private.cms_rw_inc() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select value from public.cms_rw_settings where key = 'incentives' $$;

-- one payroll line (a one-month allowance of a payment type) in the first payroll month not yet finalised, from p_from
create or replace function private.cms_rw_line(p_person uuid, p_type text, p_amount numeric, p_from date, p_note text, out allowance_id bigint, out pay_month date)
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_from)::date; n int := 0; v_asg bigint; v_type bigint;
begin
  while exists (select 1 from public.eppd_pay_runs where period = m and status = 'finalised') and n < 24 loop m := (m + interval '1 month')::date; n := n + 1; end loop;
  pay_month := m;
  select id into v_type from public.eppd_payment_types where code = p_type;
  v_asg := private.cms_rw_assignment(p_person, m);
  if v_asg is null or v_type is null or coalesce(p_amount, 0) <= 0 then allowance_id := null; return; end if;
  insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
  values (v_asg, v_type, round(p_amount, 2), m, (m + interval '1 month - 1 day')::date, p_note) returning id into allowance_id;
end $$;

-- is this person in the scheme (confirmed and full time unless Admin / a Director allowed otherwise)
create or replace function private.cms_rw_att_person(p uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with s as (select private.cms_rw_inc()->'att' a), m as (select * from public.employee_master where id = p)
  select jsonb_build_object('ok', coalesce(((s.a->>'allow_probation')::boolean or m.confirmation_status = 'confirmed'), false)
      and coalesce(((s.a->>'allow_part_time')::boolean or m.employment_type ~* '^(permanent )?full[- ]?time$' or m.employment_type is null), false),
    'reasons', to_jsonb(array_remove(array[
      case when not coalesce((s.a->>'allow_probation')::boolean, false) and coalesce(m.confirmation_status, '') <> 'confirmed' then 'Not confirmed yet (probation)' end,
      case when not coalesce((s.a->>'allow_part_time')::boolean, false) and m.employment_type is not null and m.employment_type !~* '^(permanent )?full[- ]?time$' then 'Not full time (' || m.employment_type || ')' end], null)))
  from s, m $$;

-- one month: finished, employed the whole month, no resignation letter, no leave at all
create or replace function private.cms_rw_att_month(p uuid, p_month date) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with mm as (select date_trunc('month', p_month)::date a, (date_trunc('month', p_month) + interval '1 month - 1 day')::date b),
  m as (select * from public.employee_master where id = p),
  lv as (select l.leave_type, l.days, l.date_from, l.date_to from public.eppd_leave_records l join public.eppd_employees ee on ee.id = l.employee_id, mm
         where ee.employee_master_id = p and coalesce(l.status, 'taken') = 'taken' and l.date_from <= mm.b and coalesce(l.date_to, l.date_from) >= mm.a)
  select jsonb_build_object('month', mm.a, 'finished', mm.b < private.cms_rw_today(),
    'reasons', to_jsonb(array_remove(array[
      case when mm.b >= private.cms_rw_today() then 'Month not finished' end,
      case when m.start_date is null or m.start_date > mm.a then 'Not employed for the whole month' end,
      case when m.resignation_letter_date is not null and m.resignation_letter_date <= mm.b then 'Resignation letter dated ' || to_char(m.resignation_letter_date, 'DD Mon YYYY') end,
      case when exists (select 1 from lv) then 'Leave: ' || (select string_agg(leave_type || ' ' || to_char(date_from, 'DD Mon') || case when coalesce(date_to, date_from) <> date_from then '–' || to_char(date_to, 'DD Mon') else '' end, ', ' order by date_from) from lv) end], null)))
  from mm, m $$;

-- the months of a block that are not clean (empty = the whole block is clean)
create or replace function private.cms_rw_att_block(p uuid, p_start date, p_n int) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(private.cms_rw_att_month(p, (date_trunc('month', p_start) + make_interval(months => g))::date) order by g), '[]'::jsonb) from generate_series(0, p_n - 1) g $$;

-- months already in a block (applied, checked or approved); a new block starts after the last one
create or replace function private.cms_rw_att_next(p uuid) returns date language sql stable security definer set search_path = public, pg_temp as $$
  select max((start_month + make_interval(months => months))::date) from public.cms_rw_att_claims where person_id = p and status in ('submitted', 'checked', 'approved', 'declined') $$;

-- referral milestones: pay what is due
create or replace function private.cms_rw_ref_sync(p_ref uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_referrals; nh public.employee_master; rf public.employee_master; x record; ln record; hold boolean := coalesce((private.cms_rw_inc()->'ref'->>'hold_until_confirmed')::boolean, true);
begin
  select * into r from public.cms_rw_referrals where id = p_ref for update;
  if r.id is null or r.status <> 'approved' then return; end if;
  select * into nh from public.employee_master where id = r.new_hire_id; select * into rf from public.employee_master where id = r.referrer_id;
  for x in select * from public.cms_rw_ref_payments where referral_id = r.id and status in ('waiting', 'held') and due_on < private.cms_rw_today() order by due_on loop
    if nh.resignation_letter_date is not null and nh.resignation_letter_date <= x.due_on or coalesce(nh.actual_last_working_date, 'infinity') <= x.due_on then
      update public.cms_rw_ref_payments set status = 'lost', note = 'The new hire was leaving by the end of month ' || x.milestone where id = x.id;
    elsif rf.resignation_letter_date is not null and rf.resignation_letter_date <= x.due_on then
      update public.cms_rw_ref_payments set status = 'lost', note = 'Referrer''s resignation letter dated ' || to_char(rf.resignation_letter_date, 'DD Mon YYYY') where id = x.id;
    elsif hold and coalesce(rf.confirmation_status, '') <> 'confirmed' then
      update public.cms_rw_ref_payments set status = 'held', note = 'Paid once the referrer is confirmed' where id = x.id;
    else
      select * into ln from private.cms_rw_line(r.referrer_id, 'REFERRAL', x.amount, private.cms_rw_today(),
        'Referral incentive · ' || coalesce(upper(nh.employee_name), '') || ' · end of month ' || x.milestone || ' (' || to_char(x.due_on, 'DD Mon YYYY') || ')');
      update public.cms_rw_ref_payments set status = 'paid', allowance_id = ln.allowance_id, pay_month = ln.pay_month,
        note = case when ln.allowance_id is null then 'No payroll record for the referrer that month: add it by hand' end where id = x.id;
    end if;
  end loop;
end $$;

create or replace function private.cms_rw_inc_sync_all() returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; begin for r in select id from public.cms_rw_referrals where status = 'approved' loop perform private.cms_rw_ref_sync(r.id); end loop; end $$;

create or replace function private.cms_rw_att_json(c public.cms_rw_att_claims) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(c) || jsonb_build_object('name', private.cms_rw_name(c.person_id), 'employee_id', (select employee_id from public.employee_master where id = c.person_id),
    'end_month', (c.start_month + make_interval(months => c.months - 1))::date, 'now', private.cms_rw_att_block(c.person_id, c.start_month, c.months),
    'checked_by_name', private.cms_user_name(c.checked_by), 'decided_by_name', private.cms_user_name(c.decided_by)) $$;

create or replace function private.cms_rw_ref_json(r public.cms_rw_referrals) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(r) || jsonb_build_object('referrer', private.cms_rw_name(r.referrer_id), 'new_hire', private.cms_rw_name(r.new_hire_id),
    'new_hire_start', (select start_date from public.employee_master where id = r.new_hire_id),
    'new_hire_position', (select approved_job_title from public.employee_master where id = r.new_hire_id),
    'referrer_confirmed', (select confirmation_status = 'confirmed' from public.employee_master where id = r.referrer_id),
    'decided_by_name', private.cms_user_name(r.decided_by),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.milestone) from public.cms_rw_ref_payments x where x.referral_id = r.id), '[]'::jsonb)) $$;

-- ---------------------------------------------------------------- staff: My Rewards (self-service part "claims")
create or replace function public.cms_rw_my_rewards() returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims'); s jsonb := private.cms_rw_inc(); n int := coalesce((s->'att'->>'months')::int, 3); nxt date; sug date; t date := private.cms_rw_today(); i int; blk jsonb; rr record;
begin
  for rr in select id from public.cms_rw_referrals where referrer_id = v and status = 'approved' loop perform private.cms_rw_ref_sync(rr.id); end loop;
  nxt := greatest(coalesce(private.cms_rw_att_next(v), '1900-01-01'), (date_trunc('month', coalesce((select start_date from public.employee_master where id = v), t) - interval '1 day') + interval '1 month')::date,
                  (date_trunc('month', t) - interval '12 months')::date);
  -- the earliest clean block of finished months after the last one
  for i in 0..24 loop
    exit when (nxt + make_interval(months => i + n))::date > date_trunc('month', t)::date;
    blk := private.cms_rw_att_block(v, (nxt + make_interval(months => i))::date, n);
    if not exists (select 1 from jsonb_array_elements(blk) e where jsonb_array_length(e->'reasons') > 0) then sug := (nxt + make_interval(months => i))::date; exit; end if;
  end loop;
  return jsonb_build_object('today', t, 'name', private.cms_rw_name(v), 'person_id', v,
    'att', jsonb_build_object('months', n, 'amount', s->'att'->'amount', 'checks', s->'att'->'checks', 'eligible', private.cms_rw_att_person(v), 'next_from', nxt, 'suggest', sug,
      'grid', (select jsonb_agg(private.cms_rw_att_month(v, (date_trunc('month', t) - make_interval(months => g))::date) order by g desc) from generate_series(1, 12) g),
      'claims', coalesce((select jsonb_agg(private.cms_rw_att_json(c) order by c.start_month desc) from public.cms_rw_att_claims c where c.person_id = v), '[]'::jsonb)),
    'ref', jsonb_build_object('milestones', s->'ref'->'milestones', 'hint', s->'ref'->'hint',
      'list', coalesce((select jsonb_agg(private.cms_rw_ref_json(r) order by r.created_at desc) from public.cms_rw_referrals r where r.referrer_id = v), '[]'::jsonb)));
end $$;

create or replace function public.cms_rw_att_apply(p_start date, p_words text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims'); s jsonb := private.cms_rw_inc(); n int := coalesce((s->'att'->>'months')::int, 3); st date := date_trunc('month', p_start)::date; blk jsonb; el jsonb; x uuid; nxt date;
begin
  el := private.cms_rw_att_person(v);
  if not (el->>'ok')::boolean then raise exception 'Not in the Full Attendance scheme: %', (select string_agg(value, '; ') from jsonb_array_elements_text(el->'reasons')); end if;
  if length(btrim(coalesce(p_words, ''))) < 3 or length(p_words) > 120 then raise exception 'Give your 3 words for these months.'; end if;
  nxt := private.cms_rw_att_next(v);
  if nxt is not null and st < nxt then raise exception 'Blocks cannot overlap: the next block can start from %.', to_char(nxt, 'Mon YYYY'); end if;
  blk := private.cms_rw_att_block(v, st, n);
  if exists (select 1 from jsonb_array_elements(blk) e where jsonb_array_length(e->'reasons') > 0) then
    raise exception 'Not every month is clean: %', (select string_agg(to_char((e->>'month')::date, 'Mon YYYY') || ' (' || (select string_agg(value, '; ') from jsonb_array_elements_text(e->'reasons')) || ')', ', ')
      from jsonb_array_elements(blk) e where jsonb_array_length(e->'reasons') > 0);
  end if;
  insert into public.cms_rw_att_claims (person_id, start_month, months, words, detail, created_by) values (v, st, n, btrim(p_words), blk, auth.uid()) returning id into x;
  perform private.cms_log('rewards.att_apply', 'cms_rw_att_claims', x::text, null, private.cms_rw_name(v) || ': Full Attendance applied for ' || to_char(st, 'Mon YYYY') || ' – ' || to_char((st + make_interval(months => n - 1))::date, 'Mon YYYY'), '{}'::jsonb);
  return x;
end $$;

create or replace function public.cms_rw_att_withdraw(p_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims');
begin
  update public.cms_rw_att_claims set status = 'withdrawn' where id = p_id and person_id = v and status = 'submitted';
  if not found then raise exception 'Only an application not yet checked can be withdrawn.'; end if;
  perform private.cms_log('rewards.att_withdraw', 'cms_rw_att_claims', p_id::text, null, private.cms_rw_name(v) || ': Full Attendance application withdrawn', '{}'::jsonb);
end $$;

create or replace function public.cms_rw_ref_submit(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims'); x uuid;
begin
  if length(btrim(coalesce(p->>'name', ''))) < 3 then raise exception 'Give the candidate''s full name.'; end if;
  if length(btrim(coalesce(p->>'contact', ''))) < 5 then raise exception 'Give the candidate''s phone or email.'; end if;
  insert into public.cms_rw_referrals (referrer_id, candidate_name, candidate_contact, position, note, created_by)
  values (v, upper(btrim(p->>'name')), btrim(p->>'contact'), nullif(btrim(coalesce(p->>'position', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid()) returning id into x;
  perform private.cms_log('rewards.ref_submit', 'cms_rw_referrals', x::text, null, private.cms_rw_name(v) || ' referred ' || upper(btrim(p->>'name')), '{}'::jsonb);
  return x;
end $$;

-- ---------------------------------------------------------------- management (module "rewards")
create or replace function public.cms_rw_inc_admin() returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'V');
  perform private.cms_rw_inc_sync_all();
  return jsonb_build_object('settings', private.cms_rw_inc(), 'can_edit', public.cms_can('rewards', 'E'), 'can_boss', private.cms_rw_boss(), 'today', private.cms_rw_today(),
    'att', coalesce((select jsonb_agg(private.cms_rw_att_json(c) order by c.status in ('submitted', 'checked') desc, c.created_at desc) from public.cms_rw_att_claims c where c.status <> 'withdrawn'), '[]'::jsonb),
    'ref', coalesce((select jsonb_agg(private.cms_rw_ref_json(r) order by r.status in ('submitted', 'linked') desc, r.created_at desc) from public.cms_rw_referrals r), '[]'::jsonb),
    'hires', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', upper(m.employee_name), 'employee_id', m.employee_id, 'start_date', m.start_date, 'position', m.approved_job_title) order by m.start_date desc)
        from public.employee_master m where m.start_date >= (private.cms_rw_today() - interval '24 months') and coalesce(m.employment_status, '') <> 'applicant'), '[]'::jsonb));
end $$;

create or replace function public.cms_rw_att_check(p_id uuid, p_ok boolean, p_checks jsonb, p_note text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_rw_att_claims;
begin
  perform private.cms_require('rewards', 'E');
  select * into c from public.cms_rw_att_claims where id = p_id for update;
  if c.id is null or c.status <> 'submitted' then raise exception 'This application is not waiting for HR.'; end if;
  if not p_ok and length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_att_claims set status = case when p_ok then 'checked' else 'declined' end, checks = p_checks, checked_by = auth.uid(), checked_at = now(), check_note = nullif(btrim(coalesce(p_note, '')), '') where id = c.id;
  perform private.cms_log('rewards.att_check', 'cms_rw_att_claims', c.id::text, null, private.cms_rw_name(c.person_id) || ': Full Attendance ' || case when p_ok then 'checked by HR' else 'not met (HR)' end, jsonb_build_object('checks', p_checks, 'note', p_note));
end $$;

create or replace function public.cms_rw_att_decide(p_id uuid, p_approve boolean, p_amount numeric, p_note text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_rw_att_claims; ln record; blk jsonb;
begin
  perform private.cms_rw_need_boss();
  select * into c from public.cms_rw_att_claims where id = p_id for update;
  if c.id is null or c.status <> 'checked' then raise exception 'This application is not waiting for approval.'; end if;
  if not p_approve then
    if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'Give the reason.'; end if;
    update public.cms_rw_att_claims set status = 'declined', decided_by = auth.uid(), decided_at = now(), decide_note = btrim(p_note) where id = c.id;
    perform private.cms_log('rewards.att_decline', 'cms_rw_att_claims', c.id::text, null, private.cms_rw_name(c.person_id) || ': Full Attendance declined', jsonb_build_object('reason', p_note));
    return null;
  end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Give the amount.'; end if;
  blk := private.cms_rw_att_block(c.person_id, c.start_month, c.months);
  if exists (select 1 from jsonb_array_elements(blk) e where jsonb_array_length(e->'reasons') > 0) then raise exception 'A month in this block is no longer clean (a leave record was added?). Check the months.'; end if;
  select * into ln from private.cms_rw_line(c.person_id, 'FULL_ATT', p_amount, private.cms_rw_today(),
    'Full Attendance · ' || to_char(c.start_month, 'Mon YYYY') || ' – ' || to_char((c.start_month + make_interval(months => c.months - 1))::date, 'Mon YYYY'));
  update public.cms_rw_att_claims set status = 'approved', amount = round(p_amount, 2), decided_by = auth.uid(), decided_at = now(), decide_note = nullif(btrim(coalesce(p_note, '')), ''),
    allowance_id = ln.allowance_id, pay_month = ln.pay_month where id = c.id;
  perform private.cms_log('rewards.att_approve', 'cms_rw_att_claims', c.id::text, null, private.cms_rw_name(c.person_id) || ': Full Attendance RM ' || round(p_amount, 2) || ' approved for the ' || to_char(ln.pay_month, 'Mon YYYY') || ' payroll', '{}'::jsonb);
  return jsonb_build_object('pay_month', ln.pay_month, 'in_payroll', ln.allowance_id is not null);
end $$;

-- HR records a referral directly (referrer + new hire), or links a staff member's referral to the new hire
create or replace function public.cms_rw_ref_record(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare x uuid; rf uuid := (p->>'referrer_id')::uuid; nh uuid := (p->>'new_hire_id')::uuid;
begin
  perform private.cms_require('rewards', 'E');
  if not exists (select 1 from public.employee_master where id = rf) or not exists (select 1 from public.employee_master where id = nh) then raise exception 'Choose the referrer and the new hire.'; end if;
  if rf = nh then raise exception 'The referrer and the new hire must be different people.'; end if;
  if exists (select 1 from public.cms_rw_referrals where new_hire_id = nh and status in ('linked', 'approved')) then raise exception 'This new hire already has a referral.'; end if;
  insert into public.cms_rw_referrals (referrer_id, new_hire_id, candidate_name, note, status, created_by, linked_by, linked_at)
  values (rf, nh, private.cms_rw_name(nh), nullif(btrim(coalesce(p->>'note', '')), ''), 'linked', auth.uid(), auth.uid(), now()) returning id into x;
  perform private.cms_log('rewards.ref_record', 'cms_rw_referrals', x::text, null, private.cms_rw_name(rf) || ' referred ' || private.cms_rw_name(nh) || ' (recorded by HR)', '{}'::jsonb);
  return x;
end $$;

create or replace function public.cms_rw_ref_link(p_id uuid, p_new_hire uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_referrals;
begin
  perform private.cms_require('rewards', 'E');
  select * into r from public.cms_rw_referrals where id = p_id for update;
  if r.id is null or r.status not in ('submitted', 'linked') then raise exception 'This referral cannot be linked now.'; end if;
  if not exists (select 1 from public.employee_master where id = p_new_hire) or p_new_hire = r.referrer_id then raise exception 'Choose the new hire.'; end if;
  if exists (select 1 from public.cms_rw_referrals where new_hire_id = p_new_hire and status in ('linked', 'approved') and id <> r.id) then raise exception 'This new hire already has a referral.'; end if;
  update public.cms_rw_referrals set new_hire_id = p_new_hire, status = 'linked', linked_by = auth.uid(), linked_at = now() where id = r.id;
  perform private.cms_log('rewards.ref_link', 'cms_rw_referrals', r.id::text, null, private.cms_rw_name(r.referrer_id) || '''s referral linked to new hire ' || private.cms_rw_name(p_new_hire), '{}'::jsonb);
end $$;

-- Admin / a Director approves: the milestones and their amounts are fixed on the referral
create or replace function public.cms_rw_ref_decide(p_id uuid, p_approve boolean, p_milestones jsonb, p_note text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_referrals; st date; m jsonb;
begin
  perform private.cms_rw_need_boss();
  select * into r from public.cms_rw_referrals where id = p_id for update;
  if r.id is null or r.status not in ('submitted', 'linked') then raise exception 'This referral is not waiting for a decision.'; end if;
  if not p_approve then
    if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'Give the reason.'; end if;
    update public.cms_rw_referrals set status = 'declined', decided_by = auth.uid(), decided_at = now(), decide_note = btrim(p_note) where id = r.id;
    perform private.cms_log('rewards.ref_decline', 'cms_rw_referrals', r.id::text, null, private.cms_rw_name(r.referrer_id) || '''s referral declined', jsonb_build_object('reason', p_note));
    return;
  end if;
  if r.new_hire_id is null then raise exception 'Link the new hire first.'; end if;
  select start_date into st from public.employee_master where id = r.new_hire_id;
  if st is null then raise exception 'The new hire has no start date.'; end if;
  if jsonb_typeof(p_milestones) <> 'array' or jsonb_array_length(p_milestones) = 0 then raise exception 'Give the milestones.'; end if;
  for m in select value from jsonb_array_elements(p_milestones) loop
    if coalesce((m->>'month')::int, 0) not between 1 and 60 or coalesce((m->>'amount')::numeric, 0) <= 0 then raise exception 'Each milestone needs its month and amount.'; end if;
    insert into public.cms_rw_ref_payments (referral_id, milestone, due_on, amount)
    values (r.id, (m->>'month')::int, (st + make_interval(months => (m->>'month')::int))::date - 1, round((m->>'amount')::numeric, 2)) on conflict (referral_id, milestone) do nothing;
  end loop;
  update public.cms_rw_referrals set status = 'approved', decided_by = auth.uid(), decided_at = now(), decide_note = nullif(btrim(coalesce(p_note, '')), '') where id = r.id;
  perform private.cms_log('rewards.ref_approve', 'cms_rw_referrals', r.id::text, null, private.cms_rw_name(r.referrer_id) || '''s referral of ' || private.cms_rw_name(r.new_hire_id) || ' approved', jsonb_build_object('milestones', p_milestones));
  perform private.cms_rw_ref_sync(r.id);
end $$;

create or replace function public.cms_rw_ref_end(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_referrals;
begin
  perform private.cms_require('rewards', 'E');
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_referrals set status = 'ended', ended_at = now(), end_reason = btrim(p_reason) where id = p_id and status in ('submitted', 'linked', 'approved') returning * into r;
  if r.id is null then raise exception 'This referral is not running.'; end if;
  update public.cms_rw_ref_payments set status = 'lost', note = 'Referral ended: ' || btrim(p_reason) where referral_id = r.id and status in ('waiting', 'held');
  perform private.cms_log('rewards.ref_end', 'cms_rw_referrals', r.id::text, null, private.cms_rw_name(r.referrer_id) || '''s referral ended (payments made stay paid)', jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.cms_rw_inc_settings_set(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare o jsonb := private.cms_rw_inc(); n jsonb := o; ms jsonb := '[]'::jsonb; m jsonb;
begin
  perform private.cms_rw_need_boss();
  if p ? 'att' then
    if nullif(p->'att'->>'amount', '') is not null and (p->'att'->>'amount')::numeric <= 0 then raise exception 'Full Attendance amount: more than RM 0, or blank.'; end if;
    if coalesce((p->'att'->>'months')::int, 0) not between 1 and 12 then raise exception 'Full Attendance block: 1 to 12 months.'; end if;
    n := jsonb_set(n, '{att}', (o->'att') || jsonb_build_object('amount', case when nullif(p->'att'->>'amount', '') is null then null else round((p->'att'->>'amount')::numeric, 2) end,
      'months', (p->'att'->>'months')::int, 'allow_probation', coalesce((p->'att'->>'allow_probation')::boolean, false), 'allow_part_time', coalesce((p->'att'->>'allow_part_time')::boolean, false)));
  end if;
  if p ? 'ref' then
    for m in select value from jsonb_array_elements(coalesce(p->'ref'->'milestones', '[]'::jsonb)) loop
      if coalesce((m->>'month')::int, 0) not between 1 and 60 then raise exception 'Referral milestone month: 1 to 60.'; end if;
      ms := ms || jsonb_build_array(jsonb_build_object('month', (m->>'month')::int, 'amount', case when nullif(m->>'amount', '') is null then null else round((m->>'amount')::numeric, 2) end));
    end loop;
    if jsonb_array_length(ms) = 0 then raise exception 'Give at least one referral milestone.'; end if;
    n := jsonb_set(n, '{ref}', (o->'ref') || jsonb_build_object('milestones', ms, 'hold_until_confirmed', coalesce((p->'ref'->>'hold_until_confirmed')::boolean, true)));
  end if;
  update public.cms_rw_settings set value = n, updated_by = auth.uid(), updated_at = now() where key = 'incentives';
  perform private.cms_log('rewards.inc_settings', 'cms_rw_settings', 'incentives', null, 'Full Attendance / Referral settings saved', jsonb_build_object('before', o, 'after', n));
  return n;
end $$;

create or replace function public.cms_rw_inc_pending() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  return jsonb_build_object(
    'att_check', case when public.cms_can('rewards', 'E') then (select count(*) from public.cms_rw_att_claims where status = 'submitted') else 0 end,
    'att_approve', case when private.cms_rw_boss() then (select count(*) from public.cms_rw_att_claims where status = 'checked') else 0 end,
    'ref_link', case when public.cms_can('rewards', 'E') then (select count(*) from public.cms_rw_referrals where status = 'submitted') else 0 end,
    'ref_approve', case when private.cms_rw_boss() then (select count(*) from public.cms_rw_referrals where status = 'linked') else 0 end);
end $$;

do $$ declare f text;
begin
  foreach f in array array['public.cms_rw_my_rewards()', 'public.cms_rw_att_apply(date, text)', 'public.cms_rw_att_withdraw(uuid)', 'public.cms_rw_ref_submit(jsonb)',
    'public.cms_rw_inc_admin()', 'public.cms_rw_att_check(uuid, boolean, jsonb, text)', 'public.cms_rw_att_decide(uuid, boolean, numeric, text)', 'public.cms_rw_ref_record(jsonb)',
    'public.cms_rw_ref_link(uuid, uuid)', 'public.cms_rw_ref_decide(uuid, boolean, jsonb, text)', 'public.cms_rw_ref_end(uuid, text)', 'public.cms_rw_inc_settings_set(jsonb)', 'public.cms_rw_inc_pending()'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['private.cms_rw_inc()', 'private.cms_rw_line(uuid, text, numeric, date, text)', 'private.cms_rw_att_person(uuid)', 'private.cms_rw_att_month(uuid, date)',
    'private.cms_rw_att_block(uuid, date, int)', 'private.cms_rw_att_next(uuid)', 'private.cms_rw_ref_sync(uuid)', 'private.cms_rw_inc_sync_all()',
    'private.cms_rw_att_json(public.cms_rw_att_claims)', 'private.cms_rw_ref_json(public.cms_rw_referrals)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
  end loop;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and not exists (select 1 from cron.job where jobname = 'cms-rw-inc-sync') then
    perform cron.schedule('cms-rw-inc-sync', '15 16 * * *', 'select private.cms_rw_inc_sync_all()');
  end if;
end $$;
