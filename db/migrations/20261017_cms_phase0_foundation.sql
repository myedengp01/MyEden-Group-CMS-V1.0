-- MyEden Group CMS V1.0 · Phase 0 foundation · v2026.10.17-13:30
-- Supabase project vzngfswtofegimfcoigx ("MyEden Group CMS V1.0").
--
-- Additive only: creates new cms_ tables and functions. No existing table, view or function is changed,
-- so MEG-EAF V2, MEG-FORMS and the forms keep working exactly as before.
--
-- 0. structure snapshot of everything that exists today (taken first)
-- 1. companies (one code each, with the other spellings as aliases) and centres / units
-- 2. modules, roles, role permissions (V view · C create · E edit · A approve · D delete · X export)
-- 3. user roles (optionally limited to companies), login ↔ person links, paying company per person
-- 4. JD position → suggested role rules
-- 5. audit log (append-only)
-- 6. functions the CMS pages call; tables are never read or written directly from the browser

create schema if not exists private;

-- ============================================================ 0. structure snapshot
create table public.cms_schema_snapshots (
  id bigint generated always as identity primary key,
  taken_at timestamptz not null default now(),
  label text not null,
  summary jsonb not null,
  structure jsonb not null
);

create or replace function private.cms_take_schema_snapshot(p_label text)
returns bigint language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_id bigint; v_tables jsonb; v_views jsonb; v_funcs jsonb; v_types jsonb; v_storage jsonb; v_cron jsonb;
  v_schemas text[] := array['public', 'private', 'hr_letters_private'];
begin
  select coalesce(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'table', c.relname, 'rls', c.relrowsecurity,
      'columns', (select jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                     'not_null', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid)) order by a.attnum)
                  from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                  where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped),
      'constraints', (select jsonb_agg(jsonb_build_object('name', k.conname, 'def', pg_get_constraintdef(k.oid)) order by k.conname)
                      from pg_constraint k where k.conrelid = c.oid),
      'indexes', (select jsonb_agg(pg_get_indexdef(i.indexrelid)) from pg_index i where i.indrelid = c.oid),
      'policies', (select jsonb_agg(jsonb_build_object('name', po.polname, 'cmd', po.polcmd::text, 'permissive', po.polpermissive,
                      'roles', (select array_agg(r.rolname) from pg_roles r where r.oid = any(po.polroles)),
                      'using', pg_get_expr(po.polqual, po.polrelid), 'check', pg_get_expr(po.polwithcheck, po.polrelid)))
                   from pg_policy po where po.polrelid = c.oid),
      'triggers', (select jsonb_agg(pg_get_triggerdef(t.oid)) from pg_trigger t where t.tgrelid = c.oid and not t.tgisinternal)
    ) order by n.nspname, c.relname), '[]'::jsonb)
  into v_tables
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p') and n.nspname = any(v_schemas) and c.relname not like 'cms\_%'
    and not exists (select 1 from pg_depend dp where dp.objid = c.oid and dp.deptype = 'e');

  select coalesce(jsonb_agg(jsonb_build_object('schema', n.nspname, 'view', c.relname,
      'materialized', c.relkind = 'm', 'def', pg_get_viewdef(c.oid, true)) order by n.nspname, c.relname), '[]'::jsonb)
  into v_views
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('v', 'm') and n.nspname = any(v_schemas)
    and not exists (select 1 from pg_depend dp where dp.objid = c.oid and dp.deptype = 'e');

  select coalesce(jsonb_agg(jsonb_build_object('schema', n.nspname, 'name', p.proname,
      'args', pg_get_function_identity_arguments(p.oid), 'security_definer', p.prosecdef,
      'def', pg_get_functiondef(p.oid)) order by n.nspname, p.proname), '[]'::jsonb)
  into v_funcs
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = any(v_schemas) and p.prokind in ('f', 'p') and p.proname not like 'cms\_%'
    and not exists (select 1 from pg_depend dp where dp.objid = p.oid and dp.deptype = 'e');

  select coalesce(jsonb_agg(jsonb_build_object('schema', n.nspname, 'type', t.typname,
      'labels', (select jsonb_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid))), '[]'::jsonb)
  into v_types
  from pg_type t join pg_namespace n on n.oid = t.typnamespace
  where t.typtype = 'e' and n.nspname = any(v_schemas);

  select jsonb_build_object(
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'public', b.public,
                  'file_size_limit', b.file_size_limit, 'allowed_mime_types', b.allowed_mime_types)), '[]'::jsonb) from storage.buckets b),
    'policies', (select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'name', po.polname, 'cmd', po.polcmd::text,
                  'using', pg_get_expr(po.polqual, po.polrelid), 'check', pg_get_expr(po.polwithcheck, po.polrelid))), '[]'::jsonb)
                 from pg_policy po join pg_class c on c.oid = po.polrelid join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'storage'))
  into v_storage;

  begin
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''job'', jobname, ''schedule'', schedule, ''command'', command, ''active'', active)), ''[]''::jsonb) from cron.job'
      into v_cron;
  exception when others then v_cron := '[]'::jsonb;
  end;

  insert into public.cms_schema_snapshots (label, summary, structure)
  values (p_label,
    jsonb_build_object('tables', jsonb_array_length(v_tables), 'views', jsonb_array_length(v_views),
      'functions', jsonb_array_length(v_funcs), 'enum_types', jsonb_array_length(v_types),
      'buckets', jsonb_array_length(v_storage->'buckets'), 'cron_jobs', jsonb_array_length(v_cron)),
    jsonb_build_object('tables', v_tables, 'views', v_views, 'functions', v_funcs, 'enum_types', v_types,
      'storage', v_storage, 'cron', v_cron))
  returning id into v_id;
  return v_id;
end $$;

select private.cms_take_schema_snapshot('Before Phase 0 · v2026.10.17-13:30');

