-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 F1 — new Staff Claims (SCF) made in the CMS (CLC 7 Nov 2026)
-- Staff with the "Claims" self-service part make SCF claims from My Claims: claimant and preparer from their login, their own company
-- (another company only with the new self-service part "Claims for other companies"), period, payment method, lines with receipts,
-- bank from their payroll record. Same scf_submissions table, serial format (CODE-YYYYMM-DLDLDL), receipt storage and revision process as
-- the SCF app, so the Action Center, payroll and the SCF app see these claims as they see SCF-app claims.
-- Receipts required on every line by default; an Admin can switch this off (Action Center › Claim settings).
-- Office users with SCF create permission (Admin, Super Admin, or as granted) may prepare a claim on someone's behalf.
-- Emails (scf-notify function): "claim received" to the claimant and "new SCF claim" to SCF processors on submit; "paid" to the claimant.
-- Additive: setting, functions, one more self-service part name.

insert into public.cms_settings (key, value) values ('scf_settings', '{"receipts_required": true}'::jsonb) on conflict (key) do nothing;

-- the new self-service part "claims_co" (claims for other companies)
do $m$ declare src text;
begin
  select pg_get_functiondef('public.cms_self_set(uuid[],text,boolean)'::regprocedure) into src;
  if position('claims_co' in src) = 0 then
    if position($o$'handbook','certs')$o$ in src) = 0 then raise exception 'cms_self_set has changed; part list not found'; end if;
    execute replace(src, $o$'handbook','certs')$o$, $n$'handbook','certs','claims_co')$n$);
  end if;
end $m$;

create or replace function private.cms_scf_code(p_co text) returns text language sql immutable as $$
  select case upper(coalesce(p_co, '')) when 'HD' then 'HDS' when 'HDS' then 'HDS' when 'ABP' then 'ABN' when 'ABN' then 'ABN' when 'MEH' then 'MEH' else 'MEG' end;
$$;

-- my linked person
create or replace function private.cms_me_person() returns uuid language sql stable security definer set search_path = public, pg_temp as $$
  select employee_master_id from public.cms_user_links where user_id = auth.uid() limit 1;
$$;
revoke all on function private.cms_me_person() from public, anon, authenticated;

-- who the claim is for, and whether the caller may make it: themselves with the Claims part, or on behalf with SCF create
create or replace function private.cms_scf_who(p_person uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me uuid := private.cms_me_person(); pid uuid := coalesce(p_person, me); em public.employee_master; behalf boolean;
begin
  if pid is null then raise exception 'Your login is not linked to a person record yet. Ask HR.'; end if;
  select * into em from public.employee_master where id = pid;
  if em.id is null then raise exception 'Person not found.'; end if;
  behalf := me is null or pid <> me;
  if behalf then
    if not public.cms_can('scf', 'C', private.cms_canon(em.company_code)) then raise exception 'You cannot make SCF claims for other people.'; end if;
  elsif not (private.cms_self_on(pid, 'claims') or public.cms_can('scf', 'C')) then
    raise exception 'Claims are not switched on for you. Ask HR.';
  end if;
  return jsonb_build_object('id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'behalf', behalf, 'any_company', behalf or private.cms_self_on(pid, 'claims_co') or public.cms_can('scf', 'C'),
    'preparer', coalesce((select employee_name from public.employee_master where id = me), private.cms_user_name(auth.uid())));
end $f$;
revoke all on function private.cms_scf_who(uuid) from public, anon, authenticated;

create or replace function public.cms_scf_context(p_person uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare w jsonb := private.cms_scf_who(p_person); bank record;
begin
  select coalesce(l.label, p.bank_code) bank_name, p.bank_account_no into bank
    from public.eppd_employees e join public.eppd_employee_private p on p.employee_id = e.id
    left join public.eppd_lookups l on l.category = 'bank' and l.code = p.bank_code
   where e.employee_master_id = (w->>'id')::uuid and nullif(btrim(p.bank_account_no), '') is not null
   order by e.id desc limit 1;
  return w || jsonb_build_object(
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'scf', private.cms_scf_code(c.code), 'name', c.name, 'short', c.short_name) order by c.sort_order)
                    from public.cms_companies c where c.is_active and ((w->>'any_company')::boolean or c.code = w->>'company')),
    'bank', case when bank.bank_account_no is null then null else jsonb_build_object('name', bank.bank_name,
              'masked', repeat('•', greatest(length(btrim(bank.bank_account_no)) - 4, 0)) || right(btrim(bank.bank_account_no), 4)) end,
    'suppliers', coalesce((select jsonb_agg(name order by lower(name)) from public.scf_suppliers), '[]'::jsonb),
    'settings', coalesce((select value from public.cms_settings where key = 'scf_settings'), '{}'::jsonb));
