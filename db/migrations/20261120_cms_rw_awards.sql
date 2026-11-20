-- PRI-026 Company Reward System · Phase 3: awards, and the Reward System summary report (v2026.11.20). Additive; nothing is removed.
-- Awards (2024 General Benefit & Award Criteria): a catalogue (cycle, criteria, prizes, cash as Bonus / Incentive / none, amount blank by
-- default, who may take part), rounds opened by HR, nominations (self / colleague in My Rewards, or HR), HR review against the criteria,
-- and Admin / a Director choosing 0 … the maximum number of winners (no award when the standard is not met). A winner's cash is a payroll
-- line of the chosen type; certificates print from the CMS. Long Service (6 / 10 years) is suggested from the service dates.
-- Summary report: permission "rewards.report" (HR, Admin, Directors by default); amounts only for roles that may see salaries.

create table if not exists public.cms_rw_awards (
  code text primary key, name text not null, cycle text not null check (cycle in ('quarterly', 'annual', 'event', 'milestone')),
  max_winners int not null default 1, criteria jsonb not null default '[]'::jsonb, prizes jsonb not null default '[]'::jsonb,
  cash_type text not null default 'BONUS' check (cash_type in ('BONUS', 'INCENTIVE', 'NONE')), amount numeric(10,2),
  allow_probation boolean not null default false, allow_part_time boolean not null default false, self_nominate boolean not null default true,
  peer_nominate boolean not null default true, team boolean not null default false, active boolean not null default true, sort int not null default 0,
  note text, updated_by uuid, updated_at timestamptz not null default now());
create table if not exists public.cms_rw_rounds (
  id uuid primary key default gen_random_uuid(), award_code text not null references public.cms_rw_awards(code), label text not null,
  period_from date not null, period_to date not null, nominate_until date not null,
  status text not null default 'open' check (status in ('open', 'review', 'decided', 'cancelled')),
  note text, created_by uuid, created_at timestamptz not null default now(), decided_by uuid, decided_at timestamptz, decide_note text);
create table if not exists public.cms_rw_noms (
  id uuid primary key default gen_random_uuid(), round_id uuid not null references public.cms_rw_rounds(id),
  person_id uuid references public.employee_master(id), department text, kind text not null check (kind in ('self', 'peer', 'hr')),
  nominated_by uuid, nominator_id uuid references public.employee_master(id), reason text,
  status text not null default 'nominated' check (status in ('nominated', 'reviewed', 'winner', 'not_selected', 'withdrawn')),
  checks jsonb, comment text, reviewed_by uuid, reviewed_at timestamptz, amount numeric(10,2), prizes jsonb,
  allowance_id bigint, pay_month date, note text, created_at timestamptz not null default now());
