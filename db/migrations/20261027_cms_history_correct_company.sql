-- MyEden Group CMS V1.0 · Employment history: correct the company of a paying-company part (Super Admin)
-- For records that were wrong from the start (e.g. imported under MyEden Group but always paid by Happy Dino): the part keeps its dates,
-- only its company changes. Different from Transfer, which changes the company from a date onwards. Pay lines are then moved with
-- "Pay lines vs history". Reason required; logged on the Timeline and in the audit log.
create or replace function public.cms_person_assignment_correct(p_person uuid, p_assignment bigint, p jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; a public.eppd_assignments; m public.eppd_employments; pc public.eppd_companies; fco text;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can correct the paying company of a past part.' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason for the change (at least 5 characters).'; end if;
  select * into em from public.employee_master where id = p_person;
  select a0.* into a from public.eppd_assignments a0 join public.eppd_employments m0 on m0.id = a0.employment_id join public.eppd_employees e0 on e0.id = m0.employee_id
   where a0.id = p_assignment and e0.employee_master_id = em.id for update;
  if a.id is null then raise exception 'Paying-company part not found.'; end if;
  select * into m from public.eppd_employments where id = a.employment_id;
  select * into pc from public.eppd_companies where code = p->>'company'; if pc.id is null then raise exception 'Choose the company.'; end if;
  if pc.id = a.company_id then raise exception 'This part is already under %.', pc.name; end if;
  if exists (select 1 from public.eppd_assignments x where x.employment_id = a.employment_id and x.id <> a.id and x.company_id = pc.id
              and daterange(x.start_date, x.end_date, '[]') && daterange(a.start_date, a.end_date, '[]')) then
    raise exception '% already pays this person in the same dates.', pc.name; end if;
  select code into fco from public.eppd_companies where id = a.company_id;
  update public.eppd_assignments set company_id = pc.id where id = a.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'paying_company_corrected', 'Paid by ' || fco || ' → ' || pc.code || ' for ' || coalesce(to_char(a.start_date, 'DD Mon YYYY'), 'the start') || ' – ' || coalesce(to_char(a.end_date, 'DD Mon YYYY'), 'now') || ' · ' || btrim(p_reason),
          jsonb_build_object('assignment', a.id, 'from', fco, 'to', pc.code, 'reason', btrim(p_reason)), auth.uid());
  perform private.cms_log('person.paying', 'employee_master', em.id::text, pc.code,
    em.employee_name || ': paying company corrected ' || fco || ' → ' || pc.code || ' (' || coalesce(to_char(a.start_date, 'DD Mon YYYY'), 'start') || ' – ' || coalesce(to_char(a.end_date, 'DD Mon YYYY'), 'now') || ') · ' || btrim(p_reason),
    jsonb_build_object('assignment', a.id, 'from', fco, 'to', pc.code, 'reason', btrim(p_reason)));
  return jsonb_build_object('from', fco, 'to', pc.code);
end $f$;
revoke all on function public.cms_person_assignment_correct(uuid, bigint, jsonb, text) from public, anon;
grant execute on function public.cms_person_assignment_correct(uuid, bigint, jsonb, text) to authenticated;

-- employer periods seeded from the master record end on the last day when every employment period has ended
create or replace function private.cms_seed_employer_periods(p_person uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; v_start date; v_end date;
begin
  if exists (select 1 from public.cms_employer_periods where person_id = p_person) then return; end if;
  select * into em from public.employee_master where id = p_person;
  select min(m.join_date), case when bool_and(m.resigned_date is not null) then max(m.resigned_date) end into v_start, v_end
    from public.eppd_employments m join public.eppd_employees ee on ee.id = m.employee_id where ee.employee_master_id = p_person;
  v_start := coalesce(v_start, em.start_date, em.original_group_join_date);
  if v_start is null or private.cms_canon(em.company_code) not in ('MEG', 'MEH', 'HD', 'ABP') then return; end if;
  insert into public.cms_employer_periods (person_id, company_code, start_date, end_date, note)
  values (p_person, private.cms_canon(em.company_code), v_start, v_end, 'From the master record');
end $f$;
revoke all on function private.cms_seed_employer_periods(uuid) from public, anon, authenticated;