end $f$;
revoke all on function public.cms_scf_context(uuid) from public, anon;
grant execute on function public.cms_scf_context(uuid) to authenticated;

-- one of my SCF claims (made by me, or for me)
create or replace function public.cms_scf_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare s public.scf_submissions; me uuid := private.cms_me_person();
begin
  select * into s from public.scf_submissions where id = p_id and deleted_at is null;
  if s.id is null then raise exception 'Claim not found.'; end if;
  if s.submitted_by is distinct from auth.uid() and (me is null or (select id from private.cms_claim_person(s.claimed_by)) is distinct from me)
     and not public.cms_can('scf', 'V', private.cms_canon(s.company_code)) then raise exception 'Claim not found.'; end if;
  return to_jsonb(s) - 'approval_token' - 'bank_account_no'
    || jsonb_build_object('bank_masked', case when nullif(btrim(s.bank_account_no), '') is null then null
                            else repeat('•', greatest(length(btrim(s.bank_account_no)) - 4, 0)) || right(btrim(s.bank_account_no), 4) end,
       'editable', s.status = 'draft' and s.submitted_by = auth.uid(), 'mine', s.submitted_by = auth.uid(),
       'person_id', (select id from private.cms_claim_person(s.claimed_by)));
end $f$;
revoke all on function public.cms_scf_get(uuid) from public, anon;
grant execute on function public.cms_scf_get(uuid) to authenticated;

-- save a draft (p_submit false) or submit (true). p: person_id?, company (CMS code), period_from, period_to (month names), period_year,
-- payment_method (Cash | Online Transfer), rows [{date DD-MM-YYYY, supplier, item, amount, remarks, receipts [{path, isA4}]}]
create or replace function public.cms_scf_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare w jsonb; s public.scf_submissions; co text; v_code text; rows jsonb := '[]'::jsonb; r jsonb; tot numeric := 0; amt numeric; n int := 0;
  pm text := coalesce(nullif(p->>'payment_method', ''), 'Online Transfer'); months text[] := array['January','February','March','April','May','June','July','August','September','October','November','December'];
  b_name text; b_acct text; ser text; req boolean; i int; now_my timestamp := now() at time zone 'Asia/Kuala_Lumpur';
