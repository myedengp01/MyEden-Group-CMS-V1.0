-- MyEden Group CMS V1.0 · Phase 6e · Company Loans, Final Settlement and Import Past Months inside the CMS,
-- plus the Employee Directory (Phase 4 page, built now) for HR and above.
--
-- Payroll (MyPayroll page code on the same tables; MyPayroll's own rules stay as they are):
--   company loans and final settlements: read with Payroll "view" (Phase 6c), add / change with "Prepare payroll";
--   Import Past Months (workbook history): CMS Super Admin too.
--
-- Employee Directory: a new permission section with three special permissions, all settable per role or per person:
--   directory          V open the directory · X export to Excel
--   directory.contacts   see phone and email
--   directory.all        see every company (without it: only the company of your own person record)
--   directory.chart      the org-chart view (who reports to whom)
-- Defaults: Admin, HR and Director get all of it; Super Admin always does. Nobody else, until you grant it.

-- ------------------------------------------------------------------ payroll: loans, settlements, import
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eppd_loans' and policyname = 'CMS payroll prepare') then
    create policy "CMS payroll prepare" on public.eppd_loans for all to authenticated
      using (public.cms_can('payroll.prepare', 'V')) with check (public.cms_can('payroll.prepare', 'V'));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eppd_settlements' and policyname = 'CMS payroll prepare') then
    create policy "CMS payroll prepare" on public.eppd_settlements for all to authenticated
      using (public.cms_can('payroll.prepare', 'V')) with check (public.cms_can('payroll.prepare', 'V'));
  end if;
end $p$;

do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.eppd_import_pay_history(jsonb)'::regprocedure);
  n := replace(d, $x$if not public.eppd_is_admin() then$x$, $x$if not (public.eppd_is_admin() or public.cms_is_super_admin()) then$x$);
  if n = d and strpos(d, 'cms_is_super_admin') = 0 then raise exception 'eppd_import_pay_history patch point not found'; end if;
  if n <> d then execute n; end if;
end $m$;

-- ------------------------------------------------------------------ directory permissions
insert into public.cms_modules (code, label, grp, phase, sort_order, kind, parent, acts, act_labels, description, from_phase, locked) values
  ('directory', 'Employee Directory', 'People & Employment', 4, 14, 'section', null, 'VX', '{"X":"Export to Excel"}'::jsonb,
   'Who is who: position, centre, department, company and who each person reports to', null, false),
  ('directory.contacts', 'See phone and email in the directory', 'People & Employment', 4, 1006, 'special', 'directory', 'V', '{}'::jsonb,
   'Phone numbers and email addresses on directory cards and in its export', null, false),
  ('directory.all', 'See all companies in the directory', 'People & Employment', 4, 1007, 'special', 'directory', 'V', '{}'::jsonb,
   'Without it, the directory shows only the company of your own person record', null, false),
  ('directory.chart', 'Org chart in the directory', 'People & Employment', 4, 1008, 'special', 'directory', 'V', '{}'::jsonb,
   'The chart view: each manager with the people who report to them', null, false)
on conflict (code) do nothing;

insert into public.cms_role_permissions (role_code, module_code, actions)
select r, m, a from (values ('super_admin', 'directory', 'VX'), ('admin', 'directory', 'VX'), ('hr', 'directory', 'VX'), ('director', 'directory', 'VX'),
  ('admin', 'directory.contacts', 'V'), ('hr', 'directory.contacts', 'V'), ('director', 'directory.contacts', 'V'),
  ('admin', 'directory.all', 'V'), ('hr', 'directory.all', 'V'), ('director', 'directory.all', 'V'),
  ('admin', 'directory.chart', 'V'), ('hr', 'directory.chart', 'V'), ('director', 'directory.chart', 'V')) t(r, m, a)
where exists (select 1 from public.cms_roles where code = t.r)
on conflict (role_code, module_code) do nothing;

insert into public.cms_role_permission_defaults (role_code, module_code, actions)
select role_code, module_code, actions from public.cms_role_permissions where module_code like 'directory%' and actions <> ''
on conflict (role_code, module_code) do nothing;

-- ------------------------------------------------------------------ directory data
create or replace function public.cms_directory()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare v_contacts boolean; v_all boolean; v_chart boolean; v_export boolean; v_mine text; v_people jsonb;
begin
  perform private.cms_require('directory', 'V');
  v_contacts := public.cms_can('directory.contacts', 'V'); v_all := public.cms_can('directory.all', 'V');
  v_chart := public.cms_can('directory.chart', 'V'); v_export := public.cms_can('directory', 'X');
  select private.cms_canon(em.company_code) into v_mine
    from public.cms_user_links l join public.employee_master em on em.id = l.employee_master_id where l.user_id = auth.uid() limit 1;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_people from (
    select jsonb_build_object(
      'id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name,
      'company', private.cms_canon(em.company_code),
      'company_name', (select coalesce(c.short_name, c.name) from public.cms_companies c where c.code = private.cms_canon(em.company_code)),
      'unit', u.code, 'unit_name', u.name, 'department', em.department, 'title', em.approved_job_title,
      'level', nullif(split_part(coalesce(em.job_title_level, ''), '|', 1), ''),
      'status', em.employment_status, 'start', em.start_date, 'confirmation', le.confirmation_status,
      'reports_to', em.reports_to_id, 'reports_to_name', b.employee_name,
      'phone', case when v_contacts then em.contact end, 'email', case when v_contacts then em.email end) x
    from public.employee_master em
    left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
    left join public.cms_units u on u.code = coalesce(pp.unit_code, (select un.code from public.cms_units un where un.code = upper(btrim(em.department)) and un.is_active))
    left join public.employee_master b on b.id = em.reports_to_id
    left join lateral (select e.confirmation_status from public.eppd_employees ee join public.eppd_employments e on e.employee_id = ee.id
                       where ee.employee_master_id = em.id order by e.join_date desc nulls last, e.id desc limit 1) le on true
    where em.employment_status in ('active', 'onboarding')
      and public.cms_can('directory', 'V', em.company_code)
      and (v_all or private.cms_canon(em.company_code) = v_mine)) s;
  return jsonb_build_object('can_contacts', v_contacts, 'can_all', v_all, 'can_chart', v_chart, 'can_export', v_export,
    'my_company', v_mine, 'people', v_people);
end $f$;
revoke all on function public.cms_directory() from public, anon;
grant execute on function public.cms_directory() to authenticated;

-- the directory export is logged like other exports
create or replace function public.cms_directory_exported(p_count int)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  perform private.cms_require('directory', 'X');
  perform private.cms_log('directory.export', 'directory', null, null, 'Exported the employee directory (' || p_count || ' people)', jsonb_build_object('count', p_count));
end $f$;
revoke all on function public.cms_directory_exported(int) from public, anon;
grant execute on function public.cms_directory_exported(int) to authenticated;