-- ============================================================ 1. companies and units
create table public.cms_companies (
  code text primary key,
  name text not null,
  short_name text not null,
  is_active boolean not null default true,
  is_paying boolean not null default false,
  aliases text[] not null default '{}',      -- other spellings used by older apps (upper case)
  logo text,
  note text,
  sort_order int not null default 0
);

insert into public.cms_companies (code, name, short_name, is_active, is_paying, aliases, logo, note, sort_order) values
  ('MEG',  'MyEden Group Sdn. Bhd.',        'MyEden Group',          true,  true,  '{MYEDEN,MYEDEN GROUP}', 'assets/logos/myeden-group.png',   null, 1),
  ('MEH',  'MyEden Edu Hub Sdn. Bhd.',      'MyEden Edu Hub',        true,  true,  '{EDU HUB}',            'assets/logos/edu-hub.jpg',        null, 2),
  ('HD',   'Happy Dino Sdn. Bhd.',          'Happy Dino',            true,  true,  '{HDS}',                'assets/logos/happy-dino.jpg',     null, 3),
  ('ABP',  'Aborne Project Sdn. Bhd.',      'Aborne Project',        true,  true,  '{ABN}',                'assets/logos/aborne-project.png', null, 4),
  ('MHD',  'MyEden Holding Sdn. Bhd.',      'MyEden Holding',        false, false, '{}', null, 'Inactive. Its staff are paid by MyEden Group.', 5),
  ('TGE',  'Tadika Genius Eden',            'Tadika Genius Eden',    false, false, '{}', null, 'Old payroll code. Now a centre (E3) paid by MyEden Edu Hub.', 6),
  ('PJKE', 'Pusat Jagaan Kanak-Kanak Eden', 'PJK Eden',              false, false, '{}', null, 'Old payroll code. Now centres E10/E11 paid by MyEden Group.', 7),
  ('THD',  'Tadika Happy Dino',             'Tadika Happy Dino',     false, false, '{}', null, 'Old payroll code. Now a centre (E3+) paid by MyEden Edu Hub.', 8),
  ('EDC',  'Eden Childcare',                'Eden Childcare',        false, false, '{}', null, 'Old payroll code. Now paid by MyEden Group.', 9),
  ('WF',   'White Feather Sdn. Bhd.',       'White Feather',         false, false, '{}', null, 'Inactive.', 10);

create table public.cms_units (
  code text primary key,
  name text not null,
  company_code text references public.cms_companies(code),
  kind text not null default 'centre' check (kind in ('centre', 'office')),
  is_active boolean not null default true,
  note text,
  sort_order int not null default 0
);

insert into public.cms_units (code, name, company_code, kind, is_active, note, sort_order) values
  ('HQ',  'HQ',                            'MEG', 'office', true,  'E8 was merged into HQ.', 1),
  ('E1',  'Taska Genius Eden',             'MEG', 'centre', true,  null, 2),
  ('E6',  'Taska Genius Eden',             'MEG', 'centre', true,  null, 3),
  ('E7',  'Taska Genius Eden',             'MEG', 'centre', true,  null, 4),
  ('E10', 'Pusat Jagaan Kanak-Kanak Eden', 'MEG', 'centre', true,  'Eden Childcare Center', 5),
  ('E11', 'Pusat Jagaan Kanak-Kanak Eden', 'MEG', 'centre', true,  'Eden Childcare Center', 6),
  ('E3',  'Tadika Genius Eden',            'MEH', 'centre', true,  null, 7),
  ('E3+', 'Tadika Happy Dino',             'MEH', 'centre', true,  null, 8),
  ('E8',  'E8',                            'MEG', 'office', false, 'Merged into HQ.', 20),
  ('E2',  'E2',                            null,  'centre', false, null, 21),
  ('E4',  'E4',                            null,  'centre', false, null, 22),
  ('E5',  'E5',                            null,  'centre', false, null, 23),
  ('E9',  'E9',                            null,  'centre', false, null, 24);

-- one code for every spelling: meg / hds / abn / HDS / ABN … → MEG / HD / ABP
create or replace function private.cms_canon(p_code text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select c.code from public.cms_companies c
      where c.code = upper(btrim(p_code)) or upper(btrim(p_code)) = any(c.aliases) limit 1),
    nullif(upper(btrim(p_code)), ''));
$$;

-- ============================================================ 2. modules, roles, permissions
create table public.cms_modules (
  code text primary key,
  label text not null,
  grp text not null,
  phase int not null,
  sort_order int not null
);

insert into public.cms_modules (code, label, grp, phase, sort_order) values
  ('dashboard',       'Dashboard',                      'Workspace',            0, 1),
  ('people',          'People',                         'People & Employment',  2, 10),
  ('org',             'Organisation Structure',         'People & Employment',  0, 11),
  ('documents',       'Employee Documents',             'People & Employment',  5, 12),
  ('jd',              'Job Description Manual',         'Recruitment',          3, 20),
  ('recruitment',     'Positions, Applications & Interviews', 'Recruitment',    3, 21),
  ('onboarding',      'Offers & Onboarding',            'Recruitment',          3, 22),
  ('handbook',        'Employee Handbook',              'Recruitment',          3, 23),
  ('leave',           'Leave',                          'Time & Leave',         2, 30),
  ('overtime',        'Overtime (OTCF)',                'Time & Leave',         1, 31),
  ('scf',             'Staff Claims (SCF)',             'Forms & Claims',       1, 40),
  ('mtcf',            'Mileage Claims (MTCF)',          'Forms & Claims',       1, 41),
  ('tec',             'Teacher Tuition Claims (TEC)',   'Forms & Claims',       1, 42),
  ('prfaf',           'Purchase & Funding (PRFAF)',     'Forms & Claims',       1, 43),
  ('payroll',         'Payroll',                        'Payroll',              2, 50),
  ('performance',     'KPI & Appraisal',                'Performance & Growth', 5, 60),
  ('training',        'Training & Certificates',        'Performance & Growth', 5, 61),
  ('assets',          'Assets & Equipment',             'Operations',           5, 70),
  ('letters',         'HR Letters',                     'Operations',           5, 71),
  ('hrlaw',           'Employment Act & Calculators',   'Operations',           3, 72),
  ('approvals',       'Approvals & Workflows',          'Operations',           0, 73),
  ('reports',         'Reports & Analytics',            'Operations',           5, 74),
  ('admin.roles',     'Users, Roles & Access',          'Administration',       0, 90),
  ('admin.companies', 'Companies & Settings',           'Administration',       0, 91),
  ('admin.audit',     'Audit Log',                      'Administration',       0, 92),
  ('admin.export',    'Export All Data',                'Administration',       0, 93);