begin
  if p_id is not null then
    select * into s from public.scf_submissions where id = p_id and deleted_at is null for update;
    if s.id is null then raise exception 'Claim not found.'; end if;
    if s.submitted_by is distinct from auth.uid() then raise exception 'Only the person who made this claim can change it.'; end if;
    if s.status <> 'draft' then raise exception 'This claim has been submitted and can no longer be changed.'; end if;
    w := private.cms_scf_who(coalesce(nullif(p->>'person_id', '')::uuid, (select id from private.cms_claim_person(s.claimed_by))));
  else
    w := private.cms_scf_who(nullif(p->>'person_id', '')::uuid);
  end if;
  co := coalesce(private.cms_canon(nullif(p->>'company', '')), w->>'company');
  if co is distinct from w->>'company' and not (w->>'any_company')::boolean then raise exception 'You can only claim under your own company.'; end if;
  if not exists (select 1 from public.cms_companies where code = co and is_active) then raise exception 'Unknown company.'; end if;
  v_code := private.cms_scf_code(co);
  if pm not in ('Cash', 'Online Transfer') then raise exception 'Payment method must be Cash or Online Transfer.'; end if;
  if coalesce(p->>'period_from', '') <> '' and not (p->>'period_from' = any (months)) then raise exception 'Unknown month.'; end if;
  if coalesce(p->>'period_to', '') <> '' and not (p->>'period_to' = any (months)) then raise exception 'Unknown month.'; end if;
  if coalesce(p->>'period_year', '') <> '' and (p->>'period_year') !~ '^20[0-9]{2}$' then raise exception 'Year must be like 2026.'; end if;
  req := coalesce((select (value->>'receipts_required')::boolean from public.cms_settings where key = 'scf_settings'), true);
  for r in select x from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) x loop
    n := n + 1;
    if n > 60 then raise exception 'At most 60 lines in one claim.'; end if;
    amt := round(coalesce(public.meg_forms_try_numeric(r->>'amount'), 0), 2);
    if amt < 0 or amt > 100000 then raise exception 'Line %: amount is not valid.', n; end if;
    if coalesce(r->>'date', '') <> '' and (r->>'date') !~ '^[0-3][0-9]-[01][0-9]-20[0-9]{2}$' then raise exception 'Line %: date must be DD-MM-YYYY.', n; end if;
    if jsonb_typeof(coalesce(r->'receipts', '[]'::jsonb)) <> 'array' then raise exception 'Line %: receipts must be a list.', n; end if;
    if exists (select 1 from jsonb_array_elements(coalesce(r->'receipts', '[]'::jsonb)) x where coalesce(x->>'path', '') !~ ('^' || coalesce(p_id::text, '-') || '/')) then
      raise exception 'Line %: a receipt is not stored with this claim.', n; end if;
    rows := rows || jsonb_build_object('date', coalesce(r->>'date', ''), 'supplier', left(btrim(coalesce(r->>'supplier', '')), 120),
      'item', left(btrim(coalesce(r->>'item', '')), 120), 'amount', amt, 'remarks', left(btrim(coalesce(r->>'remarks', '')), 300),
      'receipts', coalesce(r->'receipts', '[]'::jsonb));
    tot := tot + amt;
  end loop;
  if pm = 'Online Transfer' then
    select coalesce(l.label, pp.bank_code), pp.bank_account_no into b_name, b_acct
      from public.eppd_employees e join public.eppd_employee_private pp on pp.employee_id = e.id
      left join public.eppd_lookups l on l.category = 'bank' and l.code = pp.bank_code
     where e.employee_master_id = (w->>'id')::uuid and nullif(btrim(pp.bank_account_no), '') is not null order by e.id desc limit 1;
  end if;
  if p_submit then
    if coalesce(p->>'period_from', '') = '' or coalesce(p->>'period_year', '') = '' then raise exception 'Choose the claim period.'; end if;
    if n = 0 then raise exception 'Add at least one line.'; end if;
    for i in 0 .. jsonb_array_length(rows) - 1 loop
      r := rows->i;
      if r->>'date' = '' or r->>'supplier' = '' or (r->>'amount')::numeric <= 0 then raise exception 'Line %: date, supplier and amount are needed.', i + 1; end if;
      if req and jsonb_array_length(r->'receipts') = 0 then raise exception 'Line %: attach the receipt.', i + 1; end if;
      if not req and jsonb_array_length(r->'receipts') = 0 and r->>'remarks' = '' then raise exception 'Line %: no receipt, so add a remark explaining why.', i + 1; end if;
    end loop;
    if pm = 'Online Transfer' and b_acct is null then raise exception 'No bank account on your payroll record. Choose Cash, or ask HR to add your bank details.'; end if;
  end if;
  if s.id is null then
    loop
      ser := v_code || '-' || to_char(now_my, 'YYYYMM') || '-' || (select string_agg(case when g % 2 = 1 then substr('0123456789', 1 + floor(random() * 10)::int, 1)
                                                                            else substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1) end, '' order by g) from generate_series(1, 6) g);
      exit when not exists (select 1 from public.scf_submissions where serial_no = ser);
    end loop;
    insert into public.scf_submissions (serial_no, company_code, status, submitted_by, claimed_by, prepared_by, claim_date, line_items, total, payment_method)
    values (ser, v_code, 'draft', auth.uid(), w->>'name', w->>'preparer', to_char(now_my, 'DD/MM/YYYY HH24:MI'), '[]'::jsonb, 0, pm)
    returning * into s;
    if jsonb_array_length(rows) > 0 and exists (select 1 from jsonb_array_elements(rows) x, jsonb_array_elements(x->'receipts') y) then
      raise exception 'Save the claim before attaching receipts.'; end if;
  end if;
  update public.scf_submissions set
    company_code = v_code,
    serial_no = case when s.submitted_at is null and coalesce(s.revision_count, 0) = 0 then v_code || substr(s.serial_no, position('-' in s.serial_no)) else s.serial_no end,
    period_from = nullif(p->>'period_from', ''), period_to = coalesce(nullif(p->>'period_to', ''), nullif(p->>'period_from', '')), period_year = nullif(p->>'period_year', ''),
    payment_method = pm, claimed_by = w->>'name', prepared_by = w->>'preparer', claim_date = to_char(now_my, 'DD/MM/YYYY HH24:MI'),
    bank_name = case when pm = 'Online Transfer' then b_name end, bank_account_no = case when pm = 'Online Transfer' then b_acct end,
    line_items = rows, total = tot,
    status = case when p_submit then 'submitted' else 'draft' end,
    submitted_at = case when p_submit then now() else submitted_at end, updated_at = now()
  where id = s.id
  returning * into s;
  if p_submit then
    insert into public.scf_suppliers (name, created_by)
    select distinct x->>'supplier', auth.uid() from jsonb_array_elements(rows) x
     where x->>'supplier' <> '' and not exists (select 1 from public.scf_suppliers su where lower(su.name) = lower(x->>'supplier'));
    perform private.cms_log('claim.submitted', 'scf', s.id::text, co, 'SCF ' || s.serial_no || ' submitted in the CMS for ' || (w->>'name') || ' (RM ' || to_char(tot, 'FM999,990.00') || ')',
      jsonb_build_object('behalf', w->'behalf', 'lines', n));
  end if;
  return jsonb_build_object('id', s.id, 'serial_no', s.serial_no, 'status', s.status, 'total', s.total);
