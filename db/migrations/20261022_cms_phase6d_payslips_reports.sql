-- MyEden Group CMS V1.0 · Phase 6d · Payslips & Reports inside the CMS
-- Identity & bank details for payroll pages in the CMS now come through one read-only view that follows the CMS permissions
-- column by column, instead of the whole private table:
--   employee_id and date of birth (for EPF / SOCSO age rates): Payroll "view";
--   IC / passport, EPF, SOCSO and income tax numbers: also "See IC and passport numbers";
--   bank and account number: also "See bank account details".
-- Home address, spouse and emergency contacts are never shown on payroll pages.
-- The wider Phase 6c read rule on the private table is switched off (kept, but matches nothing), so Payroll "view" alone
-- no longer reads the whole row. MyPayroll's own rules (its admin / hr users) are unchanged.

create or replace function public.cms_payroll_private()
returns table (employee_id bigint, dob date, nric text, passport_no text, bank_code text, bank_account_no text, epf_no text, socso_no text, tax_no text)
language plpgsql stable security definer set search_path = public as $f$
declare v_ic boolean; v_bank boolean;
begin
  if not public.cms_can('payroll', 'V') then return; end if;
  v_ic := public.cms_can('people.ic', 'V'); v_bank := public.cms_can('people.bank', 'V');
  return query select p.employee_id, p.dob,
    case when v_ic then p.nric end, case when v_ic then p.passport_no end,
    case when v_bank then p.bank_code end, case when v_bank then p.bank_account_no end,
    case when v_ic then p.epf_no end, case when v_ic then p.socso_no end, case when v_ic then p.tax_no end
  from public.eppd_employee_private p;
end $f$;
revoke all on function public.cms_payroll_private() from public, anon;
grant execute on function public.cms_payroll_private() to authenticated;

create or replace view public.cms_eppd_private with (security_invoker = true) as select * from public.cms_payroll_private();
revoke all on public.cms_eppd_private from anon;
grant select on public.cms_eppd_private to authenticated;

alter policy "CMS payroll read" on public.eppd_employee_private using (false);