create table public.cms_roles (
  code text primary key,
  name text not null,
  description text not null,
  rank int not null,
  phase int not null default 0,
  is_system boolean not null default true
);

insert into public.cms_roles (code, name, description, rank, phase) values
  ('super_admin', 'Super Admin', 'Everything, including granting roles, changing permissions and exporting all data.', 100, 0),
  ('admin',       'Admin',       'Sees, edits and approves everything. Links logins to people. Cannot grant roles or export all data.', 90, 0),
  ('hr',          'HR',          'People, recruitment, onboarding, handbook, leave, letters, training and performance.', 70, 0),
  ('payroll',     'Payroll',     'Payroll, and Payroll / Account processing of approved claims.', 60, 1),
  ('finance',     'Finance',     'Marks approved claims and funding as paid; reads payroll.', 60, 1),
  ('approver',    'Approver',    'Approves claims, overtime and leave, usually for their own company.', 50, 1),
  ('staff',       'Staff',       'Own payslips, leave and claims (self-service).', 10, 4);

create table public.cms_role_permissions (
  role_code text not null references public.cms_roles(code) on delete cascade,
  module_code text not null references public.cms_modules(code) on delete cascade,
  actions text not null default '' check (actions ~ '^[VCEADX]*$'),
  primary key (role_code, module_code)
);

insert into public.cms_role_permissions (role_code, module_code, actions)
select 'super_admin', code, 'VCEADX' from public.cms_modules;

insert into public.cms_role_permissions (role_code, module_code, actions)
select 'admin', code, case code when 'admin.roles' then 'VE' when 'admin.export' then '' when 'admin.audit' then 'V'
                                when 'admin.companies' then 'VCE' else 'VCEADX' end
from public.cms_modules;

insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('hr', 'dashboard', 'V'), ('hr', 'people', 'VCEX'), ('hr', 'org', 'V'), ('hr', 'documents', 'VCE'),
  ('hr', 'jd', 'V'), ('hr', 'recruitment', 'VCE'), ('hr', 'onboarding', 'VCE'), ('hr', 'handbook', 'VCE'),
  ('hr', 'leave', 'VCE'), ('hr', 'overtime', 'V'), ('hr', 'letters', 'VCE'), ('hr', 'hrlaw', 'V'),
  ('hr', 'performance', 'VCE'), ('hr', 'training', 'VCE'), ('hr', 'assets', 'VCE'), ('hr', 'approvals', 'V'), ('hr', 'reports', 'VX'),

  ('payroll', 'dashboard', 'V'), ('payroll', 'people', 'V'), ('payroll', 'org', 'V'), ('payroll', 'leave', 'V'),
  ('payroll', 'overtime', 'VE'), ('payroll', 'scf', 'VE'), ('payroll', 'mtcf', 'VE'), ('payroll', 'tec', 'VE'),
  ('payroll', 'prfaf', 'V'), ('payroll', 'payroll', 'VCEX'), ('payroll', 'approvals', 'V'), ('payroll', 'reports', 'VX'), ('payroll', 'hrlaw', 'V'),

  ('finance', 'dashboard', 'V'), ('finance', 'org', 'V'), ('finance', 'overtime', 'VE'), ('finance', 'scf', 'VE'),
  ('finance', 'mtcf', 'VE'), ('finance', 'tec', 'VE'), ('finance', 'prfaf', 'VE'), ('finance', 'payroll', 'V'),
  ('finance', 'approvals', 'V'), ('finance', 'reports', 'VX'),

  ('approver', 'dashboard', 'V'), ('approver', 'people', 'V'), ('approver', 'org', 'V'), ('approver', 'leave', 'VA'),
  ('approver', 'overtime', 'VA'), ('approver', 'scf', 'VA'), ('approver', 'mtcf', 'VA'), ('approver', 'tec', 'VA'),
  ('approver', 'prfaf', 'VA'), ('approver', 'approvals', 'VA'), ('approver', 'hrlaw', 'V'),

  ('staff', 'dashboard', 'V'), ('staff', 'hrlaw', 'V'), ('staff', 'handbook', 'V'), ('staff', 'leave', 'VC'),
  ('staff', 'overtime', 'VC'), ('staff', 'scf', 'VC'), ('staff', 'mtcf', 'VC'), ('staff', 'tec', 'VC'), ('staff', 'prfaf', 'VC');

-- ============================================================ 3. user roles, links, paying company
create table public.cms_user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role_code text not null references public.cms_roles(code),
  companies text[],                  -- null = all companies
  is_active boolean not null default true,
  note text,
  granted_by uuid,
  granted_at timestamptz not null default now(),
  revoked_by uuid,
  revoked_at timestamptz,
  primary key (user_id, role_code)
);

create table public.cms_user_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  employee_master_id uuid not null unique references public.employee_master(id) on delete cascade,
  method text not null default 'manual' check (method in ('manual', 'email_match')),
  linked_by uuid,
  linked_at timestamptz not null default now()
);

