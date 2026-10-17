-- MyEden Group CMS V1.0 · v2026.10.17-18:20 · Account / Payroll Viewer role (sees, never changes)
insert into public.cms_roles (code, name, description, rank, phase) values
  ('payroll_viewer', 'Account / Payroll Viewer', 'Sees claims, people, payroll and reports. Cannot change, approve, pay or export anything.', 55, 1)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions)
select 'payroll_viewer', m, 'V' from unnest(array['dashboard', 'people', 'org', 'approvals', 'overtime', 'scf', 'mtcf', 'tec', 'prfaf',
  'leave', 'payroll', 'payroll.settings', 'reports', 'hrlaw']) m
on conflict (role_code, module_code) do nothing;

-- MEG-EAF V2 "read-only payroll" now suggests this role instead of Payroll
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
    select 'payroll_viewer', null, 'Read-only payroll access in MEG-EAF V2'
      from public.eaf_v2_staff_permissions where user_id = p_uid and coalesce(can_view_only, false)
    union all
    select 'admin', null, 'Admin of ' || string_agg(upper(form_code), ', ' order by form_code) || ' in MEG-FORMS'
      from public.form_permissions where user_id = p_uid and form_code !~ '^<' and coalesce(is_admin, false) having count(*) > 0
    union all
    select 'finance', null, 'Marks claims paid in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and form_code !~ '^<' and (coalesce(can_mark_paid, false) or coalesce(can_finance, false)) having count(*) > 0
    union all
    select 'payroll', null, 'Payroll / Account processing in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and form_code !~ '^<' and coalesce(can_view, false) and not coalesce(can_submit, false) having count(*) > 0
    union all
    select 'approver',
      case when bool_or(coalesce(approval_scope, '') not in ('myeden', 'hds', 'abn')) then null
           else array(select distinct x from public.form_permissions f2,
                      unnest(case f2.approval_scope when 'myeden' then array['MEG', 'MEH'] when 'hds' then array['HD'] when 'abn' then array['ABP'] end) x
                      where f2.user_id = p_uid and f2.can_approve) end,
      'Approves claims in MEG-FORMS (' || string_agg(upper(form_code), ', ' order by form_code) || ')'
      from public.form_permissions where user_id = p_uid and form_code !~ '^<' and coalesce(can_approve, false) having count(*) > 0
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


insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'Added the Account / Payroll Viewer role (v2026.10.17-18:20)', '{"role":"payroll_viewer"}');
notify pgrst, 'reload schema';
