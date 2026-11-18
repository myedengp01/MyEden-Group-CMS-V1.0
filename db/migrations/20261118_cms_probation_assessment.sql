-- MyEden Group CMS V1.0 · v2026.11.18 · PRI-023 Phase 1: probation assessment on the JD KPIs (CLC 18 Nov 2026).
-- · Settings (eppd_policies 'probation_assessment', editable): grade bands E 90 / S 75 / A 60 / I 45 (% from), pass grade S, must-pass areas
--   ("child safety" at least 4), PIP 3 months (editable per case), probation cap 12 months, reviewers JD level L3 and above, review starts
--   30 days before probation ends, early-warning check-in at the halfway point.
-- · Rubric: 5 checks per KPI area, 1 point each, minimum score 1 (cms_kpi_rubrics; '*' = the general ladder used until an area has its own).
--   The score sheet (areas + check wording) is frozen into the review when it starts. Duplicated general rows removed.
-- · More than one reviewer (cms_appraisal_reviewers): each scores on their own sheet; the review shows the average per KPI (2 decimals),
--   total, % = total ÷ (criteria × 5) × 100, grade from the bands, must-pass check, pass / not passed.
-- · Flow: reviewers score → HR checks (recommendation, grade override only with a reason) → Director (performance.probation 'A') approves.
--   Pass → confirm (early confirmation allowed during the PIP, with the confirmation date). Below the pass → extend with a PIP
--   (length per case, monthly reviews); during the PIP: continue / confirm; last month below → end or extend again.
-- · Outside the CMS: HR records a result done on paper (note, letter date / reference), the Director approves.
-- · Daily job: starts probation reviews 30 days before the end and the halfway check-ins.
-- · Permission module performance.probation (V view, C score as a reviewer, E HR check / start / reviewers / letters, A approve / settings).

-- ------------------------------------------------------------------ settings, permissions
insert into public.eppd_policies (key, value, description, updated_at) values ('probation_assessment',
  '{"bands":{"E":90,"S":75,"A":60,"I":45},"pass_grade":"S","must_pass":[{"match":"child safety","min":4}],"pip_months":3,"cap_months":12,"min_reviewer_level":3,"start_days_before":30,"early_warning":true}'::jsonb,
  'Probation assessment on the JD KPIs (PRI-023): grade bands (% from), pass grade, must-pass areas, PIP months, cap, reviewer level, start days, check-in', now())
on conflict (key) do nothing;

insert into public.cms_modules (code, label, grp, phase, sort_order)
values ('performance.probation', 'Probation Reviews', 'Performance & Growth', 5, 60) on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'performance.probation', 'VCEADX'), ('admin', 'performance.probation', 'VCEADX'), ('hr', 'performance.probation', 'VCE'),
  ('director', 'performance.probation', 'VCA')
on conflict do nothing;

-- ------------------------------------------------------------------ tables / columns
create table if not exists public.cms_kpi_rubrics (
  area_key   text primary key,            -- lower-case KPI area, or '*' for the general ladder
  area       text not null,
  checks     jsonb not null,              -- 5 statements, 1 point each
  status     text not null default 'approved' check (status in ('draft', 'approved')),
  updated_by uuid, updated_at timestamptz not null default now()
);
alter table public.cms_kpi_rubrics enable row level security;

create table if not exists public.cms_appraisal_reviewers (
  appraisal_id uuid not null references public.cms_appraisals(id) on delete cascade,
  reviewer_id  uuid not null references public.employee_master(id) on delete cascade,
  lead         boolean not null default false,
  sheet        jsonb,                     -- [{area, ticks:[5 booleans], score, comment, evidence}]
  submitted_at timestamptz,
  added_by uuid, added_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  primary key (appraisal_id, reviewer_id)
);
alter table public.cms_appraisal_reviewers enable row level security;

alter table public.cms_appraisals add column if not exists result jsonb;
alter table public.cms_appraisals add column if not exists rating_auto text;
alter table public.cms_appraisals add column if not exists rating_reason text;
alter table public.cms_appraisals add column if not exists pip_month int;
alter table public.cms_appraisals add column if not exists pip_months int;
alter table public.cms_appraisals add column if not exists pip_targets jsonb;
alter table public.cms_appraisals add column if not exists next_pip_months int;
alter table public.cms_appraisals add column if not exists confirm_on date;
alter table public.cms_appraisals add column if not exists outside boolean not null default false;
alter table public.cms_appraisals add column if not exists outside_note text;
alter table public.cms_appraisals add column if not exists outside_letter_date date;
alter table public.cms_appraisals drop constraint if exists cms_appraisals_kind_check;
alter table public.cms_appraisals add constraint cms_appraisals_kind_check check (kind in ('probation', 'annual', 'checkin'));
alter table public.cms_appraisals drop constraint if exists cms_appraisals_recommendation_check;
alter table public.cms_appraisals add constraint cms_appraisals_recommendation_check
  check (recommendation in ('confirm', 'extend', 'end', 'continue', 'increment', 'promote', 'no_change', 'pip', 'on_track', 'at_risk'));

-- the lead reviewer of the reviews already open becomes their first reviewer
insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead)
select a.id, a.reviewer_id, true from public.cms_appraisals a where a.kind = 'probation' and a.status in ('open', 'reviewed') and a.reviewer_id is not null
on conflict do nothing;

-- ------------------------------------------------------------------ rubric seed
insert into public.cms_kpi_rubrics (area_key, area, checks) values
 ('*', 'General ladder (any KPI area without its own checks)', '["Knows the standard: can explain the procedure or expectation for this area","Does it correctly with guidance or reminders","Does it correctly and independently on most observed occasions","Records and evidence are complete, accurate and on time; no repeated issue in the period","Goes beyond: improves something, helps others, or receives positive feedback"]'),
 ('accuracy and timeliness of assigned work', 'Accuracy and timeliness of assigned work', '["Knows what is expected for each assigned task and its deadline","Completes assigned work correctly when checked or reminded","Completes work correctly and on time without reminders","Work is complete and traceable (records, sign-offs); no repeated errors in the period","Spots and corrects errors early, or helps improve how the work is done"]'),
 ('attendance, punctuality and learning progress', 'Attendance, punctuality and learning progress', '["Knows the working hours, leave and lateness rules and the learning required","Attendance and punctuality mostly within policy, with reminders","No unapproved absence or repeated lateness in the period","Required training / learning completed on time, with records","Takes extra learning or applies it visibly in daily work"]'),
 ('child safety and supervision compliance', 'Child safety and supervision compliance', '["Can state the child-to-staff ratio, the headcount routine and the emergency steps","Keeps the ratio and does a headcount at every transition","No incident in the period caused by a lapse in supervision","Every incident / accident report is complete and submitted the same day","Spots hazards and reports or fixes them before anyone is hurt"]'),
 ('feeding, hygiene, sleep and care-record accuracy', 'Feeding, hygiene, sleep and care-record accuracy', '["Knows each child''s feeding, allergy and sleep needs on record","Follows the feeding, nappy, sleep and hygiene routines correctly","Care records are complete for every child, every day","Records are written at the time, with no errors found when checked","Notices changes in a child and reports them to the lead or the parents"]'),
 ('health, sanitation and environment readiness', 'Health, sanitation and environment readiness', '["Knows the cleaning, sanitising and room-readiness checklist","Follows the checklist correctly when reminded","Room and equipment are clean and ready on time without reminders","Checklists / logs are complete and pass spot checks","Raises or fixes environment issues before they affect the children"]'),
 ('developmental engagement and emotional responsiveness', 'Developmental engagement and emotional responsiveness', '["Knows the planned activities and each child''s developmental focus","Engages children in the planned activities with guidance","Responds warmly and consistently to children''s needs and emotions without prompting","Observations / progress notes are recorded on time and accurately","Adapts activities to individual children, or receives positive feedback from parents or the lead"]'),
 ('conduct and teamwork', 'Conduct and teamwork', '["Knows the Employee Handbook rules and the team''s ways of working","Follows the rules and cooperates when guided","Works well with colleagues and parents without issues raised","No conduct issue or complaint in the period; follows through on commitments","Helps colleagues, takes initiative, or is praised by parents or colleagues"]')
