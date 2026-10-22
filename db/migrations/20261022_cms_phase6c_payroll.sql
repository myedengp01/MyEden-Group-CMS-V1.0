-- MyEden Group CMS V1.0 · Phase 6c · Monthly payroll inside the CMS (MyPayroll page code on the same tables)
-- Extra row-level rules by CMS permission (MyPayroll's own rules stay as they are):
--   pay lines, claims, private details (date of birth), salary history, tax profiles, loans, settlements: read with Payroll "view";
--   fixed allowances added from a pay line: change with "Prepare payroll";
--   a draft month may be deleted with "Prepare payroll" (finalised months never).
-- The save / finalise / reopen functions accept the CMS permissions "Prepare payroll", "Finalise payroll" and "Reopen a finalised month".

do $p$ declare t text;
begin
  foreach t in array array['eppd_pay_lines','eppd_claims','eppd_employee_private','eppd_salary_history','eppd_tax_profiles','eppd_loans','eppd_settlements'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'CMS payroll read') then
      execute format('create policy "CMS payroll read" on public.%I for select to authenticated using (public.cms_can(''payroll'', ''V''))', t);
    end if;
  end loop;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eppd_allowances' and policyname = 'CMS payroll prepare') then
    create policy "CMS payroll prepare" on public.eppd_allowances for all to authenticated
      using (public.cms_can('payroll.prepare', 'V')) with check (public.cms_can('payroll.prepare', 'V'));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eppd_pay_runs' and policyname = 'CMS delete draft month') then
    create policy "CMS delete draft month" on public.eppd_pay_runs for delete to authenticated
      using (status = 'draft' and public.cms_can('payroll.prepare', 'V'));
  end if;
end $p$;

do $m$ declare r record; d text; n text;
begin
  for r in select * from (values
    ('eppd_save_pay_run',     $x$if not public.eppd_has_role(array['admin','hr']) then$x$, $x$if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll.prepare', 'V')) then$x$),
    ('eppd_finalise_pay_run', $x$if not public.eppd_has_role(array['admin','hr']) then$x$, $x$if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll.finalise', 'V')) then$x$),
    ('eppd_reopen_pay_run',   $x$if not public.eppd_is_admin() then$x$, $x$if not (public.eppd_is_admin() or public.cms_can('payroll.reopen', 'V')) then$x$)) t(f, a, b) loop
    for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = r.f loop
      n := replace(d, r.a, r.b);
      if n <> d then execute n; elsif strpos(d, 'cms_can') = 0 then raise exception 'patch point not found in %', r.f; end if;
    end loop;
  end loop;
end $m$;

-- these three now work in the CMS
update public.cms_modules set from_phase = null where code in ('payroll.prepare', 'payroll.finalise', 'payroll.reopen');
