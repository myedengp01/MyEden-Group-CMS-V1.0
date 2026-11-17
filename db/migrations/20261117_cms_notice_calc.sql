-- MyEden Group CMS V1.0 · v2026.11.17 · Notice period calculator (CLC 17 Nov 2026): what the calculator needs for one employee —
-- join date, probation / confirmation, the notice in the contract, a recorded resignation, and (payroll access only) the basic salary.
-- Read-only; HR / Admin (people or leave access).
create or replace function public.cms_notice_context(p_employee bigint)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare ee public.eppd_employees; em public.employee_master; x public.eppd_employments; r public.cms_resignations; sal record;
begin
  if not (public.cms_can('people', 'V') or public.cms_can('leave', 'V')) then raise exception 'You do not have access to this.'; end if;
  select * into ee from public.eppd_employees where id = p_employee;
  if ee.id is null then raise exception 'Employee not found.'; end if;
  select * into em from public.employee_master where id = ee.employee_master_id;
  select * into x from public.eppd_employments where employee_id = ee.id order by join_date desc limit 1;
  if em.id is not null then select * into r from public.cms_resignations where person_id = em.id order by created_at desc limit 1; end if;
  if public.cms_can('payroll', 'V') then
    select s.amount, s.pay_basis into sal from public.eppd_salary_history s join public.eppd_assignments a on a.id = s.assignment_id
     where a.employment_id = x.id and a.is_primary order by s.effective_from desc, s.id desc limit 1;
  end if;
  return jsonb_build_object('employee_id', ee.id, 'name', ee.full_name, 'emp_id', ee.emp_id,
    'join_date', x.join_date, 'confirmation_status', x.confirmation_status, 'confirmed_date', x.confirmed_date, 'resigned_date', x.resigned_date,
    'contract_notice', case when em.notice_period_value is not null then jsonb_build_object('value', em.notice_period_value, 'unit', em.notice_period_unit) end,
    'resignation', case when r.person_id is not null then jsonb_build_object('letter_date', r.letter_date, 'notice_start', r.notice_start, 'notice_end', r.notice_end, 'status', r.status) end,
    'salary', case when sal.amount is not null then jsonb_build_object('amount', sal.amount, 'pay_basis', sal.pay_basis) end,
    'policy', (select value from public.eppd_policies where key = 'notice_period'));
end $f$;
revoke all on function public.cms_notice_context(bigint) from public, anon; grant execute on function public.cms_notice_context(bigint) to authenticated;
