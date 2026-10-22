-- MyEden Group CMS V1.0 · Complete permission list, defaults, per-person permissions, custom roles
-- * cms_modules becomes the full catalogue: every section with a description and only the actions that apply to it,
--   plus "special permissions" (one switch each, granted as V) for single actions such as approving letters or marking
--   a claim as paid. Specials marked phase 6 are listed now and take effect when payroll moves into the CMS.
-- * Today's settings are saved as each role's default; "Reset to default" puts them back.
-- * Per-person permissions: extra permissions for one login on top of their roles.
-- * Roles: Admin and Super Admin grant roles and change permissions; Admin can create roles (copied from another role).
--   Super Admin only: locked sections, the Super Admin and Admin roles, granting Super Admin.
-- * Account Viewer (new) and Payroll Viewer (the old Account / Payroll Viewer, renamed) are separate roles.

-- ------------------------------------------------------------------ catalogue columns
alter table public.cms_modules
  add column if not exists description text,
  add column if not exists acts text not null default 'VCEADX',
  add column if not exists kind text not null default 'section',
  add column if not exists parent text,
  add column if not exists act_labels jsonb not null default '{}'::jsonb,
  add column if not exists from_phase int;

alter table public.cms_roles
  add column if not exists is_system boolean not null default true,
  add column if not exists created_by uuid,
  add column if not exists created_at timestamptz default now();

-- sections: what each one covers and which actions apply
update public.cms_modules m set description = x.d, acts = x.a, act_labels = x.l::jsonb from (values
  ('dashboard', 'Home page, tasks and the bell', 'V', '{}'),
  ('people', 'Employee Master: people list, person pages, add person, leaving and rehire', 'VCEAX', '{"C":"Add people","E":"Edit person details, leaving dates","A":"Confirm a person has left, rehire","X":"Export people"}'),
  ('org', 'Organisation structure: companies, centres, departments', 'VCE', '{}'),
  ('documents', 'Employee documents: contracts, IC copies, certificates, signed letters', 'VCEX', '{"C":"Upload","E":"Replace and remove","X":"Export"}'),
  ('selfservice', 'Self-service access page and who each person reports to', 'VE', '{"E":"Set who each person reports to"}'),
  ('jd', 'Job Description Manual', 'V', '{}'),
  ('recruitment', 'Positions, applications, shortlist and interviews', 'VCE', '{"E":"Move applications, edit positions"}'),
  ('onboarding', 'Offers and onboarding: hiring accepted applicants', 'VCE', '{"E":"Hire and link applications"}'),
  ('handbook', 'Employee Handbook and who has read it', 'VCE', '{}'),
  ('leave', 'Leave requests from self-service', 'VCEA', '{"E":"Manage requests, mark as entered in payroll","A":"Approve leave"}'),
  ('overtime', 'Overtime claims (OTCF)', 'VCEAX', '{"C":"Submit own claims","E":"Process claims","A":"Approve or disapprove","X":"Export"}'),
  ('scf', 'Staff claims (SCF)', 'VCEAX', '{"C":"Submit own claims","E":"Process claims, see bank details","A":"Approve or disapprove","X":"Export"}'),
  ('mtcf', 'Mileage claims (MTCF)', 'VCEAX', '{"C":"Submit own claims","E":"Process claims, see bank details","A":"Approve or disapprove","X":"Export"}'),
  ('tec', 'Teacher tuition claims (TEC)', 'VCEAX', '{"C":"Submit own claims","E":"Process claims, see bank details","A":"Approve or disapprove","X":"Export"}'),
  ('prfaf', 'Purchase and funding requests (PRFAF)', 'VCEAX', '{"C":"Submit own requests","E":"Process requests","A":"Approve or disapprove","X":"Export"}'),
  ('payroll', 'Payroll: monthly payroll, payslips and reports, loans, final settlement (MyPayroll until Phase 6)', 'VCEX', '{"C":"Create payroll months","E":"Edit payroll (also gives MyPayroll access)","X":"Export"}'),
  ('payroll.paying', 'Paying companies: which company pays each person', 'VCE', '{}'),
  ('payroll.increments', 'Increments and salary reviews', 'VCEA', '{"C":"Record increments","E":"Set review dates","A":"Change review intervals"}'),
  ('payroll.settings', 'Payroll settings: pick-lists, payment types, statutory tables, holidays, policies', 'VCE', '{}'),
  ('performance', 'KPI and appraisals, probation reviews', 'VCEA', '{"E":"Start and fill appraisals","A":"Approve appraisals"}'),
  ('training', 'Training and certificates', 'VCEA', '{"E":"Record training, verify certificates","A":"Manage certificate types"}'),
  ('careers', 'Career paths and salary caps (view)', 'VCE', '{"E":"Place people on JD positions"}'),
  ('assets', 'Items and hand-over', 'VCEA', '{"E":"Issue items, open hand-overs","A":"Manage item types"}'),
  ('letters', 'HR letters: the register of letters', 'VE', '{"E":"Cancel letters, change other people''s drafts"}'),
  ('hrlaw', 'Employment Act and calculators', 'V', '{}'),
  ('approvals', 'Approvals and workflows', 'VA', '{}'),
  ('reports', 'Reports and analytics', 'VX', '{"X":"Export CSV"}'),
  ('admin.roles', 'Users, roles and access page (see who has which role)', 'V', '{}'),
  ('admin.companies', 'Companies and settings', 'VCE', '{}'),
  ('admin.audit', 'Audit log', 'V', '{}'),
  ('admin.export', 'Export all data', 'V', '{}')
) x(c, d, a, l) where m.code = x.c;

