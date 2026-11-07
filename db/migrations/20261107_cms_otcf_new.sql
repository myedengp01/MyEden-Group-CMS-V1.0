-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 F1 — new Overtime claims (OTCF) made in the CMS (CLC 7 Nov 2026)
-- Staff with the "Claims" part make OTCF claims from My Claims, like SCF: claimant from the login (person_id set), own company (others with
-- "Claims: other companies"), the month, working hours, then each overtime entry (date, from, to, meal break, claim type, public holiday,
-- remarks; several entries a day allowed). The server builds the same month sheet the OTCF app saves (one row per day, extra times as slot rows),
-- works out the hours (from → to, across midnight, less the meal break), refuses overlapping times on a day, and warns (does not block) on the
-- Employment Act limits (more than 12 hours in a day with working hours, more than 104 overtime hours in the month).
-- Same otcf_submissions table and serial format (OTCF-<CODE>-YYYYMMDD-HHMM-XX); approval stays as it is (Action Center or the OTCF app,
-- with the same rules: no self-approval, approvers / admins claim needs another admin). On behalf: office users with Overtime create.
-- Public holidays from the payroll holiday list (Payroll › Holidays) are ticked automatically when that list has them.
-- Additive: functions only.

-- who the claim is for, for any form module (SCF used private.cms_scf_who; same rules)
create or replace function private.cms_claim_who(p_person uuid, p_module text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me uuid := private.cms_me_person(); pid uuid := coalesce(p_person, me); em public.employee_master; behalf boolean;
begin
  if pid is null then raise exception 'Your login is not linked to a person record yet. Ask HR.'; end if;
  select * into em from public.employee_master where id = pid;
  if em.id is null then raise exception 'Person not found.'; end if;
  behalf := me is null or pid <> me;
  if behalf then
    if not public.cms_can(p_module, 'C', private.cms_canon(em.company_code)) then raise exception 'You cannot make these claims for other people.'; end if;
  elsif not (private.cms_self_on(pid, 'claims') or public.cms_can(p_module, 'C')) then
    raise exception 'Claims are not switched on for you. Ask HR.';
  end if;
  return jsonb_build_object('id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'department', coalesce(em.department, ''), 'designation', coalesce(nullif(split_part(coalesce(em.job_title_level, ''), '|', 2), ''), em.approved_job_title, ''),
    'behalf', behalf, 'any_company', behalf or private.cms_self_on(pid, 'claims_co') or public.cms_can(p_module, 'C'),
    'preparer', coalesce((select employee_name from public.employee_master where id = me), private.cms_user_name(auth.uid())));
end $f$;
revoke all on function private.cms_claim_who(uuid, text) from public, anon, authenticated;

create or replace function public.cms_otcf_context(p_person uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare w jsonb := private.cms_claim_who(p_person, 'overtime'); last public.otcf_submissions;
begin
  select * into last from public.otcf_submissions o where o.person_id = (w->>'id')::uuid and o.deleted_at is null order by o.created_at desc limit 1;
  return w || jsonb_build_object(
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'otcf', private.cms_scf_code(c.code), 'name', c.name) order by c.sort_order)
                    from public.cms_companies c where c.is_active and ((w->>'any_company')::boolean or c.code = w->>'company')),
    'working_from', coalesce(nullif(last.working_hour_from, ''), '09:00'), 'working_to', coalesce(nullif(last.working_hour_to, ''), '18:00'),
    'holidays', coalesce((select jsonb_agg(jsonb_build_object('date', h.holiday_date, 'name', h.name) order by h.holiday_date) from public.eppd_holidays h
                           where h.is_active and h.holiday_date >= (date_trunc('year', now()) - interval '1 year')::date), '[]'::jsonb));
end $f$;
revoke all on function public.cms_otcf_context(uuid) from public, anon;
grant execute on function public.cms_otcf_context(uuid) to authenticated;

create or replace function public.cms_otcf_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare s public.otcf_submissions; me uuid := private.cms_me_person();
begin
  select * into s from public.otcf_submissions where id = p_id and deleted_at is null;
  if s.id is null then raise exception 'Claim not found.'; end if;
  if s.submitted_by is distinct from auth.uid() and (me is null or coalesce(s.person_id, (select id from private.cms_claim_person(s.emp_name))) is distinct from me)
     and not public.cms_can('overtime', 'V', private.cms_canon(s.company_code)) then raise exception 'Claim not found.'; end if;
  return to_jsonb(s) - 'approval_token'
    || jsonb_build_object('editable', s.status = 'draft' and s.submitted_by = auth.uid(), 'mine', s.submitted_by = auth.uid(),
       'person', coalesce(s.person_id, (select id from private.cms_claim_person(s.emp_name))));
end $f$;
revoke all on function public.cms_otcf_get(uuid) from public, anon;
grant execute on function public.cms_otcf_get(uuid) to authenticated;

create or replace function private.cms_hm(t text) returns int language sql immutable as $$
  select case when coalesce(t, '') ~ '^[0-2][0-9]:[0-5][0-9]$' and split_part(t, ':', 1)::int < 24 then split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int end;
