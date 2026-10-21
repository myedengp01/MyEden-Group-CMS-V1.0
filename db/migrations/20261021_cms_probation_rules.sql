-- MyEden Group CMS V1.0 · probation rules (CLC 21 Oct 2026)
-- * Probation end date = confirmation date. On "confirm" the confirmation date is the probation end date.
-- * The probation period differs per person (3 to 6 months, can be longer): taken from the record, else from the offer
--   (MEG-EAF V2 Office Use "probation months"), else assumed 3 months (shown as assumed; HR sets it when starting the review).
-- * An extension needs a probation extension letter: tracked on the appraisal until HR ticks it as issued, and a follow-up
--   probation review is opened automatically, due on the new end date.

alter table public.cms_appraisals add column if not exists letter_issued_at timestamptz;
alter table public.cms_appraisals add column if not exists letter_ref text;
alter table public.cms_appraisals add column if not exists letter_by uuid;
alter table public.cms_appraisals add column if not exists follow_up_of uuid references public.cms_appraisals(id) on delete set null;

-- probation end and where it came from
create or replace function private.cms_probation_end(p_person uuid)
returns table(end_date date, source text, months numeric, join_date date)
language sql stable security definer set search_path = public, pg_temp as $$
  with j as (select max(m.join_date) jd from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
              where e.employee_master_id = p_person and m.resigned_date is null),
       o as (select nullif(regexp_replace(coalesce(a.payload->>'v2ProbationMonths', ''), '[^0-9.]', '', 'g'), '')::numeric mo
               from public.employee_master em join public.eaf_applications a on a.id = em.source_application_id where em.id = p_person)
  select case when em.probation_end_date is not null then em.probation_end_date
              when (select mo from o) is not null then (coalesce((select jd from j), em.start_date) + make_interval(months => (select mo from o)::int))::date
              else (coalesce((select jd from j), em.start_date) + interval '3 months')::date end,
         case when em.probation_end_date is not null then 'recorded' when (select mo from o) is not null then 'offer' else 'assumed' end,
         (select mo from o), coalesce((select jd from j), em.start_date)
  from public.employee_master em where em.id = p_person;
$$;

do $m$ declare d text; n text;
begin
  -- HR list: probation end from the rule above (+ where it came from)
  d := pg_get_functiondef('public.cms_appraisals()'::regprocedure);
  n := replace(d, $x$'on_probation', pr.on_prob, 'probation_end', case when pr.on_prob then coalesce(em.probation_end_date, (pr.join_date + interval '3 months')::date) end,$x$,
                  $x$'on_probation', pr.on_prob, 'probation_end', case when pr.on_prob then (select end_date from private.cms_probation_end(em.id)) end,
          'probation_source', case when pr.on_prob then (select source from private.cms_probation_end(em.id)) end,
          'letters_due', (select count(*) from public.cms_appraisals x where x.person_id = em.id and x.recommendation = 'extend' and x.status = 'approved' and x.letter_issued_at is null),$x$);
  if n = d then raise exception 'cms_appraisals patch point not found'; end if;
  execute n;
  -- reminders: probation due by the rule; extension letters not yet issued
  d := pg_get_functiondef('public.cms_appraisals_pending()'::regprocedure);
  n := replace(d, $x$and coalesce(em.probation_end_date, (pr.jd + interval '3 months')::date) <= current_date + 30$x$,
                  $x$and (select end_date from private.cms_probation_end(em.id)) <= current_date + 30$x$);
  n := replace(n, $x$'to_review', case when me is null$x$, $x$'letters_due', case when public.cms_can('performance', 'E') then (select count(*) from public.cms_appraisals where recommendation = 'extend' and status = 'approved' and letter_issued_at is null) else 0 end,
    'to_review', case when me is null$x$);
  if n = d then raise exception 'cms_appraisals_pending patch point not found'; end if;
  execute n;
end $m$;