-- special permissions (granted = V)
insert into public.cms_modules (code, label, grp, phase, sort_order, kind, parent, acts, description, from_phase, locked) values
  ('people.ic', 'See IC and passport numbers', 'People & Employment', 6, 1001, 'special', 'people', 'V', 'Full IC / passport numbers on person and payroll pages', 6, false),
  ('people.bank', 'See bank account details', 'People & Employment', 6, 1002, 'special', 'people', 'V', 'Bank name and account number on person and payroll pages', 6, false),
  ('people.salary', 'See salaries', 'People & Employment', 6, 1003, 'special', 'people', 'V', 'Basic salary and pay on person and payroll pages', 6, false),
  ('people.eid', 'Change Employee ID', 'People & Employment', 6, 1004, 'special', 'people', 'V', 'Give or change a person''s Employee ID', 6, false),
  ('people.link', 'Link logins to people', 'People & Employment', 0, 1005, 'special', 'people', 'V', 'Connect a sign-in to a person in the Employee Master', null, false),
  ('payroll.prepare', 'Prepare monthly payroll', 'Payroll', 6, 1010, 'special', 'payroll', 'V', 'Create and edit a payroll month', 6, false),
  ('payroll.finalise', 'Finalise payroll', 'Payroll', 6, 1011, 'special', 'payroll', 'V', 'Lock a payroll month as final', 6, false),
  ('payroll.reopen', 'Reopen a finalised month', 'Payroll', 6, 1012, 'special', 'payroll', 'V', 'Unlock a finalised payroll month', 6, false),
  ('payroll.release', 'Release payslips and EA forms to staff', 'Payroll', 4, 1013, 'special', 'payroll', 'V', 'Choose which months'' payslips and which years'' EA forms each person can see', null, false),
  ('scf.pay', 'Mark staff claims as paid', 'Forms & Claims', 1, 1020, 'special', 'scf', 'V', 'Record that an approved SCF claim was paid', null, false),
  ('mtcf.pay', 'Mark mileage claims as paid', 'Forms & Claims', 1, 1021, 'special', 'mtcf', 'V', 'Record that an approved MTCF claim was paid', null, false),
  ('tec.pay', 'Mark tuition claims as paid', 'Forms & Claims', 1, 1022, 'special', 'tec', 'V', 'Record that an approved TEC claim was paid', null, false),
  ('prfaf.pay', 'Mark purchase / funding as paid', 'Forms & Claims', 1, 1023, 'special', 'prfaf', 'V', 'Record that an approved PRFAF request was paid', null, false),
  ('overtime.pay', 'Mark overtime claims as paid', 'Time & Leave', 1, 1024, 'special', 'overtime', 'V', 'Record that an approved OTCF claim was paid', null, false),
  ('letters.draft', 'Draft HR letters', 'Operations', 5, 1030, 'special', 'letters', 'V', 'Draft letters and send them for approval', null, false),
  ('letters.approve', 'Approve HR letters', 'Operations', 5, 1031, 'special', 'letters', 'V', 'Approve or send back letters drafted by someone else', null, false),
  ('letters.issue', 'Issue approved letters', 'Operations', 5, 1032, 'special', 'letters', 'V', 'Issue an approved letter to the person', null, false),
  ('letters.templates', 'Manage letter templates', 'Operations', 5, 1033, 'special', 'letters', 'V', 'Create, change, import from Word and ask to retire templates', null, false),
  ('letters.publish', 'Publish letter templates', 'Operations', 5, 1034, 'special', 'letters', 'V', 'Approve new and changed templates and retirements (own ones too)', null, false),
  ('letters.switch', 'Switch templates on / off', 'Operations', 5, 1035, 'special', 'letters', 'V', 'Choose which published templates can be used', null, false),
  ('letters.placeholders', 'Manage placeholders', 'Operations', 5, 1036, 'special', 'letters', 'V', 'Create and change letter placeholders', null, false),
  ('selfservice.parts', 'Switch on self-service parts', 'People & Employment', 4, 1040, 'special', 'selfservice', 'V', 'Choose which My pages each person can use', null, false),
  ('selfservice.profile', 'Approve profile changes', 'People & Employment', 4, 1041, 'special', 'selfservice', 'V', 'Approve or reject changes staff send from My Profile', null, false),
  ('assets.handover', 'Approve hand-overs', 'Operations', 5, 1050, 'special', 'assets', 'V', 'Approve or cancel an off-boarding hand-over', null, false),
  ('admin.grant', 'Grant and remove roles', 'Administration', 0, 1060, 'special', 'admin.roles', 'V', 'Give logins roles (never Super Admin) and per-person permissions', null, true),
  ('admin.permissions', 'Change permissions and roles', 'Administration', 0, 1061, 'special', 'admin.roles', 'V', 'Change what each role can do, create roles, reset to default', null, true)
