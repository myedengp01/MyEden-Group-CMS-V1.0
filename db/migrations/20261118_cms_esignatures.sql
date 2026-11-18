-- HR letters: signatories, e-signatures, company stamps (v2026.11.18)
-- Additive only. A signatory list drives the letter's Name / Designation; an e-signature (drawn, uploaded or typed) is applied
-- only when an approved letter is issued, by the signatory or by someone they (or Admin / a Director) allowed and who holds
-- "Apply e-signatures". Applying copies the image to the letter's own folder, so issued letters keep the signature they were
-- issued with. The signatory gets a CMS notice when someone else applies theirs. Employee acknowledgements stay hand-signed.

-- ------------------------------------------------------------------ permissions
insert into public.cms_modules (code, label, grp, phase, sort_order, description, acts, kind, parent) values
  ('letters.signatories', 'Manage signatories', 'Operations', 5, 1037, 'Add and change signatories, who may apply their e-signatures, and company stamps', 'V', 'special', 'letters'),
  ('letters.esign', 'Apply e-signatures', 'Operations', 5, 1038, 'When issuing a letter, apply the e-signature (and company stamp) of a signatory who allowed it', 'V', 'special', 'letters')
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('admin', 'letters.signatories', 'V'), ('director', 'letters.signatories', 'V'), ('admin', 'letters.esign', 'V'), ('director', 'letters.esign', 'V')
on conflict do nothing;
insert into public.cms_role_permission_defaults (role_code, module_code, actions) values
  ('admin', 'letters.signatories', 'V'), ('director', 'letters.signatories', 'V'), ('admin', 'letters.esign', 'V'), ('director', 'letters.esign', 'V')
on conflict do nothing;

-- ------------------------------------------------------------------ tables
create table if not exists public.cms_signatories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  designation text not null default '',
  companies text[] not null default '{}',     -- empty = signs for every company
  user_id uuid,                                -- the signatory's own CMS login (optional)
  active boolean not null default true,
  sort int not null default 0,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  updated_by uuid, updated_at timestamptz not null default now()
);
create table if not exists public.cms_signature_versions (
  id uuid primary key default gen_random_uuid(),
  signatory_id uuid not null references public.cms_signatories(id),
  method text not null check (method in ('draw', 'upload', 'type')),
  path text not null unique,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  retired_at timestamptz, retired_by uuid
);
create index if not exists cms_signature_versions_sig on public.cms_signature_versions (signatory_id) where retired_at is null;
create table if not exists public.cms_signatory_access (
  signatory_id uuid not null references public.cms_signatories(id),
  user_id uuid not null,
  granted_by uuid, granted_at timestamptz not null default now(),
  revoked_by uuid, revoked_at timestamptz,
  primary key (signatory_id, user_id)
);
create table if not exists public.cms_company_stamps (
  id uuid primary key default gen_random_uuid(),
  company text not null,
  path text not null unique,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  retired_at timestamptz, retired_by uuid
);
create table if not exists public.cms_esign_log (
  id bigserial primary key,
  letter_id uuid not null, signatory_id uuid, signature_version_id uuid, stamp_id uuid,
  sig_path text, stamp_path text, applied_by uuid, applied_at timestamptz not null default now()
);
create table if not exists public.cms_notices (
  id bigserial primary key,
  user_id uuid not null,
  kind text not null default 'info',
  title text not null, body text not null default '', href text,
  created_at timestamptz not null default now(), read_at timestamptz
);
create index if not exists cms_notices_user on public.cms_notices (user_id) where read_at is null;
alter table public.cms_signatories enable row level security;
alter table public.cms_signature_versions enable row level security;
alter table public.cms_signatory_access enable row level security;
alter table public.cms_company_stamps enable row level security;
alter table public.cms_esign_log enable row level security;
alter table public.cms_notices enable row level security;
alter table public.hr_letter_records add column if not exists esign jsonb;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('authorized_signature', 'Authorized Signature', 'Where the e-signature (and company stamp) goes. Left blank for a pen signature when none is applied on issue.', 'text', 'manual', '', '', false, false, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
update public.hr_letter_placeholders set label = 'Authorized Designation', updated_at = now() where key = 'authorized_designation' and label = 'authorized designation';

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_uid_can(p_uid uuid, p_module text, p_action text default 'V')
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_user_roles where user_id = p_uid and is_active and role_code = 'super_admin')
      or exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                  where ur.user_id = p_uid and ur.is_active and rp.module_code = p_module and strpos(rp.actions, upper(p_action)) > 0)
      or exists (select 1 from public.cms_user_permissions up where up.user_id = p_uid and up.module_code = p_module and strpos(up.actions, upper(p_action)) > 0);
