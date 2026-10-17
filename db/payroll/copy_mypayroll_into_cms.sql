-- =====================================================================
-- MyEden Group CMS V1.0 · copy MyPayroll V2.0 data into the CMS project
-- Run ONCE in the Supabase SQL editor of the **MyEden Group CMS V1.0** project (not MyPayroll).
--
-- Before running:
--   1. Find the line marked >>> below (inside the do $copy_mypayroll$ block) and replace [YOUR-PASSWORD], including the
--      square brackets, with the MyPayroll database password. Nothing else needs changing.
--      Use a password of letters and numbers only (reset it if needed): characters such as $ @ ' # / : ? %
--      break the connection string or this script.
--      (Forgotten? MyPayroll › Project Settings › Database › Reset database password. The MyPayroll app
--      does not use that password, so resetting it does not affect the app.)
--   2. Run it in the SQL editor of the **MyEden Group CMS V1.0** project. Do not save the query afterwards.
--
-- What it does (all in one transaction: if any check fails, nothing is kept):
--   · adds the 4 payroll functions that contain DELETE statements (identical to MyPayroll 005/006)
--   · clears the placeholder rows the setup scripts put in the new, empty copy
--   · reads every eppd_ table from MyPayroll (read-only) and inserts the same rows, same ids, into the CMS
--     project; MyPayroll login ids are swapped for the CMS login with the same email
--   · checks every table row-for-row (count + checksum) against MyPayroll, and resets the id counters
-- MyPayroll itself is only read, never changed. MyPRSys tables are not copied.
-- =====================================================================

begin;

create or replace function public.eppd_import_leave(p jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare x jsonb; n_rec int := 0; n_adj int := 0; n_time int := 0;
begin
  if not public.eppd_is_admin() then raise exception 'Only admins can run the workbook import.'; end if;
  perform set_config('eppd.skip_audit', 'on', true);
  delete from public.eppd_leave_records     where source = 'import';
  delete from public.eppd_leave_adjustments where source = 'import';
  delete from public.eppd_time_entries      where source = 'import';
  for x in select * from jsonb_array_elements(coalesce(p->'records', '[]'::jsonb)) loop
    insert into public.eppd_leave_records (employee_id, leave_type, date_from, date_to, days, days_override, source, note)
    values ((x->>'employee_id')::bigint, x->>'leave_type', (x->>'date_from')::date, (x->>'date_to')::date,
            (x->>'days')::numeric, true, 'import', x->>'note');
    n_rec := n_rec + 1;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p->'adjustments', '[]'::jsonb)) loop
    insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, buyback_pct, source, note)
    values ((x->>'employee_id')::bigint, x->>'leave_type', (x->>'year')::int, x->>'kind', (x->>'days')::numeric,
            nullif(x->>'effective_date', '')::date, nullif(x->>'buyback_pct', '')::numeric, 'import', x->>'note');
    n_adj := n_adj + 1;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p->'time', '[]'::jsonb)) loop
    insert into public.eppd_time_entries (employee_id, work_date, category, hours, source, note)
    values ((x->>'employee_id')::bigint, (x->>'work_date')::date, x->>'category', (x->>'hours')::numeric, 'import', x->>'note');
    n_time := n_time + 1;
  end loop;
  perform set_config('eppd.skip_audit', 'off', true);
  perform public.eppd_log_summary('eppd_leave_records', 'IMPORT',
    jsonb_build_object('source', p->>'source', 'leave_records', n_rec, 'adjustments', n_adj, 'time_entries', n_time));
  return jsonb_build_object('leave_records', n_rec, 'adjustments', n_adj, 'time_entries', n_time);
end $$;