on conflict (code) do update set label = excluded.label, kind = 'special', parent = excluded.parent, acts = 'V', description = excluded.description, from_phase = excluded.from_phase;
update public.cms_modules set kind = 'special', parent = 'careers', acts = 'V', label = 'Set MyEden salary caps', description = 'Set and change the MyEden cap beside each JD salary range' where code = 'careers.caps';

-- defaults for the specials, from what each role can do today
insert into public.cms_role_permissions (role_code, module_code, actions)
select r.code, s.code, 'V' from public.cms_roles r cross join (values
  ('people.link', 'admin.roles', 'E'), ('payroll.release', 'selfservice', 'E'), ('selfservice.parts', 'selfservice', 'E'), ('selfservice.profile', 'selfservice', 'E'),
  ('scf.pay', 'scf', 'E'), ('mtcf.pay', 'mtcf', 'E'), ('tec.pay', 'tec', 'E'), ('prfaf.pay', 'prfaf', 'E'), ('overtime.pay', 'overtime', 'E'),
  ('letters.draft', 'letters', 'C'), ('letters.approve', 'letters', 'A'), ('letters.templates', 'letters', 'E'), ('letters.publish', 'letters', 'A'),
  ('letters.switch', 'letters', 'A'), ('letters.placeholders', 'letters', 'E'), ('assets.handover', 'assets', 'E'), ('admin.permissions', 'admin.roles', 'E'),
  ('admin.grant', 'admin.roles', 'E'), ('payroll.prepare', 'payroll', 'E'), ('payroll.finalise', 'payroll', 'E'), ('people.eid', 'people', 'E'),
  ('people.salary', 'payroll.increments', 'V'), ('people.ic', 'payroll', 'E'), ('people.bank', 'payroll', 'E')) s(code, src, act)
