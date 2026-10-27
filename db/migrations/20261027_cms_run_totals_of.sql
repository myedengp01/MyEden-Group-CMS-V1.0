-- MyEden Group CMS V1.0 · a payroll month's stored totals, worked out again from its lines (used by corrections)
-- Same figures the payroll stores when a month is saved: sums of the lines that are not excluded, and employer cost = gross + employer
-- EPF + employer SOCSO + employer EIS. p_company null → all companies.
create or replace function private.cms_totals_of(p_run bigint, p_company bigint) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $f$
  select jsonb_build_object('gross', round(coalesce(sum(gross), 0), 2), 'net', round(coalesce(sum(net), 0), 2), 'pcb', round(coalesce(sum(pcb), 0), 2), 'lines', count(*),
    'eis_ee', round(coalesce(sum(eis_ee), 0), 2), 'eis_er', round(coalesce(sum(eis_er), 0), 2), 'epf_ee', round(coalesce(sum(epf_ee), 0), 2), 'epf_er', round(coalesce(sum(epf_er), 0), 2),
    'net_paid', round(coalesce(sum(net_paid), 0), 2), 'socso_ee', round(coalesce(sum(socso_ee), 0), 2), 'socso_er', round(coalesce(sum(socso_er), 0), 2),
    'socso_ee_nei', round(coalesce(sum(socso_ee_nei), 0), 2), 'employer_cost', round(coalesce(sum(gross + epf_er + socso_er + eis_er), 0), 2),
    'reimbursements', round(coalesce(sum(reimbursements), 0), 2), 'personal_deductions', round(coalesce(sum(personal_deductions), 0), 2))
  from public.eppd_pay_lines where run_id = p_run and not excluded and (p_company is null or company_id = p_company) $f$;
revoke all on function private.cms_totals_of(bigint, bigint) from public, anon, authenticated;