on conflict (area_key) do nothing;

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_prob_settings() returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  select '{"bands":{"E":90,"S":75,"A":60,"I":45},"pass_grade":"S","must_pass":[{"match":"child safety","min":4}],"pip_months":3,"cap_months":12,"min_reviewer_level":3,"start_days_before":30,"early_warning":true}'::jsonb
         || coalesce((select value from public.eppd_policies where key = 'probation_assessment'), '{}'::jsonb);
$f$;

create or replace function private.cms_grade_rank(g text) returns int language sql immutable as $f$
  select case g when 'E' then 5 when 'S' then 4 when 'A' then 3 when 'I' then 2 when 'U' then 1 else 0 end;
$f$;

create or replace function private.cms_grade_of(p_pct numeric, s jsonb) returns text language sql immutable as $f$
  select case when p_pct is null then null
              when p_pct >= (s->'bands'->>'E')::numeric then 'E' when p_pct >= (s->'bands'->>'S')::numeric then 'S'
              when p_pct >= (s->'bands'->>'A')::numeric then 'A' when p_pct >= (s->'bands'->>'I')::numeric then 'I' else 'U' end;
$f$;

-- total, maximum, %, grade, must-pass failures and pass for a score sheet (score per area may be an average)
create or replace function private.cms_prob_result(p_scores jsonb) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare s jsonb := private.cms_prob_settings(); n int; done int; tot numeric; pct numeric; g text; mf jsonb;
begin
  n := coalesce(jsonb_array_length(p_scores), 0);
  select count(*) filter (where nullif(x->>'score', '') is not null), coalesce(sum(nullif(x->>'score', '')::numeric), 0) into done, tot from jsonb_array_elements(coalesce(p_scores, '[]'::jsonb)) x;
  if n = 0 or done < n then return jsonb_build_object('complete', false, 'scored', done, 'criteria', n, 'total', tot, 'max', n * 5); end if;
  pct := round(tot / (n * 5) * 100, 2); g := private.cms_grade_of(pct, s);
  select coalesce(jsonb_agg(jsonb_build_object('area', x->>'area', 'score', (x->>'score')::numeric, 'min', (m->>'min')::numeric)), '[]'::jsonb) into mf
    from jsonb_array_elements(p_scores) x cross join jsonb_array_elements(coalesce(s->'must_pass', '[]'::jsonb)) m
   where position(lower(m->>'match') in lower(x->>'area')) > 0 and (x->>'score')::numeric < (m->>'min')::numeric;
  return jsonb_build_object('complete', true, 'scored', done, 'criteria', n, 'total', round(tot, 2), 'max', n * 5, 'pct', pct, 'grade', g,
    'must_fail', mf, 'pass', private.cms_grade_rank(g) >= private.cms_grade_rank(s->>'pass_grade') and jsonb_array_length(mf) = 0, 'pass_grade', s->>'pass_grade');
end $f$;

create or replace function private.cms_level_num(p_person uuid) returns int language sql stable security definer set search_path = public, pg_temp as $f$
  select nullif(regexp_replace(coalesce(jp.level, ''), '\D', '', 'g'), '')::int from public.jd_positions jp
   where jp.id = (select position_id from private.cms_position_of(p_person) limit 1);
$f$;

create or replace function private.cms_rubric(p_area text) returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  select coalesce((select checks from public.cms_kpi_rubrics where area_key = lower(btrim(p_area)) and status = 'approved'),
                  (select checks from public.cms_kpi_rubrics where area_key = '*'));
$f$;

