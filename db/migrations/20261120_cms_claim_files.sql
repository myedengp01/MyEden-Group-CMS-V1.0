-- Claim receipts, journey photos and signed PDFs readable in the CMS by role (v2026.11.20). Additive (read only).
-- The files sit in the form apps' storage under <claim id>/...; until now only the form apps' own permission list could read them.
-- A CMS user may read a claim's files when their role may view that form for the claim's company.
create or replace function public.cms_claim_file_ok(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_form text; v_id text := split_part(coalesce(p_name, ''), '/', 1); v_co text;
begin
  v_form := case p_bucket when 'scf-receipts' then 'scf' when 'mtcf-receipts' then 'mtcf' when 'mtcf-pdfs' then 'mtcf' when 'otcf-pdfs' then 'otcf' end;
  if v_form is null or auth.uid() is null or v_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  execute format('select company_code from public.%I where id = $1::uuid', v_form || '_submissions') into v_co using v_id;
  if v_co is null then return false; end if;
  return public.cms_can(private.cms_claim_module(v_form), 'V', private.cms_canon(v_co));
end $$;
revoke all on function public.cms_claim_file_ok(text, text) from public, anon;
grant execute on function public.cms_claim_file_ok(text, text) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms roles read claim files') then
    create policy "cms roles read claim files" on storage.objects for select to authenticated
      using (bucket_id in ('scf-receipts', 'mtcf-receipts', 'otcf-pdfs', 'mtcf-pdfs') and public.cms_claim_file_ok(bucket_id, name));
  end if;
end $$;