$$;
create or replace function private.cms_esign_manager() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_can('letters.signatories', 'V');
$$;
-- may change this signatory's e-signature and who may apply it: managers, and the signatory themself
create or replace function private.cms_esign_can_edit(p_sid uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (private.cms_esign_manager()
    or exists (select 1 from public.cms_signatories s where s.id = p_sid and s.user_id = auth.uid()));
$$;
-- may apply (and so see) this signatory's e-signature: the signatory themself, or someone they allowed who holds "Apply e-signatures"
create or replace function private.cms_esign_can_use(p_sid uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.cms_signatories s where s.id = p_sid and s.active and (s.user_id = auth.uid()
    or (public.cms_can('letters.esign', 'V') and exists (select 1 from public.cms_signatory_access a where a.signatory_id = s.id and a.user_id = auth.uid() and a.revoked_at is null))));
$$;
create or replace function private.cms_esign_stamp_user() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (private.cms_esign_manager() or public.cms_can('letters.esign', 'V')
    or exists (select 1 from public.cms_signatories s where s.user_id = auth.uid() and s.active));
$$;

-- storage: sig/<signatory>/<uuid>.png · stamp/<COMPANY>/<uuid>.png · issued/<letter>/<uuid>.png
create or replace function public.cms_esign_obj_read(p_name text) returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m text[];
begin
  if auth.uid() is null then return false; end if;
  m := regexp_match(p_name, '^sig/([0-9a-f-]{36})/[0-9a-f-]{36}\.png$');
  if m is not null then return private.cms_esign_can_edit(m[1]::uuid) or private.cms_esign_can_use(m[1]::uuid); end if;
  if p_name ~ '^stamp/[A-Z0-9]{2,8}/[0-9a-f-]{36}\.png$' then return private.cms_esign_stamp_user(); end if;
  if p_name ~ '^issued/[0-9a-f-]{36}/[0-9a-f-]{36}\.png$' then return public.cms_can('letters', 'V'); end if;
  return false;
end $$;
create or replace function public.cms_esign_obj_write(p_name text) returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m text[];
begin
  if auth.uid() is null then return false; end if;
  m := regexp_match(p_name, '^sig/([0-9a-f-]{36})/[0-9a-f-]{36}\.png$');
  if m is not null then return private.cms_esign_can_edit(m[1]::uuid); end if;
  if p_name ~ '^stamp/[A-Z0-9]{2,8}/[0-9a-f-]{36}\.png$' then return private.cms_esign_manager(); end if;
  m := regexp_match(p_name, '^issued/([0-9a-f-]{36})/[0-9a-f-]{36}\.png$');
  if m is not null then return public.cms_can('letters.issue', 'V') and exists (select 1 from public.hr_letter_records where id = m[1]::uuid and status = 'approved'); end if;
  return false;
end $$;
grant execute on function public.cms_esign_obj_read(text), public.cms_esign_obj_write(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cms-esign', 'cms-esign', false, 2097152, array['image/png']) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'CMS e-sign read') then
    create policy "CMS e-sign read" on storage.objects for select to authenticated using (bucket_id = 'cms-esign' and public.cms_esign_obj_read(name));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'CMS e-sign upload') then
    create policy "CMS e-sign upload" on storage.objects for insert to authenticated with check (bucket_id = 'cms-esign' and public.cms_esign_obj_write(name));
  end if;
  -- no update / removal policy: files in this bucket can never be changed or taken away by a user
end $$;

-- ------------------------------------------------------------------ RPCs: the list, signatories, signatures, access, stamps
create or replace function public.cms_signatories() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare mgr boolean := private.cms_esign_manager();
begin
  if auth.uid() is null or not public.cms_can('letters', 'V') then return jsonb_build_object('signatories', '[]'::jsonb, 'stamps', '[]'::jsonb); end if;
  return jsonb_build_object(
    'can_manage', mgr, 'can_esign', public.cms_can('letters.esign', 'V'), 'me', auth.uid(),
    'signatories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'designation', s.designation, 'companies', to_jsonb(s.companies), 'active', s.active, 'sort', s.sort,
        'user_id', s.user_id, 'user_name', case when s.user_id is not null then private.cms_user_name(s.user_id) end,
        'is_mine', s.user_id = auth.uid(), 'can_edit', private.cms_esign_can_edit(s.id), 'can_use', private.cms_esign_can_use(s.id),
        'sig', (select jsonb_build_object('id', v.id, 'method', v.method, 'created_at', v.created_at, 'by', private.cms_user_name(v.created_by),
                  'path', case when private.cms_esign_can_edit(s.id) or private.cms_esign_can_use(s.id) then v.path end)
                from public.cms_signature_versions v where v.signatory_id = s.id and v.retired_at is null order by v.created_at desc limit 1),
        'access', case when private.cms_esign_can_edit(s.id) then coalesce((select jsonb_agg(jsonb_build_object('user_id', a.user_id, 'name', private.cms_user_name(a.user_id),
                  'has_esign', private.cms_uid_can(a.user_id, 'letters.esign'), 'granted_at', a.granted_at) order by private.cms_user_name(a.user_id))
                from public.cms_signatory_access a where a.signatory_id = s.id and a.revoked_at is null), '[]'::jsonb) end,
        'uses', case when private.cms_esign_can_edit(s.id) then (select count(*) from public.cms_esign_log g where g.signatory_id = s.id) end)
      order by s.active desc, s.sort, s.name) from public.cms_signatories s where s.active or mgr), '[]'::jsonb),
    'stamps', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'company', x.company, 'created_at', x.created_at, 'by', private.cms_user_name(x.created_by),
        'path', case when private.cms_esign_stamp_user() then x.path end) order by x.company)
      from public.cms_company_stamps x where x.retired_at is null), '[]'::jsonb),
    'users', case when mgr or exists (select 1 from public.cms_signatories s where s.user_id = auth.uid()) then coalesce((select jsonb_agg(jsonb_build_object('id', u.uid,
        'name', private.cms_user_name(u.uid), 'has_esign', private.cms_uid_can(u.uid, 'letters.esign'), 'can_issue', private.cms_uid_can(u.uid, 'letters.issue')) order by private.cms_user_name(u.uid))
      from (select distinct user_id uid from public.cms_user_roles where is_active) u), '[]'::jsonb) end);