create or replace function public.eppd_close_leave_year(p jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_year int := (p->>'year')::int; x jsonb; n int := 0;
begin
  if not public.eppd_has_role(array['admin','hr']) then raise exception 'Only HR and admins can close a leave year.'; end if;
  if v_year is null then raise exception 'Year is required.'; end if;
  delete from public.eppd_leave_adjustments where source = 'year_close' and close_year = v_year;
  for x in select * from jsonb_array_elements(coalesce(p->'adjustments', '[]'::jsonb)) loop
    insert into public.eppd_leave_adjustments (employee_id, leave_type, year, kind, days, effective_date, expires_on,
           buyback_pct, close_year, source, note)
    values ((x->>'employee_id')::bigint, coalesce(x->>'leave_type', 'AL'), (x->>'year')::int, x->>'kind', (x->>'days')::numeric,
            nullif(x->>'effective_date', '')::date, nullif(x->>'expires_on', '')::date,
            nullif(x->>'buyback_pct', '')::numeric, v_year, 'year_close', x->>'note');
    n := n + 1;
  end loop;
  insert into public.eppd_leave_year_closes (year, closed_at, closed_by, summary)
  values (v_year, now(), auth.uid(), p->'summary')
  on conflict (year) do update set closed_at = now(), closed_by = auth.uid(), summary = excluded.summary;
  perform public.eppd_log_summary('eppd_leave_adjustments', 'YEAR_CLOSE', jsonb_build_object('year', v_year, 'adjustments', n) || coalesce(p->'summary', '{}'::jsonb));
  return jsonb_build_object('adjustments', n);
end $$;

create or replace function public.eppd_save_pay_run(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_period date := (p->>'period')::date; v_run public.eppd_pay_runs; v_exists boolean; n int;
begin
  if not public.eppd_has_role(array['admin','hr']) then raise exception 'Only HR and admins can prepare payroll.'; end if;
  if v_period is null or extract(day from v_period) <> 1 then raise exception 'Period must be the first day of a month.'; end if;
  select * into v_run from public.eppd_pay_runs where period = v_period for update;
  v_exists := found;   -- PERFORM resets FOUND, so keep the answer
  if v_exists and v_run.status = 'finalised' then raise exception 'This month is finalised. Ask an admin to reopen it.'; end if;
  if v_exists and coalesce(p->>'expected_updated_at', '') = '' then
    raise exception 'Someone else started this month after you opened it. Reload the page to see their figures; nothing was saved.';
  end if;
  if v_exists and (p->>'expected_updated_at')::timestamptz is distinct from v_run.updated_at then
    raise exception 'Someone else saved this month after you opened it. Reload the page to see their changes; nothing was saved.';
  end if;
  perform set_config('eppd.skip_audit', 'on', true);
  if not v_exists then
    insert into public.eppd_pay_runs (period, notes, totals) values (v_period, p->>'notes', coalesce(p->'totals', '{}'::jsonb))
    returning * into v_run;
  else
    update public.eppd_pay_runs set notes = p->>'notes', totals = coalesce(p->'totals', '{}'::jsonb) where id = v_run.id
    returning * into v_run;
    delete from public.eppd_pay_lines where run_id = v_run.id;
  end if;
  n := public.eppd_insert_pay_lines(v_run.id, p->'lines');
  perform set_config('eppd.skip_audit', 'off', true);
  perform public.eppd_pay_log('PAY_SAVE', jsonb_build_object('run_id', v_run.id, 'period', v_period, 'lines', n) || coalesce(p->'totals'->'all', '{}'::jsonb));
  return jsonb_build_object('run_id', v_run.id, 'lines', n, 'updated_at', v_run.updated_at);
end $$;

create or replace function public.eppd_import_pay_history(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_period date; v_run public.eppd_pay_runs; v_exists boolean; n_runs int := 0; n_lines int := 0;
begin
  if not public.eppd_is_admin() then raise exception 'Only admins can import payroll history.'; end if;
  perform set_config('eppd.skip_audit', 'on', true);
  perform set_config('eppd.pay_unlock', 'on', true);
  for r in select * from jsonb_array_elements(coalesce(p->'runs', '[]'::jsonb)) loop
    v_period := (r->>'period')::date;
    select * into v_run from public.eppd_pay_runs where period = v_period for update;
    v_exists := found;
    if v_exists and v_run.source <> 'import' then
      raise exception '% already has a pay run made in the app; it was not replaced. Nothing was imported.', to_char(v_period, 'Mon YYYY');
    end if;
    if v_exists and v_run.reopened_at is not null then
      raise exception '% was reopened and changed in the app; it was not replaced. Nothing was imported.', to_char(v_period, 'Mon YYYY');
    end if;
    if v_exists then delete from public.eppd_pay_runs where id = v_run.id; end if;
    insert into public.eppd_pay_runs (period, status, source, totals, notes, finalised_at, finalised_by)
    values (v_period, 'finalised', 'import', coalesce(r->'totals', '{}'::jsonb), 'Imported from the MEG-EPPD workbook', now(), auth.uid())
    returning * into v_run;
    n_lines := n_lines + public.eppd_insert_pay_lines(v_run.id, r->'lines');
    n_runs := n_runs + 1;
  end loop;
  perform set_config('eppd.pay_unlock', 'off', true);
  perform set_config('eppd.skip_audit', 'off', true);
  perform public.eppd_pay_log('PAY_IMPORT', jsonb_build_object('months', n_runs, 'lines', n_lines, 'source', p->>'source'));
  return jsonb_build_object('months', n_runs, 'lines', n_lines);
end $$;

revoke execute on function public.eppd_import_leave(jsonb), public.eppd_close_leave_year(jsonb),
  public.eppd_save_pay_run(jsonb), public.eppd_import_pay_history(jsonb) from public, anon;
grant execute on function public.eppd_import_leave(jsonb), public.eppd_close_leave_year(jsonb),
  public.eppd_save_pay_run(jsonb), public.eppd_import_pay_history(jsonb) to authenticated;


revoke execute on function public.eppd_import_leave(jsonb), public.eppd_close_leave_year(jsonb),
  public.eppd_save_pay_run(jsonb), public.eppd_import_pay_history(jsonb) from public, anon;
grant execute on function public.eppd_import_leave(jsonb), public.eppd_close_leave_year(jsonb),
  public.eppd_save_pay_run(jsonb), public.eppd_import_pay_history(jsonb) to authenticated;

create extension if not exists dblink with schema extensions;

create temporary table if not exists pay_copy_report (n serial, tbl text, rows_mypayroll bigint, rows_cms bigint, same boolean);

do $copy_mypayroll$
declare
  -- >>> replace [YOUR-PASSWORD] (including the square brackets) with the MyPayroll database password <<<
  src text := 'postgresql://postgres.tjoijzzeayolsqnguvpj:[YOUR-PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres';
  tbls text[] := array['eppd_companies','eppd_departments','eppd_job_titles','eppd_lookups','eppd_payment_types',
    'eppd_policies','eppd_stat_versions','eppd_stat_brackets','eppd_holidays','eppd_user_roles','eppd_employees',
    'eppd_employee_private','eppd_employments','eppd_assignments','eppd_salary_history','eppd_allowances',
    'eppd_leave_records','eppd_leave_adjustments','eppd_kpi_ratings','eppd_leave_year_closes','eppd_time_entries',
    'eppd_otcf_links','eppd_pay_runs','eppd_pay_lines','eppd_tax_profiles','eppd_claims','eppd_loans',
    'eppd_settlements','eppd_audit_log'];
  t text; j text; m record; n_src bigint; n_dst bigint; h_src text; h_dst text; bad text := '';
begin
  if src like '%[YOUR-PASSWORD]%' then
    raise exception 'Replace [YOUR-PASSWORD] with the MyPayroll database password first (line marked >>>).';
  end if;
  if exists (select 1 from public.eppd_employees) or exists (select 1 from public.eppd_pay_runs) then
    raise exception 'The payroll copy in the CMS already holds data. Nothing was changed.';
  end if;
  perform extensions.dblink_connect('mypay', src);
  perform extensions.dblink_exec('mypay', 'set timezone = ''UTC''');
  set local timezone = 'UTC';
  if (select x from extensions.dblink('mypay', 'select count(*) from public.eppd_pay_runs') as r(x bigint)) is null then
    raise exception 'That connection is not the MyPayroll database.';
  end if;

  perform set_config('eppd.skip_audit', 'on', true);
  perform set_config('eppd.pay_unlock', 'on', true);

  -- placeholder rows from the setup scripts (the copy holds no staff or pay runs: checked above)
  delete from public.eppd_lookups;
  delete from public.eppd_policies;
  delete from public.eppd_audit_log;

  -- MyPayroll login id -> CMS login id, matched by email
  create temporary table pay_user_map on commit drop as
    select s.id as src_id, u.id::text as dst_id, s.email
    from extensions.dblink('mypay', 'select id::text, lower(email) from auth.users') as s(id text, email text)
    left join auth.users u on lower(u.email) = s.email;

  foreach t in array tbls loop
    select x into j from extensions.dblink('mypay', format('select coalesce(json_agg(t), ''[]'')::text from public.%I t', t)) as r(x text);
    for m in select * from pay_user_map where dst_id is not null and dst_id <> src_id loop
      j := replace(j, m.src_id, m.dst_id);
    end loop;
    if t = 'eppd_user_roles' then
      -- the placeholder admin row is replaced in place; its "touch" trigger would otherwise stamp a new updated_at
      alter table public.eppd_user_roles disable trigger eppd_user_roles_touch;
      insert into public.eppd_user_roles
      select * from jsonb_populate_recordset(null::public.eppd_user_roles, j::jsonb)
      on conflict (user_id) do update set email = excluded.email, display_name = excluded.display_name, role = excluded.role,
        status = excluded.status, created_at = excluded.created_at, updated_at = excluded.updated_at;
      alter table public.eppd_user_roles enable trigger eppd_user_roles_touch;
    else
      execute format('insert into public.%I overriding system value select * from jsonb_populate_recordset(null::public.%I, $1::jsonb)', t, t) using j;
    end if;

    -- row-for-row check: same rows (text of every column) on both sides
    select x into j from extensions.dblink('mypay', format('select coalesce(json_agg(t::text), ''[]'')::text from public.%I t', t)) as r(x text);
    for m in select * from pay_user_map where dst_id is not null and dst_id <> src_id loop
      j := replace(j, m.src_id, m.dst_id);
    end loop;
    select count(*), md5(coalesce(string_agg(v, E'\n' order by v), '')) into n_src, h_src from json_array_elements_text(j::json) v;
    execute format('select count(*), md5(coalesce(string_agg(t::text, E''\n'' order by t::text), '''')) from public.%I t', t) into n_dst, h_dst;
    insert into pay_copy_report (tbl, rows_mypayroll, rows_cms, same) values (t, n_src, n_dst, h_src = h_dst);
    if h_src <> h_dst then bad := bad || t || ' '; end if;

    -- id counters continue after the copied ids
    if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'id' and is_identity = 'YES') then
      execute format('select setval(pg_get_serial_sequence(%L, ''id''), greatest(coalesce((select max(id) from public.%I), 0), 1), (select count(*) > 0 from public.%I))', 'public.' || t, t, t);
    end if;
  end loop;

  perform extensions.dblink_disconnect('mypay');
  if bad <> '' then raise exception 'These tables did not copy exactly, so nothing was kept: %', bad; end if;

  insert into public.cms_audit_log (action, entity, summary, details)
  values ('system.setup', 'database', 'MyPayroll V2.0 data copied into the CMS project (29 eppd_ tables, checked row for row)',
          (select jsonb_object_agg(tbl, rows_cms) from pay_copy_report));
end $copy_mypayroll$;

commit;

notify pgrst, 'reload schema';

-- result: one line per table; "same" must be true everywhere
select tbl as "table", rows_mypayroll as "MyPayroll rows", rows_cms as "CMS rows", same as "identical" from pay_copy_report order by n;
