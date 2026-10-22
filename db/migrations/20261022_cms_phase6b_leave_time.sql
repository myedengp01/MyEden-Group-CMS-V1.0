-- MyEden Group CMS V1.0 · Phase 6b · Leave & time inside the CMS (MyPayroll page code on the same tables)
-- Extra row-level rules by CMS permission (MyPayroll's own rules stay as they are):
--   leave records, adjustments, year closes, KPI grades: read with Leave "view" (or Payroll "view"), change with Leave "edit";
--   hours and overtime entries, OTCF links: read with Payroll "view", change with Payroll "edit";
--   payroll months: read with Payroll "view" (Year-end Close looks at them);
--   approved OTCF claims: read with Overtime claims "view" (to pull them into payroll).

do $p$ declare t text;
begin
  foreach t in array array['eppd_leave_records','eppd_leave_adjustments','eppd_leave_year_closes','eppd_kpi_ratings'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS leave read') then
      execute format('create policy "CMS leave read" on public.%I for select to authenticated using (public.cms_can(''leave'', ''V'') or public.cms_can(''payroll'', ''V''))', t);
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS leave change') then
      execute format('create policy "CMS leave change" on public.%I for all to authenticated using (public.cms_can(''leave'', ''E'')) with check (public.cms_can(''leave'', ''E''))', t);
    end if;
  end loop;
  foreach t in array array['eppd_time_entries','eppd_otcf_links'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS time read') then
      execute format('create policy "CMS time read" on public.%I for select to authenticated using (public.cms_can(''payroll'', ''V''))', t);
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS time change') then
      execute format('create policy "CMS time change" on public.%I for all to authenticated using (public.cms_can(''payroll'', ''E'')) with check (public.cms_can(''payroll'', ''E''))', t);
    end if;
  end loop;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eppd_pay_runs' and policyname = 'CMS payroll read') then
    create policy "CMS payroll read" on public.eppd_pay_runs for select to authenticated using (public.cms_can('payroll', 'V'));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'otcf_submissions' and policyname = 'CMS read approved OTCF') then
    create policy "CMS read approved OTCF" on public.otcf_submissions for select to authenticated
      using (status in ('approved', 'paid', 'completed') and public.cms_can('overtime', 'V', company_code));
  end if;
end $p$;

-- the leave and time functions accept the CMS permissions too
do $m$ declare r record; d text; n text;
begin
  for r in select * from (values
    ('public.eppd_close_leave_year', $x$if not public.eppd_has_role(array['admin','hr']) then$x$, $x$if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('leave', 'E')) then$x$),
    ('public.eppd_save_otcf_pull', $x$if not public.eppd_has_role(array['admin','hr']) then$x$, $x$if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll', 'E')) then$x$),
    ('public.eppd_import_leave', $x$if not public.eppd_is_admin() then$x$, $x$if not (public.eppd_is_admin() or public.cms_is_super_admin()) then$x$)) t(f, a, b) loop
    for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = split_part(r.f, '.', 2) loop
      n := replace(d, r.a, r.b);
      if n <> d then execute n; elsif strpos(d, 'cms_') = 0 then raise exception 'patch point not found in %', r.f; end if;
    end loop;
  end loop;
end $m$;
