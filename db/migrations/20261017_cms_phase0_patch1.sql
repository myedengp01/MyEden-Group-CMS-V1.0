-- MyEden Group CMS V1.0 · Phase 0 patch 1 · v2026.10.17-13:30
-- People: centre falls back to the department when it is a centre code (HQ, E1…).
-- Suggestions: ignore the placeholder '<form_code>' row in form_permissions.

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
         pp.paying_company_code,
         coalesce(pp.unit_code, (select un.code from public.cms_units un where un.code = upper(btrim(em.department)) and un.is_active)), em.department::text, em.approved_job_title::text,
         split_part(coalesce(em.job_title_level, ''), '|', 1), em.employment_status::text, em.start_date,
         em.actual_last_working_date, em.email::text, u.email::text, em.source_type::text
  from public.employee_master em
  left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
  left join public.cms_user_links l on l.employee_master_id = em.id
  left join auth.users u on u.id = l.user_id
  where public.cms_can('people', 'V', em.company_code)
  order by em.employee_name;
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

notify pgrst, 'reload schema';
