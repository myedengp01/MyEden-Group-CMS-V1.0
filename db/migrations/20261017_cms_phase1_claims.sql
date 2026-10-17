-- MyEden Group CMS V1.0 · Phase 1 (MEG-FORMS in the CMS) · v2026.10.17-17:50
-- Additive only. Reads the existing claim tables; actions go through the existing MEG-FORMS
-- functions (meg_forms_update_processing, meg_forms_set_payment_done_strict, meg_forms_add_processing_note),
-- so their own checks still apply. The CMS role is checked first and every action is written to the CMS audit log.
-- Staff keep submitting in the existing form apps. Approve / disapprove stays in the form apps for now,
-- because those apps also produce the signed PDF and send the notifications.

-- which CMS permission module covers which form
create or replace function private.cms_claim_module(p_form text)
returns text language sql immutable as $$
  select case lower(coalesce(p_form, '')) when 'otcf' then 'overtime' when 'tec-v2' then 'tec' else lower(coalesce(p_form, '')) end;
$$;

create or replace function private.cms_claim_table(p_form text)
returns text language sql immutable as $$
  select case lower(coalesce(p_form, '')) when 'scf' then 'scf_submissions' when 'otcf' then 'otcf_submissions'
    when 'mtcf' then 'mtcf_submissions' when 'tec' then 'tec_submissions' when 'tec-v2' then 'tec_v2_submissions'
    when 'prfaf' then 'prfaf_submissions' end;
$$;

create or replace function private.cms_norm_name(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(upper(btrim(coalesce(p, ''))), '\s+', ' ', 'g'), '');
$$;

-- the person in the Employee Master whose name matches the claimant (active staff first)
create or replace function private.cms_claim_person(p_name text)
returns table (id uuid, employee_id text)
language sql stable security definer set search_path = public, pg_temp as $$
  select em.id, em.employee_id::text from public.employee_master em
  where private.cms_norm_name(em.employee_name) = private.cms_norm_name(p_name)
  order by (em.employment_status = 'active') desc, em.start_date desc nulls last
  limit 1;
$$;

