-- Permissions: Admin + Super Admin edit "Who can do what" (with a reason); locked sections only a Super Admin can change;
-- new "Set MyEden salary caps" permission (careers.caps); HR access widened (payroll open); Directors approve HR letters;
-- MyPayroll access follows the CMS payroll permission.

alter table public.cms_modules add column if not exists locked boolean not null default false;
update public.cms_modules set locked = true where code in ('admin.companies', 'admin.roles', 'admin.export', 'prfaf');

insert into public.cms_modules (code, label, grp, phase, sort_order)
values ('careers.caps', 'Set MyEden salary caps', 'Performance & Growth', 5, 63)
on conflict (code) do nothing;

insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('admin', 'careers.caps', 'VE'),
  ('hr', 'payroll', 'VCEX'), ('hr', 'payroll.settings', 'VCE'),
  ('hr', 'scf', 'V'), ('hr', 'mtcf', 'V'), ('hr', 'tec', 'V'),
  ('hr', 'overtime', 'VCE'), ('hr', 'org', 'VCE'),
  ('hr', 'documents', 'VCEX'), ('hr', 'training', 'VCEX'), ('hr', 'admin.audit', 'V'),
  ('director', 'letters', 'VA')
on conflict (role_code, module_code) do update set actions = excluded.actions;

-- caps: setting needs careers.caps E; viewing unchanged
create or replace function public.cms_salary_cap_save(p_band uuid, p_min numeric, p_max numeric, p_from date default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.jd_salary_bands; pos public.jd_positions;
begin
  perform private.cms_require('careers.caps', 'E');
  select * into b from public.jd_salary_bands where id = p_band;
  if b.id is null then raise exception 'Salary band not found.'; end if;
  if p_min is not null and p_max is not null and p_max < p_min then raise exception 'The maximum is below the minimum.'; end if;
  if (p_min is not null and p_min < 0) or (p_max is not null and p_max < 0) then raise exception 'Amounts cannot be negative.'; end if;
  select * into pos from public.jd_positions where id = b.position_id;
  insert into public.cms_salary_caps (band_id, cap_min, cap_max, effective_from, note, updated_by, updated_at)
  values (b.id, p_min, p_max, coalesce(p_from, current_date), nullif(btrim(p_note), ''), auth.uid(), now())
  on conflict (band_id) do update set cap_min = excluded.cap_min, cap_max = excluded.cap_max, effective_from = excluded.effective_from,
     note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  insert into public.cms_salary_cap_history (band_id, cap_min, cap_max, effective_from, note, changed_by, changed_by_name)
  values (b.id, p_min, p_max, coalesce(p_from, current_date), nullif(btrim(p_note), ''), auth.uid(), private.cms_my_name());
  perform private.cms_log('salary_cap.saved', 'jd_salary_bands', b.id::text, null,
    'MyEden cap ' || pos.job_title || ' (' || coalesce(pos.level, '') || ', ' || b.tier || '): ' || coalesce(p_min::text, '—') || ' – ' || coalesce(p_max::text, '—'),
    jsonb_build_object('min', p_min, 'max', p_max, 'from', p_from, 'note', p_note));
end $$;

-- cms_careers: tell the page whether this user may set caps
do $$
declare d text := pg_get_functiondef('public.cms_careers()'::regprocedure);
begin
  if strpos(d, '''can_caps''') = 0 then
    if strpos(d, 'jsonb_build_object(''can_edit'', public.cms_can(''careers'', ''E''), ') = 0 then raise exception 'cms_careers patch point not found'; end if;
    d := replace(d, 'jsonb_build_object(''can_edit'', public.cms_can(''careers'', ''E''), ',
                    'jsonb_build_object(''can_edit'', public.cms_can(''careers'', ''E''), ''can_caps'', public.cms_can(''careers.caps'', ''E''), ');
    execute d;
  end if;
end $$;

-- MyPayroll access follows the CMS: anyone whose CMS role gives Payroll "edit" gets the MyPayroll HR role
-- (prepare and finalise; reopening stays with MyPayroll admins). Never downgrades a MyPayroll admin.
create or replace function private.cms_sync_payroll_access()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.eppd_user_roles (user_id, email, display_name, role, status)
  select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', u.email), 'hr', 'active'
  from auth.users u
  where exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                where ur.user_id = u.id and ur.is_active and rp.module_code = 'payroll' and strpos(rp.actions, 'E') > 0)
  on conflict (user_id) do update set role = 'hr', status = 'active'
    where public.eppd_user_roles.role <> 'admin' and (public.eppd_user_roles.role <> 'hr' or public.eppd_user_roles.status <> 'active');
  -- people who lose CMS payroll edit lose the MyPayroll HR role (admins are left alone)
  update public.eppd_user_roles e set status = 'disabled'
  where e.role = 'hr' and e.status = 'active'
    and not exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                    where ur.user_id = e.user_id and ur.is_active and rp.module_code = 'payroll' and strpos(rp.actions, 'E') > 0)
    and exists (select 1 from public.cms_user_roles ur where ur.user_id = e.user_id);