-- start: HR can set the probation end date (saved on the person)
do $m$ declare d text := pg_get_functiondef('public.cms_appraisal_start(jsonb)'::regprocedure); n text;
begin
  n := replace(d, $x$  insert into public.cms_appraisals (person_id, kind, year,$x$,
                  $x$  if k = 'probation' and nullif(p->>'probation_end', '') is not null then
    update public.employee_master set probation_end_date = (p->>'probation_end')::date, updated_at = now() where id = em.id;
  end if;
  insert into public.cms_appraisals (person_id, kind, year,$x$);
  if n = d then raise exception 'cms_appraisal_start patch point not found'; end if;
  execute n;
end $m$;

-- approve: confirmation date = probation end date; extension → letter to issue + follow-up review
do $m$ declare d text := pg_get_functiondef('public.cms_appraisal_approve(uuid, text, boolean)'::regprocedure); n text;
begin
  n := replace(d, $x$    if a.recommendation = 'confirm' then
      update public.eppd_employments m set confirmation_status = 'C', confirmed_date = coalesce(m.confirmed_date, d), updated_at = now()
        from public.eppd_employees e where e.id = m.employee_id and e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP';
      update public.employee_master set confirmation_status = 'confirmed', confirmation_date = d, updated_at = now() where id = em.id;
      out := out || jsonb_build_object('confirmed_on', d);
    elsif a.recommendation = 'extend' then
      update public.employee_master set probation_end_date = a.rec_extend_to, updated_at = now() where id = em.id;
      out := out || jsonb_build_object('probation_extended_to', a.rec_extend_to);$x$,
  $x$    if a.recommendation = 'confirm' then
      -- probation end date = confirmation date
      update public.employee_master set probation_end_date = coalesce(probation_end_date, (select end_date from private.cms_probation_end(em.id)), d) where id = em.id;
      update public.eppd_employments m set confirmation_status = 'C', confirmed_date = coalesce(m.confirmed_date, (select probation_end_date from public.employee_master where id = em.id)), updated_at = now()
        from public.eppd_employees e where e.id = m.employee_id and e.employee_master_id = em.id and m.resigned_date is null and m.confirmation_status = 'UP';
      update public.employee_master set confirmation_status = 'confirmed', confirmation_date = probation_end_date, updated_at = now() where id = em.id;
      out := out || jsonb_build_object('confirmed_on', (select confirmation_date from public.employee_master where id = em.id));
    elsif a.recommendation = 'extend' then
      update public.employee_master set probation_end_date = a.rec_extend_to, updated_at = now() where id = em.id;
      insert into public.cms_appraisals (person_id, kind, due_date, reviewer_id, self_requested, scores, created_by, follow_up_of)
      values (em.id, 'probation', a.rec_extend_to, a.reviewer_id, a.self_requested,
              (select jsonb_agg(x || '{"score":null,"comment":null}'::jsonb) from jsonb_array_elements(private.cms_appraisal_areas(em.id)) x), auth.uid(), a.id);
      out := out || jsonb_build_object('probation_extended_to', a.rec_extend_to, 'extension_letter', 'to issue', 'follow_up_review_due', a.rec_extend_to);$x$);
  n := replace(n, $x$case when a.recommendation = 'confirm' then d end,$x$, $x$case when a.recommendation = 'confirm' then (select confirmation_date from public.employee_master where id = em.id) end,$x$);
  if n = d then raise exception 'cms_appraisal_approve patch point not found'; end if;
  execute n;
end $m$;

-- the probation extension letter has been issued
create or replace function public.cms_appraisal_letter(p_id uuid, p_ref text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.cms_appraisals; em public.employee_master;
begin
  select * into a from public.cms_appraisals where id = p_id for update;
  if a.id is null or a.recommendation <> 'extend' or a.status <> 'approved' then raise exception 'Only an approved probation extension needs a letter.'; end if;
  select * into em from public.employee_master where id = a.person_id;
  perform private.cms_require('performance', 'E', private.cms_canon(em.company_code));
  update public.cms_appraisals set letter_issued_at = now(), letter_ref = nullif(btrim(p_ref), ''), letter_by = auth.uid(), updated_at = now() where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'probation_extension_letter', 'Probation extension letter issued' || coalesce(' · ' || nullif(btrim(p_ref), ''), ''),
          jsonb_build_object('appraisal_id', a.id, 'new_end', a.rec_extend_to), auth.uid());
  perform private.cms_log('appraisal.letter', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': probation extension letter issued (to ' || to_char(a.rec_extend_to, 'DD Mon YYYY') || ')', jsonb_build_object('ref', p_ref));
end $$;
revoke all on function public.cms_appraisal_letter(uuid, text) from public, anon;
grant execute on function public.cms_appraisal_letter(uuid, text) to authenticated;

-- the appraisal JSON carries the letter state and the probation end
do $m$ declare d text := pg_get_functiondef('private.cms_appraisal_json(public.cms_appraisals, boolean)'::regprocedure); n text;
begin
  n := replace(d, $x$'outcome', case when p_full then a.outcome end)$x$,
                  $x$'outcome', case when p_full then a.outcome end, 'letter_issued_at', a.letter_issued_at, 'letter_ref', a.letter_ref,
    'rec_extend_to', case when p_full then a.rec_extend_to end, 'follow_up', a.follow_up_of is not null,
    'probation_end', case when a.kind = 'probation' then (select end_date from private.cms_probation_end(a.person_id)) end,
    'probation_source', case when a.kind = 'probation' then (select source from private.cms_probation_end(a.person_id)) end)$x$);
  if n = d then raise exception 'cms_appraisal_json patch point not found'; end if;
  execute n;
end $m$;

-- probation review actions allowed by employee_probation_reviews
do $m$ declare d text := pg_get_functiondef('public.cms_appraisal_approve(uuid, text, boolean)'::regprocedure); n text;
begin
  n := replace(d, $x$case a.recommendation when 'confirm' then 'confirmed' when 'extend' then 'extended' else 'not_confirmed' end$x$,
                  $x$case a.recommendation when 'confirm' then 'confirmed' when 'extend' then 'probation_extended' else 'review_note' end$x$);
  if n <> d then execute n; end if;
end $m$;