end $$;

create or replace function public.cms_signatory_save(p jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := nullif(btrim(p->>'name'), ''); v_cos text[];
begin
  if not private.cms_esign_manager() then raise exception 'Not allowed: managing signatories' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Give the signatory''s name.'; end if;
  select coalesce(array_agg(distinct upper(btrim(x))) filter (where btrim(x) <> ''), '{}') into v_cos from jsonb_array_elements_text(coalesce(p->'companies', '[]'::jsonb)) x;
  if v_id is null then
    insert into public.cms_signatories (name, designation, companies, user_id, active, sort, created_by, updated_by)
    values (v_name, coalesce(btrim(p->>'designation'), ''), v_cos, nullif(p->>'user_id', '')::uuid, coalesce((p->>'active')::boolean, true), coalesce((p->>'sort')::int, 0), auth.uid(), auth.uid())
    returning id into v_id;
    perform private.cms_log('signatory.added', 'cms_signatories', v_id::text, null, v_name || ' added as a signatory', p);
  else
    update public.cms_signatories set name = v_name, designation = coalesce(btrim(p->>'designation'), ''), companies = v_cos, user_id = nullif(p->>'user_id', '')::uuid,
           active = coalesce((p->>'active')::boolean, active), sort = coalesce((p->>'sort')::int, sort), updated_by = auth.uid(), updated_at = now()
     where id = v_id;
    if not found then raise exception 'Signatory not found.'; end if;
    perform private.cms_log('signatory.changed', 'cms_signatories', v_id::text, null, v_name || ' (signatory) changed', p);
  end if;
  return v_id;
end $$;

create or replace function public.cms_signature_set(p_signatory uuid, p_path text, p_method text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; nm text;
begin
  if not private.cms_esign_can_edit(p_signatory) then raise exception 'Not allowed: only the signatory, Admin or a Director can set this e-signature' using errcode = '42501'; end if;
  if p_method not in ('draw', 'upload', 'type') then raise exception 'Unknown way of making the signature.'; end if;
  if p_path !~ ('^sig/' || p_signatory::text || '/[0-9a-f-]{36}\.png$') or not exists (select 1 from storage.objects where bucket_id = 'cms-esign' and name = p_path) then
    raise exception 'The signature picture was not saved — try again.'; end if;
  update public.cms_signature_versions set retired_at = now(), retired_by = auth.uid() where signatory_id = p_signatory and retired_at is null;
  insert into public.cms_signature_versions (signatory_id, method, path, created_by) values (p_signatory, p_method, p_path, auth.uid()) returning id into v;
  select name into nm from public.cms_signatories where id = p_signatory;
  perform private.cms_log('signature.set', 'cms_signatories', p_signatory::text, null, 'New e-signature for ' || nm || ' (' || p_method || ')', jsonb_build_object('version', v));
  return v;
end $$;

create or replace function public.cms_signature_remove(p_signatory uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare nm text;
begin
  if not private.cms_esign_can_edit(p_signatory) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.cms_signature_versions set retired_at = now(), retired_by = auth.uid() where signatory_id = p_signatory and retired_at is null;
  select name into nm from public.cms_signatories where id = p_signatory;
  perform private.cms_log('signature.removed', 'cms_signatories', p_signatory::text, null, 'E-signature of ' || nm || ' removed (issued letters keep theirs)', '{}'::jsonb);
end $$;

create or replace function public.cms_signatory_access_set(p_signatory uuid, p_user uuid, p_on boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare nm text;
begin
  if not private.cms_esign_can_edit(p_signatory) then raise exception 'Not allowed: only the signatory, Admin or a Director can choose who may apply this e-signature' using errcode = '42501'; end if;
  select name into nm from public.cms_signatories where id = p_signatory;
  if p_on then
    insert into public.cms_signatory_access (signatory_id, user_id, granted_by, granted_at) values (p_signatory, p_user, auth.uid(), now())
    on conflict (signatory_id, user_id) do update set granted_by = auth.uid(), granted_at = now(), revoked_by = null, revoked_at = null;
  else
    update public.cms_signatory_access set revoked_by = auth.uid(), revoked_at = now() where signatory_id = p_signatory and user_id = p_user and revoked_at is null;
  end if;
  perform private.cms_log(case when p_on then 'signature.access_granted' else 'signature.access_removed' end, 'cms_signatories', p_signatory::text, null,
    private.cms_user_name(p_user) || case when p_on then ' may now apply the e-signature of ' else ' may no longer apply the e-signature of ' end || nm, '{}'::jsonb);
end $$;

create or replace function public.cms_stamp_set(p_company text, p_path text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; c text := upper(btrim(p_company));
begin
  if not private.cms_esign_manager() then raise exception 'Not allowed: managing company stamps' using errcode = '42501'; end if;
  if p_path !~ ('^stamp/' || c || '/[0-9a-f-]{36}\.png$') or not exists (select 1 from storage.objects where bucket_id = 'cms-esign' and name = p_path) then
    raise exception 'The stamp picture was not saved — try again.'; end if;
  update public.cms_company_stamps set retired_at = now(), retired_by = auth.uid() where company = c and retired_at is null;
  insert into public.cms_company_stamps (company, path, created_by) values (c, p_path, auth.uid()) returning id into v;
  perform private.cms_log('stamp.set', 'cms_company_stamps', v::text, c, 'New company stamp for ' || c, '{}'::jsonb);
  return v;
end $$;

create or replace function public.cms_stamp_remove(p_company text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not private.cms_esign_manager() then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.cms_company_stamps set retired_at = now(), retired_by = auth.uid() where company = upper(btrim(p_company)) and retired_at is null;
  perform private.cms_log('stamp.removed', 'cms_company_stamps', upper(btrim(p_company)), upper(btrim(p_company)), 'Company stamp removed (issued letters keep theirs)', '{}'::jsonb);
end $$;

-- ------------------------------------------------------------------ applying on issue
-- Called just before cms_letter_issue: the letter must be approved, the signatory must be the one the approved letter names,
-- and the person must be allowed to use that signature. The copies sit in issued/<letter>/.
create or replace function public.cms_letter_esign(p_id uuid, p_sig_path text default null, p_stamp_path text default null) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.hr_letter_records; em public.employee_master; s public.cms_signatories; v public.cms_signature_versions; st public.cms_company_stamps;
        co text; e jsonb; sid uuid;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id; co := private.cms_canon(em.company_code);
  if not public.cms_can('letters.issue', 'V', co) then raise exception 'Not allowed: issuing HR letters' using errcode = '42501'; end if;
  if l.status <> 'approved' then raise exception 'An e-signature is applied only when an approved letter is issued.'; end if;
  if p_sig_path is null and p_stamp_path is null then update public.hr_letter_records set esign = null where id = l.id; return null; end if;
  e := jsonb_build_object('applied_by', auth.uid(), 'applied_by_name', private.cms_my_name(), 'applied_at', now());
  if p_sig_path is not null then
    sid := nullif(l.fields->>'_signatory_id', '')::uuid;
    if sid is null then   -- letters drafted before the signatory list: match the name typed in the letter
      select id into sid from public.cms_signatories where active and lower(btrim(name)) = lower(btrim(coalesce(l.fields->>'authorized_signatory', ''))) order by sort limit 1;
    end if;
    select * into s from public.cms_signatories where id = sid;
    if s.id is null or not s.active then raise exception 'The letter''s signatory is not on the signatory list, so no e-signature can be applied.'; end if;
    if cardinality(s.companies) > 0 and not (co = any(s.companies)) then raise exception '% does not sign for %.', s.name, co; end if;
    if not private.cms_esign_can_use(s.id) then raise exception 'You are not allowed to apply the e-signature of %.', s.name using errcode = '42501'; end if;
    select * into v from public.cms_signature_versions where signatory_id = s.id and retired_at is null order by created_at desc limit 1;
    if v.id is null then raise exception '% has no e-signature yet.', s.name; end if;
    if p_sig_path !~ ('^issued/' || l.id::text || '/[0-9a-f-]{36}\.png$') or not exists (select 1 from storage.objects where bucket_id = 'cms-esign' and name = p_sig_path) then
      raise exception 'The signature copy was not saved — try again.'; end if;
    e := e || jsonb_build_object('signatory_id', s.id, 'name', s.name, 'designation', s.designation, 'version', v.id, 'method', v.method, 'sig_path', p_sig_path);
  end if;
  if p_stamp_path is not null then
    if not private.cms_esign_stamp_user() then raise exception 'You are not allowed to apply the company stamp.' using errcode = '42501'; end if;
    select * into st from public.cms_company_stamps where company = co and retired_at is null order by created_at desc limit 1;
    if st.id is null then raise exception 'There is no company stamp for %.', co; end if;
    if p_stamp_path !~ ('^issued/' || l.id::text || '/[0-9a-f-]{36}\.png$') or not exists (select 1 from storage.objects where bucket_id = 'cms-esign' and name = p_stamp_path) then
      raise exception 'The stamp copy was not saved — try again.'; end if;
    e := e || jsonb_build_object('stamp_id', st.id, 'stamp_path', p_stamp_path, 'company', co);
  end if;
  update public.hr_letter_records set esign = e, updated_at = now() where id = l.id;
  insert into public.cms_esign_log (letter_id, signatory_id, signature_version_id, stamp_id, sig_path, stamp_path, applied_by)
  values (l.id, s.id, v.id, st.id, p_sig_path, p_stamp_path, auth.uid());
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'esigned', e);
  if s.id is not null and s.user_id is not null and s.user_id <> auth.uid() then
    insert into public.cms_notices (user_id, kind, title, body, href)
    values (s.user_id, 'esign', 'Your e-signature was applied',
            private.cms_my_name() || ' applied your e-signature' || case when p_stamp_path is not null then ' and the company stamp' else '' end || ' to ' ||
            coalesce((select title from public.hr_letter_templates where code = l.template_code), l.template_code) || ' for ' || em.employee_name || '.',
            '#/letters?ws=' || l.id::text);
  end if;
  perform private.cms_log('letter.esigned', 'employee_master', em.id::text, co, em.employee_name || ': e-signature' || case when p_stamp_path is not null then ' and stamp' else '' end || ' applied', jsonb_build_object('letter_id', l.id, 'signatory', s.name));
  return e;
end $$;

-- ------------------------------------------------------------------ notices
create or replace function public.cms_my_notices() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'title', title, 'body', body, 'href', href, 'at', created_at) order by id desc), '[]'::jsonb)
  from (select * from public.cms_notices where user_id = auth.uid() and read_at is null order by id desc limit 30) x;
$$;
create or replace function public.cms_notice_read(p_id bigint default null) returns void language sql security definer set search_path = public, pg_temp as $$
  update public.cms_notices set read_at = now() where user_id = auth.uid() and read_at is null and (p_id is null or id = p_id);
$$;

revoke all on function public.cms_signatories(), public.cms_signatory_save(jsonb), public.cms_signature_set(uuid, text, text), public.cms_signature_remove(uuid),
  public.cms_signatory_access_set(uuid, uuid, boolean), public.cms_stamp_set(text, text), public.cms_stamp_remove(text), public.cms_letter_esign(uuid, text, text),
  public.cms_my_notices(), public.cms_notice_read(bigint) from public, anon;
grant execute on function public.cms_signatories(), public.cms_signatory_save(jsonb), public.cms_signature_set(uuid, text, text), public.cms_signature_remove(uuid),
  public.cms_signatory_access_set(uuid, uuid, boolean), public.cms_stamp_set(text, text), public.cms_stamp_remove(text), public.cms_letter_esign(uuid, text, text),
  public.cms_my_notices(), public.cms_notice_read(bigint) to authenticated;

-- ------------------------------------------------------------------ cms_letters: the letter list carries esign
do $$ declare d text := pg_get_functiondef('public.cms_letters()'::regprocedure);
begin
  if strpos(d, '''esign'', l.esign') = 0 then
    d := replace(d, '''signed_at'', l.signed_at,', '''signed_at'', l.signed_at, ''esign'', l.esign,');
    if strpos(d, '''esign'', l.esign') = 0 then raise exception 'cms_letters: marker not found'; end if;
    execute d;
  end if;
end $$;

-- Template wording (applied 18 Nov 2026 with cms_letter_template_save as CLC, published; the previous wording is kept in
-- hr_letter_template_versions): every published text template's company signing block becomes
--   For and on behalf of / {{company_name}} / (blank) / {{authorized_signature}} / ____ / Authorized Signatory /
--   Name: {{authorized_signatory}} / Designation: {{authorized_designation}}
-- (DI, EL, LOC, LOC_LOI, LOI, LOP, PEL, PIP, RL, RL_TP2, RL_TP3, SAL, SCL, TL, TRL, UAL, WL). Word templates are not changed:
-- the picture and the Name / Position of the signatory are put in when the letter is filled.
