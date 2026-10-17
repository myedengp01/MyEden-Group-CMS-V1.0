-- =====================================================================
-- MyPayroll-System-V2.0  ·  009_socso_nei.sql  ·  UVN v2026.10.10-17:45
-- Run in the MyPayroll-System project AFTER 001–008. Safe to re-run.
--
-- Keeps the employee's SOCSO in two parts on every pay line:
--   invalidity  +  non-employment injury (NEI, from June 2026)
-- New column eppd_pay_lines.socso_ee_nei (invalidity = socso_ee − socso_ee_nei).
--
-- Months already saved (imported Jan–Sep 2026 and any month made in the app) are filled in by
-- matching each employee SOCSO amount against the SOCSO table in force that month:
--   amount = invalidity + NEI  → NEI from the table
--   amount = invalidity only   → NEI 0 (opted out)
--   before the NEI table       → NEI 0 (all invalidity)
-- No amount, total or status changes; only how the existing employee SOCSO divides.
-- Lines that match no table row are listed at the end and left at NEI 0.
-- =====================================================================

alter table public.eppd_pay_lines add column if not exists socso_ee_nei numeric(12,2) not null default 0;

-- ---------- save path: include the NEI part ----------
create or replace function public.eppd_insert_pay_lines(p_run bigint, p_lines jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    insert into public.eppd_pay_lines (run_id, employee_id, assignment_id, company_id, emp_name, emp_code, mode, excluded,
      items, overrides, inputs, warnings, gross, epf_wage, socso_wage, eis_wage, epf_ee, epf_er, socso_ee, socso_ee_nei, socso_er,
      eis_ee, eis_er, pcb, net, personal_deductions, reimbursements, net_paid, note)
    values (p_run, (x->>'employee_id')::bigint, nullif(x->>'assignment_id', '')::bigint, nullif(x->>'company_id', '')::bigint,
      x->>'emp_name', x->>'emp_code', coalesce(x->>'mode', 'auto'), coalesce((x->>'excluded')::boolean, false),
      coalesce(x->'items', '[]'::jsonb), coalesce(x->'overrides', '{}'::jsonb), coalesce(x->'inputs', '{}'::jsonb),
      coalesce(x->'warnings', '[]'::jsonb),
      coalesce((x->>'gross')::numeric, 0), coalesce((x->>'epf_wage')::numeric, 0), coalesce((x->>'socso_wage')::numeric, 0),
      coalesce((x->>'eis_wage')::numeric, 0), coalesce((x->>'epf_ee')::numeric, 0), coalesce((x->>'epf_er')::numeric, 0),
      coalesce((x->>'socso_ee')::numeric, 0), coalesce((x->>'socso_ee_nei')::numeric, 0), coalesce((x->>'socso_er')::numeric, 0),
      coalesce((x->>'eis_ee')::numeric, 0), coalesce((x->>'eis_er')::numeric, 0), coalesce((x->>'pcb')::numeric, 0),
      coalesce((x->>'net')::numeric, 0), coalesce((x->>'personal_deductions')::numeric, 0),
      coalesce((x->>'reimbursements')::numeric, 0), coalesce((x->>'net_paid')::numeric, 0), x->>'note');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.eppd_insert_pay_lines(bigint, jsonb) from public, anon, authenticated;

-- (The one-off fill-in of saved months is not included: the copied data already has it.)