-- employer on the contract stays in employee_master.company_code; the paying company lives here.
-- No row (or an empty paying company) means "paid by the employer".
create table public.cms_employee_payroll (
  employee_master_id uuid primary key references public.employee_master(id) on delete cascade,
  paying_company_code text references public.cms_companies(code),
  unit_code text references public.cms_units(code),
  note text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- ============================================================ 4. JD position → suggested role
create table public.cms_position_role_rules (
  id int generated always as identity primary key,
  entity_code text,                  -- null = any company
  department_name text,              -- null = any department
  min_level int not null check (min_level between 1 and 5),
  role_code text not null references public.cms_roles(code),
  scope text not null default 'own_company' check (scope in ('own_company', 'all')),
  note text
);

insert into public.cms_position_role_rules (entity_code, department_name, min_level, role_code, scope, note) values
  ('MEG', 'Human Resources',       3, 'hr',       'all',         'Group HR sits in MyEden Group'),
  ('MEG', 'Accounts & Payroll',    3, 'payroll',  'all',         null),
  ('MEG', 'Accounts',              3, 'finance',  'all',         null),
  ('MEG', 'Finance',               3, 'finance',  'all',         null),
  (null,  'Management',            4, 'approver', 'own_company', null),
  (null,  'Leadership',            5, 'approver', 'own_company', null),
  ('HD',  'Happy Dino Management', 4, 'approver', 'own_company', null),
  ('HD',  'Happy Dino Leadership', 5, 'approver', 'own_company', null),
  (null,  null,                    5, 'approver', 'own_company', 'Heads of department approve for their company');

-- ============================================================ 5. audit log
create table public.cms_audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  actor_email text,
  action text not null,
  entity text,
  entity_id text,
  company_code text,
  summary text not null,
  details jsonb not null default '{}'::jsonb
);
create index cms_audit_log_at on public.cms_audit_log (at desc);

create or replace function private.cms_audit_no_change()
returns trigger language plpgsql as $$
begin
  raise exception 'The audit log is append-only: entries cannot be changed or deleted';
end $$;
create trigger cms_audit_log_no_update before update or delete on public.cms_audit_log
  for each row execute function private.cms_audit_no_change();
create trigger cms_audit_log_no_truncate before truncate on public.cms_audit_log
  for each statement execute function private.cms_audit_no_change();

create or replace function private.cms_log(p_action text, p_entity text, p_entity_id text, p_company text,
  p_summary text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.cms_audit_log (actor_id, actor_email, action, entity, entity_id, company_code, summary, details)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_action, p_entity, p_entity_id,
          p_company, p_summary, coalesce(p_details, '{}'::jsonb));
$$;

-- ============================================================ 6. access checks
create or replace function public.cms_is_super_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.cms_user_roles
    where user_id = auth.uid() and is_active and role_code = 'super_admin');
$$;

-- may the signed-in user do p_action (V C E A D X) in p_module, for p_company (null = in general)?
create or replace function public.cms_can(p_module text, p_action text default 'V', p_company text default null)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (
    public.cms_is_super_admin()
    or exists (select 1 from public.cms_user_roles ur
               join public.cms_role_permissions rp on rp.role_code = ur.role_code
               where ur.user_id = auth.uid() and ur.is_active and rp.module_code = p_module
                 and strpos(rp.actions, upper(p_action)) > 0
                 and (p_company is null or ur.companies is null or private.cms_canon(p_company) = any(ur.companies))));
$$;

create or replace function private.cms_require(p_module text, p_action text default 'V', p_company text default null)
returns void language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please sign in' using errcode = '42501'; end if;
  if not public.cms_can(p_module, p_action, p_company) then
    raise exception 'You do not have access to do this (% · %)', p_module, p_action using errcode = '42501';
  end if;
end $$;

create or replace function private.cms_require_super_admin()
returns void language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.cms_is_super_admin() then
    raise exception 'Only a Super Admin can do this' using errcode = '42501';
  end if;
end $$;

-- ============================================================ 7. functions the pages call
-- who am I, which roles, which modules and actions
create or replace function public.cms_my_access()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v jsonb; v_super boolean;
begin
  if v_uid is null then return null; end if;
  v_super := public.cms_is_super_admin();
  select jsonb_build_object(
    'user_id', u.id,
    'email', u.email,
    'name', coalesce(nullif(em.employee_name, ''), nullif(p.full_name, ''), split_part(u.email, '@', 1)),
    'is_super_admin', v_super,
    'roles', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'companies', ur.companies) order by r.rank desc)
                       from public.cms_user_roles ur join public.cms_roles r on r.code = ur.role_code
                       where ur.user_id = v_uid and ur.is_active), '[]'::jsonb),
    'permissions', (select coalesce(jsonb_object_agg(m.code, coalesce(x.acts, '')), '{}'::jsonb)
                    from public.cms_modules m
                    left join lateral (
                      select case when v_super then 'VCEADX' else string_agg(distinct l, '') end acts
                      from public.cms_user_roles ur
                      join public.cms_role_permissions rp on rp.role_code = ur.role_code and rp.module_code = m.code
                      cross join lateral regexp_split_to_table(rp.actions, '') l
                      where ur.user_id = v_uid and ur.is_active and l <> '') x on true),
    'person', case when em.id is null then null else jsonb_build_object('id', em.id, 'employee_id', em.employee_id,
                'name', em.employee_name, 'company_code', private.cms_canon(em.company_code), 'title', em.approved_job_title) end)
  into v
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.cms_user_links l on l.user_id = u.id
  left join public.employee_master em on em.id = l.employee_master_id
  where u.id = v_uid;
  return v;
end $$;

create or replace function public.cms_note_sign_in()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then return; end if;
  perform private.cms_log('auth.sign_in', 'user', auth.uid()::text, null,
    case when exists (select 1 from public.cms_user_roles where user_id = auth.uid() and is_active)
         then 'Signed in' else 'Signed in without a CMS role (no access yet)' end);