create index if not exists cms_rw_noms_round on public.cms_rw_noms (round_id);
do $$ declare t text;
begin
  foreach t in array array['cms_rw_awards', 'cms_rw_rounds', 'cms_rw_noms'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

insert into public.cms_rw_awards (code, name, cycle, max_winners, criteria, prizes, cash_type, allow_probation, allow_part_time, self_nominate, peer_nominate, team, sort, note)
select * from (values
 ('STAR_MENTOR', 'Star Mentor', 'quarterly', 4, '["KPI grade S or E for the quarter","Attended every monthly meeting and training","Good behaviour and attitude","Guided and supported colleagues (mentoring)"]'::jsonb, '["Certificate","PIN","Facebook post"]'::jsonb, 'BONUS', false, true, true, true, false, 1, 'Quarterly: January for Oct–Dec, April for Jan–Mar, July for Apr–Jun, October for Jul–Sep. Tie: the biggest improvement (KPI, 1-2-1 goal). Full and part time; temporary workers do not take part.'),
 ('STAR_EMPLOYEE', 'Star Employee', 'quarterly', 4, '["KPI grade S or E for the quarter","Attended every monthly meeting and training","Good behaviour and attitude","Leader''s comment supports the nomination"]'::jsonb, '["Certificate","PIN","Facebook post"]'::jsonb, 'BONUS', false, true, true, true, false, 2, 'Quarterly, as Star Mentor. Tie: the biggest improvement (KPI, 1-2-1 goal).'),
 ('RISING_STAR', 'Rising Star Award', 'annual', 3, '["Confirmed within the last 18 months","KPI grade S or E at least 6 times","Not more than 3 \"I\" grades","Good behaviour and attitude"]'::jsonb, '["Certificate","Trophy"]'::jsonb, 'BONUS', false, false, true, true, false, 3, null),
 ('PERSONAL_DEV', 'Personal Development Award', 'annual', 3, '["Completed courses or certificates for own growth this year (including courses not eligible for the allowance)","Uses what was learned at work","Regular practice of the safety assessments (mastery)"]'::jsonb, '["Certificate"]'::jsonb, 'BONUS', false, false, true, true, false, 4, null),
 ('MOST_CONTRIBUTION', 'Most Contribution Award', 'annual', 1, '["Ideas or improvements adopted by the company","Took on extra duties willingly","Helped at company events and activities"]'::jsonb, '["Certificate","Trophy"]'::jsonb, 'BONUS', false, false, true, true, false, 5, null),
 ('BEST_EMPLOYEE_YEAR', 'Best Employee of The Year', 'annual', 1, '["KPI grade S or E all year","Full attendance most of the year","No warning letter in the year","Role model in behaviour and attitude"]'::jsonb, '["Certificate","Trophy"]'::jsonb, 'BONUS', false, false, false, true, false, 6, null),
 ('BEST_DEPARTMENT', 'Best Department Award', 'annual', 1, '["Department KPI","Team attendance","Error rate not more than 6%","Parent feedback","Damage: under RM 500 minor (−5 KPI points per member that month), RM 500 and above major (−10)"]'::jsonb, '["Certificate","Trophy"]'::jsonb, 'NONE', false, false, false, false, true, 7, 'Departments E1, E3, E6, E7, E8, E10, Driver & Chef (others).'),
 ('MVE', 'Most Valuable Employee Award', 'annual', 1, '["Key to the results of the team","Reliable across departments","Good behaviour and attitude"]'::jsonb, '["Certificate","Trophy"]'::jsonb, 'BONUS', false, false, false, true, false, 8, null),
 ('BEST_APPEARANCE', 'Best Appearance Award', 'annual', 1, '["Neat uniform and grooming all year","Follows the dress code"]'::jsonb, '["Certificate"]'::jsonb, 'BONUS', false, false, true, true, false, 9, null),
 ('LONG_SERVICE', 'Long Service Award', 'milestone', 50, '["6 years (2,190 days) or 10 years (3,650 days) of service"]'::jsonb, '["Certificate","Token of appreciation"]'::jsonb, 'BONUS', false, false, false, false, false, 10, 'Suggested from the service dates; one award per milestone.'),
 ('BEST_DRESS', 'Best Dress Award (Annual Dinner)', 'event', 2, '["Chosen at the Annual Dinner"]'::jsonb, '["Certificate","Prize"]'::jsonb, 'NONE', true, true, true, true, false, 11, null),
 ('SMILEY_FACE', 'Smiley Face Award', 'annual', 1, '["Positive and friendly with parents, children and colleagues","Parent or colleague compliments"]'::jsonb, '["Certificate"]'::jsonb, 'BONUS', false, false, true, true, false, 12, null),
 ('MOST_LOVING', 'Most Loving Award', 'annual', 1, '["Caring and patient with the children","Parent compliments"]'::jsonb, '["Certificate"]'::jsonb, 'BONUS', false, false, true, true, false, 13, null),
 ('BEHIND_SCENE', 'Behind The Scene Award', 'annual', 1, '["Support work that keeps things running","Reliable without being asked"]'::jsonb, '["Certificate"]'::jsonb, 'BONUS', false, false, false, true, false, 14, null),
 ('BOOK_OF_RECORD', 'Book of Record', 'event', 5, '["A notable record or achievement for the company"]'::jsonb, '["Certificate"]'::jsonb, 'NONE', true, true, true, true, false, 15, null)
) v(code, name, cycle, mx, cr, pz, ct, ap, apt, sn, pn, tm, so, nt)
where not exists (select 1 from public.cms_rw_awards);

insert into public.cms_modules (code, label, grp, phase, sort_order, locked, description, acts, kind, parent, act_labels)
select 'rewards.report', 'Reward System · Summary report', 'Performance & Growth', 5, 65, false, 'The Reward System summary: totals paid, coming up, assessments, attendance, referrals, awards and what is waiting', 'V', 'action', 'rewards', '{"V":"See the summary report"}'::jsonb
where not exists (select 1 from public.cms_modules where code = 'rewards.report');
insert into public.cms_role_permissions (role_code, module_code, actions)
select r, 'rewards.report', 'V' from (values ('super_admin'), ('admin'), ('director'), ('hr')) v(r)
where not exists (select 1 from public.cms_role_permissions where module_code = 'rewards.report' and role_code = v.r);

-- ---------------------------------------------------------------- awards
create or replace function private.cms_rw_award_elig(p_code text, p_person uuid, p_to date) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with a as (select * from public.cms_rw_awards where code = p_code), m as (select * from public.employee_master where id = p_person),
  sv as (select (p_to - coalesce(m.original_group_join_date, m.start_date)) d from m)
  select jsonb_build_object('ok', coalesce(array_length(x.r, 1), 0) = 0, 'reasons', to_jsonb(coalesce(x.r, '{}')), 'service_days', (select d from sv))
  from (select array_remove(array[
    case when not a.allow_probation and coalesce(m.confirmation_status, '') <> 'confirmed' then 'On probation' end,
    case when not a.allow_part_time and m.employment_type ~* 'part' then 'Part time' end,
    case when m.employment_type ~* 'temporary|intern|short-term' then 'Temporary / intern' end,
    case when m.resignation_letter_date is not null and m.resignation_letter_date <= p_to then 'Resignation letter dated ' || to_char(m.resignation_letter_date, 'DD Mon YYYY') end,
    case when a.code = 'RISING_STAR' and (m.confirmation_date is null or m.confirmation_date < (p_to - interval '18 months')::date) then 'Not confirmed within the last 18 months' end,
    case when a.code = 'LONG_SERVICE' and coalesce((select d from sv), 0) < 2190 then 'Less than 6 years of service' end], null) r from a, m) x $$;

create or replace function private.cms_rw_round_json(r public.cms_rw_rounds, p_full boolean) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(r) || jsonb_build_object('award', (select name from public.cms_rw_awards where code = r.award_code), 'decided_by_name', private.cms_user_name(r.decided_by),
    'noms', coalesce((select jsonb_agg(to_jsonb(n) || jsonb_build_object('name', private.cms_rw_name(n.person_id), 'nominator', private.cms_rw_name(n.nominator_id),
        'employee_id', (select employee_id from public.employee_master where id = n.person_id), 'company', (select company_code from public.employee_master where id = n.person_id),
        'dept', (select department from public.employee_master where id = n.person_id), 'reviewed_by_name', private.cms_user_name(n.reviewed_by),
        'elig', case when n.person_id is not null then private.cms_rw_award_elig(r.award_code, n.person_id, r.period_to) end)
      order by n.status = 'winner' desc, n.created_at) from public.cms_rw_noms n where n.round_id = r.id and (p_full or n.status = 'winner')), '[]'::jsonb)) $$;

create or replace function public.cms_rw_awards_admin() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'V');
  return jsonb_build_object('can_edit', public.cms_can('rewards', 'E'), 'can_boss', private.cms_rw_boss(), 'today', private.cms_rw_today(),
    'awards', coalesce((select jsonb_agg(to_jsonb(a) order by a.sort) from public.cms_rw_awards a), '[]'::jsonb),
    'rounds', coalesce((select jsonb_agg(private.cms_rw_round_json(r, true) order by r.status in ('open', 'review') desc, r.period_to desc, r.created_at desc) from public.cms_rw_rounds r), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(distinct department order by department) from public.employee_master where employment_status = 'active' and department is not null), '[]'::jsonb),
    -- Long Service: staff reaching 6 or 10 years by the end of this year or the next
    'long_service', coalesce((select jsonb_agg(jsonb_build_object('person_id', m.id, 'name', upper(m.employee_name), 'employee_id', m.employee_id, 'since', coalesce(m.original_group_join_date, m.start_date),
        'years', case when (make_date(extract(year from private.cms_rw_today())::int + 1, 12, 31) - coalesce(m.original_group_join_date, m.start_date)) >= 3650 then 10 else 6 end,
        'on', (coalesce(m.original_group_join_date, m.start_date) + case when (make_date(extract(year from private.cms_rw_today())::int + 1, 12, 31) - coalesce(m.original_group_join_date, m.start_date)) >= 3650 then 3650 else 2190 end))
      order by coalesce(m.original_group_join_date, m.start_date))
      from public.employee_master m where m.employment_status = 'active' and m.resignation_letter_date is null and coalesce(m.original_group_join_date, m.start_date) is not null
        and (make_date(extract(year from private.cms_rw_today())::int + 1, 12, 31) - coalesce(m.original_group_join_date, m.start_date)) >= 2190
        and not exists (select 1 from public.cms_rw_noms n join public.cms_rw_rounds r on r.id = n.round_id where r.award_code = 'LONG_SERVICE' and n.person_id = m.id and n.status = 'winner'
          and n.note = case when (make_date(extract(year from private.cms_rw_today())::int + 1, 12, 31) - coalesce(m.original_group_join_date, m.start_date)) >= 3650 then '10 years' else '6 years' end)), '[]'::jsonb));