where r.code <> 'super_admin' and exists (select 1 from public.cms_role_permissions p where p.role_code = r.code and p.module_code = s.src and strpos(p.actions, s.act) > 0)
on conflict (role_code, module_code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions)
select r.code, 'letters.issue', 'V' from public.cms_roles r
where r.code <> 'super_admin' and exists (select 1 from public.cms_role_permissions p where p.role_code = r.code and p.module_code = 'letters' and (strpos(p.actions, 'C') > 0 or strpos(p.actions, 'A') > 0))
on conflict (role_code, module_code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values ('admin', 'payroll.reopen', 'V') on conflict (role_code, module_code) do nothing;
update public.cms_role_permissions set actions = 'V' where module_code = 'careers.caps' and actions <> '';

-- ------------------------------------------------------------------ Account Viewer and Payroll Viewer
update public.cms_roles set name = 'Payroll Viewer', description = 'Sees payroll, paying companies, increments, payroll settings, people, leave and reports. Cannot change, approve or export anything.' where code = 'payroll_viewer';
update public.cms_role_permissions set actions = '' where role_code = 'payroll_viewer' and module_code not in ('dashboard','hrlaw','payroll','payroll.paying','payroll.settings','payroll.increments','people','org','leave','overtime','reports','people.salary');
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('payroll_viewer', 'dashboard', 'V'), ('payroll_viewer', 'hrlaw', 'V'), ('payroll_viewer', 'payroll', 'V'), ('payroll_viewer', 'payroll.paying', 'V'),
  ('payroll_viewer', 'payroll.settings', 'V'), ('payroll_viewer', 'payroll.increments', 'V'), ('payroll_viewer', 'people', 'V'), ('payroll_viewer', 'org', 'V'),
  ('payroll_viewer', 'leave', 'V'), ('payroll_viewer', 'overtime', 'V'), ('payroll_viewer', 'reports', 'V'), ('payroll_viewer', 'people.salary', 'V')
on conflict (role_code, module_code) do update set actions = excluded.actions;
insert into public.cms_roles (code, name, description, rank, phase, is_system)
values ('account_viewer', 'Account Viewer', 'Sees claims, purchase and funding, approvals, people and reports (no payroll). Cannot change, approve, pay or export anything. Give payroll viewing per person if needed.', 54, 1, true)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('account_viewer', 'dashboard', 'V'), ('account_viewer', 'hrlaw', 'V'), ('account_viewer', 'scf', 'V'), ('account_viewer', 'mtcf', 'V'), ('account_viewer', 'tec', 'V'),
  ('account_viewer', 'overtime', 'V'), ('account_viewer', 'prfaf', 'V'), ('account_viewer', 'approvals', 'V'), ('account_viewer', 'people', 'V'),
  ('account_viewer', 'org', 'V'), ('account_viewer', 'reports', 'V')
on conflict (role_code, module_code) do nothing;

-- ------------------------------------------------------------------ defaults (today's settings)
create table if not exists public.cms_role_permission_defaults (
  role_code text not null references public.cms_roles(code) on delete cascade,
  module_code text not null references public.cms_modules(code) on delete cascade,
  actions text not null default '',
  primary key (role_code, module_code));
alter table public.cms_role_permission_defaults enable row level security;
insert into public.cms_role_permission_defaults (role_code, module_code, actions)
select role_code, module_code, actions from public.cms_role_permissions where actions <> ''
on conflict (role_code, module_code) do update set actions = excluded.actions;

-- ------------------------------------------------------------------ per-person permissions
create table if not exists public.cms_user_permissions (
  user_id uuid not null references auth.users(id) on delete cascade,
  module_code text not null references public.cms_modules(code) on delete cascade,
  actions text not null,
  companies text[],
  note text,
  granted_by uuid, granted_at timestamptz not null default now(),
  primary key (user_id, module_code));
alter table public.cms_user_permissions enable row level security;

create or replace function public.cms_can(p_module text, p_action text default 'V', p_company text default null)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (
    public.cms_is_super_admin()
    or exists (select 1 from public.cms_user_roles ur
               join public.cms_role_permissions rp on rp.role_code = ur.role_code
               where ur.user_id = auth.uid() and ur.is_active and rp.module_code = p_module
                 and strpos(rp.actions, upper(p_action)) > 0
                 and (p_company is null or ur.companies is null or private.cms_canon(p_company) = any(ur.companies)))
    or exists (select 1 from public.cms_user_permissions up
               where up.user_id = auth.uid() and up.module_code = p_module and strpos(up.actions, upper(p_action)) > 0
                 and (p_company is null or up.companies is null or private.cms_canon(p_company) = any(up.companies))));
$$;

-- ================================================================== functions
alter table public.cms_roles add column if not exists archived_at timestamptz;
-- ------------------------------------------------------------------ the specials take over from the section actions
do $m$ declare r record; d text; n text; a text[]; i int;
begin
  for r in select * from (values
    ('public.cms_letter_decide(uuid, boolean, text)', array[$x$'letters', 'A'$x$, $x$'letters.approve', 'V'$x$]),
    ('public.cms_letter_issue(uuid, text)', array[$x$'letters', 'C'$x$, $x$'letters.issue', 'V'$x$, $x$'letters', 'A'$x$, $x$'letters.issue', 'V'$x$]),
    ('public.cms_letter_save(jsonb)', array[$x$'letters', 'C'$x$, $x$'letters.draft', 'V'$x$]),
    ('public.cms_letter_template_save(jsonb)', array[$x$'letters', 'A'$x$, $x$'letters.publish', 'V'$x$, $x$'letters', 'C'$x$, $x$'letters.templates', 'V'$x$, $x$'letters', 'E'$x$, $x$'letters.templates', 'V'$x$]),
    ('public.cms_letter_template_review(text, boolean, text)', array[$x$'letters', 'A'$x$, $x$'letters.publish', 'V'$x$]),
    ('public.cms_letter_template_switch(text, boolean)', array[$x$'letters', 'A'$x$, $x$'letters.switch', 'V'$x$]),
    ('public.cms_letter_template_retire(text, text)', array[$x$'letters', 'E'$x$, $x$'letters.templates', 'V'$x$, $x$'letters', 'A'$x$, $x$'letters.publish', 'V'$x$]),
    ('public.cms_letter_placeholder_save(jsonb)', array[$x$'letters', 'E'$x$, $x$'letters.placeholders', 'V'$x$]),
    ('public.cms_letters()', array[$x$'can_issue', public.cms_can('letters', 'C') or public.cms_can('letters', 'A')$x$, $x$'can_issue', public.cms_can('letters.issue', 'V')$x$,
                                    $x$'can_edit', public.cms_can('letters', 'C')$x$, $x$'can_edit', public.cms_can('letters.draft', 'V')$x$,
                                    $x$'can_change', public.cms_can('letters', 'E')$x$, $x$'can_change', public.cms_can('letters.templates', 'V'), 'can_publish', public.cms_can('letters.publish', 'V'), 'can_switch', public.cms_can('letters.switch', 'V'), 'can_placeholders', public.cms_can('letters.placeholders', 'V'), 'can_void', public.cms_can('letters', 'E')$x$,
                                    $x$'can_approve', public.cms_can('letters', 'A')$x$, $x$'can_approve', public.cms_can('letters.approve', 'V')$x$]),
    ('public.cms_letters_pending()', array[$x$case when public.cms_can('letters', 'C') or public.cms_can('letters', 'A') then$x$, $x$case when public.cms_can('letters.issue', 'V') then$x$,
                                    $x$'to_approve', case when public.cms_can('letters', 'A')$x$, $x$'to_approve', case when public.cms_can('letters.approve', 'V')$x$,
                                    $x$'templates_to_review', case when public.cms_can('letters', 'A')$x$, $x$'templates_to_review', case when public.cms_can('letters.publish', 'V')$x$]),
    ('public.cms_link_user(uuid, uuid)', array[$x$'admin.roles', 'E'$x$, $x$'people.link', 'V'$x$]),
    ('public.cms_link_candidates()', array[$x$'admin.roles', 'E'$x$, $x$'people.link', 'V'$x$]),
    ('public.cms_self_set(uuid[], text, boolean)', array[$x$'selfservice', 'E'$x$, $x$'selfservice.parts', 'V'$x$]),
    ('public.cms_self_release(uuid[], text, date, boolean)', array[$x$'selfservice', 'E'$x$, $x$'payroll.release', 'V'$x$]),
    ('public.cms_profile_decide(uuid, boolean, text)', array[$x$'selfservice', 'E'$x$, $x$'selfservice.profile', 'V'$x$]),
    ('public.cms_handover_approve(uuid, text, boolean)', array[$x$'assets', 'E'$x$, $x$'assets.handover', 'V'$x$]),
    ('public.cms_claim_paid(text, text, boolean)', array[$x$cms_require(v_mod, 'E', v_company)$x$, $x$cms_require(v_mod || '.pay', 'V', v_company)$x$]),
    ('public.cms_claim(text, text)', array[$x$'can_edit', public.cms_can(v_mod, 'E', v_company),$x$, $x$'can_edit', public.cms_can(v_mod, 'E', v_company), 'can_pay', public.cms_can(v_mod || '.pay', 'V', v_company),$x$])
  ) t(f, a) loop
    d := pg_get_functiondef(r.f::regprocedure); n := d;
    for i in 1 .. array_length(r.a, 1) / 2 loop
      if strpos(n, r.a[2 * i - 1]) = 0 then raise exception 'patch point % not found in %', r.a[2 * i - 1], r.f; end if;
      n := replace(n, r.a[2 * i - 1], r.a[2 * i]);
    end loop;
    execute n;
  end loop;
  -- the hand-over approver check and the profile-change count follow the specials too
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'cms_can_approve_handover' limit 1;
  if strpos(d, $x$'assets', 'E'$x$) > 0 then execute replace(d, $x$'assets', 'E'$x$, $x$'assets.handover', 'V'$x$); end if;
end $m$;

-- ------------------------------------------------------------------ what this login can do (roles + per-person)
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
    'extra', coalesce((select jsonb_object_agg(up.module_code, up.actions) from public.cms_user_permissions up where up.user_id = v_uid), '{}'::jsonb),
    'permissions', (select coalesce(jsonb_object_agg(m.code, coalesce(x.acts, '')), '{}'::jsonb)
                    from public.cms_modules m
                    left join lateral (
                      select case when v_super then 'VCEADX' else string_agg(distinct l, '') end acts
                      from (select rp.actions from public.cms_user_roles ur
                              join public.cms_role_permissions rp on rp.role_code = ur.role_code and rp.module_code = m.code
                             where ur.user_id = v_uid and ur.is_active
                            union all
                            select up.actions from public.cms_user_permissions up where up.user_id = v_uid and up.module_code = m.code) a
                      cross join lateral regexp_split_to_table(a.actions, '') l
                      where l <> '') x on true),
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

-- ------------------------------------------------------------------ granting roles: Admin and Super Admin
create or replace function private.cms_require_grant(p_role text, p_user uuid)
returns void language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if public.cms_is_super_admin() then return; end if;
  perform private.cms_require('admin.grant', 'V');
  if p_role in ('super_admin') then raise exception 'Only a Super Admin can give or remove the Super Admin role.' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own roles or permissions — ask a Super Admin.' using errcode = '42501'; end if;
end $$;

do $m$ declare f text; d text; n text;
begin
  foreach f in array array['public.cms_grant_role(uuid, text, text[], text)', 'public.cms_revoke_role(uuid, text, text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    n := replace(d, 'perform private.cms_require_super_admin();', 'perform private.cms_require_grant(p_role, p_user);');
    if n = d then raise exception 'patch point not found in %', f; end if;
    execute n;
  end loop;
end $m$;

-- ------------------------------------------------------------------ changing a role's permissions
create or replace function private.cms_perm_rules(p_module text, p_role text, p_user uuid)
returns public.cms_modules language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.cms_modules;
begin
  select * into m from public.cms_modules where code = p_module;
  if m.code is null then raise exception 'Unknown permission: %', p_module; end if;
  if public.cms_is_super_admin() then return m; end if;
  if m.locked then raise exception '% is locked: only a Super Admin can change it.', m.label using errcode = '42501'; end if;
  if p_role in ('super_admin', 'admin') then raise exception 'Only a Super Admin can change the % role.', (select name from public.cms_roles where code = p_role) using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own permissions — ask a Super Admin.' using errcode = '42501'; end if;
  return m;
end $$;

create or replace function private.cms_clean_actions(m public.cms_modules, p_actions text)
returns text language plpgsql immutable as $$
declare v text := ''; l text;
begin
  foreach l in array array['V', 'C', 'E', 'A', 'D', 'X'] loop
    if strpos(upper(coalesce(p_actions, '')), l) > 0 then v := v || l; end if;
  end loop;
  if m.kind = 'special' then return case when v <> '' then 'V' else '' end; end if;
  if v <> '' and strpos(v, 'V') = 0 then v := 'V' || v; end if;
  return v;
end $$;

create or replace function public.cms_permission_change(p_role text, p_module text, p_actions text, p_reason text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_new text; v_old text; m public.cms_modules;
begin
  perform private.cms_require('admin.permissions', 'V');
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason for the change.'; end if;
  if p_role = 'super_admin' then raise exception 'Super Admin always has every permission'; end if;
  if not exists (select 1 from public.cms_roles where code = p_role and archived_at is null) then raise exception 'Unknown role: %', p_role; end if;
  m := private.cms_perm_rules(p_module, p_role, null);
  v_new := private.cms_clean_actions(m, p_actions);
  if p_role = 'hr' and p_module = 'letters.approve' and v_new <> '' then
    raise exception 'HR drafts letters; approval stays with Admin, Super Admin or a Director.';
  end if;
  select actions into v_old from public.cms_role_permissions where role_code = p_role and module_code = p_module;
  if coalesce(v_old, '') = v_new then return v_new; end if;
  insert into public.cms_role_permissions (role_code, module_code, actions) values (p_role, p_module, v_new)
  on conflict (role_code, module_code) do update set actions = excluded.actions;
  perform private.cms_log('permission.set', 'role', p_role, null,
    (select name from public.cms_roles where code = p_role) || ' · ' || m.label || ': ' || coalesce(nullif(v_old, ''), 'none') || ' → ' || coalesce(nullif(v_new, ''), 'none'),
    jsonb_build_object('module', p_module, 'before', v_old, 'after', v_new, 'reason', btrim(p_reason)));
  return v_new;
end $$;

-- several changes at once: p_perms = {module: actions}
create or replace function public.cms_role_permissions_save(p_role text, p_perms jsonb, p_reason text)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; v text; n int := 0; old text;
begin
  perform private.cms_require('admin.permissions', 'V');
  for k, v in select * from jsonb_each_text(coalesce(p_perms, '{}'::jsonb)) loop
    select actions into old from public.cms_role_permissions where role_code = p_role and module_code = k;
    if coalesce(old, '') <> coalesce(private.cms_clean_actions((select m from public.cms_modules m where m.code = k), v), '') then
      perform public.cms_permission_change(p_role, k, v, p_reason); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- put a role back to its default permissions
create or replace function public.cms_role_reset(p_role text, p_reason text)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  perform private.cms_require('admin.permissions', 'V');
  for r in select m.code, m.locked, coalesce(d.actions, '') dflt, coalesce(p.actions, '') cur
             from public.cms_modules m
             left join public.cms_role_permission_defaults d on d.role_code = p_role and d.module_code = m.code
             left join public.cms_role_permissions p on p.role_code = p_role and p.module_code = m.code
            where coalesce(d.actions, '') <> coalesce(p.actions, '') loop
    if r.locked and not public.cms_is_super_admin() then continue; end if;
    perform public.cms_permission_change(p_role, r.code, r.dflt, coalesce(nullif(btrim(p_reason), ''), 'Reset to default'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- create a role (copied from another) or change a role's name / description
create or replace function public.cms_role_save(p jsonb)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare c text := nullif(p->>'code', ''); nm text := nullif(btrim(p->>'name'), ''); src text := nullif(p->>'copy_from', ''); rk int;
begin
  perform private.cms_require('admin.permissions', 'V');
  if nm is null then raise exception 'Give the role a name.'; end if;
  if c is null then
    c := 'c_' || trim(both '_' from regexp_replace(lower(nm), '[^a-z0-9]+', '_', 'g'));
    if length(c) < 3 then raise exception 'Use letters or numbers in the role name.'; end if;
    if exists (select 1 from public.cms_roles where (code = c or lower(name) = lower(nm)) and archived_at is null) then raise exception 'A role with that name already exists.'; end if;
    if src = 'super_admin' then raise exception 'Copy from another role (Super Admin has everything).'; end if;
    select greatest(5, coalesce(rank, 50) - 1) into rk from public.cms_roles where code = src;
    insert into public.cms_roles (code, name, description, rank, phase, is_system, created_by, created_at, archived_at)
    values (c, nm, coalesce(nullif(btrim(p->>'description'), ''), 'Custom role'), coalesce(rk, 40), 0, false, auth.uid(), now(), null)
    on conflict (code) do update set name = excluded.name, description = excluded.description, rank = excluded.rank, archived_at = null, created_by = excluded.created_by, created_at = now();
    update public.cms_role_permissions set actions = '' where role_code = c;
    if src is not null then
      insert into public.cms_role_permissions (role_code, module_code, actions)
      select c, rp.module_code, rp.actions from public.cms_role_permissions rp join public.cms_modules m on m.code = rp.module_code
       where rp.role_code = src and rp.actions <> '' and (not m.locked or public.cms_is_super_admin())
      on conflict (role_code, module_code) do update set actions = excluded.actions;
    end if;
    update public.cms_role_permission_defaults set actions = '' where role_code = c;
    insert into public.cms_role_permission_defaults (role_code, module_code, actions)
    select role_code, module_code, actions from public.cms_role_permissions where role_code = c and actions <> ''
    on conflict (role_code, module_code) do update set actions = excluded.actions;
    perform private.cms_log('role.created', 'role', c, null, 'Role ' || nm || ' created' || coalesce(' (copied from ' || (select name from public.cms_roles where code = src) || ')', ''), p);
    return c;
  end if;
  if c in ('super_admin', 'admin') and not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change this role.'; end if;
  update public.cms_roles set name = nm, description = coalesce(nullif(btrim(p->>'description'), ''), description) where code = c and archived_at is null;
  if not found then raise exception 'Role not found.'; end if;
  perform private.cms_log('role.changed', 'role', c, null, 'Role ' || nm || ' renamed / described', p);
  return c;
end $$;

-- remove a role made in the CMS (archived: hidden, permissions emptied; nothing is deleted)
alter table public.cms_roles add column if not exists archived_at timestamptz;
create or replace function public.cms_role_archive(p_code text, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_roles;
begin
  perform private.cms_require('admin.permissions', 'V');
  select * into r from public.cms_roles where code = p_code and archived_at is null;
  if r.code is null then raise exception 'Role not found.'; end if;
  if r.is_system then raise exception 'Built-in roles cannot be removed.'; end if;
  if exists (select 1 from public.cms_user_roles where role_code = p_code and is_active) then raise exception 'Take this role away from everyone first.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  update public.cms_role_permissions set actions = '' where role_code = p_code;
  update public.cms_roles set archived_at = now() where code = p_code;
  perform private.cms_log('role.removed', 'role', p_code, null, 'Role ' || r.name || ' removed: ' || btrim(p_reason), '{}'::jsonb);
end $$;

-- ------------------------------------------------------------------ per-person permissions
create or replace function public.cms_user_permissions_all()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('admin.roles', 'V');
  return coalesce((select jsonb_object_agg(x.user_id, x.p) from (select user_id, jsonb_object_agg(module_code, actions) p from public.cms_user_permissions where actions <> '' group by user_id) x), '{}'::jsonb);
end $$;

-- p_perms = the full set of extra permissions this login should have: {module: actions}
create or replace function public.cms_user_permissions_save(p_user uuid, p_perms jsonb, p_reason text)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; v text; m public.cms_modules; n int := 0; old text; email text; r record;
begin
  perform private.cms_require('admin.grant', 'V');
  select u.email into email from auth.users u where u.id = p_user;
  if email is null then raise exception 'Login not found.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason for the change.'; end if;
  for k, v in select * from jsonb_each_text(coalesce(p_perms, '{}'::jsonb)) loop
    m := private.cms_perm_rules(k, null, p_user); v := private.cms_clean_actions(m, v);
    select actions into old from public.cms_user_permissions where user_id = p_user and module_code = k;
    if coalesce(old, '') = v then continue; end if;
    insert into public.cms_user_permissions (user_id, module_code, actions, note, granted_by, granted_at) values (p_user, k, v, btrim(p_reason), auth.uid(), now())
    on conflict (user_id, module_code) do update set actions = excluded.actions, note = excluded.note, granted_by = excluded.granted_by, granted_at = now();
    perform private.cms_log('permission.person', 'user', p_user::text, null, email || ' · ' || m.label || ': ' || coalesce(nullif(old, ''), 'none') || ' → ' || coalesce(nullif(v, ''), 'none'),
      jsonb_build_object('module', k, 'before', old, 'after', v, 'reason', btrim(p_reason)));
    n := n + 1;
  end loop;
  -- anything not in the new set is taken away
  for r in select up.module_code, up.actions from public.cms_user_permissions up where up.user_id = p_user and up.actions <> '' and not (coalesce(p_perms, '{}'::jsonb) ? up.module_code) loop
    m := private.cms_perm_rules(r.module_code, null, p_user);
    update public.cms_user_permissions set actions = '', note = btrim(p_reason), granted_by = auth.uid(), granted_at = now() where user_id = p_user and module_code = r.module_code;
    perform private.cms_log('permission.person', 'user', p_user::text, null, email || ' · ' || m.label || ': ' || r.actions || ' → none', jsonb_build_object('module', r.module_code, 'reason', btrim(p_reason)));
    n := n + 1;
  end loop;
  return n;
end $$;

-- the roles page: defaults and who may change what
do $m$ declare d text := pg_get_functiondef('public.cms_roles_matrix()'::regprocedure); n text;
begin
  if strpos(d, '''can_permissions''') > 0 then return; end if;
  n := replace(d, $x$    'rules', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from public.cms_position_role_rules x));$x$,
    $x$    'rules', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from public.cms_position_role_rules x),
    'defaults', (select coalesce(jsonb_object_agg(r.code, (select coalesce(jsonb_object_agg(d.module_code, d.actions), '{}'::jsonb)
                      from public.cms_role_permission_defaults d where d.role_code = r.code and d.actions <> '')), '{}'::jsonb) from public.cms_roles r where r.archived_at is null),
    'can_permissions', public.cms_can('admin.permissions', 'V'), 'can_grant', public.cms_can('admin.grant', 'V'), 'is_super', public.cms_is_super_admin(), 'me', auth.uid());$x$);
  if n = d then raise exception 'cms_roles_matrix rules patch point not found'; end if;
  d := n;
  n := replace(d, $x$'rank', r.rank, 'phase', r.phase,$x$, $x$'rank', r.rank, 'phase', r.phase, 'is_system', r.is_system,$x$);
  d := n;
  n := replace(d, $x$order by r.rank desc) from public.cms_roles r),$x$, $x$order by r.rank desc) from public.cms_roles r where r.archived_at is null),$x$);
  execute n;
