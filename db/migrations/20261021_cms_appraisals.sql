-- MyEden Group CMS V1.0 · Phase 5b · KPI & Appraisal
-- Probation and annual appraisals. HR starts an appraisal (reviewer = the person they report to, editable; optional
-- self-assessment by the person). The reviewer scores the JD KPIs + conduct, attendance and child safety, gives the KPI
-- grade (E/S/A/I/U) and a recommendation. HR / Admin or a director approves (never their own), which applies the outcome:
--   annual    → KPI grade written to payroll (eppd_kpi_ratings: annual-leave carry forward); promotion → JD position;
--               increment → recommended amount shown for Increments & Reviews (recorded there, from a payroll month)
--   probation → confirm (payroll confirmation + Employee Master), extend (new probation end), or end (note only)

insert into public.cms_role_permissions (role_code, module_code, actions) values ('director', 'performance', 'VA')
on conflict (role_code, module_code) do update set actions = case when cms_role_permissions.actions like '%A%' then cms_role_permissions.actions else cms_role_permissions.actions || 'A' end;

create table if not exists public.cms_appraisals (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  kind text not null check (kind in ('probation','annual')),
  year int, period_from date, period_to date, due_date date,
  reviewer_id uuid references public.employee_master(id) on delete set null,
  self_requested boolean not null default false,
  status text not null default 'open' check (status in ('open','reviewed','approved','cancelled')),
  self_answers jsonb, self_at timestamptz,
  scores jsonb not null default '[]'::jsonb,           -- [{area, measure, score 1-5, comment}]
  rating text check (rating in ('E','S','A','I','U')),
  strengths text, improvements text, goals text,
  recommendation text check (recommendation in ('confirm','extend','end','increment','promote','no_change','pip')),
  rec_increment numeric(12,2), rec_position uuid references public.jd_positions(id) on delete set null, rec_extend_to date,
  reviewed_by uuid, reviewed_by_name text, reviewed_at timestamptz,
  approved_by uuid, approved_by_name text, approved_at timestamptz, approve_note text, outcome jsonb,
  created_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table public.cms_appraisals enable row level security;
create index if not exists cms_appraisals_person_idx on public.cms_appraisals (person_id, status);
create unique index if not exists cms_appraisals_one_annual on public.cms_appraisals (person_id, year) where kind = 'annual' and status <> 'cancelled';

-- roles on one appraisal for the signed-in user
create or replace function private.cms_appraisal_role(a public.cms_appraisals)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me(); em public.employee_master; hr boolean;
begin
  select * into em from public.employee_master where id = a.person_id;
  if me is not null and me = a.person_id then return 'self'; end if;
  hr := private.cms_can_company('performance', 'E', private.cms_canon(em.company_code));
  if hr then return 'hr'; end if;
  if me is not null and private.cms_person_is_director(me) then return 'director'; end if;
  if me is not null and me = a.reviewer_id then return 'reviewer'; end if;
  if me is not null and exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
        select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
      select 1 from up where id = me) then return 'manager'; end if;
  if private.cms_can_company('performance', 'V', private.cms_canon(em.company_code)) then return 'viewer'; end if;
  return null;
end $$;

-- the KPI areas to score: the person's JD KPIs plus three that apply to everyone
create or replace function private.cms_appraisal_areas(p_person uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select jsonb_agg(jsonb_build_object('area', k.area, 'measure', k.measure) order by k.sequence)
                   from public.jd_kpis k where k.position_id = (select position_id from private.cms_position_of(p_person) limit 1)), '[]'::jsonb)
      || '[{"area":"Conduct and teamwork","measure":"Follows the handbook; works well with colleagues and parents"},
           {"area":"Attendance and punctuality","measure":"Leave, lateness and absence within policy"},
           {"area":"Child safety and safeguarding","measure":"Follows safety and child-protection procedures at all times"}]'::jsonb;
$$;