end $$;

create or replace function public.cms_rw_award_save(p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_rw_need_boss();
  if not exists (select 1 from public.cms_rw_awards where code = p->>'code') then raise exception 'Unknown award.'; end if;
  if coalesce((p->>'max_winners')::int, 0) not between 1 and 100 then raise exception 'Winners: 1 to 100.'; end if;
  if p->>'cash_type' not in ('BONUS', 'INCENTIVE', 'NONE') then raise exception 'Choose how the cash is paid.'; end if;
  if nullif(p->>'amount', '') is not null and (p->>'amount')::numeric <= 0 then raise exception 'Amount: more than RM 0, or blank.'; end if;
  update public.cms_rw_awards set name = coalesce(nullif(btrim(p->>'name'), ''), name), max_winners = (p->>'max_winners')::int, cash_type = p->>'cash_type',
    amount = round(nullif(p->>'amount', '')::numeric, 2), criteria = coalesce(p->'criteria', criteria), prizes = coalesce(p->'prizes', prizes),
    allow_probation = coalesce((p->>'allow_probation')::boolean, false), allow_part_time = coalesce((p->>'allow_part_time')::boolean, false),
    self_nominate = coalesce((p->>'self_nominate')::boolean, false), peer_nominate = coalesce((p->>'peer_nominate')::boolean, false), active = coalesce((p->>'active')::boolean, true),
    note = nullif(btrim(coalesce(p->>'note', '')), ''), updated_by = auth.uid(), updated_at = now() where code = p->>'code';
  perform private.cms_log('rewards.award', 'cms_rw_awards', p->>'code', null, 'Award settings saved: ' || (p->>'code'), p);
end $$;

create or replace function public.cms_rw_round_open(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_rw_awards; v uuid;
begin
  perform private.cms_require('rewards', 'E');
  select * into a from public.cms_rw_awards where code = p->>'award' and active;
  if a.code is null then raise exception 'Choose an award in use.'; end if;
  if length(btrim(coalesce(p->>'label', ''))) < 2 then raise exception 'Give the round a name (e.g. Q4 2026).'; end if;
  if nullif(p->>'from', '') is null or nullif(p->>'to', '') is null or (p->>'to')::date < (p->>'from')::date then raise exception 'Give the period.'; end if;
  if nullif(p->>'until', '') is null then raise exception 'Give the last day for nominations.'; end if;
  if exists (select 1 from public.cms_rw_rounds where award_code = a.code and lower(label) = lower(btrim(p->>'label')) and status <> 'cancelled') then raise exception 'There is already a round called % for this award.', btrim(p->>'label'); end if;
  insert into public.cms_rw_rounds (award_code, label, period_from, period_to, nominate_until, note, created_by)
  values (a.code, btrim(p->>'label'), (p->>'from')::date, (p->>'to')::date, (p->>'until')::date, nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid()) returning id into v;
  perform private.cms_log('rewards.round_open', 'cms_rw_rounds', v::text, null, a.name || ' · ' || btrim(p->>'label') || ': nominations open until ' || to_char((p->>'until')::date, 'DD Mon YYYY'), '{}'::jsonb);
  return v;
end $$;

create or replace function public.cms_rw_round_set(p_id uuid, p_status text, p_note text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_rounds;
begin
  perform private.cms_require('rewards', 'E');
  select * into r from public.cms_rw_rounds where id = p_id for update;
  if r.id is null or r.status not in ('open', 'review') then raise exception 'This round is already decided or cancelled.'; end if;
  if p_status not in ('open', 'review', 'cancelled') then raise exception 'Unknown status.'; end if;
  if p_status = 'cancelled' and length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_rounds set status = p_status, note = case when p_status = 'cancelled' then coalesce(note || ' · ', '') || 'Cancelled: ' || btrim(p_note) else note end where id = r.id;
  perform private.cms_log('rewards.round_status', 'cms_rw_rounds', r.id::text, null, r.label || ': ' || case p_status when 'open' then 'nominations open again' when 'review' then 'nominations closed, under review' else 'cancelled' end, jsonb_build_object('note', p_note));
end $$;

-- a nomination: HR (anyone, or a department for a team award), or a staff member (self / colleague) while the round is open
create or replace function private.cms_rw_nom_do(p_round uuid, p_person uuid, p_dept text, p_kind text, p_nominator uuid, p_reason text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_rounds; a public.cms_rw_awards; v uuid;
begin
  select * into r from public.cms_rw_rounds where id = p_round; select * into a from public.cms_rw_awards where code = r.award_code;
  if r.id is null or r.status <> 'open' then raise exception 'Nominations for this round are closed.'; end if;
  if a.team then
    if length(btrim(coalesce(p_dept, ''))) = 0 then raise exception 'Choose the department.'; end if;
    if exists (select 1 from public.cms_rw_noms where round_id = r.id and department = btrim(p_dept) and status <> 'withdrawn') then raise exception 'This department is already nominated.'; end if;
  else
    if p_person is null or not exists (select 1 from public.employee_master where id = p_person) then raise exception 'Choose the person.'; end if;
    if exists (select 1 from public.cms_rw_noms where round_id = r.id and person_id = p_person and status <> 'withdrawn') then raise exception 'This person is already nominated in this round.'; end if;
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'Say why (at least a sentence).'; end if;
  insert into public.cms_rw_noms (round_id, person_id, department, kind, nominated_by, nominator_id, reason)
  values (r.id, case when a.team then null else p_person end, case when a.team then btrim(p_dept) end, p_kind, auth.uid(), p_nominator, btrim(p_reason)) returning id into v;
  perform private.cms_log('rewards.nominate', 'cms_rw_noms', v::text, null, a.name || ' · ' || r.label || ': ' || coalesce(private.cms_rw_name(p_person), btrim(p_dept)) || ' nominated (' || p_kind || ')', '{}'::jsonb);
  return v;
end $$;

create or replace function public.cms_rw_nom_add(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('rewards', 'E');
  return private.cms_rw_nom_do((p->>'round_id')::uuid, nullif(p->>'person_id', '')::uuid, p->>'department', 'hr', private.cms_me(), p->>'reason');
end $$;

create or replace function public.cms_rw_nominate(p_round uuid, p_person uuid, p_reason text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims'); a public.cms_rw_awards;
begin
  select w.* into a from public.cms_rw_awards w join public.cms_rw_rounds r on r.award_code = w.code where r.id = p_round;
  if a.code is null or a.team then raise exception 'This award is not open to nominations from staff.'; end if;
  if (select nominate_until from public.cms_rw_rounds where id = p_round) < private.cms_rw_today() then raise exception 'Nominations for this round have closed.'; end if;
  if p_person = v and not a.self_nominate then raise exception 'This award does not take self-nominations.'; end if;
  if p_person <> v and not a.peer_nominate then raise exception 'This award does not take nominations from colleagues.'; end if;
  if not exists (select 1 from public.employee_master where id = p_person and employment_status = 'active') then raise exception 'Choose a colleague who works here.'; end if;
  return private.cms_rw_nom_do(p_round, p_person, null, case when p_person = v then 'self' else 'peer' end, v, p_reason);
end $$;

create or replace function public.cms_rw_nom_review(p_id uuid, p_checks jsonb, p_comment text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare n public.cms_rw_noms;
begin
  perform private.cms_require('rewards', 'E');
  select * into n from public.cms_rw_noms where id = p_id for update;
  if n.id is null or n.status not in ('nominated', 'reviewed') or (select status from public.cms_rw_rounds where id = n.round_id) not in ('open', 'review') then raise exception 'This nomination cannot be reviewed now.'; end if;
  update public.cms_rw_noms set checks = p_checks, comment = nullif(btrim(coalesce(p_comment, '')), ''), status = 'reviewed', reviewed_by = auth.uid(), reviewed_at = now() where id = n.id;
  perform private.cms_log('rewards.nom_review', 'cms_rw_noms', n.id::text, null, coalesce(private.cms_rw_name(n.person_id), n.department) || ': nomination reviewed', jsonb_build_object('checks', p_checks, 'comment', p_comment));
end $$;

create or replace function public.cms_rw_nom_withdraw(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare n public.cms_rw_noms;
begin
  perform private.cms_require('rewards', 'E');
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give the reason.'; end if;
  update public.cms_rw_noms set status = 'withdrawn', note = 'Withdrawn: ' || btrim(p_reason) where id = p_id and status in ('nominated', 'reviewed') returning * into n;
  if n.id is null then raise exception 'This nomination cannot be withdrawn.'; end if;
  perform private.cms_log('rewards.nom_withdraw', 'cms_rw_noms', n.id::text, null, coalesce(private.cms_rw_name(n.person_id), n.department) || ': nomination withdrawn', jsonb_build_object('reason', p_reason));
end $$;

-- Admin / a Director decides: winners (0 … max) with their amount; everyone else is not selected
create or replace function public.cms_rw_round_decide(p_id uuid, p_winners jsonb, p_note text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_rw_rounds; a public.cms_rw_awards; w jsonb; n public.cms_rw_noms; v_al bigint; v_pm date; k int := 0; paid int := 0;
begin
  perform private.cms_rw_need_boss();
  select * into r from public.cms_rw_rounds where id = p_id for update; select * into a from public.cms_rw_awards where code = r.award_code;
  if r.id is null or r.status not in ('open', 'review') then raise exception 'This round is already decided or cancelled.'; end if;
  if jsonb_typeof(coalesce(p_winners, '[]'::jsonb)) <> 'array' then raise exception 'Bad winners list.'; end if;
  if jsonb_array_length(coalesce(p_winners, '[]'::jsonb)) > a.max_winners then raise exception 'At most % winner(s) for this award.', a.max_winners; end if;
  if jsonb_array_length(coalesce(p_winners, '[]'::jsonb)) = 0 and length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'No winner: say why (e.g. the standard was not met).'; end if;
  for w in select value from jsonb_array_elements(coalesce(p_winners, '[]'::jsonb)) loop
    select * into n from public.cms_rw_noms where id = (w->>'id')::uuid and round_id = r.id and status in ('nominated', 'reviewed') for update;
    if n.id is null then raise exception 'A chosen winner is not a nomination of this round.'; end if;
    if a.cash_type <> 'NONE' and n.person_id is not null and nullif(w->>'amount', '') is not null and (w->>'amount')::numeric > 0 then
      select l.allowance_id, l.pay_month into v_al, v_pm from private.cms_rw_line(n.person_id, a.cash_type, (w->>'amount')::numeric, private.cms_rw_today(), a.name || ' · ' || r.label) l;
      paid := paid + 1;
    else v_al := null; v_pm := null; end if;
    update public.cms_rw_noms set status = 'winner', amount = round(nullif(w->>'amount', '')::numeric, 2), prizes = coalesce(w->'prizes', a.prizes),
      allowance_id = v_al, pay_month = v_pm, note = coalesce(nullif(w->>'note', ''), note) where id = n.id;
    k := k + 1;
  end loop;
  update public.cms_rw_noms set status = 'not_selected' where round_id = r.id and status in ('nominated', 'reviewed');
  update public.cms_rw_rounds set status = 'decided', decided_by = auth.uid(), decided_at = now(), decide_note = nullif(btrim(coalesce(p_note, '')), '') where id = r.id;
  perform private.cms_log('rewards.round_decide', 'cms_rw_rounds', r.id::text, null, a.name || ' · ' || r.label || ': ' || k || ' winner(s)', jsonb_build_object('winners', p_winners, 'note', p_note));
  return jsonb_build_object('winners', k, 'paid', paid);
end $$;

-- staff: open rounds, colleagues to nominate, and their own awards
create or replace function public.cms_rw_my_awards() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('claims');
begin
  return jsonb_build_object('person_id', v,
    'rounds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label, 'award', a.name, 'code', a.code, 'cycle', a.cycle, 'criteria', a.criteria, 'prizes', a.prizes, 'from', r.period_from, 'to', r.period_to,
        'until', r.nominate_until, 'self', a.self_nominate, 'peer', a.peer_nominate, 'mine', (select jsonb_agg(jsonb_build_object('name', private.cms_rw_name(n.person_id), 'status', n.status)) from public.cms_rw_noms n where n.round_id = r.id and n.nominator_id = v)) order by r.nominate_until)
      from public.cms_rw_rounds r join public.cms_rw_awards a on a.code = r.award_code where r.status = 'open' and r.nominate_until >= private.cms_rw_today() and not a.team and (a.self_nominate or a.peer_nominate)), '[]'::jsonb),
    'colleagues', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', upper(m.employee_name), 'dept', m.department) order by m.employee_name) from public.employee_master m where m.employment_status = 'active'), '[]'::jsonb),
    'awards', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'award', a.name, 'label', r.label, 'decided_at', r.decided_at, 'prizes', n.prizes, 'amount', n.amount, 'pay_month', n.pay_month, 'note', n.note) order by r.decided_at desc)
      from public.cms_rw_noms n join public.cms_rw_rounds r on r.id = n.round_id join public.cms_rw_awards a on a.code = r.award_code where n.person_id = v and n.status = 'winner'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- summary report
create or replace function public.cms_rw_report(p_from date, p_to date, p_company text) returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare co text := nullif(upper(btrim(coalesce(p_company, ''))), ''); f date := date_trunc('month', p_from)::date; t date := (date_trunc('month', p_to) + interval '1 month - 1 day')::date;
  money boolean := public.cms_can('people.salary', 'V'); today date := private.cms_rw_today(); pay jsonb;
begin
  perform private.cms_require('rewards.report', 'V');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Give the period.'; end if;
  -- every payment the Reward System put into payroll, by payroll month
  create temp table if not exists rw_pay (kind text, person_id uuid, pay_month date, amount numeric, label text) on commit drop;
  truncate rw_pay;
  insert into rw_pay select 'Certification allowance', e.person_id, p.pay_month, p.amount, coalesce((select label from public.cms_cert_types where code = e.type_code), e.type_code)
    from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id where p.status in ('passed', 'exempt') and p.pay_month between f and t;
  insert into rw_pay select 'Full Attendance', c.person_id, c.pay_month, c.amount, to_char(c.start_month, 'Mon YYYY') from public.cms_rw_att_claims c where c.status = 'approved' and c.pay_month between f and t;
  insert into rw_pay select 'Referral', r.referrer_id, x.pay_month, x.amount, private.cms_rw_name(r.new_hire_id) from public.cms_rw_ref_payments x join public.cms_rw_referrals r on r.id = x.referral_id where x.status = 'paid' and x.pay_month between f and t;
  insert into rw_pay select 'Awards', n.person_id, n.pay_month, n.amount, a.name from public.cms_rw_noms n join public.cms_rw_rounds r on r.id = n.round_id join public.cms_rw_awards a on a.code = r.award_code
    where n.status = 'winner' and n.person_id is not null and n.amount is not null and n.pay_month between f and t;
  if co is not null then
    update rw_pay set kind = null where person_id not in (select id from public.employee_master where private.cms_canon(company_code) = private.cms_canon(co));
  end if;
  return jsonb_build_object('from', f, 'to', t, 'company', co, 'money', money, 'today', today,
    'paid', jsonb_build_object(
      'by_kind', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'count', n, 'amount', case when money then amt end) order by kind) from (select kind, count(*) n, sum(amount) amt from rw_pay where kind is not null group by kind) x), '[]'::jsonb),
      'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', pay_month, 'kind', kind, 'count', n, 'amount', case when money then amt end) order by pay_month, kind) from (select pay_month, kind, count(*) n, sum(amount) amt from rw_pay where kind is not null group by 1, 2) x), '[]'::jsonb),
      'by_company', coalesce((select jsonb_agg(jsonb_build_object('company', c, 'count', n, 'amount', case when money then amt end) order by c) from (select private.cms_canon(m.company_code) c, count(*) n, sum(p.amount) amt from rw_pay p join public.employee_master m on m.id = p.person_id where p.kind is not null group by 1) x), '[]'::jsonb),
      'people', coalesce((select jsonb_agg(jsonb_build_object('name', private.cms_rw_name(pid), 'employee_id', (select employee_id from public.employee_master where id = pid), 'company', (select company_code from public.employee_master where id = pid),
          'dept', (select department from public.employee_master where id = pid), 'cert', case when money then c1 end, 'att', case when money then c2 end, 'ref', case when money then c3 end, 'award', case when money then c4 end,
          'total', case when money then tot end, 'items', n) order by tot desc) from (select person_id pid, sum(amount) filter (where kind = 'Certification allowance') c1, sum(amount) filter (where kind = 'Full Attendance') c2,
          sum(amount) filter (where kind = 'Referral') c3, sum(amount) filter (where kind = 'Awards') c4, sum(amount) tot, count(*) n from rw_pay where kind is not null group by person_id) x), '[]'::jsonb)),
    'coming', jsonb_build_object(
      'periods_open', (select count(*) from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id join public.employee_master m on m.id = e.person_id where p.status = 'open' and e.status = 'active' and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'periods_open_amount', case when money then (select sum(e.amount) from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id join public.employee_master m on m.id = e.person_id where p.status = 'open' and e.status = 'active' and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))) end,
      'referrals', coalesce((select jsonb_agg(jsonb_build_object('referrer', private.cms_rw_name(r.referrer_id), 'new_hire', private.cms_rw_name(r.new_hire_id), 'milestone', x.milestone, 'due_on', x.due_on, 'status', x.status, 'amount', case when money then x.amount end) order by x.due_on)
        from public.cms_rw_ref_payments x join public.cms_rw_referrals r on r.id = x.referral_id join public.employee_master m on m.id = r.referrer_id
        where x.status in ('waiting', 'held') and x.due_on <= (today + interval '3 months')::date and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))), '[]'::jsonb)),
    'cert', jsonb_build_object(
      'enrolled', coalesce((select jsonb_agg(jsonb_build_object('type', lbl, 'status', st, 'count', n) order by lbl, st) from (select coalesce(ct.label, e.type_code) lbl, e.status st, count(*) n from public.cms_rw_enrolments e
          left join public.cms_cert_types ct on ct.code = e.type_code join public.employee_master m on m.id = e.person_id where (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1, 2) x), '[]'::jsonb),
      'assessments', (select count(*) from public.cms_rw_attempts a join public.employee_master m on m.id = a.person_id where a.kind = 'assessment' and a.submitted_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'passed', (select count(*) from public.cms_rw_attempts a join public.employee_master m on m.id = a.person_id where a.kind = 'assessment' and a.passed and a.submitted_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'practice', (select count(*) from public.cms_rw_attempts a join public.employee_master m on m.id = a.person_id where a.kind = 'practice' and a.submitted_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'periods', coalesce((select jsonb_agg(jsonb_build_object('status', st, 'count', n)) from (select p.status st, count(*) n from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id join public.employee_master m on m.id = e.person_id
          where p.period_end between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1) x), '[]'::jsonb),
      'first_try', (select round(100.0 * count(*) filter (where first_ok) / nullif(count(*), 0)) from (select p.id, (select a.passed from public.cms_rw_attempts a where a.period_id = p.id and a.submitted_at is not null order by a.submitted_at limit 1) first_ok
          from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id join public.employee_master m on m.id = e.person_id where p.status = 'passed' and p.period_end between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))) x),
      'avg_tries', (select round(avg(n), 1) from (select p.id, (select count(*) from public.cms_rw_attempts a where a.period_id = p.id and a.submitted_at is not null) n
          from public.cms_rw_periods p join public.cms_rw_enrolments e on e.id = p.enrolment_id join public.employee_master m on m.id = e.person_id where p.status = 'passed' and p.period_end between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))) x),
      'practical_overdue', (select count(*) from (select distinct on (person_id, category) person_id, done_on from public.cms_rw_practicals where retired_at is null order by person_id, category, done_on desc) x
          join public.employee_master m on m.id = x.person_id where (x.done_on + make_interval(months => coalesce((private.cms_rw_set()->>'practical_months')::int, 6)))::date < today and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'reviews_due', (select count(*) from public.cms_rw_enrolments e join public.employee_master m on m.id = e.person_id where e.status in ('active', 'awaiting_ack') and e.eligible_until is not null and e.eligible_until <= (today + interval '60 days')::date and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'mastery', coalesce((select jsonb_agg(x order by (x->'mastery'->>'progress')::numeric desc) from (select jsonb_build_object('name', private.cms_rw_name(pid), 'mastery', private.cms_rw_mastery(pid)) x
          from (select distinct a.person_id pid from public.cms_rw_attempts a join public.employee_master m on m.id = a.person_id where (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))) q) z), '[]'::jsonb),
      'hardest', coalesce((select jsonb_agg(jsonb_build_object('category', category, 'q', q, 'answered', n, 'right_pct', pct) order by pct, n desc) from (select qq.category, qq.q->>'en' q, count(*) n, round(100.0 * count(*) filter (where an.correct) / count(*)) pct
          from public.cms_rw_answers an join public.cms_rw_questions qq on qq.id = an.question_id join public.employee_master m on m.id = an.person_id
          where an.answered_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1, 2 having count(*) >= 5 order by 4, 3 desc limit 10) x), '[]'::jsonb)),
    'att', jsonb_build_object(
      'by_status', coalesce((select jsonb_agg(jsonb_build_object('status', st, 'count', n)) from (select c.status st, count(*) n from public.cms_rw_att_claims c join public.employee_master m on m.id = c.person_id
          where c.created_at::date between f and t and c.status <> 'withdrawn' and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1) x), '[]'::jsonb),
      'qualified', coalesce((select jsonb_agg(jsonb_build_object('name', private.cms_rw_name(c.person_id), 'months', to_char(c.start_month, 'Mon YYYY') || ' – ' || to_char((c.start_month + make_interval(months => c.months - 1))::date, 'Mon YYYY'), 'amount', case when money then c.amount end) order by c.start_month)
          from public.cms_rw_att_claims c join public.employee_master m on m.id = c.person_id where c.status = 'approved' and c.decided_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))), '[]'::jsonb)),
    'ref', jsonb_build_object(
      'made', (select count(*) from public.cms_rw_referrals r join public.employee_master m on m.id = r.referrer_id where r.created_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'hired', (select count(*) from public.cms_rw_referrals r join public.employee_master m on m.id = r.referrer_id where r.new_hire_id is not null and r.created_at::date between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co))),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('status', st, 'count', n, 'amount', case when money then amt end)) from (select x.status st, count(*) n, sum(x.amount) amt from public.cms_rw_ref_payments x join public.cms_rw_referrals r on r.id = x.referral_id
          join public.employee_master m on m.id = r.referrer_id where x.due_on between f and t and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1) z), '[]'::jsonb),
      'top', coalesce((select jsonb_agg(jsonb_build_object('name', private.cms_rw_name(rid), 'referrals', n, 'hired', h) order by h desc, n desc) from (select r.referrer_id rid, count(*) n, count(*) filter (where r.new_hire_id is not null) h
          from public.cms_rw_referrals r join public.employee_master m on m.id = r.referrer_id where r.status <> 'declined' and (co is null or private.cms_canon(m.company_code) = private.cms_canon(co)) group by 1 order by 3 desc, 2 desc limit 10) x), '[]'::jsonb)),
    'awards', coalesce((select jsonb_agg(jsonb_build_object('award', a.name, 'round', r.label, 'status', r.status, 'nominations', (select count(*) from public.cms_rw_noms n where n.round_id = r.id and n.status <> 'withdrawn'),
        'winners', (select jsonb_agg(coalesce(private.cms_rw_name(n.person_id), n.department) || case when money and n.amount is not null then ' (RM ' || to_char(n.amount, 'FM999,990.00') || ')' else '' end) from public.cms_rw_noms n where n.round_id = r.id and n.status = 'winner'))
        order by r.period_to desc, a.sort) from public.cms_rw_rounds r join public.cms_rw_awards a on a.code = r.award_code where r.status <> 'cancelled' and r.period_to >= f and r.period_from <= t), '[]'::jsonb),
    'waiting', coalesce((select jsonb_agg(x order by (x->>'since') ) from (
        select jsonb_build_object('what', 'Certification enrolment to approve', 'who', private.cms_rw_name(person_id), 'since', created_at, 'days', today - created_at::date) x from public.cms_rw_enrolments where status = 'pending_approval'
        union all select jsonb_build_object('what', 'Eligibility letter not acknowledged', 'who', private.cms_rw_name(person_id), 'since', approved_at, 'days', today - approved_at::date) from public.cms_rw_enrolments where status = 'awaiting_ack'
        union all select jsonb_build_object('what', 'Assessment period change', 'who', private.cms_rw_name(e.person_id), 'since', x.requested_at, 'days', today - x.requested_at::date) from public.cms_rw_period_changes x join public.cms_rw_enrolments e on e.id = x.enrolment_id where x.status = 'pending'
        union all select jsonb_build_object('what', case c.status when 'submitted' then 'Full Attendance: HR check' else 'Full Attendance: approval' end, 'who', private.cms_rw_name(c.person_id), 'since', c.created_at, 'days', today - c.created_at::date) from public.cms_rw_att_claims c where c.status in ('submitted', 'checked')
        union all select jsonb_build_object('what', case r.status when 'submitted' then 'Referral: link the new hire' else 'Referral: approval' end, 'who', private.cms_rw_name(r.referrer_id), 'since', r.created_at, 'days', today - r.created_at::date) from public.cms_rw_referrals r where r.status in ('submitted', 'linked')
        union all select jsonb_build_object('what', 'Award round to decide: ' || a.name, 'who', r.label, 'since', r.nominate_until, 'days', greatest(today - r.nominate_until, 0)) from public.cms_rw_rounds r join public.cms_rw_awards a on a.code = r.award_code where r.status in ('open', 'review') and r.nominate_until < today
      ) q), '[]'::jsonb));
end $$;

do $$ declare f text;
begin
  foreach f in array array['public.cms_rw_awards_admin()', 'public.cms_rw_award_save(jsonb)', 'public.cms_rw_round_open(jsonb)', 'public.cms_rw_round_set(uuid, text, text)', 'public.cms_rw_nom_add(jsonb)',
    'public.cms_rw_nominate(uuid, uuid, text)', 'public.cms_rw_nom_review(uuid, jsonb, text)', 'public.cms_rw_nom_withdraw(uuid, text)', 'public.cms_rw_round_decide(uuid, jsonb, text)',
    'public.cms_rw_my_awards()', 'public.cms_rw_report(date, date, text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['private.cms_rw_award_elig(text, uuid, date)', 'private.cms_rw_round_json(public.cms_rw_rounds, boolean)', 'private.cms_rw_nom_do(uuid, uuid, text, text, uuid, text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
  end loop;
end $$;
