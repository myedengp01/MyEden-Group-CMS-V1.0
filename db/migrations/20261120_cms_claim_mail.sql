-- Claim emails from the CMS (v2026.11.20). Additive.
-- Who to email about a claim is taken from CMS roles (not the form apps' own permission list): everyone whose CMS role may approve
-- that form for the claim's company, never the claimant; a claim made by a Super Admin / Admin / Director goes to the Directors only
-- (the CMS rule). Called by the form email functions with the service key only.

-- may this user do this, for this company (CMS roles and personal permissions, by company)
create or replace function private.cms_uid_can_co(p_uid uuid, p_module text, p_action text, p_company text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_user_roles where user_id = p_uid and is_active and role_code = 'super_admin')
      or exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                  where ur.user_id = p_uid and ur.is_active and rp.module_code = p_module and strpos(rp.actions, upper(p_action)) > 0
                    and (p_company is null or ur.companies is null or private.cms_canon(p_company) = any(ur.companies)))
      or exists (select 1 from public.cms_user_permissions up where up.user_id = p_uid and up.module_code = p_module and strpos(up.actions, upper(p_action)) > 0
                    and (p_company is null or up.companies is null or private.cms_canon(p_company) = any(up.companies)));
$$;

create or replace function public.cms_claim_mail_info(p_form text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare j jsonb; v_mod text := private.cms_claim_module(p_form); v_tbl text := private.cms_claim_table(p_form); v_co text; v_dir boolean; v_by text;
begin
  if v_tbl is null then raise exception 'Unknown form %', p_form; end if;
  execute format('select to_jsonb(t) from public.%I t where t.id::text = $1', v_tbl) into j using p_id;
  if j is null then return null; end if;
  v_co := private.cms_canon(nullif(j->>'company_code', '')); v_by := coalesce(j->>'submitted_by', j->>'requested_by_user_id', '');
  v_dir := private.cms_needs_director(v_by);
  return jsonb_build_object('form', lower(p_form), 'module', v_mod, 'company_code', v_co, 'needs_director', v_dir,
    'claimant_email', (select u.email from auth.users u where u.id::text = v_by),
    'approvers', coalesce((select jsonb_agg(distinct u.email) from auth.users u
       where u.email is not null and u.id::text <> v_by
         and exists (select 1 from public.cms_user_roles r where r.user_id = u.id and r.is_active)
         and private.cms_uid_can_co(u.id, v_mod, 'A', v_co)
         and (not v_dir or exists (select 1 from public.cms_user_roles r where r.user_id = u.id and r.is_active and r.role_code = 'director'))), '[]'::jsonb),
    'processors', coalesce((select jsonb_agg(distinct u.email) from auth.users u
       where u.email is not null and u.id::text <> v_by
         and exists (select 1 from public.cms_user_roles r where r.user_id = u.id and r.is_active)
         and private.cms_uid_can_co(u.id, v_mod, 'E', v_co)), '[]'::jsonb));
end $$;
revoke all on function public.cms_claim_mail_info(text, text) from public, anon, authenticated;
grant execute on function public.cms_claim_mail_info(text, text) to service_role;
revoke all on function private.cms_uid_can_co(uuid, text, text, text) from public, anon;

-- the signed PDF a CMS approver makes on approve / disapprove is saved to the form's PDF bucket (<claim id>/<file>)
create or replace function public.cms_claim_pdf_write_ok(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_form text; v_id text := split_part(coalesce(p_name, ''), '/', 1); v_co text;
begin
  v_form := case p_bucket when 'otcf-pdfs' then 'otcf' when 'mtcf-pdfs' then 'mtcf' end;
  if v_form is null or auth.uid() is null or v_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  execute format('select company_code from public.%I where id = $1::uuid', v_form || '_submissions') into v_co using v_id;
  if v_co is null then return false; end if;
  return public.cms_can(private.cms_claim_module(v_form), 'A', private.cms_canon(v_co));
end $$;
revoke all on function public.cms_claim_pdf_write_ok(text, text) from public, anon;
grant execute on function public.cms_claim_pdf_write_ok(text, text) to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms approvers add claim pdfs') then
    create policy "cms approvers add claim pdfs" on storage.objects for insert to authenticated
      with check (bucket_id in ('otcf-pdfs', 'mtcf-pdfs') and public.cms_claim_pdf_write_ok(bucket_id, name));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms approvers replace claim pdfs') then
    create policy "cms approvers replace claim pdfs" on storage.objects for update to authenticated
      using (bucket_id in ('otcf-pdfs', 'mtcf-pdfs') and public.cms_claim_pdf_write_ok(bucket_id, name))
      with check (bucket_id in ('otcf-pdfs', 'mtcf-pdfs') and public.cms_claim_pdf_write_ok(bucket_id, name));
  end if;
end $$;
