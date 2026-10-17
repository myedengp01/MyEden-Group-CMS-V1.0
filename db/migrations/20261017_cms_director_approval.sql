-- MyEden Group CMS V1.0 · v2026.10.17-19:00 · CEO / Director approves claims of Super Admins, Admins and Directors
-- Rule (CMS only; the form apps are unchanged): a claim submitted by someone holding an active Super Admin, Admin or
-- CEO / Director role in the CMS can only be approved or disapproved in the CMS by a CEO / Director, never their own.
-- Applied in five parts (cms_director_role / _claim_flags(+fix) / _claim_detail / _decide / _grant, 20261017_1900).

-- part 1: role and helpers
insert into public.cms_roles (code, name, description, rank, phase) values
  ('director', 'CEO / Director', 'Sees everything. Approves and disapproves claims for all companies, including claims by Super Admins and Admins. Does not manage roles or export.', 95, 1)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions)
select 'director', m.code, case when m.code in ('approvals', 'overtime', 'mtcf', 'scf', 'tec', 'prfaf', 'leave') then 'VA' else 'V' end
from public.cms_modules m where m.code not in ('admin.export', 'admin.roles', 'admin.companies')
on conflict (role_code, module_code) do nothing;

create or replace function private.cms_is_director(p_uid uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_uid is not null and exists (select 1 from public.cms_user_roles where user_id = p_uid and role_code = 'director' and is_active);
$$;

create or replace function private.cms_needs_director(p_submitted_by text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(p_submitted_by, '') <> '' and exists (select 1 from public.cms_user_roles
    where user_id::text = p_submitted_by and is_active and role_code in ('super_admin', 'admin', 'director'));
$$;
revoke all on function private.cms_is_director(uuid) from public, anon, authenticated;
revoke all on function private.cms_needs_director(text) from public, anon, authenticated;

-- part 2: for claims still waiting, whether each is the viewer's own and whether it needs a CEO / Director
create or replace function public.cms_claim_flags()
returns table (form_code text, id text, is_mine boolean, needs_director boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare src record; j jsonb; v_mod text; v_company text;
begin
  if auth.uid() is null then raise exception 'Please sign in' using errcode = '42501'; end if;
  for src in select * from (values ('otcf', 'otcf_submissions'), ('mtcf', 'mtcf_submissions'), ('tec', 'tec_submissions'),
      ('tec-v2', 'tec_v2_submissions'), ('scf', 'scf_submissions'), ('prfaf', 'prfaf_submissions')) s(code, tbl)
  loop
    v_mod := private.cms_claim_module(src.code);
    if not public.cms_can(v_mod, 'V') or to_regclass('public.' || src.tbl) is null then continue; end if;
    for j in execute format('select to_jsonb(t) from public.%I t where lower(coalesce(t.status, '''')) = ''submitted''', src.tbl) loop
      if nullif(j->>'deleted_at', '') is not null then continue; end if;
      v_company := private.cms_canon(nullif(j->>'company_code', ''));
      if v_company is not null and not public.cms_can(v_mod, 'V', v_company) then continue; end if;
      form_code := src.code; id := j->>'id';
      is_mine := (j->>'submitted_by') = auth.uid()::text;
      needs_director := private.cms_needs_director(j->>'submitted_by');
      return next;
    end loop;
  end loop;
end $$;
revoke all on function public.cms_claim_flags() from public, anon;
grant execute on function public.cms_claim_flags() to authenticated;

-- part 3: one claim in full says the same, and whether the viewer is a Director
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
    'is_mine', (j->>'submitted_by') = auth.uid()::text,
    'needs_director', private.cms_needs_director(j->>'submitted_by'),
    'is_director', private.cms_is_director(auth.uid()),
    'app_link', private.cms_claim_link(p_form, p_id, j->>'status'));
end $$;

-- part 4: the rule, checked when deciding
create or replace function public.cms_claim_decide(p_form text, p_id text, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_form text := lower(coalesce(p_form, ''));
  v_dec text := lower(coalesce(p_decision, ''));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_mod text := private.cms_claim_module(p_form);
  j jsonb; v_company text; v_name text; v_token text; v_now timestamptz := now(); r jsonb;
begin
  if v_form not in ('otcf', 'mtcf', 'tec', 'tec-v2') then
    raise exception 'Approve % claims in its own app for now', upper(v_form);
  end if;
  if v_form in ('otcf', 'mtcf') and v_dec not in ('approve', 'disapprove') then raise exception 'Choose approve or disapprove'; end if;
  if v_form in ('tec', 'tec-v2') and v_dec <> 'done' then raise exception 'Teacher tuition claims are marked as done'; end if;
  if v_dec = 'disapprove' and v_reason is null then raise exception 'Give a reason for disapproving'; end if;

  j := private.cms_claim_row(v_form, p_id);
  if j is null then raise exception 'Claim not found'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(v_mod, 'A', v_company);
  if lower(coalesce(j->>'status', '')) <> 'submitted' then
    raise exception 'This claim is no longer waiting (it is %)', coalesce(j->>'status', 'unknown');
  end if;
  if (j->>'submitted_by') = auth.uid()::text then
    raise exception 'You cannot decide your own claim';
  end if;
  if private.cms_needs_director(j->>'submitted_by') and not private.cms_is_director(auth.uid()) then
    raise exception 'This claim was submitted by a Super Admin or Admin, so it must be decided by the CEO / a Director' using errcode = '42501';
  end if;
  if v_form in ('tec', 'tec-v2') and not (public.is_form_approver(v_form) or public.is_form_admin(v_form)) then
    raise exception 'Your MEG-FORMS account is not an approver for %', upper(v_form) using errcode = '42501';
  end if;

  select coalesce(nullif(p.full_name, ''), u.email) into v_name
  from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();

  if v_form = 'otcf' then
    if v_dec = 'approve' then
      v_token := private.cms_approval_token();
      update public.otcf_submissions set status = 'approved', approval_token = v_token, approved_by = auth.uid(),
        approved_by_name = v_name, approved_at = v_now where id::text = p_id returning to_jsonb(otcf_submissions.*) into r;
    else
      update public.otcf_submissions set status = 'disapproved', disapproved_by = auth.uid(), disapproved_by_name = v_name,
        disapproved_at = v_now, disapproval_reason = v_reason where id::text = p_id returning to_jsonb(otcf_submissions.*) into r;
    end if;
  elsif v_form = 'mtcf' then
    if v_dec = 'approve' then
      v_token := private.cms_approval_token();
      update public.mtcf_submissions set status = 'approved', approval_token = v_token, approved_by = auth.uid(),
        approved_by_name = v_name, approved_at = v_now where id::text = p_id returning to_jsonb(mtcf_submissions.*) into r;
    else
      update public.mtcf_submissions set status = 'disapproved', disapproval_reason = v_reason, approved_by = auth.uid(),
        approved_by_name = v_name, approved_at = v_now, disapproved_by = auth.uid(), disapproved_by_name = v_name,
        disapproved_at = v_now where id::text = p_id returning to_jsonb(mtcf_submissions.*) into r;
    end if;
  elsif v_form = 'tec' then
    update public.tec_submissions set status = 'done', done_by = auth.uid(), done_by_name = v_name, done_at = v_now
      where id::text = p_id returning to_jsonb(tec_submissions.*) into r;
  else
    update public.tec_v2_submissions set status = 'done', done_by = auth.uid(), done_by_name = v_name, done_at = v_now
      where id::text = p_id returning to_jsonb(tec_v2_submissions.*) into r;
  end if;

  perform private.cms_log('claim.' || v_dec, v_form, p_id, v_company,
    upper(v_form) || ' ' || coalesce(j->>'serial_no', p_id) || ': ' ||
      case v_dec when 'approve' then 'approved' when 'disapprove' then 'disapproved' else 'marked as done' end,
    jsonb_build_object('reason', v_reason));
  return r;
end $$;

-- part 5: the two CEO / Director logins, as asked (all companies)
insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_at)
select u.id, 'director', null, true, 'CEO / Director, set at release v2026.10.17-19:00', now()
from auth.users u where lower(u.email) in ('irenetms2013@gmail.com', 'trade12win@gmail.com')
on conflict (user_id, role_code) do update set is_active = true, companies = null, revoked_at = null, revoked_by = null;

insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'CEO / Director role added; claims by Super Admins, Admins and Directors now need a Director (v2026.10.17-19:00)',
        '{"role":"director","granted":["irenetms2013@gmail.com","trade12win@gmail.com"]}');
notify pgrst, 'reload schema';