end $$;

-- dashboard figures
create or replace function public.cms_dashboard()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform private.cms_require('dashboard', 'V');
  select jsonb_build_object(
    'people', (select jsonb_build_object(
                  'active', count(*) filter (where employment_status = 'active'),
                  'onboarding', count(*) filter (where employment_status = 'onboarding'),
                  'applicants', count(*) filter (where employment_status = 'applicant'),
                  'former', count(*) filter (where employment_status = 'former'),
                  'total', count(*)) from public.employee_master),
    'active_by_employer', (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
                  select private.cms_canon(company_code) c, count(*) n from public.employee_master
                  where employment_status = 'active' group by 1) x),
    'active_by_payer', (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
                  select coalesce(pp.paying_company_code, private.cms_canon(em.company_code)) c, count(*) n
                  from public.employee_master em left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
                  where em.employment_status = 'active' group by 1) x),
    'positions', (select count(*) from public.jd_positions where status = 'approved'),
    'departments', (select count(*) from public.jd_departments),
    'applications_pending', (select count(*) from public.eaf_applications where status = 'pending'),
    'claims_pending', (select count(*) from public.all_submissions_view where deleted_at is null and status = 'submitted'),
    'claims_pending_by_form', (select coalesce(jsonb_object_agg(form_code, n), '{}'::jsonb) from (
                  select form_code, count(*) n from public.all_submissions_view
                  where deleted_at is null and status = 'submitted' group by 1) x),
    'claims_pending_amount', (select coalesce(sum(amount) filter (where coalesce(amount_unit, 'RM') in ('RM', 'MYR')), 0)
                  from public.all_submissions_view where deleted_at is null and status = 'submitted'),
    'handbook_outstanding', (select count(*) from public.handbook_assignments
                  where revoked_at is null and status in ('assigned', 'viewed')),
    'logins', (select count(*) from auth.users),
    'logins_with_role', (select count(distinct user_id) from public.cms_user_roles where is_active),
    'logins_unlinked', (select count(*) from auth.users u where not exists (select 1 from public.cms_user_links l where l.user_id = u.id)),
    'recent', case when public.cms_can('admin.audit', 'V') then (
                  select coalesce(jsonb_agg(jsonb_build_object('at', a.at, 'actor', a.actor_email, 'action', a.action,
                         'summary', a.summary) order by a.id desc), '[]'::jsonb)
                  from (select * from public.cms_audit_log order by id desc limit 8) a)
               else '[]'::jsonb end,
    'snapshot', (select jsonb_build_object('id', id, 'taken_at', taken_at, 'label', label, 'summary', summary)
                 from public.cms_schema_snapshots order by id desc limit 1))
  into v;
  return v;
end $$;

-- people list (no IC, bank or salary)
create or replace function public.cms_people()
returns table (id uuid, employee_id text, name text, company_code text, paying_company_code text, unit_code text,
               department text, job_title text, level text, status text, start_date date, last_day date,
               email text, login_email text, source_type text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform private.cms_require('people', 'V');
  return query
  select em.id, em.employee_id::text, em.employee_name::text, private.cms_canon(em.company_code),
         pp.paying_company_code, pp.unit_code, em.department::text, em.approved_job_title::text,
         split_part(coalesce(em.job_title_level, ''), '|', 1), em.employment_status::text, em.start_date,
         em.actual_last_working_date, em.email::text, u.email::text, em.source_type::text
  from public.employee_master em
  left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
  left join public.cms_user_links l on l.employee_master_id = em.id
  left join auth.users u on u.id = l.user_id
  where public.cms_can('people', 'V', em.company_code)
  order by em.employee_name;
end $$;

create or replace function public.cms_set_person_payroll(p_person uuid, p_paying_company text, p_unit text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_co text; v_name text; v_before jsonb; v_pay text := private.cms_canon(nullif(p_paying_company, ''));
        v_unit text := nullif(btrim(coalesce(p_unit, '')), '');
begin
  select private.cms_canon(company_code), employee_name into v_co, v_name from public.employee_master where id = p_person;
  if v_name is null then raise exception 'Person not found'; end if;
  perform private.cms_require('people', 'E', v_co);
  if v_pay is not null and not exists (select 1 from public.cms_companies where code = v_pay and is_active and is_paying) then
    raise exception 'Unknown or inactive paying company: %', v_pay;
  end if;
  if v_unit is not null and not exists (select 1 from public.cms_units where code = v_unit) then
    raise exception 'Unknown centre / unit: %', v_unit;
  end if;
  select to_jsonb(pp) - 'employee_master_id' into v_before from public.cms_employee_payroll pp where employee_master_id = p_person;
  if v_pay is null and v_unit is null then
    delete from public.cms_employee_payroll where employee_master_id = p_person;
  else
    insert into public.cms_employee_payroll (employee_master_id, paying_company_code, unit_code, note, updated_by, updated_at)
    values (p_person, v_pay, v_unit, nullif(p_note, ''), auth.uid(), now())
    on conflict (employee_master_id) do update set paying_company_code = excluded.paying_company_code,
      unit_code = excluded.unit_code, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  end if;
  perform private.cms_log('person.payroll', 'employee_master', p_person::text, v_co,
    v_name || ': paying company ' || coalesce(v_pay, 'same as employer') || ', centre ' || coalesce(v_unit, '—'),
    jsonb_build_object('before', v_before, 'after', jsonb_build_object('paying_company_code', v_pay, 'unit_code', v_unit, 'note', p_note)));
end $$;

-- organisation
create or replace function public.cms_org()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not (public.cms_can('org', 'V') or public.cms_can('admin.companies', 'V')) then
    perform private.cms_require('org', 'V');
  end if;
  return jsonb_build_object(
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'short_name', c.short_name,
        'is_active', c.is_active, 'is_paying', c.is_paying, 'aliases', c.aliases, 'logo', c.logo, 'note', c.note,
        'employed', (select count(*) from public.employee_master em where em.employment_status = 'active' and private.cms_canon(em.company_code) = c.code),
        'paid', (select count(*) from public.employee_master em left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
                 where em.employment_status = 'active' and coalesce(pp.paying_company_code, private.cms_canon(em.company_code)) = c.code),
        'jd_departments', (select count(*) from public.jd_departments d join public.jd_entities e on e.id = d.entity_id where e.code = c.code),
        'jd_positions', (select count(*) from public.jd_positions p join public.jd_entities e on e.id = p.entity_id where e.code = c.code and p.status = 'approved'))
        order by c.sort_order), '[]'::jsonb) from public.cms_companies c),
    'units', (select coalesce(jsonb_agg(to_jsonb(u) order by u.sort_order), '[]'::jsonb) from public.cms_units u),
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('company', e.code, 'name', d.name,
        'positions', (select count(*) from public.jd_positions p where p.department_id = d.id and p.status = 'approved'))
        order by e.code, d.name), '[]'::jsonb)
        from public.jd_departments d join public.jd_entities e on e.id = d.entity_id));
