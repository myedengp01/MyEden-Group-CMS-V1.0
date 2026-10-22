-- MyEden Group CMS V1.0 · Phase 6a · Payroll settings, Employee IDs and Import from Workbook inside the CMS
-- The MyPayroll V2.0 page code now runs inside the CMS on the same tables. These extra row-level rules let CMS users
-- reach those tables by their CMS permissions (MyPayroll's own rules stay as they are, for MyPayroll itself):
--   read: Payroll "view" or Payroll settings "view";  change settings: Payroll settings "edit";
--   Employee IDs: the "Change Employee ID" permission;  Import from Workbook: Super Admin (it only runs on an empty list).

do $p$ declare t text;
begin
  foreach t in array array['eppd_companies','eppd_departments','eppd_job_titles','eppd_lookups','eppd_payment_types','eppd_allowances','eppd_stat_versions',
                           'eppd_stat_brackets','eppd_holidays','eppd_policies','eppd_employees','eppd_employments','eppd_assignments'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS payroll read') then
      execute format('create policy "CMS payroll read" on public.%I for select to authenticated using (public.cms_can(''payroll'', ''V'') or public.cms_can(''payroll.settings'', ''V'') or public.cms_can(''people.eid'', ''V''))', t);
    end if;
  end loop;
  foreach t in array array['eppd_departments','eppd_job_titles','eppd_lookups','eppd_payment_types','eppd_stat_versions','eppd_stat_brackets','eppd_holidays','eppd_policies'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS payroll settings') then
      execute format('create policy "CMS payroll settings" on public.%I for all to authenticated using (public.cms_can(''payroll.settings'', ''E'')) with check (public.cms_can(''payroll.settings'', ''E''))', t);
    end if;
  end loop;
end $p$;

-- Employee IDs: "Change Employee ID" may assign IDs; the Workbook import: CMS Super Admin too
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.eppd_generate_emp_id(bigint)'::regprocedure);
  n := replace(d, $x$if not public.eppd_has_role(array['admin','hr']) then$x$, $x$if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('people.eid', 'V')) then$x$);
  if n = d and strpos(d, 'people.eid') = 0 then raise exception 'eppd_generate_emp_id patch point not found'; end if;
  if n <> d then execute n; end if;
  -- it checks who may assign IDs itself, then writes the ID (also for CMS users without a MyPayroll login)
  alter function public.eppd_generate_emp_id(bigint) security definer;
  d := pg_get_functiondef('public.eppd_import_employees(jsonb)'::regprocedure);
  n := replace(d, $x$if not public.eppd_is_admin() then$x$, $x$if not (public.eppd_is_admin() or public.cms_is_super_admin()) then$x$);
  if n = d and strpos(d, 'cms_is_super_admin') = 0 then raise exception 'eppd_import_employees patch point not found'; end if;
  if n <> d then execute n; end if;
end $m$;

-- "Change Employee ID" now works in the CMS
update public.cms_modules set from_phase = null where code = 'people.eid';