$$;

-- p: person_id?, company, month (1-12), year, working_from, working_to, department, designation,
--    entries [{date (day of month), from 'HH:MM', to, meal (hours), claim_type, ph, remarks}]
create or replace function public.cms_otcf_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare w jsonb; s public.otcf_submissions; co text; v_code text; mon int := (p->>'month')::int; yr int := (p->>'year')::int; nd int;
  e jsonb; d int; items jsonb := '[]'::jsonb; day_e jsonb; k int; fm int; tm int; tot numeric; meal numeric; act numeric; month_tot numeric := 0;
  ct text; warns jsonb := '[]'::jsonb; wf int := private.cms_hm(p->>'working_from'); wt int := private.cms_hm(p->>'working_to'); span numeric; day_tot numeric;
  spans int[][]; a int[]; b int[]; i int; j int; dname text; now_my timestamp := now() at time zone 'Asia/Kuala_Lumpur'; ser text; n int := 0;
begin
  if p_id is not null then
    select * into s from public.otcf_submissions where id = p_id and deleted_at is null for update;
    if s.id is null then raise exception 'Claim not found.'; end if;
    if s.submitted_by is distinct from auth.uid() then raise exception 'Only the person who made this claim can change it.'; end if;
    if s.status <> 'draft' then raise exception 'This claim has been submitted and can no longer be changed.'; end if;
    w := private.cms_claim_who(coalesce(nullif(p->>'person_id', '')::uuid, s.person_id, (select id from private.cms_claim_person(s.emp_name))), 'overtime');
  else
    w := private.cms_claim_who(nullif(p->>'person_id', '')::uuid, 'overtime');
  end if;
  co := coalesce(private.cms_canon(nullif(p->>'company', '')), w->>'company');
  if co is distinct from w->>'company' and not (w->>'any_company')::boolean then raise exception 'You can only claim under your own company.'; end if;
  if not exists (select 1 from public.cms_companies c where c.code = co and c.is_active) then raise exception 'Unknown company.'; end if;
  v_code := private.cms_scf_code(co);
  if mon is null or mon not between 1 and 12 or yr is null or yr not between 2024 and 2099 then raise exception 'Choose the month and year.'; end if;
  if wf is null or wt is null then raise exception 'Working hours must be like 09:00 and 18:00.'; end if;
  span := ((wt - wf + 1440) % 1440) / 60.0;
  nd := extract(day from (make_date(yr, mon, 1) + interval '1 month' - interval '1 day'))::int;
  for d in 1 .. nd loop
    dname := trim(to_char(make_date(yr, mon, d), 'Day'));
    k := 0; day_tot := 0; spans := array[]::int[][];
    for e in select x from jsonb_array_elements(coalesce(p->'entries', '[]'::jsonb)) x where (x->>'date')::int = d order by x->>'from' loop
      k := k + 1; n := n + 1;
      if n > 120 then raise exception 'Too many entries.'; end if;
      fm := private.cms_hm(e->>'from'); tm := private.cms_hm(e->>'to');
      if (coalesce(e->>'from', '') <> '' and fm is null) or (coalesce(e->>'to', '') <> '' and tm is null) then raise exception 'Day %: times must be like 18:30.', d; end if;
      if (fm is null) <> (tm is null) then raise exception 'Day %: give both the start and the end time.', d; end if;
      tot := case when fm is null then 0 else (((tm - fm) + 1440) % 1440) / 60.0 end;
      if fm is not null and fm = tm then raise exception 'Day %: start and end time are the same.', d; end if;
      meal := greatest(coalesce(public.meg_forms_try_numeric(e->>'meal'), 0), 0);
      if meal > tot then raise exception 'Day %: the meal break is longer than the overtime.', d; end if;
      act := round(tot - meal, 2);
      ct := coalesce(nullif(e->>'claim_type', ''), case when fm is null then '' when coalesce((e->>'ph')::boolean, false) then 'Public Holiday'
                                                       when extract(dow from make_date(yr, mon, d)) = 6 then 'Off Day' when extract(dow from make_date(yr, mon, d)) = 0 then 'Rest Day' else 'Normal' end);
      if ct not in ('', 'Normal', 'Off Day', 'Rest Day', 'Public Holiday') then raise exception 'Day %: unknown claim type.', d; end if;
      if fm is not null then
        a := array[fm, case when tm <= fm then tm + 1440 else tm end];
        for i in 1 .. coalesce(array_length(spans, 1), 0) loop
          if a[1] < spans[i][2] and spans[i][1] < a[2] then raise exception 'Day %: two overtime times overlap.', d; end if;
        end loop;
        spans := spans || array[a];
        if wf is not null and ct = 'Normal' and a[1] < (case when wt <= wf then wt + 1440 else wt end) and wf < a[2] then
          warns := warns || to_jsonb(format('Day %s: %s–%s overlaps the working hours %s–%s.', d, e->>'from', e->>'to', p->>'working_from', p->>'working_to')); end if;
      end if;
      day_tot := day_tot + act; month_tot := month_tot + act;
      if k = 1 then day_e := e || jsonb_build_object('_ct', ct, '_ph', coalesce((e->>'ph')::boolean, false)); end if;
      items := items || (jsonb_build_object('date', d::text, 'day', dname, 'ph', coalesce((day_e->>'_ph')::boolean, false), 'claimType', case when k = 1 then ct else coalesce(day_e->>'_ct', ct) end,
        'from', coalesce(e->>'from', ''), 'to', coalesce(e->>'to', ''), 'totalHrs', case when fm is null then '' else to_char(tot, 'FM990.00') end,
        'mealTime', to_char(meal, 'FM990.00'), 'actualHrs', case when fm is null then '' else to_char(act, 'FM990.00') end,
        'remarks', left(btrim(coalesce(e->>'remarks', '')), 200))
        || case when k > 1 then jsonb_build_object('slot', k) else '{}'::jsonb end);
    end loop;
    if k = 0 then
      items := items || jsonb_build_object('date', d::text, 'day', dname, 'ph', false, 'claimType', '', 'from', '', 'to', '', 'totalHrs', '', 'mealTime', '0.00', 'actualHrs', '', 'remarks', '');
    elsif day_tot > 0 and (case when day_e->>'_ct' = 'Normal' and not (day_e->>'_ph')::boolean then span else 0 end) + day_tot > 12 then
      warns := warns || to_jsonb(format('Day %s: %s h in the day (more than 12 hours).', d, to_char((case when day_e->>'_ct' = 'Normal' then span else 0 end) + day_tot, 'FM990.00')));
    end if;
  end loop;
  if month_tot > 104 then warns := warns || to_jsonb(format('Overtime this month: %s h — more than the 104-hour monthly limit.', to_char(month_tot, 'FM990.00'))); end if;
  if p_submit and month_tot <= 0 then raise exception 'Add at least one overtime time.'; end if;
  if s.id is null then
    ser := 'OTCF-' || v_code || '-' || to_char(now_my, 'YYYYMMDD-HH24MI') || '-' || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1) || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1);
    while exists (select 1 from public.otcf_submissions where serial_no = ser) loop
      ser := left(ser, length(ser) - 2) || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1) || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1);
    end loop;
    insert into public.otcf_submissions (serial_no, company_code, emp_name, person_id, status, submitted_by, line_items, total_hours)
    values (ser, v_code, w->>'name', (w->>'id')::uuid, 'draft', auth.uid(), '[]'::jsonb, 0) returning * into s;
  end if;
  update public.otcf_submissions set
    company_code = v_code,
    serial_no = case when s.submitted_at is null then 'OTCF-' || v_code || substr(s.serial_no, 5 + length(split_part(s.serial_no, '-', 2)) + 1) else s.serial_no end,
    emp_name = w->>'name', person_id = (w->>'id')::uuid,
    department = left(coalesce(nullif(btrim(p->>'department'), ''), w->>'department', ''), 120), designation = left(coalesce(nullif(btrim(p->>'designation'), ''), w->>'designation', ''), 120),
    month = mon, year = yr, no_of_days = nd, submission_date = now_my::date, working_hour_from = p->>'working_from', working_hour_to = p->>'working_to',
    line_items = items, total_hours = month_tot,
    status = case when p_submit then 'submitted' else 'draft' end, submitted_at = case when p_submit then now() else submitted_at end, updated_at = now()
  where id = s.id returning * into s;
  if p_submit then
    perform private.cms_log('claim.submitted', 'otcf', s.id::text, co, 'OTCF ' || s.serial_no || ' submitted in the CMS for ' || (w->>'name') || ' (' || to_char(month_tot, 'FM990.00') || ' h)',
      jsonb_build_object('behalf', w->'behalf', 'warnings', warns));
  end if;
  return jsonb_build_object('id', s.id, 'serial_no', s.serial_no, 'status', s.status, 'total_hours', s.total_hours, 'warnings', warns);
end $f$;
revoke all on function public.cms_otcf_save(uuid, jsonb, boolean) from public, anon;
grant execute on function public.cms_otcf_save(uuid, jsonb, boolean) to authenticated;

create or replace function public.cms_otcf_discard(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare s public.otcf_submissions;
begin
  select * into s from public.otcf_submissions where id = p_id and deleted_at is null for update;
  if s.id is null or s.submitted_by is distinct from auth.uid() then raise exception 'Claim not found.'; end if;
  if s.status <> 'draft' or s.submitted_at is not null then raise exception 'Only a draft that was never submitted can be discarded.'; end if;
  update public.otcf_submissions set deleted_at = now(), deleted_by_name = private.cms_user_name(auth.uid()), updated_at = now() where id = s.id;
end $f$;
revoke all on function public.cms_otcf_discard(uuid) from public, anon;
grant execute on function public.cms_otcf_discard(uuid) to authenticated;
