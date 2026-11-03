-- MyEden Group CMS V1.0 · v2026.11.03 · Bank and statutory numbers edited on the CMS profile (Pay tab)
-- HR edits bank, account no., EPF, SOCSO and income tax numbers on the profile instead of in MyPayroll V2.0.
-- Needs "People: edit" for the person's company, plus "See bank" for the bank fields and "See IC" for EPF / SOCSO / tax.
-- Each change is kept by the existing eppd_employee_private audit trigger, and in the CMS audit log with the numbers masked.
-- Additive only.

create or replace function public.cms_person_private_get(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; ee public.eppd_employees; pv public.eppd_employee_private; c_bank boolean; c_ic boolean;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'E', co);
  c_bank := public.cms_can('people.bank', 'V', co); c_ic := public.cms_can('people.ic', 'V', co);
  if not (c_bank or c_ic) then raise exception 'Editing bank or statutory numbers needs "See bank" or "See IC".'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is null then raise exception 'This person has no payroll record yet.'; end if;
  select * into pv from public.eppd_employee_private where employee_id = ee.id;
  return jsonb_build_object('can_bank', c_bank, 'can_ic', c_ic,
    'banks', (select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups where category = 'bank' and is_active),
    'bank_code', case when c_bank then pv.bank_code end, 'bank_account_no', case when c_bank then pv.bank_account_no end,
    'epf_no', case when c_ic then pv.epf_no end, 'socso_no', case when c_ic then pv.socso_no end, 'tax_no', case when c_ic then pv.tax_no end,
    'socso_from_nric', case when c_ic then nullif(regexp_replace(coalesce(pv.nric, ''), '\D', '', 'g'), '') end);
end $f$;
revoke all on function public.cms_person_private_get(uuid) from public, anon;
grant execute on function public.cms_person_private_get(uuid) to authenticated;

create or replace function public.cms_person_private_save(p_person uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; ee public.eppd_employees; pv public.eppd_employee_private; c_bank boolean; c_ic boolean;
  v_bank text; v_acc text; v_epf text; v_socso text; v_tax text; ch text[] := '{}';
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'E', co);
  c_bank := public.cms_can('people.bank', 'V', co); c_ic := public.cms_can('people.ic', 'V', co);
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  if ee.id is null then raise exception 'This person has no payroll record yet.'; end if;
  select * into pv from public.eppd_employee_private where employee_id = ee.id;
  v_bank := pv.bank_code; v_acc := pv.bank_account_no; v_epf := pv.epf_no; v_socso := pv.socso_no; v_tax := pv.tax_no;

  if p ? 'bank_code' or p ? 'bank_account_no' then
    if not c_bank then raise exception 'Changing bank details needs "See bank".'; end if;
    v_bank := nullif(btrim(coalesce(p->>'bank_code', '')), '');
    v_acc := nullif(regexp_replace(coalesce(p->>'bank_account_no', ''), '[\s-]', '', 'g'), '');
    if v_bank is not null and not exists (select 1 from public.eppd_lookups where category = 'bank' and code = v_bank) then raise exception 'Choose the bank from the list.'; end if;
    if v_acc is not null and v_acc !~ '^\d{5,20}$' then raise exception 'The account number should be digits only (5–20 digits).'; end if;
    if v_acc is not null and v_bank is null then raise exception 'Choose the bank for this account number.'; end if;
  end if;
  if p ? 'epf_no' or p ? 'socso_no' or p ? 'tax_no' then
    if not c_ic then raise exception 'Changing EPF, SOCSO or tax numbers needs "See IC".'; end if;
    v_epf := nullif(regexp_replace(coalesce(p->>'epf_no', ''), '\s', '', 'g'), '');
    v_socso := nullif(regexp_replace(coalesce(p->>'socso_no', ''), '[\s-]', '', 'g'), '');
    v_tax := nullif(upper(regexp_replace(coalesce(p->>'tax_no', ''), '\s', '', 'g')), '');
    if v_epf is not null and v_epf !~ '^\d{4,12}$' then raise exception 'The EPF number should be digits only.'; end if;
    if v_socso is not null and v_socso !~ '^[A-Z0-9]{6,15}$' then raise exception 'The SOCSO number should be letters and digits only (usually the IC number without dashes).'; end if;
    if v_tax is not null and v_tax !~ '^[A-Z]{0,3}\d{6,13}$' then raise exception 'The income tax number looks wrong (e.g. IG12345678090 or SG10234567080).'; end if;
  end if;

  if v_bank is distinct from pv.bank_code then ch := array_append(ch, 'bank'::text); end if;
  if v_acc is distinct from pv.bank_account_no then ch := array_append(ch, 'account no.'::text); end if;
  if v_epf is distinct from pv.epf_no then ch := array_append(ch, 'EPF no.'::text); end if;
  if v_socso is distinct from pv.socso_no then ch := array_append(ch, 'SOCSO no.'::text); end if;
  if v_tax is distinct from pv.tax_no then ch := array_append(ch, 'income tax no.'::text); end if;
  if cardinality(ch) = 0 then return jsonb_build_object('changed', '[]'::jsonb); end if;

  insert into public.eppd_employee_private (employee_id, bank_code, bank_account_no, epf_no, socso_no, tax_no)
  values (ee.id, v_bank, v_acc, v_epf, v_socso, v_tax)
  on conflict (employee_id) do update set bank_code = excluded.bank_code, bank_account_no = excluded.bank_account_no, epf_no = excluded.epf_no,
    socso_no = excluded.socso_no, tax_no = excluded.tax_no;
  perform private.cms_log('people.private_numbers', 'employee_master', em.id::text, co,
    em.employee_name || ': changed ' || array_to_string(ch, ', ') || ' (Pay tab)',
    jsonb_build_object('changed', to_jsonb(ch), 'account_last4', case when v_acc is not null then right(v_acc, 4) end));
  return jsonb_build_object('changed', to_jsonb(ch));
end $f$;
revoke all on function public.cms_person_private_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_person_private_save(uuid, jsonb) to authenticated;