create or replace function private.cms_claim_row(p_form text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tbl text := private.cms_claim_table(p_form); j jsonb;
begin
  if v_tbl is null then raise exception 'Unknown form: %', p_form; end if;
  execute format('select to_jsonb(t) from public.%I t where t.id::text = $1', v_tbl) into j using p_id;
  return j;
end $$;

create or replace function private.cms_claim_link(p_form text, p_id text, p_status text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case when fr.url is null or fr.url = '' then null
    when lower(p_form) in ('tec', 'tec-v2', 'prfaf') then fr.url || case when position('?' in fr.url) > 0 then '&' else '?' end || 'review=' || p_id || '&dashboard_mode=admin&from=dashboard'
    when lower(p_form) in ('mtcf', 'otcf') and lower(p_status) = 'submitted' then fr.url || case when position('?' in fr.url) > 0 then '&' else '?' end || 'review=' || p_id || '&dashboard_mode=approval&from=dashboard'
    else fr.url || case when position('?' in fr.url) > 0 then '&' else '?' end || 'dashboard_claim=' || p_id || '&dashboard_mode=admin&from=dashboard' end
  from (select (select url from public.form_registry where form_code = lower(p_form) limit 1) url) fr;
$$;

-- every claim the signed-in user may see through their CMS roles (drafts and deleted claims left out)
create or replace function public.cms_claims(p_form text default null)
returns table (form_code text, form_name text, module text, id text, serial_no text, company_code text, claimant_name text,
               person_id uuid, employee_id text, workflow_status text, display_status text, stage text, payment_status text,
               amount numeric, amount_unit text, submitted_at timestamptz, approved_at timestamptz, approved_by_name text,
               event_at timestamptz, requires_approval boolean, supports_payment boolean, processing_eligible boolean,
               documents_checked boolean, supporting_docs_checked boolean, payment_process_checked boolean, fully_processed boolean,
               processed_by_name text, payment_done_at timestamptz, payment_done_by_name text, app_link text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  src record; j jsonb; v_ra boolean; v_sp boolean; fin record; proc record; per record;
  v_mod text; v_status text; v_company text; v_pay boolean; v_elig boolean; v_id text; v_claimant text;
begin
  if auth.uid() is null then raise exception 'Please sign in' using errcode = '42501'; end if;
  for src in select * from (values
      ('scf', 'scf_submissions', 'Staff Claim (SCF)', 'RM'),
      ('otcf', 'otcf_submissions', 'Overtime (OTCF)', 'hrs'),
      ('mtcf', 'mtcf_submissions', 'Mileage (MTCF)', 'RM'),
      ('tec', 'tec_submissions', 'Teacher Tuition (TEC V1)', 'RM'),
      ('tec-v2', 'tec_v2_submissions', 'Teacher Tuition (TEC)', 'RM'),
      ('prfaf', 'prfaf_submissions', 'Purchase & Funding (PRFAF)', 'RM')) s(code, tbl, label, unit)
  loop
    v_mod := private.cms_claim_module(src.code);
    if p_form is not null and lower(p_form) not in (src.code, v_mod) then continue; end if;
    if not public.cms_can(v_mod, 'V') or to_regclass('public.' || src.tbl) is null then continue; end if;
    select coalesce(c.requires_approval, true), coalesce(c.supports_payment, true) into v_ra, v_sp
      from (select 1) x left join public.meg_forms_workflow_config c on c.form_code = src.code;

    for j in execute format('select to_jsonb(t) from public.%I t', src.tbl) loop
      if nullif(j->>'deleted_at', '') is not null then continue; end if;
      v_status := lower(coalesce(j->>'status', ''));
      if v_status = 'draft' then continue; end if;
      v_company := private.cms_canon(nullif(j->>'company_code', ''));
      if v_company is not null and not public.cms_can(v_mod, 'V', v_company) then continue; end if;
      v_id := j->>'id';

      select f.payment_done, f.payment_done_at, f.payment_done_by_name into fin
        from public.meg_forms_finance_status f where f.form_code = src.code and f.submission_id = v_id;
      select p.documents_checked, p.supporting_docs_checked, p.payment_process_checked, p.fully_processed, p.processed_by_name into proc
        from public.meg_forms_processing p where p.form_code = src.code and p.submission_id = v_id;
      v_pay := coalesce(fin.payment_done, false) or lower(coalesce(j->>'payment_confirmed', 'false')) = 'true' or v_status in ('paid', 'disbursed', 'completed');
      v_elig := case when v_status = 'disapproved' then false
        when v_ra then v_status in ('approved', 'paid', 'disbursed', 'completed') or v_pay or (src.code in ('tec', 'tec-v2') and v_status = 'done')
        else v_status in ('submitted', 'approved', 'paid', 'disbursed', 'completed') or v_pay end;
      v_claimant := coalesce(nullif(j->>'claimed_by', ''), nullif(j->>'claimant_name', ''), nullif(j->>'emp_name', ''),
        nullif(j->>'teacher_name', ''), nullif(j->>'submitted_by_name', ''), 'Unknown claimant');
      select * into per from private.cms_claim_person(v_claimant);

      form_code := src.code; form_name := src.label; module := v_mod; id := v_id;
      serial_no := coalesce(j->>'serial_no', (select string_agg(distinct e->>'serial_no', ', ') from jsonb_array_elements(coalesce(j->'pages', '[]'::jsonb)) e), v_id);
      company_code := v_company; claimant_name := v_claimant; person_id := per.id; employee_id := per.employee_id;
      workflow_status := v_status;
      amount := case src.code
        when 'scf' then public.meg_forms_try_numeric(j->>'total')
        when 'otcf' then public.meg_forms_try_numeric(j->>'total_hours')
        when 'mtcf' then public.meg_forms_try_numeric(j->>'total_amount')
        when 'prfaf' then public.meg_forms_try_numeric(j->>'requested_amount')
        when 'tec' then (select coalesce(sum(public.meg_forms_try_numeric(e->>'netPay')), 0) from jsonb_array_elements(coalesce(j->'students', '[]'::jsonb)) e)
        when 'tec-v2' then (select coalesce(sum(public.meg_forms_try_numeric(e->>'subtotal')), 0) from jsonb_array_elements(coalesce(j->'pages', '[]'::jsonb)) e) end;
      amount_unit := src.unit;
      submitted_at := coalesce(public.meg_forms_try_timestamptz(j->>'submitted_at'), public.meg_forms_try_timestamptz(j->>'created_at'));
      approved_at := coalesce(public.meg_forms_try_timestamptz(j->>'approved_at'), public.meg_forms_try_timestamptz(j->>'done_at'));
      approved_by_name := coalesce(j->>'approved_by_name', j->>'done_by_name');
      event_at := coalesce(fin.payment_done_at, public.meg_forms_try_timestamptz(j->>'payment_confirmed_at'),
        public.meg_forms_try_timestamptz(j->>'disbursed_at'), public.meg_forms_try_timestamptz(j->>'disapproved_at'),
        approved_at, submitted_at);
      requires_approval := v_ra; supports_payment := v_sp; processing_eligible := v_elig;
      documents_checked := coalesce(proc.documents_checked, false);
      supporting_docs_checked := coalesce(proc.supporting_docs_checked, false);
      payment_process_checked := coalesce(proc.payment_process_checked, false);
      fully_processed := coalesce(proc.fully_processed, false);
      processed_by_name := proc.processed_by_name;
      payment_done_at := coalesce(fin.payment_done_at, public.meg_forms_try_timestamptz(j->>'payment_confirmed_at'), public.meg_forms_try_timestamptz(j->>'disbursed_at'));
      payment_done_by_name := coalesce(fin.payment_done_by_name, j->>'payment_confirmed_by_name', j->>'disbursed_by_name');
      payment_status := case when not v_sp then 'n/a' when v_pay then 'done' else 'pending' end;
      stage := case
        when v_status = 'disapproved' then 'disapproved'
        when v_pay then 'paid'
        when v_ra and v_status = 'submitted' then 'approval'
        when v_elig and not coalesce(proc.fully_processed, false) then 'processing'
        when v_elig and v_sp then 'payment'
        else 'closed' end;
      display_status := case stage when 'disapproved' then 'Disapproved' when 'paid' then 'Paid'
        when 'approval' then 'Waiting for approval' when 'processing' then 'Ready to process'
        when 'payment' then 'Waiting for payment' else initcap(replace(v_status, '_', ' ')) end;
      app_link := private.cms_claim_link(src.code, v_id, v_status);
      return next;
    end loop;
  end loop;
end $$;

-- one claim in full: the claim itself, processing, payment and notes (bank account masked unless the role may edit)
create or replace function public.cms_claim(p_form text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare j jsonb; v_mod text := private.cms_claim_module(p_form); v_company text; v_acc text; per record;
begin
  j := private.cms_claim_row(p_form, p_id);
  if j is null then raise exception 'Claim not found'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(v_mod, 'V', v_company);
  v_acc := regexp_replace(coalesce(j->>'bank_account_no', ''), '\s', '', 'g');
  j := j - 'approval_token' - 'bank_account_no';
  if v_acc <> '' then
    j := j || jsonb_build_object('bank_account_no', case when public.cms_can(v_mod, 'E', v_company) then v_acc else '••••' || right(v_acc, 4) end);
  end if;
  select * into per from private.cms_claim_person(coalesce(j->>'claimed_by', j->>'claimant_name', j->>'emp_name', j->>'teacher_name', j->>'submitted_by_name'));
  return jsonb_build_object(
    'form_code', lower(p_form), 'module', v_mod, 'company_code', v_company, 'claim', j,
    'processing', (select to_jsonb(p) - 'form_code' - 'submission_id' from public.meg_forms_processing p where p.form_code = lower(p_form) and p.submission_id = p_id),
    'finance', (select to_jsonb(f) - 'form_code' - 'submission_id' from public.meg_forms_finance_status f where f.form_code = lower(p_form) and f.submission_id = p_id),
    'notes', (select coalesce(jsonb_agg(jsonb_build_object('note', n.note, 'by', n.created_by_name, 'at', n.created_at) order by n.created_at), '[]'::jsonb)
              from public.meg_forms_processing_notes n where n.form_code = lower(p_form) and n.submission_id = p_id),
    'person', case when per.id is null then null else jsonb_build_object('id', per.id, 'employee_id', per.employee_id) end,
    'can_edit', public.cms_can(v_mod, 'E', v_company),
    'can_approve', public.cms_can(v_mod, 'A', v_company),
    'app_link', private.cms_claim_link(p_form, p_id, j->>'status'));
end $$;

-- Payroll / Account processing checklist (runs the existing MEG-FORMS step, then logs it)
create or replace function public.cms_claim_process(p_form text, p_id text, p_documents boolean, p_supporting boolean, p_payment_process boolean, p_fully boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare j jsonb := private.cms_claim_row(p_form, p_id); v_mod text := private.cms_claim_module(p_form); v_company text;
begin
  if j is null then raise exception 'Claim not found'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(v_mod, 'E', v_company);
  perform public.meg_forms_update_processing(lower(p_form), p_id, p_documents, p_supporting, p_payment_process, p_fully);
  perform private.cms_log('claim.process', lower(p_form), p_id, v_company,
    upper(p_form) || ' ' || coalesce(j->>'serial_no', p_id) || ': processing ' ||
    case when p_fully then 'completed' else coalesce(nullif(concat_ws(', ', case when p_documents then 'documents checked' end,
      case when p_supporting then 'supporting documents checked' end, case when p_payment_process then 'payment process checked' end), ''), 'checks cleared') end,
    jsonb_build_object('documents', p_documents, 'supporting', p_supporting, 'payment_process', p_payment_process, 'fully_processed', p_fully));
end $$;

-- Finance: mark paid / undo (existing strict step with its duplicate guard and the SCF 60-day undo rule)
create or replace function public.cms_claim_paid(p_form text, p_id text, p_done boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare j jsonb := private.cms_claim_row(p_form, p_id); v_mod text := private.cms_claim_module(p_form); v_company text;
begin
  if j is null then raise exception 'Claim not found'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(v_mod, 'E', v_company);
  perform public.meg_forms_set_payment_done_strict(lower(p_form), p_id, p_done);
  perform private.cms_log(case when p_done then 'claim.paid' else 'claim.unpaid' end, lower(p_form), p_id, v_company,
    upper(p_form) || ' ' || coalesce(j->>'serial_no', p_id) || ': ' || case when p_done then 'marked as paid' else 'payment undone' end, '{}'::jsonb);
end $$;

create or replace function public.cms_claim_note(p_form text, p_id text, p_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare j jsonb := private.cms_claim_row(p_form, p_id); v_mod text := private.cms_claim_module(p_form); v_company text;
begin
  if j is null then raise exception 'Claim not found'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Write a note first'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(v_mod, 'V', v_company);
  perform public.meg_forms_add_processing_note(lower(p_form), p_id, btrim(p_note));
  perform private.cms_log('claim.note', lower(p_form), p_id, v_company,
    upper(p_form) || ' ' || coalesce(j->>'serial_no', p_id) || ': note added', jsonb_build_object('note', left(btrim(p_note), 500)));
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where p.proname in ('cms_claim_module', 'cms_claim_table', 'cms_norm_name', 'cms_claim_person', 'cms_claim_row', 'cms_claim_link',
                               'cms_claims', 'cms_claim', 'cms_claim_process', 'cms_claim_paid', 'cms_claim_note')
             and n.nspname in ('public', 'private') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.nspname = 'public' then execute format('grant execute on function %s to authenticated', f.sig);
    else execute format('revoke all on function %s from authenticated', f.sig); end if;
  end loop;
end $$;

insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'Phase 1 claims functions installed (v2026.10.17-17:50)', '{}'::jsonb);

notify pgrst, 'reload schema';