end $$;

create or replace function private.cms_sync_payroll_trg()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform private.cms_sync_payroll_access(); return null; end $$;

create or replace trigger cms_user_roles_payroll_sync after insert or update or delete on public.cms_user_roles
  for each statement execute function private.cms_sync_payroll_trg();
create or replace trigger cms_role_permissions_payroll_sync after insert or update or delete on public.cms_role_permissions
  for each statement execute function private.cms_sync_payroll_trg();

select private.cms_sync_payroll_access();

-- editing permissions: Admin and Super Admin, with a reason; locked sections Super Admin only;
-- HR can never approve HR letters (drafter and approver must differ by role).
-- the old 3-argument version now asks for the updated page (a reason is required)
create or replace function public.cms_set_permission(p_role text, p_module text, p_actions text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
begin raise exception 'Reload the CMS: permission changes now need a reason.'; end $$;

create or replace function public.cms_permission_change(p_role text, p_module text, p_actions text, p_reason text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_new text := ''; v_old text; l text; m public.cms_modules;
begin
  perform private.cms_require('admin.roles', 'E');
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason for the change.'; end if;
  if p_role = 'super_admin' then raise exception 'Super Admin always has every permission'; end if;
  if not exists (select 1 from public.cms_roles where code = p_role) then raise exception 'Unknown role: %', p_role; end if;
  select * into m from public.cms_modules where code = p_module;
  if m.code is null then raise exception 'Unknown module: %', p_module; end if;
  if m.locked and not public.cms_is_super_admin() then raise exception '% is a locked section: only a Super Admin can change it.', m.label; end if;
  if p_role = 'admin' and not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change the Admin role.'; end if;
  foreach l in array array['V', 'C', 'E', 'A', 'D', 'X'] loop
    if strpos(upper(coalesce(p_actions, '')), l) > 0 then v_new := v_new || l; end if;
  end loop;
  if v_new <> '' and strpos(v_new, 'V') = 0 then v_new := 'V' || v_new; end if;
  if p_role = 'hr' and p_module = 'letters' and strpos(v_new, 'A') > 0 then
    raise exception 'HR drafts letters; approval stays with Admin, Super Admin or a Director.';
  end if;
  select actions into v_old from public.cms_role_permissions where role_code = p_role and module_code = p_module;
  insert into public.cms_role_permissions (role_code, module_code, actions) values (p_role, p_module, v_new)
  on conflict (role_code, module_code) do update set actions = excluded.actions;
  perform private.cms_log('permission.set', 'role', p_role, null,
    (select name from public.cms_roles where code = p_role) || ' · ' || m.label
      || ': ' || coalesce(nullif(v_old, ''), 'none') || ' → ' || coalesce(nullif(v_new, ''), 'none'),
    jsonb_build_object('module', p_module, 'before', v_old, 'after', v_new, 'reason', btrim(p_reason)));
  return v_new;
end $$;
grant execute on function public.cms_permission_change(text, text, text, text) to authenticated;

revoke all on function public.cms_permission_change(text, text, text, text) from public, anon;
grant execute on function public.cms_permission_change(text, text, text, text) to authenticated;
revoke all on function public.cms_set_permission(text, text, text) from public, anon;
revoke all on function private.cms_sync_payroll_access() from public, anon, authenticated;
