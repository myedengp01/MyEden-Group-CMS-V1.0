-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 F1 — new Mileage claims (MTCF) made in the CMS (CLC 7 Nov 2026)
-- Staff with the "Claims" part make MTCF claims from My Claims: claimant from the login, own company (others with "Claims: other companies"),
-- trips (date, purpose, from, to, km, remarks, optional journey photos). The rate per km comes from the company's MTCF rate (mtcf_rates, set in
-- the MTCF app); the server works out total km and amount, and the claim period from the first and last trip. Same mtcf_submissions table,
-- serial format (<CODE>-MTCF-YYYYMM-XXXX), photo storage (mtcf-receipts/<claim>/<trip>/...) and approval (Action Center or the MTCF app, approval
-- scope by company). On behalf: office users with Mileage create. MTCF has no "deleted" column, so CMS drafts are kept (not discarded).
-- Additive: functions only.

create or replace function public.cms_mtcf_context(p_person uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare w jsonb := private.cms_claim_who(p_person, 'mtcf');
begin
  return w || jsonb_build_object(
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'mtcf', private.cms_scf_code(c.code), 'name', c.name,
                     'rate', (select r.rate_rm_per_km from public.mtcf_rates r where r.company_code = private.cms_scf_code(c.code))) order by c.sort_order)
                    from public.cms_companies c where c.is_active and ((w->>'any_company')::boolean or c.code = w->>'company')),
    'places', coalesce((select jsonb_agg(distinct x) from (select t->>'start_location' x from public.mtcf_submissions s, jsonb_array_elements(coalesce(s.trips, '[]'::jsonb)) t where s.submitted_by = auth.uid()
                        union select t->>'end_location' from public.mtcf_submissions s, jsonb_array_elements(coalesce(s.trips, '[]'::jsonb)) t where s.submitted_by = auth.uid()) z where coalesce(btrim(x), '') <> ''), '[]'::jsonb));
end $f$;
revoke all on function public.cms_mtcf_context(uuid) from public, anon;
grant execute on function public.cms_mtcf_context(uuid) to authenticated;

create or replace function public.cms_mtcf_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare s public.mtcf_submissions; me uuid := private.cms_me_person();
begin
  select * into s from public.mtcf_submissions where id = p_id;
  if s.id is null then raise exception 'Claim not found.'; end if;
  if s.submitted_by is distinct from auth.uid() and (me is null or (select id from private.cms_claim_person(s.claimant_name)) is distinct from me)
     and not public.cms_can('mtcf', 'V', private.cms_canon(s.company_code)) then raise exception 'Claim not found.'; end if;
  return to_jsonb(s) - 'approval_token'
    || jsonb_build_object('editable', s.status = 'draft' and s.submitted_by = auth.uid(), 'mine', s.submitted_by = auth.uid(),
       'person', (select id from private.cms_claim_person(s.claimant_name)));
end $f$;
revoke all on function public.cms_mtcf_get(uuid) from public, anon;
grant execute on function public.cms_mtcf_get(uuid) to authenticated;

-- p: person_id?, company, trips [{date YYYY-MM-DD, purpose, start_location, end_location, distance_km, remarks, receipts [{path}]}]
create or replace function public.cms_mtcf_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare w jsonb; s public.mtcf_submissions; co text; v_code text; rate numeric; t jsonb; v_trips jsonb := '[]'::jsonb; km numeric := 0; dk numeric; n int := 0;
  d date; d0 date; d1 date; now_my timestamp := now() at time zone 'Asia/Kuala_Lumpur'; ser text; i int;
