-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 Action Center (CLC 7 Nov 2026)
-- "Approvals & Workflows" becomes the Action Center: every claim to approve, process or pay, plus the settings the MEG-FORMS portal kept.
-- 1. cms_claim_delete: Super Admin deletes a claim with a reason. Same rules as the portal's Admin delete (paid, completed, disbursed
--    or ledger-linked claims cannot be deleted) and the same soft delete; logged in the CMS activity log.
-- 2. Claimant history months (how far back staff see their own claims in the forms): read / set from the CMS.
-- 3. Claim permissions: the portal's form_permissions table (who submits, approves, processes, pays, views each form),
--    read and edited from Admin › Users, roles & access › Claim permissions. Same table, so the form apps follow it at once.
-- Additive: new functions only; the delete reuses the portal's own checks and soft delete.

-- 1 · delete with a reason (Super Admin) --------------------------------------------------------------------------------------
do $m$
declare src text;
  hdr_old text := 'public.meg_forms_admin_delete_claim(p_form_code text, p_submission_id text, p_reason text)';
  chk_old text := $o$not exists(select 1 from public.form_permissions fp where fp.user_id=auth.uid() and lower(fp.form_code)=v_form and fp.is_admin is true)$o$;
begin
  select pg_get_functiondef('public.meg_forms_admin_delete_claim(text,text,text)'::regprocedure) into src;
  if position(hdr_old in src) = 0 or position(chk_old in src) = 0 then raise exception 'meg_forms_admin_delete_claim has changed; not copied'; end if;
  src := replace(src, hdr_old, 'private.cms_claim_delete_impl(p_form_code text, p_submission_id text, p_reason text)');
  src := replace(src, chk_old, 'not public.cms_is_super_admin()');
  src := replace(src, 'Form Admin authority required', 'Only a Super Admin can delete claims');
  execute src;
end $m$;
revoke all on function private.cms_claim_delete_impl(text, text, text) from public, anon, authenticated;

create or replace function public.cms_claim_delete(p_form text, p_id text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare j jsonb := private.cms_claim_row(p_form, p_id); r jsonb;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can delete claims.'; end if;
  if j is null then raise exception 'Claim not found'; end if;
  r := private.cms_claim_delete_impl(lower(p_form), p_id, btrim(coalesce(p_reason, '')));
  if coalesce((r->>'deleted')::boolean, true) then
    perform private.cms_log('claim.deleted', lower(p_form), p_id, private.cms_canon(nullif(j->>'company_code', '')),
      upper(p_form) || ' ' || coalesce(j->>'serial_no', p_id) || ' deleted: ' || btrim(p_reason), jsonb_build_object('reason', btrim(p_reason)));
  end if;
  return r;
end $f$;
revoke all on function public.cms_claim_delete(text, text, text) from public, anon;
grant execute on function public.cms_claim_delete(text, text, text) to authenticated;

-- 2 · claimant history months ------------------------------------------------------------------------------------------------
create or replace function public.cms_claim_settings()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('history_months', (select claimant_history_months from public.meg_forms_settings where singleton limit 1),
    'can_edit', public.cms_is_super_admin() or public.cms_can('admin.roles', 'E'))
  where public.cms_can('approvals', 'V');
$$;
revoke all on function public.cms_claim_settings() from public, anon;
grant execute on function public.cms_claim_settings() to authenticated;

create or replace function public.cms_claim_history_months_set(p_months int)
returns int language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not (public.cms_is_super_admin() or public.cms_can('admin.roles', 'E')) then raise exception 'You do not have access to this.'; end if;
  if p_months not in (1, 2, 3, 6, 12) then raise exception 'Choose 1, 2, 3, 6 or 12 months.'; end if;
  update public.meg_forms_settings set claimant_history_months = p_months, updated_at = now(), updated_by = auth.uid() where singleton;
  perform private.cms_log('forms.history_months', 'meg_forms_settings', 'singleton', null, 'Claimant history set to ' || p_months || ' months', '{}'::jsonb);
  return p_months;
end $f$;
revoke all on function public.cms_claim_history_months_set(int) from public, anon;
grant execute on function public.cms_claim_history_months_set(int) to authenticated;

-- 3 · claim permissions (form_permissions) -----------------------------------------------------------------------------------
create or replace function public.cms_form_permissions()
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $f$
begin
  if not (public.cms_is_super_admin() or public.cms_can('admin.roles', 'V')) then raise exception 'You do not have access to this.'; end if;
  return jsonb_build_object(
    'forms', (select jsonb_agg(f order by o) from (values ('scf', 1), ('otcf', 2), ('mtcf', 3), ('tec-v2', 4), ('tec', 5), ('prfaf', 6), ('prfaf_v2', 7)) v(f, o)),
    'can_edit', public.cms_is_super_admin() or public.cms_can('admin.roles', 'E'),
    'users', coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'name', coalesce(nullif(pr.full_name, ''), em.employee_name, u.email),
        'person', em.employee_name, 'employee_id', em.employee_id,
        'perms', coalesce((select jsonb_object_agg(lower(fp.form_code), jsonb_build_object('submit', coalesce(fp.can_submit, false), 'approve', coalesce(fp.can_approve, false),
            'scope', fp.approval_scope, 'admin', coalesce(fp.is_admin, false), 'view', coalesce(fp.can_view, false), 'finance', coalesce(fp.can_finance, false),
            'paid', coalesce(fp.can_mark_paid, false), 'ledger', coalesce(fp.can_manage_ledger, false), 'summary', coalesce(fp.can_view_summary, false)))
          from public.form_permissions fp where fp.user_id = u.id and fp.form_code !~ '[<>]'), '{}'::jsonb))
        order by coalesce(nullif(pr.full_name, ''), em.employee_name, u.email))
      from auth.users u left join public.profiles pr on pr.id = u.id
      left join public.cms_user_links ul on ul.user_id = u.id left join public.employee_master em on em.id = ul.employee_master_id
      where u.deleted_at is null), '[]'::jsonb));
