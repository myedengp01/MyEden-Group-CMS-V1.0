-- MyEden Group CMS V1.0 · Phase 1 · approve / disapprove / mark as done in the CMS · v2026.10.17-18:20
-- Writes exactly the fields the form apps write (MEG-OTCF, MEG-MTCF, MEG-TEC, MEG-TEC-V2).
-- Checks, in order: CMS role with Approve for the form and company; the claim is still waiting;
-- nobody decides their own claim; MEG-FORMS' own approval rules (the scoped-decision trigger on
-- OTCF / MTCF, approver or admin permission on TEC). Every decision goes in the CMS audit log.
-- PRFAF stays in its app because approving there also sets up the fund release.

create or replace function private.cms_approval_token()
returns text language sql volatile as $$
  select string_agg(substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + floor(random() * 36)::int, 1), '')
  from generate_series(1, 12);
$$;

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

create or replace function public.cms_claim_set_pdf(p_form text, p_id text, p_url text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_form text := lower(coalesce(p_form, '')); j jsonb; v_company text;
begin
  if v_form not in ('otcf', 'mtcf') then raise exception 'Only OTCF and MTCF keep a PDF link'; end if;
  if coalesce(p_url, '') !~ '^https://vzngfswtofegimfcoigx\.supabase\.co/storage/' then raise exception 'Not a CMS storage link'; end if;
  j := private.cms_claim_row(v_form, p_id);
  if j is null then raise exception 'Claim not found'; end if;
  v_company := private.cms_canon(nullif(j->>'company_code', ''));
  perform private.cms_require(private.cms_claim_module(v_form), 'A', v_company);
  if v_form = 'otcf' then update public.otcf_submissions set pdf_url = p_url where id::text = p_id;
  else update public.mtcf_submissions set pdf_url = p_url where id::text = p_id; end if;
  perform private.cms_log('claim.pdf', v_form, p_id, v_company, upper(v_form) || ' ' || coalesce(j->>'serial_no', p_id) || ': signed PDF saved', '{}'::jsonb);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where p.proname in ('cms_approval_token', 'cms_claim_decide', 'cms_claim_set_pdf') and n.nspname in ('public', 'private') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.nspname = 'public' then execute format('grant execute on function %s to authenticated', f.sig);
    else execute format('revoke all on function %s from authenticated', f.sig); end if;
  end loop;
end $$;

insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'Approve / disapprove / mark as done added (v2026.10.17-18:20)', '{}'::jsonb);

notify pgrst, 'reload schema';