end $m$;

-- MyPayroll access follows per-person payroll permission too
create or replace function private.cms_sync_payroll_access()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.eppd_user_roles (user_id, email, display_name, role, status)
  select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', u.email), 'hr', 'active'
  from auth.users u
  where exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                where ur.user_id = u.id and ur.is_active and rp.module_code = 'payroll' and strpos(rp.actions, 'E') > 0)
     or exists (select 1 from public.cms_user_permissions up where up.user_id = u.id and up.module_code = 'payroll' and strpos(up.actions, 'E') > 0)
  on conflict (user_id) do update set role = 'hr', status = 'active'
    where public.eppd_user_roles.role <> 'admin' and (public.eppd_user_roles.role <> 'hr' or public.eppd_user_roles.status <> 'active');
  update public.eppd_user_roles e set status = 'disabled'
  where e.role = 'hr' and e.status = 'active'
    and not exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                    where ur.user_id = e.user_id and ur.is_active and rp.module_code = 'payroll' and strpos(rp.actions, 'E') > 0)
    and not exists (select 1 from public.cms_user_permissions up where up.user_id = e.user_id and up.module_code = 'payroll' and strpos(up.actions, 'E') > 0)
    and exists (select 1 from public.cms_user_roles ur where ur.user_id = e.user_id);