-- JD KPIs + general rows, without general rows that repeat a JD area
create or replace function private.cms_appraisal_areas(p_person uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  with k as (select area, measure, sequence from public.jd_kpis where position_id = (select position_id from private.cms_position_of(p_person) limit 1))
  select coalesce((select jsonb_agg(jsonb_build_object('area', area, 'measure', measure) order by sequence) from k), '[]'::jsonb)
      || '[{"area":"Conduct and teamwork","measure":"Follows the handbook; works well with colleagues and parents"}]'::jsonb
      || case when exists (select 1 from k where area ilike '%attendance%') then '[]'::jsonb
              else '[{"area":"Attendance and punctuality","measure":"Leave, lateness and absence within policy"}]'::jsonb end
      || case when exists (select 1 from k where area ilike '%safety%' or area ilike '%safeguard%') then '[]'::jsonb
              else '[{"area":"Child safety and safeguarding","measure":"Follows safety and child-protection procedures at all times"}]'::jsonb end;
$f$;

-- the probation score sheet: areas with their 5 checks frozen in
create or replace function private.cms_prob_areas(p_person uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  select coalesce(jsonb_agg(x || jsonb_build_object('checks', private.cms_rubric(x->>'area'), 'score', null, 'comment', null)), '[]'::jsonb)
    from jsonb_array_elements(private.cms_appraisal_areas(p_person)) x;
$f$;

-- average the submitted reviewer sheets into the review, with the result and the automatic grade
create or replace function private.cms_prob_aggregate(p_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; sc jsonb := '[]'::jsonb; i int; av numeric; cm text; nrev int; res jsonb;
begin
  select * into a from public.cms_appraisals where id = p_id;
  for i in 0 .. coalesce(jsonb_array_length(a.scores), 0) - 1 loop
    select round(avg((r.sheet->i->>'score')::numeric), 2), string_agg(em.employee_name || ': ' || (r.sheet->i->>'comment'), ' · ' order by r.lead desc, em.employee_name) filter (where nullif(r.sheet->i->>'comment', '') is not null), count(*)
      into av, cm, nrev
      from public.cms_appraisal_reviewers r join public.employee_master em on em.id = r.reviewer_id
     where r.appraisal_id = a.id and r.submitted_at is not null and r.sheet is not null;
    sc := sc || ((a.scores->i) || jsonb_build_object('score', av, 'comment', cm, 'reviewers', nrev));
  end loop;
  res := private.cms_prob_result(sc);
  update public.cms_appraisals set scores = sc, result = res, rating_auto = res->>'grade',
         rating = case when rating_reason is not null then rating else res->>'grade' end, updated_at = now()
   where id = a.id;
end $f$;

-- role: also the extra reviewers; HR / director rights from the probation module
create or replace function private.cms_appraisal_role(a public.cms_appraisals) returns text language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me uuid := private.cms_me(); em public.employee_master; co text; hr boolean;
begin
  select * into em from public.employee_master where id = a.person_id; co := private.cms_canon(em.company_code);
  if me is not null and me = a.person_id then return 'self'; end if;
  hr := private.cms_can_company('performance', 'E', co) or (a.kind in ('probation', 'checkin') and private.cms_can_company('performance.probation', 'E', co));
  if hr then return 'hr'; end if;
  if me is not null and private.cms_person_is_director(me) then return 'director'; end if;
  if a.kind in ('probation', 'checkin') and private.cms_can_company('performance.probation', 'A', co) then return 'director'; end if;
  if me is not null and (me = a.reviewer_id or exists (select 1 from public.cms_appraisal_reviewers r where r.appraisal_id = a.id and r.reviewer_id = me)) then return 'reviewer'; end if;
  if me is not null and exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
        select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
      select 1 from up where id = me) then return 'manager'; end if;
  if private.cms_can_company('performance', 'V', co) or (a.kind in ('probation', 'checkin') and private.cms_can_company('performance.probation', 'V', co)) then return 'viewer'; end if;
  return null;
end $f$;

-- a reviewer must be on a JD level at or above the setting (L3)
create or replace function private.cms_prob_check_reviewer(p_person uuid, p_reviewer uuid) returns void language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare lv int := private.cms_level_num(p_reviewer); mn int := (private.cms_prob_settings()->>'min_reviewer_level')::int; nm text;
begin
  select employee_name into nm from public.employee_master where id = p_reviewer;
  if nm is null then raise exception 'Reviewer not found.'; end if;
  if p_reviewer = p_person then raise exception 'A person cannot review their own probation.'; end if;
  if lv is null then raise exception '% is not placed on a JD position (Career Paths), so the JD level (L% or above) cannot be checked.', nm, mn; end if;
  if lv < mn then raise exception '% is on JD level L%; reviewers must be L% or above.', nm, lv, mn; end if;
end $f$;

-- a PIP / follow-up review after an extension (or the next PIP month)
create or replace function private.cms_prob_followup(a public.cms_appraisals, p_month int, p_months int, p_due date) returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid;
begin
  insert into public.cms_appraisals (person_id, kind, due_date, reviewer_id, self_requested, scores, created_by, follow_up_of, pip_month, pip_months, pip_targets)
  values (a.person_id, 'probation', p_due, a.reviewer_id, a.self_requested, private.cms_prob_areas(a.person_id), auth.uid(), a.id, p_month, p_months, a.pip_targets)
  returning id into v;
  insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead, added_by)
  select v, r.reviewer_id, r.lead, auth.uid() from public.cms_appraisal_reviewers r where r.appraisal_id = a.id on conflict do nothing;
  if not exists (select 1 from public.cms_appraisal_reviewers where appraisal_id = v) and a.reviewer_id is not null then
    insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead, added_by) values (v, a.reviewer_id, true, auth.uid()) on conflict do nothing;
  end if;
  return v;
end $f$;

-- ------------------------------------------------------------------ start (probation sheet + reviewers)
create or replace function public.cms_appraisal_start(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; v uuid; k text := p->>'kind'; y int; lead uuid; rid uuid; auto boolean := coalesce((p->>'auto')::boolean, false);
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  if not auto then
    if k = 'probation' then
      if not (private.cms_can_company('performance', 'E', private.cms_canon(em.company_code)) or private.cms_can_company('performance.probation', 'E', private.cms_canon(em.company_code))) then raise exception 'Not allowed.'; end if;
    else perform private.cms_require('performance', 'E', private.cms_canon(em.company_code)); end if;
  end if;
  if k not in ('probation', 'annual') then raise exception 'Choose probation or annual.'; end if;
  y := coalesce(nullif(p->>'year', '')::int, extract(year from current_date)::int);
  if k = 'annual' and exists (select 1 from public.cms_appraisals where person_id = em.id and kind = 'annual' and year = y and status <> 'cancelled') then
    raise exception '% already has an annual appraisal for %.', em.employee_name, y; end if;
  if k = 'probation' and exists (select 1 from public.cms_appraisals where person_id = em.id and kind = 'probation' and status in ('open', 'reviewed')) then
    raise exception '% already has a probation review in progress.', em.employee_name; end if;
  if k = 'probation' and (select position_id from private.cms_position_of(em.id) limit 1) is null then
    raise exception '% is not placed on a JD position (Career Paths): the probation review is scored on the JD KPIs.', em.employee_name; end if;
  if k = 'probation' and nullif(p->>'probation_end', '') is not null then
    update public.employee_master set probation_end_date = (p->>'probation_end')::date, updated_at = now() where id = em.id; end if;
  lead := coalesce(nullif(p->>'reviewer_id', '')::uuid, em.reports_to_id);
  if k = 'probation' and lead is not null then
    if auto then
      if coalesce(private.cms_level_num(lead), 0) < (private.cms_prob_settings()->>'min_reviewer_level')::int then lead := null; end if;
    else perform private.cms_prob_check_reviewer(em.id, lead); end if;
  end if;
  insert into public.cms_appraisals (person_id, kind, year, period_from, period_to, due_date, reviewer_id, self_requested, scores, created_by)
  values (em.id, k, case when k = 'annual' then y end, nullif(p->>'period_from', '')::date, nullif(p->>'period_to', '')::date,
          coalesce(nullif(p->>'due', '')::date, case when k = 'probation' then (select end_date from private.cms_probation_end(em.id)) end),
          lead, coalesce((p->>'self_requested')::boolean, false),
          case when k = 'probation' then private.cms_prob_areas(em.id)
               else (select jsonb_agg(x || '{"score":null,"comment":null}'::jsonb) from jsonb_array_elements(private.cms_appraisal_areas(em.id)) x) end, auth.uid())
  returning id into v;
  if k = 'probation' then
    if lead is not null then insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead, added_by) values (v, lead, true, auth.uid()); end if;
    for rid in select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(p->'reviewers', '[]'::jsonb)) x loop
      if rid is distinct from lead then
        perform private.cms_prob_check_reviewer(em.id, rid);
        insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead, added_by) values (v, rid, false, auth.uid()) on conflict do nothing;
      end if;
    end loop;
  end if;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'appraisal_started', initcap(k) || case when k = 'probation' then ' review' else ' appraisal' end || ' started' || case when auto then ' (automatically)' else '' end,
          jsonb_build_object('appraisal_id', v, 'year', y), auth.uid());
  perform private.cms_log('appraisal.started', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || k || ' appraisal started', p);
  return v;
end $f$;