end $$;

-- suggested roles for one login: from MEG-EAF V2, MEG-FORMS and the person's JD position
create or replace function private.cms_suggestions(p_uid uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with person as (
    (select em.* from public.cms_user_links l join public.employee_master em on em.id = l.employee_master_id where l.user_id = p_uid)
    union all
    (select em.* from public.employee_master em join auth.users u on lower(u.email) = lower(em.email)
      where u.id = p_uid and not exists (select 1 from public.cms_user_links where user_id = p_uid) limit 1)
  ),
  pos as (
    select p.job_title, p.level, d.name dept, e.code entity
    from person
    join public.jd_entities e on e.code = private.cms_canon(person.company_code)
    join public.jd_positions p on p.entity_id = e.id and p.status = 'approved'
      and lower(btrim(p.job_title)) = lower(btrim(coalesce(person.approved_job_title,
          nullif(split_part(person.job_title_level, '|', 2), ''))))
    left join public.jd_departments d on d.id = p.department_id
    limit 1
  ),
  s as (
    select 'super_admin'::text r, null::text[] cos, 'Super Admin in MEG-EAF V2'::text why
      from public.eaf_v2_staff_permissions where user_id = p_uid and is_super_admin
    union all
    select 'admin', null, 'Admin in MEG-EAF V2'
      from public.eaf_v2_staff_permissions where user_id = p_uid and is_admin and not coalesce(is_super_admin, false)
    union all
    select 'hr', null, 'HR access in MEG-EAF V2'
      from public.eaf_v2_staff_permissions where user_id = p_uid and not coalesce(is_admin, false)
       and not coalesce(is_super_admin, false) and (coalesce(can_access_hr, false) or coalesce(can_view_applications, false))
    union all
    select 'payroll', null, 'Read-only payroll access in MEG-EAF V2'
      from public.eaf_v2_staff_permissions where user_id = p_uid and coalesce(can_view_only, false)
    union all
    select 'admin', null, 'Admin of ' || string_agg(upper(form_code), ', ' order by form_code) || ' in MEG-FORMS'
      from public.form_permissions where user_id = p_uid and coalesce(is_admin, false) having count(*) > 0
    union all
    select 'finance', null, 'Marks claims paid in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and (coalesce(can_mark_paid, false) or coalesce(can_finance, false)) having count(*) > 0
    union all
    select 'payroll', null, 'Payroll / Account processing in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and coalesce(can_view, false) and not coalesce(can_submit, false) having count(*) > 0
    union all
    select 'approver',
      case when bool_or(coalesce(approval_scope, '') not in ('myeden', 'hds', 'abn')) then null
           else array(select distinct x from public.form_permissions f2,
                      unnest(case f2.approval_scope when 'myeden' then array['MEG', 'MEH'] when 'hds' then array['HD'] when 'abn' then array['ABP'] end) x
                      where f2.user_id = p_uid and f2.can_approve) end,
      'Approves claims in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and coalesce(can_approve, false) having count(*) > 0
    union all
    select r.role_code, case when r.scope = 'own_company' then array[pos.entity] end,
           'JD position: ' || pos.job_title || ' (' || pos.level || ', ' || coalesce(pos.dept, '—') || ')'
      from pos join public.cms_position_role_rules r
        on (r.entity_code is null or r.entity_code = pos.entity)
       and (r.department_name is null or r.department_name = pos.dept)
       and nullif(regexp_replace(pos.level, '\D', '', 'g'), '')::int >= r.min_level
    union all
    select 'staff', array[pos.entity], 'JD position: ' || pos.job_title || ' (' || pos.level || ')' from pos
  )
  select coalesce(jsonb_agg(distinct jsonb_build_object('role', s.r, 'companies', s.cos, 'reason', s.why)), '[]'::jsonb)
  from s
  where not exists (select 1 from public.cms_user_roles ur where ur.user_id = p_uid and ur.role_code = s.r and ur.is_active);
$$;

-- every login with roles, linked person and suggestions
create or replace function public.cms_users()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform private.cms_require('admin.roles', 'V');
  select coalesce(jsonb_agg(x.j order by x.has_role desc, x.nm), '[]'::jsonb) into v
  from (
    select exists (select 1 from public.cms_user_roles ur where ur.user_id = u.id and ur.is_active) has_role,
           lower(coalesce(nullif(p.full_name, ''), em.employee_name, u.email)) nm,
           jsonb_build_object(
             'id', u.id, 'email', u.email,
             'name', coalesce(nullif(p.full_name, ''), em.employee_name, split_part(u.email, '@', 1)),
             'profile_status', p.status, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
             'roles', coalesce((select jsonb_agg(jsonb_build_object('code', ur.role_code, 'companies', ur.companies,
                         'granted_at', ur.granted_at, 'note', ur.note) order by r.rank desc)
                       from public.cms_user_roles ur join public.cms_roles r on r.code = ur.role_code
                       where ur.user_id = u.id and ur.is_active), '[]'::jsonb),
             'person', case when em.id is null then null else jsonb_build_object('id', em.id, 'employee_id', em.employee_id,
                         'name', em.employee_name, 'company_code', private.cms_canon(em.company_code),
                         'title', em.approved_job_title, 'status', em.employment_status) end,
             'suggested_person', case when em.id is not null then null else (
                         select jsonb_build_object('id', e2.id, 'employee_id', e2.employee_id, 'name', e2.employee_name,
                                'company_code', private.cms_canon(e2.company_code))
                         from public.employee_master e2
                         where lower(e2.email) = lower(u.email)
                           and not exists (select 1 from public.cms_user_links l2 where l2.employee_master_id = e2.id)
                         limit 1) end,
             'suggestions', private.cms_suggestions(u.id)) j
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join public.cms_user_links l on l.user_id = u.id
    left join public.employee_master em on em.id = l.employee_master_id
  ) x;
  return v;
end $$;

-- people a login can be linked to (picker)
create or replace function public.cms_link_candidates()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('admin.roles', 'E');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name,
            'company_code', private.cms_canon(em.company_code), 'status', em.employment_status, 'title', em.approved_job_title)
            order by em.employee_name), '[]'::jsonb)
          from public.employee_master em
          where not exists (select 1 from public.cms_user_links l where l.employee_master_id = em.id));