end $$;
create or replace trigger cms_user_permissions_payroll_sync after insert or update on public.cms_user_permissions
  for each statement execute function private.cms_sync_payroll_trg();

do $g$ declare f text;
begin
  foreach f in array array['cms_role_permissions_save(text, jsonb, text)', 'cms_role_reset(text, text)', 'cms_role_save(jsonb)', 'cms_role_archive(text, text)',
    'cms_user_permissions_all()', 'cms_user_permissions_save(uuid, jsonb, text)', 'cms_permission_change(text, text, text, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
revoke all on function private.cms_require_grant(text, uuid) from public, anon;
revoke all on function private.cms_perm_rules(text, text, uuid) from public, anon;

-- granting a role that was removed is refused
do $m$ declare d text := pg_get_functiondef('public.cms_grant_role(uuid, text, text[], text)'::regprocedure); n text;
begin
  n := replace(d, $x$if not exists (select 1 from public.cms_roles where code = p_role) then$x$, $x$if not exists (select 1 from public.cms_roles where code = p_role and archived_at is null) then$x$);
  if n <> d then execute n; end if;
end $m$;

-- the profile-change count follows "Approve profile changes"
do $m$ declare d text := pg_get_functiondef('public.cms_self_pending()'::regprocedure); n text;
begin
  n := replace(d, $x$'selfservice', 'E'$x$, $x$'selfservice.profile', 'V'$x$);
  if n <> d then execute n; end if;
end $m$;
