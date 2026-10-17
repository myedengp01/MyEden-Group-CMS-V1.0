-- =====================================================================
-- MyPayroll-System-V2.0  ·  010_company_structure.sql  ·  UVN v2026.10.10-19:00
-- Run in the MyPayroll-System project AFTER 001–009. Safe to re-run.
--
-- Puts the paying companies and departments in line with MyEden Group's structure:
--   Paying companies (active):  Myeden Group · Myeden Edu Hub · Happy Dino · Aborne Project
--   No longer paying (kept on record, inactive): Myeden Holding · Tadika Genius Eden · PJK Eden ·
--     Tadika Happy Dino · Eden Childcare · White Feather
--   Departments:  E1/E6/E7 Taska Genius Eden, E10/E11 Pusat Jagaan Kanak-Kanak Eden, HQ  → Myeden Group
--                 E3 Tadika Genius Eden, E3+ Tadika Happy Dino                           → Myeden Edu Hub
--                 E8 merged into HQ; E2, E4, E5, E9 switched off (former staff keep them on record)
-- Moves every paying-company record (current and former staff) off the inactive companies:
--   Tadika Genius Eden, Tadika Happy Dino → Myeden Edu Hub
--   PJK Eden, Eden Childcare, Myeden Holding → Myeden Group
-- then applies the per-person decisions below, and moves the 2026 payroll lines (finalised months
-- included) to the same companies. Only the company changes: no amount, total or status.
-- Also adds eppd_move_paying_company() used by Payroll › Paying companies.
-- =====================================================================

-- (Steps 1–4, the one-off company and department changes, are not included: the copied data already has them.)

-- ---------- 5. move a person to another paying company from a given month (Payroll › Paying companies) ----------
-- If nothing has been paid on the old record before that month, the record simply changes company.
-- Otherwise the old record ends the day before and a new one starts that month, with the same salary
-- history, allowances and statutory switches, so earlier months (and their EA form) keep the old company.
create or replace function public.eppd_move_paying_company(p_assignment bigint, p_company bigint, p_from date)
returns bigint language plpgsql security definer set search_path = public as $$
declare a public.eppd_assignments; v_from date := date_trunc('month', p_from)::date; v_new bigint; v_paid boolean; v_fin text;
begin
  if not public.eppd_has_role(array['admin','hr']) then raise exception 'Only admin or HR can change paying companies.'; end if;
  select * into a from public.eppd_assignments where id = p_assignment for update;
  if not found then raise exception 'Paying company record not found.'; end if;
  if not exists (select 1 from public.eppd_companies where id = p_company and is_active) then raise exception 'Choose an active paying company.'; end if;
  if a.company_id = p_company then return a.id; end if;
  if a.end_date is not null and a.end_date < v_from then raise exception 'This record already ended on %.', a.end_date; end if;
  select string_agg(to_char(r.period, 'Mon YYYY'), ', ' order by r.period) into v_fin
    from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
   where l.assignment_id = a.id and r.period >= v_from and r.status = 'finalised';
  if v_fin is not null then raise exception 'Already finalised under the current company: %. Choose a later month, or ask an admin to reopen it.', v_fin; end if;
  select exists (select 1 from public.eppd_pay_lines l join public.eppd_pay_runs r on r.id = l.run_id
                  where l.assignment_id = a.id and r.period < v_from) into v_paid;
  if not v_paid and (a.start_date is null or a.start_date >= v_from or not exists (select 1 from public.eppd_pay_lines where assignment_id = a.id)) then
    update public.eppd_assignments set company_id = p_company where id = a.id;
    return a.id;
  end if;
  -- split: old record ends, new one starts
  update public.eppd_assignments set is_primary = false, end_date = v_from - 1 where id = a.id;
  insert into public.eppd_assignments (employment_id, company_id, is_primary, start_date, end_date, epf_ee, epf_er, socso_ee, socso_er, eis_ee, eis_er, socso_nei_opt_out)
  values (a.employment_id, p_company, a.is_primary, v_from, a.end_date, a.epf_ee, a.epf_er, a.socso_ee, a.socso_er, a.eis_ee, a.eis_er, a.socso_nei_opt_out)
  returning id into v_new;
  insert into public.eppd_salary_history (assignment_id, effective_from, amount, pay_basis, reason, note)
  select v_new, effective_from, amount, pay_basis, reason, note from public.eppd_salary_history where assignment_id = a.id;
  insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
  select v_new, payment_type_id, amount, greatest(coalesce(start_date, v_from), v_from), end_date, note
    from public.eppd_allowances where assignment_id = a.id and (end_date is null or end_date >= v_from);
  return v_new;
end $$;
revoke execute on function public.eppd_move_paying_company(bigint, bigint, date) from public, anon;
grant execute on function public.eppd_move_paying_company(bigint, bigint, date) to authenticated;