end $$;

create or replace function public.cms_grant_role(p_user uuid, p_role text, p_companies text[] default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text; v_cos text[]; v_bad text;
begin
  perform private.cms_require_super_admin();
  select email into v_email from auth.users where id = p_user;
  if v_email is null then raise exception 'Login not found'; end if;
  if not exists (select 1 from public.cms_roles where code = p_role) then raise exception 'Unknown role: %', p_role; end if;
  if p_companies is not null and cardinality(p_companies) > 0 then
    select array_agg(distinct private.cms_canon(c)) into v_cos from unnest(p_companies) c;
    select c into v_bad from unnest(v_cos) c where not exists (select 1 from public.cms_companies where code = c) limit 1;
    if v_bad is not null then raise exception 'Unknown company: %', v_bad; end if;
  end if;
  if p_role = 'super_admin' then v_cos := null; end if;
  insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_by, granted_at, revoked_by, revoked_at)
  values (p_user, p_role, v_cos, true, nullif(p_note, ''), auth.uid(), now(), null, null)
  on conflict (user_id, role_code) do update set companies = excluded.companies, is_active = true, note = excluded.note,
    granted_by = excluded.granted_by, granted_at = now(), revoked_by = null, revoked_at = null;
  perform private.cms_log('role.grant', 'user', p_user::text, null,
    'Granted ' || (select name from public.cms_roles where code = p_role) || ' to ' || v_email
      || coalesce(' for ' || array_to_string(v_cos, ', '), ' (all companies)'),
    jsonb_build_object('role', p_role, 'companies', v_cos, 'note', p_note));
end $$;

create or replace function public.cms_revoke_role(p_user uuid, p_role text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text;
begin
  perform private.cms_require_super_admin();
  select email into v_email from auth.users where id = p_user;
  if p_role = 'super_admin' and (select count(*) from public.cms_user_roles where role_code = 'super_admin' and is_active and user_id <> p_user) = 0 then
    raise exception 'This is the last Super Admin. Grant Super Admin to someone else first.';
  end if;
  update public.cms_user_roles set is_active = false, revoked_by = auth.uid(), revoked_at = now(),
         note = coalesce(nullif(p_note, ''), note)
   where user_id = p_user and role_code = p_role and is_active;
  if not found then raise exception 'That login does not hold this role'; end if;
  perform private.cms_log('role.revoke', 'user', p_user::text, null,
    'Removed ' || (select name from public.cms_roles where code = p_role) || ' from ' || coalesce(v_email, p_user::text),
    jsonb_build_object('role', p_role, 'note', p_note));
end $$;

create or replace function public.cms_link_user(p_user uuid, p_person uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text; v_name text; v_before uuid; v_other text;
begin
  perform private.cms_require('admin.roles', 'E');
  select email into v_email from auth.users where id = p_user;
  if v_email is null then raise exception 'Login not found'; end if;
  select employee_master_id into v_before from public.cms_user_links where user_id = p_user;
  if p_person is null then
    delete from public.cms_user_links where user_id = p_user;
    perform private.cms_log('user.unlink', 'user', p_user::text, null, 'Unlinked ' || v_email || ' from its person record',
      jsonb_build_object('before', v_before));
    return;
  end if;
  select employee_name into v_name from public.employee_master where id = p_person;
  if v_name is null then raise exception 'Person not found'; end if;
  select u.email into v_other from public.cms_user_links l join auth.users u on u.id = l.user_id
   where l.employee_master_id = p_person and l.user_id <> p_user;
  if v_other is not null then raise exception '% is already linked to %', v_name, v_other; end if;
  insert into public.cms_user_links (user_id, employee_master_id, method, linked_by, linked_at)
  values (p_user, p_person,
          case when exists (select 1 from public.employee_master where id = p_person and lower(email) = lower(v_email)) then 'email_match' else 'manual' end,
          auth.uid(), now())
  on conflict (user_id) do update set employee_master_id = excluded.employee_master_id, method = excluded.method,
    linked_by = excluded.linked_by, linked_at = now();
  perform private.cms_log('user.link', 'user', p_user::text, null, 'Linked ' || v_email || ' to ' || v_name,
    jsonb_build_object('before', v_before, 'after', p_person));
end $$;

-- roles × modules grid
create or replace function public.cms_roles_matrix()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('admin.roles', 'V');
  return jsonb_build_object(
    'roles', (select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'description', r.description,
                'rank', r.rank, 'phase', r.phase,
                'users', (select count(*) from public.cms_user_roles ur where ur.role_code = r.code and ur.is_active))
                order by r.rank desc) from public.cms_roles r),
    'modules', (select jsonb_agg(to_jsonb(m) order by m.sort_order) from public.cms_modules m),
    'permissions', (select coalesce(jsonb_object_agg(r.code, (select coalesce(jsonb_object_agg(rp.module_code, rp.actions), '{}'::jsonb)
                      from public.cms_role_permissions rp where rp.role_code = r.code)), '{}'::jsonb) from public.cms_roles r),
    'rules', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from public.cms_position_role_rules x));