end $f$;
revoke all on function public.cms_scf_save(uuid, jsonb, boolean) from public, anon;
grant execute on function public.cms_scf_save(uuid, jsonb, boolean) to authenticated;

-- discard my draft (kept, marked deleted, like the forms' admin delete)
create or replace function public.cms_scf_discard(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare s public.scf_submissions;
begin
  select * into s from public.scf_submissions where id = p_id and deleted_at is null for update;
  if s.id is null or s.submitted_by is distinct from auth.uid() then raise exception 'Claim not found.'; end if;
  if s.status <> 'draft' or s.submitted_at is not null then raise exception 'Only a draft that was never submitted can be discarded.'; end if;
  update public.scf_submissions set deleted_at = now(), deleted_by_name = private.cms_user_name(auth.uid()), updated_at = now() where id = s.id;
end $f$;
revoke all on function public.cms_scf_discard(uuid) from public, anon;
grant execute on function public.cms_scf_discard(uuid) to authenticated;

create or replace function public.cms_scf_settings_set(p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not (public.cms_is_super_admin() or public.cms_can('admin.roles', 'E')) then raise exception 'Only an Admin can change claim settings.'; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by)
  values ('scf_settings', jsonb_build_object('receipts_required', coalesce((p->>'receipts_required')::boolean, true)), now(), auth.uid())
  on conflict (key) do update set value = public.cms_settings.value || excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('settings.scf', 'cms_settings', 'scf_settings', null, 'SCF settings changed', p);
end $f$;
revoke all on function public.cms_scf_settings_set(jsonb) from public, anon;
grant execute on function public.cms_scf_settings_set(jsonb) to authenticated;

-- for the scf-notify function (service role only): who to email about a claim
create or replace function public.cms_scf_notify_info(p_id uuid)
returns jsonb language sql stable security definer set search_path = public, auth, pg_temp as $$
  select jsonb_build_object('serial_no', s.serial_no, 'status', s.status, 'claimed_by', s.claimed_by, 'total', s.total, 'company_code', s.company_code,
    'period', concat_ws(' ', s.period_from, case when s.period_to is distinct from s.period_from then '– ' || s.period_to end, s.period_year),
    'paid', coalesce(s.payment_confirmed, false) or exists (select 1 from public.meg_forms_finance_status f where f.form_code = 'scf' and f.submission_id = s.id::text and f.payment_done),
    'claimant_email', coalesce((select u.email from public.cms_user_links l join auth.users u on u.id = l.user_id
                                 where l.employee_master_id = (select id from private.cms_claim_person(s.claimed_by)) limit 1),
                               (select nullif(btrim(email), '') from public.employee_master where id = (select id from private.cms_claim_person(s.claimed_by))),
                               (select email from auth.users where id = s.submitted_by)),
    'processors', coalesce((select jsonb_agg(distinct u.email) from public.form_permissions fp join auth.users u on u.id = fp.user_id
                             where lower(fp.form_code) = 'scf' and (coalesce(fp.can_finance, false) or coalesce(fp.can_mark_paid, false) or coalesce(fp.is_admin, false))), '[]'::jsonb))
  from public.scf_submissions s where s.id = p_id and s.deleted_at is null;
$$;
revoke all on function public.cms_scf_notify_info(uuid) from public, anon, authenticated;
grant execute on function public.cms_scf_notify_info(uuid) to service_role;