begin
  if p_id is not null then
    select * into s from public.mtcf_submissions where id = p_id for update;
    if s.id is null then raise exception 'Claim not found.'; end if;
    if s.submitted_by is distinct from auth.uid() then raise exception 'Only the person who made this claim can change it.'; end if;
    if s.status <> 'draft' then raise exception 'This claim has been submitted and can no longer be changed.'; end if;
    w := private.cms_claim_who(coalesce(nullif(p->>'person_id', '')::uuid, (select id from private.cms_claim_person(s.claimant_name))), 'mtcf');
  else
    w := private.cms_claim_who(nullif(p->>'person_id', '')::uuid, 'mtcf');
  end if;
  co := coalesce(private.cms_canon(nullif(p->>'company', '')), w->>'company');
  if co is distinct from w->>'company' and not (w->>'any_company')::boolean then raise exception 'You can only claim under your own company.'; end if;
  if not exists (select 1 from public.cms_companies c where c.code = co and c.is_active) then raise exception 'Unknown company.'; end if;
  v_code := private.cms_scf_code(co);
  select r.rate_rm_per_km into rate from public.mtcf_rates r where r.company_code = v_code;
  if rate is null then raise exception 'No mileage rate is set for this company yet. Ask HR.'; end if;
  for t in select x from jsonb_array_elements(coalesce(p->'trips', '[]'::jsonb)) x loop
    n := n + 1;
    if n > 100 then raise exception 'At most 100 trips in one claim.'; end if;
    d := case when coalesce(t->>'date', '') ~ '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$' then (t->>'date')::date end;
    if coalesce(t->>'date', '') <> '' and d is null then raise exception 'Trip %: date is not valid.', n; end if;
    if d > now_my::date then raise exception 'Trip %: the date is in the future.', n; end if;
    dk := round(coalesce(public.meg_forms_try_numeric(t->>'distance_km'), 0), 2);
    if dk < 0 or dk > 2000 then raise exception 'Trip %: distance is not valid.', n; end if;
    if exists (select 1 from jsonb_array_elements(coalesce(t->'receipts', '[]'::jsonb)) x where coalesce(x->>'path', '') !~ ('^' || coalesce(p_id::text, '-') || '/')) then
      raise exception 'Trip %: a photo is not stored with this claim.', n; end if;
    v_trips := v_trips || jsonb_build_object('date', coalesce(t->>'date', ''), 'purpose', left(btrim(coalesce(t->>'purpose', '')), 200),
      'start_location', left(btrim(coalesce(t->>'start_location', '')), 120), 'end_location', left(btrim(coalesce(t->>'end_location', '')), 120),
      'distance_km', dk, 'remarks', left(btrim(coalesce(t->>'remarks', '')), 200), 'receipts', coalesce(t->'receipts', '[]'::jsonb));
    km := km + dk;
    if d is not null then d0 := least(coalesce(d0, d), d); d1 := greatest(coalesce(d1, d), d); end if;
  end loop;
  if p_submit then
    if n = 0 then raise exception 'Add at least one trip.'; end if;
    for i in 0 .. jsonb_array_length(v_trips) - 1 loop
      t := v_trips->i;
      if t->>'date' = '' or t->>'purpose' = '' or t->>'start_location' = '' or t->>'end_location' = '' or (t->>'distance_km')::numeric <= 0 then
        raise exception 'Trip %: date, purpose, from, to and distance are needed.', i + 1; end if;
    end loop;
  end if;
  if s.id is null then
    loop
      ser := v_code || '-MTCF-' || to_char(now_my, 'YYYYMM') || '-' || (select string_agg(c, '' order by random()) from unnest(array[
               substr('0123456789', 1 + floor(random() * 10)::int, 1), substr('0123456789', 1 + floor(random() * 10)::int, 1),
               substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1), substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1)]) c);
      exit when not exists (select 1 from public.mtcf_submissions where serial_no = ser);
    end loop;
    insert into public.mtcf_submissions (serial_no, company_code, claimant_name, status, submitted_by, trips, rate_rm_per_km, total_mileage_km, total_amount, year)
    values (ser, v_code, w->>'name', 'draft', auth.uid(), '[]'::jsonb, rate, 0, 0, extract(year from now_my)::int) returning * into s;
  end if;
  update public.mtcf_submissions set
    company_code = v_code,
    serial_no = case when s.status = 'draft' then v_code || substr(s.serial_no, position('-MTCF-' in s.serial_no)) else s.serial_no end,
    claimant_name = w->>'name', year = extract(year from coalesce(d0, now_my::date))::int, start_date = d0, end_date = d1, date_of_claim = now_my::date,
    trips = v_trips, rate_rm_per_km = rate, total_mileage_km = km, total_amount = round(km * rate, 2),
    status = case when p_submit then 'submitted' else 'draft' end
  where id = s.id returning * into s;
  if p_submit then
    perform private.cms_log('claim.submitted', 'mtcf', s.id::text, co, 'MTCF ' || s.serial_no || ' submitted in the CMS for ' || (w->>'name') || ' (' || to_char(km, 'FM99990.00') || ' km, RM ' || to_char(s.total_amount, 'FM999,990.00') || ')',
      jsonb_build_object('behalf', w->'behalf', 'trips', n));
  end if;
  return jsonb_build_object('id', s.id, 'serial_no', s.serial_no, 'status', s.status, 'total_km', s.total_mileage_km, 'total_amount', s.total_amount, 'rate', rate);
end $f$;
revoke all on function public.cms_mtcf_save(uuid, jsonb, boolean) from public, anon;
grant execute on function public.cms_mtcf_save(uuid, jsonb, boolean) to authenticated;