create or replace function private.cms_appraisal_json(a public.cms_appraisals, p_full boolean)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', a.id, 'person_id', a.person_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'title', em.approved_job_title, 'kind', a.kind, 'year', a.year, 'period_from', a.period_from, 'period_to', a.period_to, 'due', a.due_date,
    'reviewer_id', a.reviewer_id, 'reviewer', rv.employee_name, 'self_requested', a.self_requested, 'status', a.status, 'self_done', a.self_at is not null, 'self_at', a.self_at,
    'rating', case when p_full or a.status = 'approved' then a.rating end, 'recommendation', case when p_full then a.recommendation end,
    'reviewed_by', a.reviewed_by_name, 'reviewed_at', a.reviewed_at, 'approved_by', a.approved_by_name, 'approved_at', a.approved_at, 'outcome', case when p_full then a.outcome end)
  from public.employee_master em left join public.employee_master rv on rv.id = a.reviewer_id where em.id = a.person_id;
$$;

-- HR page: appraisals and who is due
create or replace function public.cms_appraisals()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare y int := extract(year from (now() at time zone 'Asia/Kuala_Lumpur'))::int; cut int;
begin
  perform private.cms_require('performance', 'V');
  cut := coalesce(((select value from public.eppd_policies where key = 'carry_forward')->>'kpi_cutoff_month')::int, 10);
  return jsonb_build_object('can_edit', public.cms_can('performance', 'E'), 'year', y, 'kpi_cutoff_month', cut,
    'grade_labels', coalesce((select value->'grade_labels' from public.eppd_policies where key = 'carry_forward'), '{"E":"Excellent","S":"Satisfactory","A":"Average","I":"Needs improvement","U":"Under performing"}'::jsonb),
    'appraisals', coalesce((select jsonb_agg(private.cms_appraisal_json(a, true) order by (a.status in ('open','reviewed')) desc, a.due_date nulls last, a.created_at desc)
      from public.cms_appraisals a join public.employee_master em on em.id = a.person_id
      where private.cms_can_company('performance', 'V', private.cms_canon(em.company_code)) and (a.status <> 'cancelled' or a.updated_at > now() - interval '30 days')), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
          'title', em.approved_job_title, 'reports_to_id', em.reports_to_id, 'start', em.start_date,
          'on_probation', pr.on_prob, 'probation_end', case when pr.on_prob then coalesce(em.probation_end_date, (pr.join_date + interval '3 months')::date) end,
          'annual_done', exists (select 1 from public.cms_appraisals a where a.person_id = em.id and a.kind = 'annual' and a.year = y and a.status <> 'cancelled'),
          'probation_open', exists (select 1 from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status in ('open','reviewed')),
          'grade', (select k.grade from public.eppd_kpi_ratings k join public.eppd_employees e on e.id = k.employee_id where e.employee_master_id = em.id and k.year = y limit 1))
        order by em.employee_name)
      from public.employee_master em
      left join lateral (select bool_or(m.confirmation_status = 'UP') on_prob, max(m.join_date) join_date from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
                         where e.employee_master_id = em.id and m.resigned_date is null) pr on true
      where em.employment_status in ('active','onboarding') and private.cms_can_company('performance', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $$;

create or replace function public.cms_appraisal_start(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; v uuid; k text := p->>'kind'; y int;
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('performance', 'E', private.cms_canon(em.company_code));
  if k not in ('probation','annual') then raise exception 'Choose probation or annual.'; end if;
  y := coalesce(nullif(p->>'year', '')::int, extract(year from current_date)::int);
  if k = 'annual' and exists (select 1 from public.cms_appraisals where person_id = em.id and kind = 'annual' and year = y and status <> 'cancelled') then
    raise exception '% already has an annual appraisal for %.', em.employee_name, y;
  end if;
  if k = 'probation' and exists (select 1 from public.cms_appraisals where person_id = em.id and kind = 'probation' and status in ('open','reviewed')) then
    raise exception '% already has a probation review in progress.', em.employee_name;
  end if;
  insert into public.cms_appraisals (person_id, kind, year, period_from, period_to, due_date, reviewer_id, self_requested, scores, created_by)
  values (em.id, k, case when k = 'annual' then y end, nullif(p->>'period_from', '')::date, nullif(p->>'period_to', '')::date, nullif(p->>'due', '')::date,
          coalesce(nullif(p->>'reviewer_id', '')::uuid, em.reports_to_id), coalesce((p->>'self_requested')::boolean, false),
          (select jsonb_agg(x || '{"score":null,"comment":null}'::jsonb) from jsonb_array_elements(private.cms_appraisal_areas(em.id)) x), auth.uid())
  returning id into v;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'appraisal_started', initcap(k) || ' appraisal started', jsonb_build_object('appraisal_id', v, 'year', y), auth.uid());
  perform private.cms_log('appraisal.started', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || k || ' appraisal started', p);
  return v;
end $$;

create or replace function public.cms_appraisal(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals; r text; pos record;
begin
  select * into a from public.cms_appraisals where id = p_id;
  if a.id is null then raise exception 'Appraisal not found.'; end if;
  r := private.cms_appraisal_role(a);
  if r is null then raise exception 'Not allowed.'; end if;
  select p.id, p.level, p.job_title, p.company, p.department_id into pos
    from (select jp.*, private.cms_canon(e.code) company from public.jd_positions jp join public.jd_entities e on e.id = jp.entity_id) p
   where p.id = (select position_id from private.cms_position_of(a.person_id) limit 1);
  if r = 'self' then   -- the person: their own answers, and the result once approved
    return private.cms_appraisal_json(a, false) || jsonb_build_object('role', r, 'self_answers', a.self_answers,
      'result', case when a.status = 'approved' then jsonb_build_object('scores', a.scores, 'rating', a.rating, 'strengths', a.strengths, 'improvements', a.improvements, 'goals', a.goals) end);
  end if;
  return private.cms_appraisal_json(a, true) || jsonb_build_object('role', r, 'self_answers', a.self_answers, 'scores', a.scores, 'strengths', a.strengths,
    'improvements', a.improvements, 'goals', a.goals, 'rec_increment', case when public.cms_can('payroll.increments', 'V') or r in ('hr','director') then a.rec_increment end,
    'rec_position', a.rec_position, 'rec_extend_to', a.rec_extend_to, 'approve_note', a.approve_note,
    'position', case when pos.id is not null then jsonb_build_object('id', pos.id, 'level', pos.level, 'title', pos.job_title) end,
    'next_positions', coalesce((select jsonb_agg(jsonb_build_object('id', jp.id, 'level', jp.level, 'title', jp.job_title))
        from public.jd_positions jp where pos.id is not null and jp.department_id = pos.department_id and jp.entity_id = (select entity_id from public.jd_positions where id = pos.id)
         and nullif(regexp_replace(jp.level, '\D', '', 'g'), '')::int = nullif(regexp_replace(pos.level, '\D', '', 'g'), '')::int + 1), '[]'::jsonb),
    'can_review', a.status in ('open','reviewed') and r in ('hr','director','reviewer','manager'),
    'can_approve', a.status = 'reviewed' and r in ('hr','director'),
    'grade_labels', coalesce((select value->'grade_labels' from public.eppd_policies where key = 'carry_forward'), '{}'::jsonb));
end $$;

create or replace function public.cms_appraisal_self(p_id uuid, p_answers jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.person_id is distinct from private.cms_me() then raise exception 'Appraisal not found.'; end if;
  if not a.self_requested then raise exception 'A self-assessment was not asked for.'; end if;
  if a.status <> 'open' then raise exception 'This appraisal has already been reviewed.'; end if;
  update public.cms_appraisals set self_answers = p_answers, self_at = now(), updated_at = now() where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (a.person_id, 'appraisal_self_done', 'Self-assessment sent', jsonb_build_object('appraisal_id', a.id), auth.uid());
end $$;

create or replace function public.cms_appraisal_review(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals; r text; rec text := nullif(p->>'recommendation', '');
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.status not in ('open','reviewed') then raise exception 'Appraisal not found or already approved.'; end if;
  r := private.cms_appraisal_role(a);
  if r not in ('hr','director','reviewer','manager') then raise exception 'You cannot review this appraisal.'; end if;
  if nullif(p->>'rating', '') is null then raise exception 'Give the overall KPI grade.'; end if;
  if rec is null then raise exception 'Choose a recommendation.'; end if;
  if a.kind = 'probation' and rec not in ('confirm','extend','end') then raise exception 'For probation choose confirm, extend or end.'; end if;
  if a.kind = 'annual' and rec not in ('increment','promote','no_change','pip') then raise exception 'Choose increment, promotion, no change or improvement plan.'; end if;
  if rec = 'extend' and nullif(p->>'rec_extend_to', '') is null then raise exception 'Give the new probation end date.'; end if;
  if rec = 'promote' and nullif(p->>'rec_position', '') is null then raise exception 'Choose the position to promote to.'; end if;
  update public.cms_appraisals set scores = coalesce(p->'scores', scores), rating = p->>'rating', strengths = nullif(btrim(p->>'strengths'), ''),
         improvements = nullif(btrim(p->>'improvements'), ''), goals = nullif(btrim(p->>'goals'), ''), recommendation = rec,
         rec_increment = nullif(p->>'rec_increment', '')::numeric, rec_position = nullif(p->>'rec_position', '')::uuid, rec_extend_to = nullif(p->>'rec_extend_to', '')::date,
         status = 'reviewed', reviewed_by = auth.uid(), reviewed_by_name = private.cms_my_name(), reviewed_at = now(), updated_at = now()
   where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (a.person_id, 'appraisal_reviewed', 'Appraisal reviewed by ' || private.cms_my_name(), jsonb_build_object('appraisal_id', a.id, 'rating', p->>'rating', 'recommendation', rec), auth.uid());
end $$;

create or replace function public.cms_appraisal_approve(p_id uuid, p_note text default null, p_return boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals; r text; em public.employee_master; out jsonb := '{}'::jsonb; eid bigint; d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.status <> 'reviewed' then raise exception 'Only a reviewed appraisal can be approved.'; end if;
  r := private.cms_appraisal_role(a);
  if r not in ('hr','director') then raise exception 'HR / Admin or a director approves appraisals.'; end if;
  if a.reviewed_by = auth.uid() and r <> 'hr' then raise exception 'The reviewer cannot also approve.'; end if;
  select * into em from public.employee_master where id = a.person_id;
  if p_return then
    update public.cms_appraisals set status = 'open', approve_note = nullif(btrim(p_note), ''), updated_at = now() where id = a.id;
    return jsonb_build_object('returned', true);
  end if;
  -- KPI grade → payroll (annual-leave carry forward)
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
  if a.recommendation in ('increment','promote') and a.rec_increment is not null then
    out := out || jsonb_build_object('increment_to_record', a.rec_increment);
  end if;
  if a.kind = 'probation' then
    if a.recommendation = 'confirm' then
      update public.eppd_employments m set confirmation_status = 'C', confirmed_date = coalesce(m.confirmed_date, d), updated_at = now()
        from public.eppd_employees e where e.id = m.employee_id and e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP';
      update public.employee_master set confirmation_status = 'confirmed', confirmation_date = d, updated_at = now() where id = em.id;
      out := out || jsonb_build_object('confirmed_on', d);
    elsif a.recommendation = 'extend' then
      update public.employee_master set probation_end_date = a.rec_extend_to, updated_at = now() where id = em.id;
      out := out || jsonb_build_object('probation_extended_to', a.rec_extend_to);
    else
      out := out || jsonb_build_object('end_of_employment', 'Record the leaving in payroll (notice, reason) — not done automatically');
    end if;
    insert into public.employee_probation_reviews (employee_id_ref, review_date, action, original_probation_end_date, revised_probation_end_date, confirmation_date,
           performance_summary, manager_recommendation, note, recorded_by, recorded_at)
    values (em.id, d, case a.recommendation when 'confirm' then 'confirmed' when 'extend' then 'extended' else 'not_confirmed' end, em.probation_end_date,
            case when a.recommendation = 'extend' then a.rec_extend_to end, case when a.recommendation = 'confirm' then d end,
            concat_ws(' · ', 'KPI grade ' || a.rating, a.strengths, a.improvements), a.recommendation, nullif(btrim(p_note), ''), auth.uid(), now());
  end if;
  update public.cms_appraisals set status = 'approved', approved_by = auth.uid(), approved_by_name = private.cms_my_name(), approved_at = now(),
         approve_note = nullif(btrim(p_note), ''), outcome = out, updated_at = now() where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'appraisal_approved', initcap(a.kind) || ' appraisal approved · grade ' || coalesce(a.rating, '—') || ' · ' || a.recommendation, jsonb_build_object('appraisal_id', a.id) || out, auth.uid());
  perform private.cms_log('appraisal.approved', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || a.kind || ' appraisal approved (' || coalesce(a.rating, '—') || ', ' || a.recommendation || ')', out);
  return out;
end $$;

create or replace function public.cms_appraisal_update(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals; em public.employee_master;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null then raise exception 'Appraisal not found.'; end if;
  select * into em from public.employee_master where id = a.person_id;
  perform private.cms_require('performance', 'E', private.cms_canon(em.company_code));
  if coalesce((p->>'cancel')::boolean, false) then
    if a.status = 'approved' then raise exception 'An approved appraisal cannot be cancelled.'; end if;
    update public.cms_appraisals set status = 'cancelled', updated_at = now() where id = a.id;
  else
    update public.cms_appraisals set due_date = coalesce(nullif(p->>'due', '')::date, due_date),
           reviewer_id = case when p ? 'reviewer_id' then nullif(p->>'reviewer_id', '')::uuid else reviewer_id end,
           self_requested = coalesce((p->>'self_requested')::boolean, self_requested), updated_at = now() where id = a.id;
  end if;
end $$;

-- staff: My Appraisal (own appraisals with a self-assessment or a result; appraisals to review as reviewer / manager)
create or replace function public.cms_my_appraisals()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me();
begin
  if me is null then raise exception 'This login is not linked to an employee record.'; end if;
  return jsonb_build_object(
    'mine', coalesce((select jsonb_agg(private.cms_appraisal_json(a, false) order by a.created_at desc) from public.cms_appraisals a
                      where a.person_id = me and (a.self_requested or a.status = 'approved') and a.status <> 'cancelled'), '[]'::jsonb),
    'to_review', coalesce((select jsonb_agg(private.cms_appraisal_json(a, true) order by a.due_date nulls last) from public.cms_appraisals a
                      where a.status in ('open','reviewed') and a.person_id <> me and (a.reviewer_id = me or private.cms_appraisal_role(a) in ('manager','director'))), '[]'::jsonb));
end $$;

create or replace function public.cms_appraisals_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me();
begin
  return jsonb_build_object(
    'self_to_do', case when me is null then 0 else (select count(*) from public.cms_appraisals where person_id = me and self_requested and self_at is null and status = 'open') end,
    'to_review', case when me is null then 0 else (select count(*) from public.cms_appraisals a where a.status = 'open' and a.person_id <> me and a.reviewer_id = me) end,
    'to_approve', case when public.cms_can('performance', 'E') or (me is not null and private.cms_person_is_director(me))
                       then (select count(*) from public.cms_appraisals a where a.status = 'reviewed' and private.cms_appraisal_role(a) in ('hr','director')) else 0 end,
    'probation_due', case when public.cms_can('performance', 'E') then (select count(*) from public.employee_master em
        join lateral (select max(m.join_date) jd from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
                      where e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP') pr on pr.jd is not null
        where em.employment_status in ('active','onboarding') and coalesce(em.probation_end_date, (pr.jd + interval '3 months')::date) <= current_date + 30
          and not exists (select 1 from public.cms_appraisals a where a.person_id = em.id and a.kind = 'probation' and a.status in ('open','reviewed'))) else 0 end);
end $$;

-- My Self-service shows "My Appraisal" while there is something for the person to do or see
create or replace function private.cms_has_appraisal(p_person uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_appraisals a where a.status <> 'cancelled' and (
      (a.person_id = p_person and (a.self_requested or (a.status = 'approved' and a.approved_at > now() - interval '400 days')))
   or (a.person_id <> p_person and a.status in ('open','reviewed') and a.reviewer_id = p_person)));
$$;

do $m$ declare d text := pg_get_functiondef('public.cms_my_self()'::regprocedure); n text;
begin
  if position('cms_has_appraisal' in d) > 0 then return; end if;
  n := replace(d, $x$'parts', coalesce((select jsonb_agg(part order by part) from public.cms_self_access where person_id = v and enabled), '[]'::jsonb),$x$,
                  $x$'parts', coalesce((select jsonb_agg(part order by part) from public.cms_self_access where person_id = v and enabled), '[]'::jsonb)
                       || case when private.cms_has_appraisal(v) then '["appraisal"]'::jsonb else '[]'::jsonb end,$x$);
  if n = d then raise exception 'cms_my_self patch point not found'; end if;
  execute n;
end $m$;

do $g$ declare f text;
begin
  foreach f in array array['cms_appraisals()','cms_appraisal_start(jsonb)','cms_appraisal(uuid)','cms_appraisal_self(uuid, jsonb)','cms_appraisal_review(uuid, jsonb)',
    'cms_appraisal_approve(uuid, text, boolean)','cms_appraisal_update(uuid, jsonb)','cms_my_appraisals()','cms_appraisals_pending()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