end $$;

create or replace function public.cms_set_permission(p_role text, p_module text, p_actions text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_new text := ''; v_old text; l text;
begin
  perform private.cms_require_super_admin();
  if p_role = 'super_admin' then raise exception 'Super Admin always has every permission'; end if;
  if not exists (select 1 from public.cms_roles where code = p_role) then raise exception 'Unknown role: %', p_role; end if;
  if not exists (select 1 from public.cms_modules where code = p_module) then raise exception 'Unknown module: %', p_module; end if;
  foreach l in array array['V', 'C', 'E', 'A', 'D', 'X'] loop
    if strpos(upper(coalesce(p_actions, '')), l) > 0 then v_new := v_new || l; end if;
  end loop;
  if v_new <> '' and strpos(v_new, 'V') = 0 then v_new := 'V' || v_new; end if;   -- any action needs view
  select actions into v_old from public.cms_role_permissions where role_code = p_role and module_code = p_module;
  insert into public.cms_role_permissions (role_code, module_code, actions) values (p_role, p_module, v_new)
  on conflict (role_code, module_code) do update set actions = excluded.actions;
  perform private.cms_log('permission.set', 'role', p_role, null,
    (select name from public.cms_roles where code = p_role) || ' · ' || (select label from public.cms_modules where code = p_module)
      || ': ' || coalesce(nullif(v_old, ''), 'none') || ' → ' || coalesce(nullif(v_new, ''), 'none'),
    jsonb_build_object('module', p_module, 'before', v_old, 'after', v_new));
  return v_new;
end $$;

-- audit log viewer
create or replace function public.cms_audit(p_limit int default 50, p_before bigint default null, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('admin.audit', 'V');
  return (select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]'::jsonb) from (
    select id, at, actor_email, action, entity, entity_id, company_code, summary, details
    from public.cms_audit_log
    where (p_before is null or id < p_before)
      and (nullif(btrim(coalesce(p_search, '')), '') is null
           or summary ilike '%' || p_search || '%' or action ilike '%' || p_search || '%'
           or coalesce(actor_email, '') ilike '%' || p_search || '%')
    order by id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)) a);
end $$;

-- export everything (Super Admin): list tables, then fetch each one
create or replace function public.cms_export_tables()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v jsonb := '[]'::jsonb; n bigint;
begin
  perform private.cms_require_super_admin();
  for r in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
           where s.nspname = 'public' and c.relkind in ('r', 'p')
             and not exists (select 1 from pg_depend dp where dp.objid = c.oid and dp.deptype = 'e')
           order by c.relname loop
    execute format('select count(*) from public.%I', r.relname) into n;
    v := v || jsonb_build_array(jsonb_build_object('table', r.relname, 'rows', n));
  end loop;
  perform private.cms_log('export.start', 'database', null, null,
    'Started a full export (' || jsonb_array_length(v) || ' tables)', jsonb_build_object('tables', jsonb_array_length(v)));
  return v;
end $$;

create or replace function public.cms_export_table(p_table text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform private.cms_require_super_admin();
  if not exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                 where s.nspname = 'public' and c.relkind in ('r', 'p') and c.relname = p_table) then
    raise exception 'Unknown table: %', p_table;
  end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', p_table) into v;
  return v;
end $$;

create or replace function public.cms_export_done(p_format text, p_tables int, p_rows bigint)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require_super_admin();
  perform private.cms_log('export.done', 'database', null, null,
    'Downloaded a full export as ' || coalesce(p_format, '?') || ' (' || p_tables || ' tables, ' || p_rows || ' rows)',
    jsonb_build_object('format', p_format, 'tables', p_tables, 'rows', p_rows));
end $$;

-- ============================================================ 8. lock down
do $$
declare t text; f record;
begin
  foreach t in array array['cms_schema_snapshots', 'cms_companies', 'cms_units', 'cms_modules', 'cms_roles',
    'cms_role_permissions', 'cms_user_roles', 'cms_user_links', 'cms_employee_payroll', 'cms_position_role_rules', 'cms_audit_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;
  for f in select p.oid::regprocedure sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where p.proname like 'cms\_%' and n.nspname in ('public', 'private') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.nspname = 'public' then execute format('grant execute on function %s to authenticated', f.sig);
    else execute format('revoke all on function %s from authenticated', f.sig); end if;
  end loop;
end $$;

-- ============================================================ 9. first Super Admin
-- The existing MEG-EAF V2 Super Admin becomes the CMS Super Admin, so someone can sign in and grant the rest.
insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_at)
select user_id, 'super_admin', null, true, 'Carried over from MEG-EAF V2 Super Admin (Phase 0 setup)', now()
from public.eaf_v2_staff_permissions where is_super_admin
on conflict do nothing;

insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'Phase 0 foundation installed (v2026.10.17-13:30)',
        jsonb_build_object('snapshot_id', (select max(id) from public.cms_schema_snapshots),
                           'super_admins', (select count(*) from public.cms_user_roles where role_code = 'super_admin')));

notify pgrst, 'reload schema';
