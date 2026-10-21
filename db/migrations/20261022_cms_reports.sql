-- MyEden Group CMS V1.0 · Phase 5e · Reports & Analytics
-- One read-only call that returns the facts the Reports page charts: people (start / end dates, company, department,
-- gender, leaving reason), payroll cost per month and company (only for users who may view Payroll) and claims (only the
-- forms the user may view, via cms_claims). Names are included only for users who may view People.

create or replace function public.cms_reports()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare names boolean := public.cms_can('people', 'V'); pay boolean := public.cms_can('payroll', 'V');
begin
  perform private.cms_require('reports', 'V');
  return jsonb_build_object(
    'can_pay', pay, 'can_names', names, 'can_export', public.cms_can('reports', 'X'), 'today', (now() at time zone 'Asia/Kuala_Lumpur')::date,
    'companies', coalesce((select jsonb_agg(jsonb_build_object('code', private.cms_canon(c.code), 'name', c.name) order by c.is_primary desc nulls last, c.code)
        from (select distinct on (private.cms_canon(code)) * from public.eppd_companies order by private.cms_canon(code), is_primary desc nulls last) c), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
          'id', em.id, 'name', case when names then em.employee_name end, 'eid', case when names then em.employee_id end,
          'co', private.cms_canon(em.company_code), 'dept', coalesce(nullif(em.department, ''), j.dept), 'pos', coalesce(nullif(em.approved_job_title, ''), j.title),
          'g', upper(left(coalesce(em.gender_code, ''), 1)), 'st', em.employment_status, 'type', em.employment_type,
          's', coalesce(em.start_date, j.join_date), 'e', case when em.employment_status = 'former' then coalesce(j.resigned_date, em.actual_last_working_date) end,
          'r', coalesce(nullif(j.leaving_reason, ''), nullif(em.exit_reason, ''))))
      from public.employee_master em
      left join lateral (select m.join_date, m.resigned_date, m.leaving_reason, t.name title, dp.name dept
                           from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id
                           left join public.eppd_job_titles t on t.id = m.job_title_id left join public.eppd_departments dp on dp.id = m.department_id
                          where e.employee_master_id = em.id order by m.join_date desc nulls last limit 1) j on true
      where em.employment_status in ('active', 'onboarding', 'former') and private.cms_can_company('reports', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'payroll', case when pay then coalesce((select jsonb_agg(jsonb_build_object('period', x.period, 'status', x.status, 'co', x.co, 'n', x.n, 'gross', x.gross,
          'epf', x.epf, 'socso', x.socso, 'eis', x.eis, 'reimb', x.reimb, 'net', x.net) order by x.period, x.co)
      from (select r.period, r.status, private.cms_canon(c.code) co, count(*) n, sum(coalesce(l.gross, 0)) gross, sum(coalesce(l.epf_er, 0)) epf,
                   sum(coalesce(l.socso_er, 0)) socso, sum(coalesce(l.eis_er, 0)) eis, sum(coalesce(l.reimbursements, 0)) reimb, sum(coalesce(l.net_paid, l.net, 0)) net
              from public.eppd_pay_runs r join public.eppd_pay_lines l on l.run_id = r.id and not coalesce(l.excluded, false)
              left join public.eppd_companies c on c.id = l.company_id
             where private.cms_can_company('payroll', 'V', private.cms_canon(c.code))
             group by r.period, r.status, private.cms_canon(c.code)) x), '[]'::jsonb) else '[]'::jsonb end,
    'claims', coalesce((select jsonb_agg(jsonb_build_object('form', c.form_code, 'label', c.form_name, 'co', c.company_code, 'amt', c.amount, 'unit', c.amount_unit,
          'stage', c.stage, 'sub', (c.submitted_at at time zone 'Asia/Kuala_Lumpur')::date, 'paid', (c.payment_done_at at time zone 'Asia/Kuala_Lumpur')::date))
      from public.cms_claims(null) c), '[]'::jsonb));
end $$;

revoke all on function public.cms_reports() from public, anon;
grant execute on function public.cms_reports() to authenticated;

-- the page goes live
update public.cms_modules set phase = 5 where code = 'reports';
