-- Letters: issuing saves the issued Word file for anyone who can issue letters (v2026.11.27). Additive: one new storage policy.
-- The existing "CMS letter sources upload" policy lets only people with Create on HR Letters (Super Admin, Admin) save to
-- cms/issued/ and cms/templates/. The HR role (Issue letters, Templates; HR Letters View + Edit) and Directors (Issue letters)
-- were refused with "new row violates row-level security policy" when issuing. Policies are OR'ed, so this only adds:
--   * cms/issued/<letter id>.docx  — anyone with letters.issue;
--   * cms/templates/<id>.docx      — anyone with letters.templates (template changes still need approval before use).
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'CMS letter issue and template upload') then
    create policy "CMS letter issue and template upload" on storage.objects for insert to authenticated
      with check (bucket_id = 'hr-letter-sources' and (
        (name ~ '^cms/issued/[0-9a-f-]{36}\.docx$' and public.cms_can('letters.issue', 'V'))
        or (name ~ '^cms/templates/[0-9a-f-]{36}\.docx$' and public.cms_can('letters.templates', 'V'))));
  end if;
end $$;
