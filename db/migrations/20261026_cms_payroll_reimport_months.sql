-- MyEden Group CMS V1.0 · Import Past Months: choose which months to (re)import, with a mandatory reason
-- The page now imports only the ticked months (months made or reopened in the payroll still cannot be replaced).
-- The reason and the months are written to the payroll log and the CMS audit log. Replaced months keep no old copy.
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.eppd_import_pay_history(jsonb)'::regprocedure);
  n := replace(d, $x$perform public.eppd_pay_log('PAY_IMPORT', jsonb_build_object('months', n_runs, 'lines', n_lines, 'source', p->>'source'));$x$,
    $x$perform public.eppd_pay_log('PAY_IMPORT', jsonb_build_object('months', n_runs, 'lines', n_lines, 'source', p->>'source', 'reason', p->>'reason',
    'periods', (select jsonb_agg(x->>'period') from jsonb_array_elements(coalesce(p->'runs', '[]'::jsonb)) x)));
  if nullif(btrim(coalesce(p->>'reason', '')), '') is not null then
    perform private.cms_log('payroll.import', 'eppd_pay_runs', null, null,
      'Imported ' || (select string_agg(to_char((x->>'period')::date, 'Mon YYYY'), ', ') from jsonb_array_elements(p->'runs') x) || ' from the workbook (' || n_lines || ' lines): ' || (p->>'reason'),
      jsonb_build_object('months', n_runs, 'lines', n_lines, 'reason', p->>'reason'));
  end if;$x$);
  if n = d and strpos(d, 'payroll.import') = 0 then raise exception 'eppd_import_pay_history patch point not found'; end if;
  if n <> d then execute n; end if;
end $m$;