end $f$;
revoke all on function public.cms_form_permissions() from public, anon;
grant execute on function public.cms_form_permissions() to authenticated;

-- p_perms: any of submit, approve, scope (null / myeden / hds / abn), admin, view, finance, paid, ledger, summary
create or replace function public.cms_form_permission_set(p_user uuid, p_form text, p_perms jsonb)
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $f$
declare f text := lower(btrim(coalesce(p_form, ''))); sc text := nullif(lower(btrim(coalesce(p_perms->>'scope', ''))), '');
  b jsonb := coalesce(p_perms, '{}'::jsonb);
begin
  if not (public.cms_is_super_admin() or public.cms_can('admin.roles', 'E')) then raise exception 'You do not have access to this.'; end if;
  if f not in ('scf', 'otcf', 'mtcf', 'tec', 'tec-v2', 'prfaf', 'prfaf_v2') then raise exception 'Unknown form %', p_form; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Login not found.'; end if;
  if b ? 'scope' and sc is not null and sc not in ('myeden', 'hds', 'abn') then raise exception 'Approval scope must be all, myeden, hds or abn.'; end if;
  if (b ? 'admin') and not public.cms_is_super_admin() then raise exception 'Only a Super Admin can give Form Admin.'; end if;
  insert into public.form_permissions (user_id, form_code) values (p_user, f) on conflict (user_id, form_code) do nothing;
  update public.form_permissions set
    can_submit = case when b ? 'submit' then (b->>'submit')::boolean else can_submit end,
    can_approve = case when b ? 'approve' then (b->>'approve')::boolean else can_approve end,
    approval_scope = case when b ? 'scope' then sc else approval_scope end,
    is_admin = case when b ? 'admin' then (b->>'admin')::boolean else is_admin end,
    can_view = case when b ? 'view' then (b->>'view')::boolean else can_view end,
    can_finance = case when b ? 'finance' then (b->>'finance')::boolean else can_finance end,
    can_mark_paid = case when b ? 'paid' then (b->>'paid')::boolean else can_mark_paid end,
    can_manage_ledger = case when b ? 'ledger' then (b->>'ledger')::boolean else can_manage_ledger end,
    can_view_summary = case when b ? 'summary' then (b->>'summary')::boolean else can_view_summary end
  where user_id = p_user and lower(form_code) = f;
  perform private.cms_log('forms.permission', 'form_permissions', p_user::text || ':' || f, null,
    'Claim permissions for ' || coalesce((select email from auth.users where id = p_user), p_user::text) || ' on ' || upper(f) || ' changed', b);
end $f$;
revoke all on function public.cms_form_permission_set(uuid, text, jsonb) from public, anon;
grant execute on function public.cms_form_permission_set(uuid, text, jsonb) to authenticated;
