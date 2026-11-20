-- User Manual (HR and above) and Staff Guide (self-service) inside the CMS (v2026.11.20). Additive.
-- The manuals are kept in the database and in the private storage bucket "cms-manual", never in the (public) code repository.
-- User Manual: permission "manual" (HR, Admin, Directors, Super Admin by default; Admin may give it to others). Staff Guide: every
-- signed-in person linked to an employee record (and anyone with the manual permission). A new edition is uploaded by whoever has
-- manual · E (Admin, Super Admin): the text of each manual and language, its pictures and its Word file.

create table if not exists public.cms_manual_docs (
  audience text not null check (audience in ('hr', 'staff')), lang text not null check (lang in ('en', 'zh', 'ms')),
  version text not null, title text not null, sections jsonb not null, word_path text,
  uploaded_by uuid, uploaded_at timestamptz not null default now(), primary key (audience, lang));
alter table public.cms_manual_docs enable row level security;
revoke all on public.cms_manual_docs from anon, authenticated;

insert into public.cms_modules (code, label, grp, phase, sort_order, locked, description, acts, kind, act_labels)
select 'manual', 'User Manual', 'Administration', 0, 1062, false, 'The CMS User Manual (HR and above); the Staff Guide is in self-service for everyone', 'VE', 'section',
  '{"V":"Read the User Manual","E":"Upload a new edition of the manuals"}'::jsonb
where not exists (select 1 from public.cms_modules where code = 'manual');
insert into public.cms_role_permissions (role_code, module_code, actions)
select r, 'manual', a from (values ('super_admin', 'VE'), ('admin', 'VE'), ('director', 'V'), ('hr', 'V')) v(r, a)
where not exists (select 1 from public.cms_role_permissions where module_code = 'manual' and role_code = v.r);

insert into storage.buckets (id, name, public) values ('cms-manual', 'cms-manual', false) on conflict (id) do nothing;

-- who may read a manual (hr = permission; staff = anyone linked to an employee record, or with the permission)
create or replace function public.cms_manual_ok(p_audience text) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (public.cms_can('manual', 'V') or (p_audience = 'staff' and private.cms_me() is not null)) $$;
create or replace function public.cms_manual_file_ok(p_name text, p_write boolean) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_write then auth.uid() is not null and public.cms_can('manual', 'E')
              else public.cms_manual_ok(split_part(coalesce(p_name, ''), '/', 1)) end $$;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms manual read') then
    create policy "cms manual read" on storage.objects for select to authenticated using (bucket_id = 'cms-manual' and public.cms_manual_file_ok(name, false));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms manual add') then
    create policy "cms manual add" on storage.objects for insert to authenticated with check (bucket_id = 'cms-manual' and public.cms_manual_file_ok(name, true));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'cms manual replace') then
    create policy "cms manual replace" on storage.objects for update to authenticated using (bucket_id = 'cms-manual' and public.cms_manual_file_ok(name, true)) with check (bucket_id = 'cms-manual' and public.cms_manual_file_ok(name, true));
  end if;
end $$;

-- the languages and editions this person may read
create or replace function public.cms_manual_list() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('can_edit', public.cms_can('manual', 'E'), 'hr', public.cms_manual_ok('hr'), 'staff', public.cms_manual_ok('staff'),
    'docs', coalesce((select jsonb_agg(jsonb_build_object('audience', audience, 'lang', lang, 'version', version, 'title', title, 'sections', jsonb_array_length(sections), 'word', word_path is not null, 'uploaded_at', uploaded_at) order by audience, lang)
      from public.cms_manual_docs d where public.cms_manual_ok(d.audience)), '[]'::jsonb)) $$;

create or replace function public.cms_manual_get(p_audience text, p_lang text) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d public.cms_manual_docs;
begin
  if not public.cms_manual_ok(p_audience) then raise exception 'You do not have access to this manual.' using errcode = '42501'; end if;
  select * into d from public.cms_manual_docs where audience = p_audience and lang = p_lang;
  if d.audience is null then select * into d from public.cms_manual_docs where audience = p_audience and lang = 'en'; end if;
  if d.audience is null then return null; end if;
  return to_jsonb(d) - 'uploaded_by';
end $$;

create or replace function public.cms_manual_save(p jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('manual', 'E');
  if p->>'audience' not in ('hr', 'staff') or p->>'lang' not in ('en', 'zh', 'ms') then raise exception 'Unknown manual or language.'; end if;
  if jsonb_typeof(p->'sections') <> 'array' or jsonb_array_length(p->'sections') = 0 then raise exception 'The manual has no sections.'; end if;
  insert into public.cms_manual_docs (audience, lang, version, title, sections, word_path, uploaded_by, uploaded_at)
  values (p->>'audience', p->>'lang', coalesce(p->>'version', ''), coalesce(p->>'title', 'User Manual'), p->'sections', nullif(p->>'word_path', ''), auth.uid(), now())
  on conflict (audience, lang) do update set version = excluded.version, title = excluded.title, sections = excluded.sections, word_path = excluded.word_path, uploaded_by = excluded.uploaded_by, uploaded_at = now();
  perform private.cms_log('manual.upload', 'cms_manual_docs', (p->>'audience') || '/' || (p->>'lang'), null, 'Manual uploaded: ' || (p->>'audience') || ' · ' || (p->>'lang') || ' · ' || coalesce(p->>'version', ''), jsonb_build_object('sections', jsonb_array_length(p->'sections')));
end $$;

revoke all on function public.cms_manual_ok(text), public.cms_manual_file_ok(text, boolean), public.cms_manual_list(), public.cms_manual_get(text, text), public.cms_manual_save(jsonb) from public, anon;
grant execute on function public.cms_manual_ok(text), public.cms_manual_file_ok(text, boolean), public.cms_manual_list(), public.cms_manual_get(text, text), public.cms_manual_save(jsonb) to authenticated;