-- HR: set the reviewers of a probation review (the first is the lead)
create or replace function public.cms_probation_reviewers(p_id uuid, p_ids jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; rid uuid; i int := 0; keep uuid[] := '{}';
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.kind <> 'probation' or a.status <> 'open' then raise exception 'Reviewers can be changed only while the review is being scored.'; end if;
  if private.cms_appraisal_role(a) <> 'hr' then raise exception 'HR sets the reviewers.'; end if;
  if jsonb_array_length(coalesce(p_ids, '[]'::jsonb)) = 0 then raise exception 'Choose at least one reviewer.'; end if;
  for rid in select (x #>> '{}')::uuid from jsonb_array_elements(p_ids) x loop
    perform private.cms_prob_check_reviewer(a.person_id, rid);
    keep := keep || rid;
    insert into public.cms_appraisal_reviewers (appraisal_id, reviewer_id, lead, added_by) values (a.id, rid, i = 0, auth.uid())
    on conflict (appraisal_id, reviewer_id) do update set lead = excluded.lead, updated_at = now();
    i := i + 1;
  end loop;
  if exists (select 1 from public.cms_appraisal_reviewers where appraisal_id = a.id and not (reviewer_id = any(keep)) and submitted_at is not null) then
    raise exception 'A reviewer who has already sent their scores cannot be removed.'; end if;
  delete from public.cms_appraisal_reviewers where appraisal_id = a.id and not (reviewer_id = any(keep));
  update public.cms_appraisals set reviewer_id = keep[1], updated_at = now() where id = a.id;
  perform private.cms_prob_aggregate(a.id);
end $f$;

-- a reviewer saves / sends their own score sheet (ticks per check; score = ticks, minimum 1)
create or replace function public.cms_appraisal_score(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; me uuid := private.cms_me(); items jsonb := coalesce(p->'items', '[]'::jsonb); out jsonb := '[]'::jsonb; it jsonb; ticks jsonb; sc int; i int;
        sub boolean := coalesce((p->>'submit')::boolean, false); co text;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.kind <> 'probation' or a.status <> 'open' or a.outside then raise exception 'This review is not open for scoring.'; end if;
  select private.cms_canon(company_code) into co from public.employee_master where id = a.person_id;
  if me is null or not exists (select 1 from public.cms_appraisal_reviewers where appraisal_id = a.id and reviewer_id = me) then raise exception 'You are not a reviewer of this probation review.'; end if;
  if not (private.cms_can_company('performance.probation', 'C', co) or private.cms_can_company('performance.probation', 'E', co)) then
    raise exception 'You need the "Probation Reviews" score permission (Users & Roles).'; end if;
  if jsonb_array_length(items) <> jsonb_array_length(a.scores) then raise exception 'The score sheet has changed: close and open the review again.'; end if;
  for i in 0 .. jsonb_array_length(items) - 1 loop
    it := items->i; ticks := coalesce(it->'ticks', '[]'::jsonb);
    sc := greatest(1, (select count(*) from jsonb_array_elements(ticks) x where x = 'true'::jsonb))::int;
    if sub and (sc <= 2 or sc = 5) and nullif(btrim(coalesce(it->>'comment', '')), '') is null then
      raise exception 'Add a comment for "%": needed for a score of 2 or lower, or 5.', a.scores->i->>'area'; end if;
    out := out || jsonb_build_object('area', a.scores->i->>'area', 'ticks', ticks, 'score', sc, 'comment', nullif(btrim(coalesce(it->>'comment', '')), ''),
                                     'evidence', nullif(btrim(coalesce(it->>'evidence', '')), ''));
  end loop;
  update public.cms_appraisal_reviewers set sheet = out, submitted_at = case when sub then now() else submitted_at end, updated_at = now()
   where appraisal_id = a.id and reviewer_id = me;
  perform private.cms_prob_aggregate(a.id);
  if sub then
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (a.person_id, 'probation_scored', 'Probation review scored by ' || private.cms_my_name(), jsonb_build_object('appraisal_id', a.id), auth.uid());
  end if;
end $f$;

-- HR check: recommendation, grade override with a reason, PIP / extension, confirmation date → waiting for the Director
create or replace function public.cms_probation_check(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; s jsonb := private.cms_prob_settings(); rec text := nullif(p->>'recommendation', ''); g text := nullif(p->>'rating', '');
        why text := nullif(btrim(coalesce(p->>'rating_reason', '')), ''); res jsonb; pass boolean; ext date := nullif(p->>'rec_extend_to', '')::date;
        pend date; cap date; em public.employee_master;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.kind <> 'probation' or a.status not in ('open', 'reviewed') then raise exception 'Review not found or already approved.'; end if;
  if private.cms_appraisal_role(a) <> 'hr' then raise exception 'HR checks probation reviews.'; end if;
  select * into em from public.employee_master where id = a.person_id;
  if not a.outside then
    perform private.cms_prob_aggregate(a.id); select * into a from public.cms_appraisals where id = p_id;
    res := a.result;
    if not coalesce((res->>'complete')::boolean, false) then raise exception 'No complete score yet: at least one reviewer must send their scores.'; end if;
    if g is not null and g is distinct from a.rating_auto and why is null then raise exception 'Give the reason for changing the grade from % to %.', a.rating_auto, g; end if;
    g := coalesce(g, a.rating_auto);
    pass := private.cms_grade_rank(g) >= private.cms_grade_rank(s->>'pass_grade') and jsonb_array_length(coalesce(res->'must_fail', '[]'::jsonb)) = 0;
    if rec = 'confirm' and not pass then
      raise exception 'Below the pass (grade % or better, and every must-pass area at its minimum): choose extend / continue the PIP or end.', s->>'pass_grade'; end if;
  else
    pass := rec = 'confirm';
  end if;
  if rec is null or rec not in ('confirm', 'extend', 'end', 'continue') then raise exception 'Choose the recommendation.'; end if;
  if rec = 'continue' and not (coalesce(a.pip_month, 0) > 0 and a.pip_month < coalesce(a.pip_months, 0)) then raise exception '"Continue the PIP" is only for a PIP month before the last one.'; end if;
  pend := (select end_date from private.cms_probation_end(a.person_id));
  if rec = 'extend' then
    if ext is null then raise exception 'Give the new probation end date.'; end if;
    if ext <= coalesce(pend, current_date) then raise exception 'The new probation end date must be after the current one (%).', to_char(pend, 'DD Mon YYYY'); end if;
    cap := ((select join_date from private.cms_probation_end(a.person_id)) + make_interval(months => (s->>'cap_months')::int))::date;
    if ext > cap and nullif(btrim(coalesce(p->>'cap_reason', '')), '') is null then
      raise exception 'Beyond the % -month probation cap (%): give the Director''s reason.', s->>'cap_months', to_char(cap, 'DD Mon YYYY'); end if;
  end if;
  update public.cms_appraisals set recommendation = rec, rating = case when a.outside then g else g end,
         rating_reason = case when g is distinct from a.rating_auto then coalesce(why, rating_reason) else null end,
         rec_extend_to = case when rec = 'extend' then ext end,
         next_pip_months = case when rec = 'extend' then greatest(1, coalesce(nullif(p->>'pip_months', '')::int, (s->>'pip_months')::int)) end,
         confirm_on = case when rec = 'confirm' then coalesce(nullif(p->>'confirm_on', '')::date, a.due_date, pend) end,
         pip_targets = case when rec in ('extend', 'continue') then coalesce(p->'pip_targets', pip_targets) else pip_targets end,
         strengths = nullif(btrim(coalesce(p->>'strengths', '')), ''), improvements = nullif(btrim(coalesce(p->>'improvements', '')), ''), goals = nullif(btrim(coalesce(p->>'goals', '')), ''),
         approve_note = case when nullif(btrim(coalesce(p->>'cap_reason', '')), '') is not null then 'Beyond the cap: ' || btrim(p->>'cap_reason') else approve_note end,
         status = 'reviewed', reviewed_by = auth.uid(), reviewed_by_name = private.cms_my_name(), reviewed_at = now(), updated_at = now()
   where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (a.person_id, 'appraisal_reviewed', 'Probation review checked by HR (' || private.cms_my_name() || ') · ' || coalesce(g, '—') || ' · ' || rec,
          jsonb_build_object('appraisal_id', a.id, 'rating', g, 'recommendation', rec, 'pct', a.result->'pct'), auth.uid());
end $f$;

-- HR: a result reached outside the CMS (paper assessment), sent to the Director for approval
create or replace function public.cms_probation_outside(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; note text := nullif(btrim(coalesce(p->>'note', '')), '');
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.kind <> 'probation' or a.status not in ('open', 'reviewed') then raise exception 'Review not found or already approved.'; end if;
  if private.cms_appraisal_role(a) <> 'hr' then raise exception 'HR records a result reached outside the CMS.'; end if;
  if note is null then raise exception 'Say how and when the assessment was done outside the CMS.'; end if;
  update public.cms_appraisals set outside = true, outside_note = note, outside_letter_date = nullif(p->>'letter_date', '')::date,
         letter_ref = coalesce(nullif(btrim(coalesce(p->>'letter_ref', '')), ''), letter_ref), result = null, rating_auto = null, updated_at = now()
   where id = a.id;
  perform public.cms_probation_check(p_id, p);
end $f$;

-- ------------------------------------------------------------------ approve (probation: Director / performance.probation 'A')
create or replace function public.cms_appraisal_approve(p_id uuid, p_note text default null, p_return boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; r text; em public.employee_master; out jsonb := '{}'::jsonb; eid bigint; d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
        co text; me uuid := private.cms_me(); pend date; due date; fu uuid; mon int;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.status <> 'reviewed' then raise exception 'Only a reviewed appraisal can be approved.'; end if;
  r := private.cms_appraisal_role(a);
  select * into em from public.employee_master where id = a.person_id; co := private.cms_canon(em.company_code);
  if a.kind = 'probation' then
    if not (private.cms_can_company('performance.probation', 'A', co) or (me is not null and private.cms_person_is_director(me))) then
      raise exception 'A Director approves probation reviews.'; end if;
    if me is not null and exists (select 1 from public.cms_appraisal_reviewers x where x.appraisal_id = a.id and x.reviewer_id = me and x.submitted_at is not null) then
      raise exception 'You scored this review, so another Director approves it.'; end if;
  else
    if r not in ('hr', 'director') then raise exception 'HR / Admin or a director approves appraisals.'; end if;
    if a.reviewed_by = auth.uid() and r <> 'hr' then raise exception 'The reviewer cannot also approve.'; end if;
  end if;
  if p_return then
    update public.cms_appraisals set status = 'open', approve_note = nullif(btrim(p_note), ''), updated_at = now() where id = a.id;
    return jsonb_build_object('returned', true);
  end if;
  if a.kind = 'annual' and a.rating is not null then
    for eid in select id from public.eppd_employees where employee_master_id = em.id loop
      insert into public.eppd_kpi_ratings (employee_id, year, grade, note, graded_by, graded_at)
      values (eid, a.year, a.rating, 'From the annual appraisal (CMS)', auth.uid(), now())
      on conflict (employee_id, year) do update set grade = excluded.grade, note = excluded.note, graded_by = excluded.graded_by, graded_at = now(), updated_at = now();
    end loop;
    out := out || jsonb_build_object('kpi_grade', a.rating);
  end if;
  if a.recommendation = 'promote' and a.rec_position is not null then
    insert into public.cms_person_position (person_id, position_id, since, note, set_by, set_at) values (em.id, a.rec_position, d, 'Promoted (appraisal)', auth.uid(), now())
    on conflict (person_id) do update set position_id = excluded.position_id, since = excluded.since, note = excluded.note, set_by = excluded.set_by, set_at = now();
    out := out || jsonb_build_object('promoted_to', (select job_title || ' (' || level || ')' from public.jd_positions where id = a.rec_position));
  end if;
  if a.recommendation in ('increment', 'promote') and a.rec_increment is not null then out := out || jsonb_build_object('increment_to_record', a.rec_increment); end if;
  if a.kind = 'probation' then
    pend := (select end_date from private.cms_probation_end(em.id));
    if a.recommendation = 'confirm' then
      -- probation end date = confirmation date (an early confirmation during the PIP moves it to the confirmation date)
      if a.confirm_on is not null then update public.employee_master set probation_end_date = a.confirm_on where id = em.id; end if;
      update public.employee_master set probation_end_date = coalesce(probation_end_date, pend, d) where id = em.id;
      update public.eppd_employments m set confirmation_status = 'C', confirmed_date = coalesce(m.confirmed_date, (select probation_end_date from public.employee_master where id = em.id)), updated_at = now()
        from public.eppd_employees e where e.id = m.employee_id and e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP';
      update public.employee_master set confirmation_status = 'confirmed', confirmation_date = probation_end_date, updated_at = now() where id = em.id;
      update public.cms_appraisals set status = 'cancelled', updated_at = now() where person_id = em.id and kind = 'checkin' and status = 'open';
      out := out || jsonb_build_object('confirmed_on', (select confirmation_date from public.employee_master where id = em.id), 'letter', 'Letter of Confirmation (or Confirmation and Increment) to issue');
    elsif a.recommendation = 'extend' then
      mon := greatest(1, coalesce(a.next_pip_months, (private.cms_prob_settings()->>'pip_months')::int));
      update public.employee_master set probation_end_date = a.rec_extend_to, updated_at = now() where id = em.id;
      due := case when mon = 1 then a.rec_extend_to else least(a.rec_extend_to, (coalesce(pend, d) + interval '1 month')::date) end;
      a.pip_targets := coalesce(a.pip_targets, (select jsonb_agg(jsonb_build_object('area', x->>'area', 'score', x->'score', 'action', null, 'support', null))
                                                  from jsonb_array_elements(a.scores) x where nullif(x->>'score', '') is not null and (x->>'score')::numeric <= 3));
      fu := private.cms_prob_followup(a, 1, mon, due);
      out := out || jsonb_build_object('probation_extended_to', a.rec_extend_to, 'pip', mon || ' month(s), reviewed monthly', 'extension_letter', 'to issue', 'first_pip_review_due', due);
    elsif a.recommendation = 'continue' then
      due := case when a.pip_month + 1 >= a.pip_months then coalesce(pend, a.due_date) else least(coalesce(pend, a.due_date), (a.due_date + interval '1 month')::date) end;
      fu := private.cms_prob_followup(a, a.pip_month + 1, a.pip_months, due);
      out := out || jsonb_build_object('pip_continues', 'month ' || (a.pip_month + 1) || ' of ' || a.pip_months, 'next_review_due', due);
    else
      out := out || jsonb_build_object('end_of_employment', 'Give notice (4 weeks on probation) with the non-confirmation letter, then record the leaving in payroll');
    end if;
    insert into public.employee_probation_reviews (employee_id_ref, review_date, action, original_probation_end_date, revised_probation_end_date, confirmation_date,
           performance_summary, manager_recommendation, note, recorded_by, recorded_at)
    values (em.id, d, case a.recommendation when 'confirm' then 'confirmed' when 'extend' then 'probation_extended' else 'review_note' end, pend,
            case when a.recommendation = 'extend' then a.rec_extend_to end, case when a.recommendation = 'confirm' then (select confirmation_date from public.employee_master where id = em.id) end,
            concat_ws(' · ', case when a.outside then 'Assessed outside the CMS: ' || a.outside_note end, case when a.result ? 'pct' then 'KPI ' || (a.result->>'pct') || '%' end,
                      'grade ' || a.rating, case when a.pip_month is not null then 'PIP month ' || a.pip_month || ' of ' || a.pip_months end, a.strengths, a.improvements),
            a.recommendation, nullif(btrim(p_note), ''), auth.uid(), now());
  end if;
  update public.cms_appraisals set status = 'approved', approved_by = auth.uid(), approved_by_name = private.cms_my_name(), approved_at = now(),
         approve_note = coalesce(nullif(btrim(p_note), ''), approve_note), outcome = out, updated_at = now() where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'appraisal_approved', initcap(a.kind) || case when a.kind = 'probation' then ' review' else ' appraisal' end || ' approved · grade ' || coalesce(a.rating, '—') || ' · ' || a.recommendation,
          jsonb_build_object('appraisal_id', a.id) || out, auth.uid());
  perform private.cms_log('appraisal.approved', 'employee_master', em.id::text, co,
    em.employee_name || ': ' || a.kind || ' approved (' || coalesce(a.rating, '—') || ', ' || a.recommendation || ')', out);
  return out;
end $f$;

-- ------------------------------------------------------------------ check-in (halfway, not scored)
create or replace function public.cms_probation_checkin(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; r text; st text := p->>'status'; note text := nullif(btrim(coalesce(p->>'note', '')), '');
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.kind <> 'checkin' or a.status <> 'open' then raise exception 'Check-in not found or already done.'; end if;
  r := private.cms_appraisal_role(a);
  if r not in ('hr', 'director', 'reviewer', 'manager') then raise exception 'You cannot record this check-in.'; end if;
  if st not in ('on_track', 'at_risk') then raise exception 'Choose on track or at risk.'; end if;
  if note is null then raise exception 'Add a short note (what is going well, what needs attention).'; end if;
  update public.cms_appraisals set recommendation = st, strengths = note, improvements = nullif(btrim(coalesce(p->>'actions', '')), ''), status = 'approved',
         reviewed_by = auth.uid(), reviewed_by_name = private.cms_my_name(), reviewed_at = now(), approved_by = auth.uid(), approved_by_name = private.cms_my_name(), approved_at = now(), updated_at = now()
   where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (a.person_id, 'probation_checkin', 'Probation check-in: ' || replace(st, '_', ' ') || ' (' || private.cms_my_name() || ')', jsonb_build_object('appraisal_id', a.id), auth.uid());
end $f$;

-- ------------------------------------------------------------------ one review (probation extras)
create or replace function public.cms_probation_review(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare a public.cms_appraisals; r text; me uuid := private.cms_me(); co text; base jsonb; full_view boolean;
begin
  select * into a from public.cms_appraisals where id = p_id;
  if a.id is null then raise exception 'Review not found.'; end if;
  base := public.cms_appraisal(p_id); r := base->>'role';
  if r = 'self' then return base; end if;
  select private.cms_canon(company_code) into co from public.employee_master where id = a.person_id;
  full_view := r in ('hr', 'director');
  return base || jsonb_build_object('settings', private.cms_prob_settings(), 'result', a.result, 'rating_auto', a.rating_auto, 'rating_reason', a.rating_reason,
    'pip_month', a.pip_month, 'pip_months', a.pip_months, 'pip_targets', a.pip_targets, 'next_pip_months', a.next_pip_months, 'confirm_on', a.confirm_on,
    'outside', a.outside, 'outside_note', a.outside_note, 'outside_letter_date', a.outside_letter_date, 'kind', a.kind,
    'join_date', (select join_date from private.cms_probation_end(a.person_id)),
    'reviewers', coalesce((select jsonb_agg(jsonb_build_object('id', x.reviewer_id, 'name', em.employee_name, 'lead', x.lead, 'level', private.cms_level_num(x.reviewer_id), 'me', x.reviewer_id = me,
        'submitted_at', x.submitted_at, 'sheet', case when full_view or x.reviewer_id = me then x.sheet end) order by x.lead desc, em.employee_name)
      from public.cms_appraisal_reviewers x join public.employee_master em on em.id = x.reviewer_id where x.appraisal_id = a.id), '[]'::jsonb),
    'is_reviewer', me is not null and exists (select 1 from public.cms_appraisal_reviewers x where x.appraisal_id = a.id and x.reviewer_id = me),
    'can_score', a.kind = 'probation' and a.status = 'open' and not a.outside and me is not null and exists (select 1 from public.cms_appraisal_reviewers x where x.appraisal_id = a.id and x.reviewer_id = me)
                 and (private.cms_can_company('performance.probation', 'C', co) or private.cms_can_company('performance.probation', 'E', co)),
    'can_check', a.kind = 'probation' and a.status in ('open', 'reviewed') and r = 'hr',
    'can_approve', a.status = 'reviewed' and (case when a.kind = 'probation' then private.cms_can_company('performance.probation', 'A', co) or (me is not null and private.cms_person_is_director(me))
                                                  else r in ('hr', 'director') end)
                   and not (me is not null and exists (select 1 from public.cms_appraisal_reviewers x where x.appraisal_id = a.id and x.reviewer_id = me and x.submitted_at is not null)),
    'reviewer_choices', case when r = 'hr' then coalesce((select jsonb_agg(jsonb_build_object('id', em.id, 'name', em.employee_name, 'level', lv, 'title', em.approved_job_title) order by em.employee_name)
        from (select em.*, private.cms_level_num(em.id) lv from public.employee_master em where em.employment_status in ('active', 'onboarding') and em.id <> a.person_id) em
       where em.lv >= (private.cms_prob_settings()->>'min_reviewer_level')::int), '[]'::jsonb) end);
end $f$;

-- ------------------------------------------------------------------ the Probation Reviews page
create or replace function private.cms_probation_status(p_person uuid) returns text language sql stable security definer set search_path = public, pg_temp as $f$
  select case
    when exists (select 1 from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = p_person and m.resigned_date is null and m.confirmation_status = 'C')
         and not exists (select 1 from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = p_person and m.resigned_date is null and m.confirmation_status = 'UP') then 'Confirmed'
    when exists (select 1 from public.cms_appraisals a where a.person_id = p_person and a.kind = 'probation' and a.status = 'approved' and a.recommendation = 'end' and a.approved_at > now() - interval '120 days') then 'Not confirmed'
    else coalesce((select 'Extended – PIP month ' || a.pip_month || ' of ' || a.pip_months from public.cms_appraisals a
                    where a.person_id = p_person and a.kind = 'probation' and a.status in ('open', 'reviewed') and a.pip_month is not null order by a.created_at desc limit 1), 'Under probation') end;
$f$;

create or replace function public.cms_probation_list() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me uuid := private.cms_me(); s jsonb := private.cms_prob_settings();
begin
  perform private.cms_require('performance.probation', 'V');
  return jsonb_build_object('settings', s, 'today', (now() at time zone 'Asia/Kuala_Lumpur')::date,
    'can', jsonb_build_object('hr', public.cms_can('performance.probation', 'E'), 'approve', public.cms_can('performance.probation', 'A'), 'settings', public.cms_can('performance.probation', 'A')),
    'rows', coalesce((select jsonb_agg(q.x order by (q.x->>'sort')::date nulls last, q.x->>'name') from (
      select jsonb_build_object('person_id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code), 'title', em.approved_job_title,
        'start', pe.join_date, 'probation_end', pe.end_date, 'probation_source', pe.source, 'status', private.cms_probation_status(em.id),
        'placed', (select position_id from private.cms_position_of(em.id) limit 1) is not null,
        'review', (select jsonb_build_object('id', a.id, 'status', a.status, 'due', a.due_date, 'pip_month', a.pip_month, 'pip_months', a.pip_months, 'pct', a.result->'pct',
              'grade', a.rating, 'complete', a.result->'complete', 'pass', a.result->'pass', 'recommendation', a.recommendation, 'outside', a.outside,
              'reviewers', (select jsonb_agg(jsonb_build_object('name', rv.employee_name, 'lead', x.lead, 'done', x.submitted_at is not null, 'me', x.reviewer_id = me) order by x.lead desc)
                              from public.cms_appraisal_reviewers x join public.employee_master rv on rv.id = x.reviewer_id where x.appraisal_id = a.id))
            from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status in ('open', 'reviewed') order by a.created_at desc limit 1),
        'checkin', (select jsonb_build_object('id', a.id, 'status', a.status, 'due', a.due_date, 'result', a.recommendation, 'note', a.strengths)
            from public.cms_appraisals a where a.person_id = em.id and a.kind = 'checkin' and a.status <> 'cancelled' order by a.created_at desc limit 1),
        'last', (select jsonb_build_object('id', a.id, 'recommendation', a.recommendation, 'grade', a.rating, 'pct', a.result->'pct', 'approved_at', a.approved_at,
              'letter_due', a.recommendation = 'extend' and a.letter_issued_at is null, 'outside', a.outside)
            from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status = 'approved' order by a.approved_at desc limit 1),
        'sort', pe.end_date) x
      from public.employee_master em
      cross join lateral (select * from private.cms_probation_end(em.id)) pe
      where em.employment_status in ('active', 'onboarding')
        and (exists (select 1 from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP')
             or exists (select 1 from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status = 'approved' and a.approved_at > now() - interval '60 days'))
        and (private.cms_can_company('performance.probation', 'E', private.cms_canon(em.company_code)) or private.cms_can_company('performance.probation', 'A', private.cms_canon(em.company_code))
             or (me is not null and exists (select 1 from public.cms_appraisals a join public.cms_appraisal_reviewers x on x.appraisal_id = a.id
                                            where a.person_id = em.id and a.status in ('open', 'reviewed') and x.reviewer_id = me)))
    ) q), '[]'::jsonb),
    'rubrics', case when public.cms_can('performance.probation', 'E') then (select jsonb_agg(jsonb_build_object('key', area_key, 'area', area, 'checks', checks, 'status', status) order by area_key <> '*', area) from public.cms_kpi_rubrics) end);
end $f$;

create or replace function public.cms_probation_settings_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare b jsonb := p->'bands';
begin
  perform private.cms_require('performance.probation', 'A');
  if b is null or not ((b->>'E')::numeric > (b->>'S')::numeric and (b->>'S')::numeric > (b->>'A')::numeric and (b->>'A')::numeric > (b->>'I')::numeric and (b->>'I')::numeric > 0 and (b->>'E')::numeric <= 100) then
    raise exception 'Grade bands must go down from E to I, between 0 and 100.'; end if;
  if coalesce(p->>'pass_grade', '') not in ('E', 'S', 'A', 'I') then raise exception 'Choose the pass grade.'; end if;
  if coalesce((p->>'pip_months')::int, 0) not between 1 and 12 or coalesce((p->>'cap_months')::int, 0) not between 3 and 36 then raise exception 'PIP 1–12 months; cap 3–36 months.'; end if;
  insert into public.eppd_policies (key, value, description, updated_at, updated_by) values ('probation_assessment',
    jsonb_build_object('bands', b, 'pass_grade', p->>'pass_grade', 'must_pass', coalesce(p->'must_pass', '[]'::jsonb), 'pip_months', (p->>'pip_months')::int,
      'cap_months', (p->>'cap_months')::int, 'min_reviewer_level', coalesce((p->>'min_reviewer_level')::int, 3), 'start_days_before', coalesce((p->>'start_days_before')::int, 30),
      'early_warning', coalesce((p->>'early_warning')::boolean, true)), 'Probation assessment on the JD KPIs (PRI-023)', now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('probation.settings', 'eppd_policies', 'probation_assessment', null, 'Probation assessment settings changed', p);
  return private.cms_prob_settings();
end $f$;

create or replace function public.cms_kpi_rubric_save(p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare k text := lower(btrim(coalesce(p->>'area', ''))); c jsonb := p->'checks';
begin
  perform private.cms_require('performance.probation', 'E');
  if coalesce(p->>'key', '') = '*' then k := '*'; end if;
  if k = '' then raise exception 'Give the KPI area.'; end if;
  if jsonb_typeof(c) <> 'array' or jsonb_array_length(c) <> 5 or exists (select 1 from jsonb_array_elements_text(c) x where btrim(x) = '') then raise exception 'Give exactly 5 checks.'; end if;
  insert into public.cms_kpi_rubrics (area_key, area, checks, status, updated_by, updated_at) values (k, case when k = '*' then 'General ladder (any KPI area without its own checks)' else btrim(p->>'area') end, c, 'approved', auth.uid(), now())
  on conflict (area_key) do update set checks = excluded.checks, status = 'approved', updated_by = auth.uid(), updated_at = now();
  perform private.cms_log('probation.rubric', 'cms_kpi_rubrics', k, null, 'KPI checks saved: ' || coalesce(p->>'area', k), p);
end $f$;

-- ------------------------------------------------------------------ reminders (bell / My tasks)
create or replace function public.cms_appraisals_pending() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me uuid := private.cms_me();
begin
  return jsonb_build_object(
    'self_to_do', case when me is null then 0 else (select count(*) from public.cms_appraisals where person_id = me and self_requested and self_at is null and status = 'open') end,
    'letters_due', case when public.cms_can('performance', 'E') or public.cms_can('performance.probation', 'E') then (select count(*) from public.cms_appraisals where recommendation = 'extend' and status = 'approved' and letter_issued_at is null) else 0 end,
    'to_review', case when me is null then 0 else
        (select count(*) from public.cms_appraisals a where a.status = 'open' and a.person_id <> me and a.kind = 'annual' and a.reviewer_id = me)
      + (select count(*) from public.cms_appraisals a join public.cms_appraisal_reviewers x on x.appraisal_id = a.id
          where a.status = 'open' and a.kind = 'probation' and not a.outside and x.reviewer_id = me and x.submitted_at is null)
      + (select count(*) from public.cms_appraisals a where a.status = 'open' and a.kind = 'checkin' and a.reviewer_id = me) end,
    'probation_review_soon', case when me is null then 0 else (select count(*) from public.cms_appraisals a join public.cms_appraisal_reviewers x on x.appraisal_id = a.id
          where a.status = 'open' and a.kind = 'probation' and x.reviewer_id = me and x.submitted_at is null and a.due_date <= current_date + 14) end,
    'to_check', case when public.cms_can('performance.probation', 'E') then (select count(*) from public.cms_appraisals a
          where a.status = 'open' and a.kind = 'probation' and (a.result->>'complete')::boolean
            and not exists (select 1 from public.cms_appraisal_reviewers x where x.appraisal_id = a.id and x.submitted_at is null)) else 0 end,
    'to_approve', (select count(*) from public.cms_appraisals a where a.status = 'reviewed' and (
          (a.kind = 'annual' and (public.cms_can('performance', 'E') or (me is not null and private.cms_person_is_director(me))) and private.cms_appraisal_role(a) in ('hr', 'director'))
       or (a.kind = 'probation' and (private.cms_can_company('performance.probation', 'A', (select private.cms_canon(company_code) from public.employee_master where id = a.person_id))
                                     or (me is not null and private.cms_person_is_director(me)))))),
    'probation_due', case when public.cms_can('performance', 'E') or public.cms_can('performance.probation', 'E') then (select count(*) from public.employee_master em
        join lateral (select max(m.join_date) jd from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
                      where e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP') pr on pr.jd is not null
        where em.employment_status in ('active', 'onboarding') and (select end_date from private.cms_probation_end(em.id)) <= current_date + 30
          and not exists (select 1 from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status in ('open', 'reviewed'))) else 0 end);
end $f$;

-- ------------------------------------------------------------------ daily: start reviews and halfway check-ins
create or replace function private.cms_probation_daily() returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare s jsonb := private.cms_prob_settings(); t date := (now() at time zone 'Asia/Kuala_Lumpur')::date; r record; n int := 0; c int := 0;
begin
  for r in select em.id, em.reports_to_id, pe.end_date, pe.join_date from public.employee_master em cross join lateral (select * from private.cms_probation_end(em.id)) pe
            where em.employment_status in ('active', 'onboarding')
              and exists (select 1 from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP')
              and (select position_id from private.cms_position_of(em.id) limit 1) is not null loop
    if r.end_date <= t + (s->>'start_days_before')::int
       and not exists (select 1 from public.cms_appraisals a where a.person_id = r.id and a.kind = 'probation' and (a.status in ('open', 'reviewed') or (a.status = 'approved' and a.recommendation = 'end'))) then
      begin perform public.cms_appraisal_start(jsonb_build_object('person_id', r.id, 'kind', 'probation', 'auto', true, 'self_requested', false)); n := n + 1;
      exception when others then null; end;
    end if;
    if coalesce((s->>'early_warning')::boolean, true) and r.join_date is not null and t >= r.join_date + (r.end_date - r.join_date) / 2 and t < r.end_date - (s->>'start_days_before')::int
       and not exists (select 1 from public.cms_appraisals a where a.person_id = r.id and a.kind in ('checkin', 'probation')) then
      insert into public.cms_appraisals (person_id, kind, due_date, reviewer_id, scores, created_by) values (r.id, 'checkin', t + 7, r.reports_to_id, '[]'::jsonb, null);
      c := c + 1;
    end if;
  end loop;
  return jsonb_build_object('reviews_started', n, 'checkins', c);
end $f$;

do $j$ begin
  if exists (select 1 from cron.job where jobname = 'cms-probation-daily') then perform cron.unschedule('cms-probation-daily'); end if;
  perform cron.schedule('cms-probation-daily', '20 16 * * *', 'select private.cms_probation_daily()');
end $j$;

-- the review list on KPI & Appraisal skips the check-ins
create or replace function private.cms_appraisal_json(a cms_appraisals, p_full boolean) returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  select jsonb_build_object('id', a.id, 'person_id', a.person_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'title', em.approved_job_title, 'kind', a.kind, 'year', a.year, 'period_from', a.period_from, 'period_to', a.period_to, 'due', a.due_date,
    'reviewer_id', a.reviewer_id, 'reviewer', rv.employee_name, 'self_requested', a.self_requested, 'status', a.status, 'self_done', a.self_at is not null, 'self_at', a.self_at,
    'rating', case when p_full or a.status = 'approved' then a.rating end, 'recommendation', case when p_full then a.recommendation end,
    'reviewed_by', a.reviewed_by_name, 'reviewed_at', a.reviewed_at, 'approved_by', a.approved_by_name, 'approved_at', a.approved_at, 'outcome', case when p_full then a.outcome end, 'letter_issued_at', a.letter_issued_at, 'letter_ref', a.letter_ref,
    'rec_extend_to', case when p_full then a.rec_extend_to end, 'follow_up', a.follow_up_of is not null, 'pip_month', a.pip_month, 'pip_months', a.pip_months, 'pct', a.result->'pct', 'outside', a.outside,
    'probation_end', case when a.kind = 'probation' then (select end_date from private.cms_probation_end(a.person_id)) end,
    'probation_source', case when a.kind = 'probation' then (select source from private.cms_probation_end(a.person_id)) end)
  from public.employee_master em left join public.employee_master rv on rv.id = a.reviewer_id where em.id = a.person_id;
$f$;

revoke all on function public.cms_probation_reviewers(uuid, jsonb), public.cms_appraisal_score(uuid, jsonb), public.cms_probation_check(uuid, jsonb), public.cms_probation_outside(uuid, jsonb),
  public.cms_probation_checkin(uuid, jsonb), public.cms_probation_review(uuid), public.cms_probation_list(), public.cms_probation_settings_save(jsonb), public.cms_kpi_rubric_save(jsonb) from public, anon;
grant execute on function public.cms_probation_reviewers(uuid, jsonb), public.cms_appraisal_score(uuid, jsonb), public.cms_probation_check(uuid, jsonb), public.cms_probation_outside(uuid, jsonb),
  public.cms_probation_checkin(uuid, jsonb), public.cms_probation_review(uuid), public.cms_probation_list(), public.cms_probation_settings_save(jsonb), public.cms_kpi_rubric_save(jsonb) to authenticated;

-- people who can be chosen as reviewers (JD level at or above the setting)
create or replace function public.cms_probation_reviewer_choices() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
begin
  perform private.cms_require('performance.probation', 'E');
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'name', q.employee_name, 'level', q.lv, 'title', q.approved_job_title, 'company', private.cms_canon(q.company_code)) order by q.employee_name)
    from (select em.*, private.cms_level_num(em.id) lv from public.employee_master em where em.employment_status in ('active', 'onboarding')) q
   where q.lv >= (private.cms_prob_settings()->>'min_reviewer_level')::int), '[]'::jsonb);
end $f$;
revoke all on function public.cms_probation_reviewer_choices() from public, anon;
grant execute on function public.cms_probation_reviewer_choices() to authenticated;
