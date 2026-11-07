-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-018 New hires & leavers report per payroll month (CLC 7 Nov 2026)
-- New hires (start date in the month), leavers (last working day in the month), upcoming leavers (resignation received, last day later),
-- transfers between companies (a new primary assignment under another company starting in the month) and headcount totals per company
-- (opening + joined − left = closing). One company or all. Salary figures only for roles with "See salaries in the New hires & leavers
-- report" (HR, Admin, Director by default; Super Admin always); others get the same report without them. Read-only, additive.

insert into public.cms_modules (code, label, grp, phase, sort_order, kind, parent, acts, description)
values ('reports.movement_salary', 'See salaries in the New hires & leavers report', 'Operations', 5, 91, 'special', 'reports', 'V',
        'Basic salary, allowances and final settlement amounts in the New hires & leavers report')
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('admin', 'reports.movement_salary', 'V'), ('hr', 'reports.movement_salary', 'V'), ('director', 'reports.movement_salary', 'V')
on conflict (role_code, module_code) do nothing;

create or replace function public.cms_movement_report(p_month date, p_company text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare m0 date := date_trunc('month', p_month)::date; m1 date; co text := nullif(nullif(upper(btrim(coalesce(p_company, ''))), ''), 'ALL');
  pay boolean;
begin
  if not public.cms_can('reports', 'V') then raise exception 'You do not have access to reports.'; end if;
  m1 := (m0 + interval '1 month')::date;   -- first day of the next month
  pay := public.cms_can('reports.movement_salary', 'V');
  return (
  with base as (
    select e.id employment_id, ee.id employee_id, em.id person_id, coalesce(em.employee_name, ee.full_name) name, coalesce(em.employee_id, ee.emp_id) eid,
           private.cms_canon(coalesce(em.company_code, (select c.code from public.eppd_assignments a join public.eppd_companies c on c.id = a.company_id
                                                        where a.employment_id = e.id and a.is_primary order by a.start_date desc nulls last limit 1))) company,
           d.name dept, coalesce(nullif(em.approved_job_title, ''), jt.name) family,
           nullif(split_part(coalesce(em.job_title_level, ''), '|', 2), '') jd_title, nullif(split_part(coalesce(em.job_title_level, ''), '|', 1), '') jd_level,
           coalesce(e.hours_class, e.job_status) job_class, em.employment_type, e.join_date, e.resigned_date, e.resignation_letter_date, e.notice_until,
           e.leaving_reason, em.probation_end_date, em.source_application_id, e.department_id
      from public.eppd_employments e join public.eppd_employees ee on ee.id = e.employee_id
      left join public.employee_master em on em.id = ee.employee_master_id
      left join public.eppd_departments d on d.id = e.department_id
      left join public.eppd_job_titles jt on jt.id = e.job_title_id
  ), scoped as (
    select * from base b where (co is null or b.company = co) and public.cms_can('reports', 'V', b.company)
  ), sal as (   -- basic and recurring allowances on a date, primary assignment
    select s.employment_id, x.dt,
      (select jsonb_build_object('amount', h.amount, 'basis', h.pay_basis) from public.eppd_assignments a join public.eppd_salary_history h on h.assignment_id = a.id
        where a.employment_id = s.employment_id and a.is_primary and h.effective_from <= x.dt order by h.effective_from desc, h.id desc limit 1) basic,
      (select coalesce(sum(al.amount), 0) from public.eppd_assignments a join public.eppd_allowances al on al.assignment_id = a.id
        where a.employment_id = s.employment_id and a.is_primary and coalesce(al.start_date, x.dt) <= x.dt and (al.end_date is null or al.end_date >= x.dt)) allowances
    from scoped s cross join lateral (select greatest(least(coalesce(s.resigned_date, s.join_date), m1 - 1), s.join_date) dt) x
  )
  select jsonb_build_object(
    'month', to_char(m0, 'YYYY-MM'), 'company', coalesce(co, 'ALL'), 'can_salary', pay,
    'reason_labels', (select coalesce(jsonb_object_agg(code, label), '{}'::jsonb) from public.eppd_lookups where category = 'leaving_reason'),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'short', c.short_name) order by c.sort_order), '[]'::jsonb)
                    from public.cms_companies c where c.is_active and public.cms_can('reports', 'V', c.code)),
    'new_hires', coalesce((select jsonb_agg(jsonb_build_object(
        'name', s.name, 'employee_id', s.eid, 'person_id', s.person_id, 'company', s.company, 'dept', s.dept, 'position', coalesce(s.jd_title, s.family),
        'family', s.family, 'level', s.jd_level, 'class', s.job_class, 'employment_type', s.employment_type, 'start', s.join_date, 'probation_end', s.probation_end_date,
        'basic', case when pay then sl.basic->'amount' end, 'basis', sl.basic->>'basis', 'allowances', case when pay then sl.allowances end,
        'statutory', (select jsonb_build_object('epf', nullif(p.epf_no, '') is not null, 'socso', nullif(p.socso_no, '') is not null, 'tax', nullif(p.tax_no, '') is not null)
                        from public.eppd_employee_private p where p.employee_id = s.employee_id),
        'offer_ref', (select l.document_id from public.eaf_loec_records l where l.application_id = s.source_application_id and l.status not in ('draft', 'cancelled', 'superseded')
                       order by l.revision desc limit 1),
        'first_payroll', (select to_char(min(r.period), 'YYYY-MM') from public.eppd_pay_lines pl join public.eppd_pay_runs r on r.id = pl.run_id where pl.employee_id = s.employee_id and r.period >= date_trunc('month', s.join_date)))
        order by s.company, s.join_date, s.name)
      from scoped s left join sal sl on sl.employment_id = s.employment_id where s.join_date >= m0 and s.join_date < m1), '[]'::jsonb),
    'leavers', coalesce((select jsonb_agg(jsonb_build_object(
        'name', s.name, 'employee_id', s.eid, 'person_id', s.person_id, 'company', s.company, 'dept', s.dept, 'position', coalesce(s.jd_title, s.family), 'level', s.jd_level,
        'class', s.job_class, 'start', s.join_date, 'last_day', s.resigned_date, 'resignation_date', s.resignation_letter_date,
        'service_months', (extract(year from age(s.resigned_date + 1, s.join_date)) * 12 + extract(month from age(s.resigned_date + 1, s.join_date)))::int,
        'reason', s.leaving_reason, 'basic', case when pay then sl.basic->'amount' end, 'basis', sl.basic->>'basis',
        'settlement', (select jsonb_build_object('notice_mode', st.notice_mode, 'notice_days', st.notice_days, 'notice_amount', case when pay then st.notice_amount end,
                         'al_mode', st.al_mode, 'al_days', st.al_days, 'al_amount', case when pay then st.al_amount end)
                         from public.eppd_settlements st where st.employment_id = s.employment_id order by st.updated_at desc limit 1),
        'letter_ref', (select r.reference from public.hr_letter_records r where r.employee_id = s.person_id and r.template_code like 'RL%' and r.status = 'issued' order by r.issued_at desc limit 1))
        order by s.company, s.resigned_date, s.name)
      from scoped s left join sal sl on sl.employment_id = s.employment_id where s.resigned_date >= m0 and s.resigned_date < m1), '[]'::jsonb),
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object(
        'name', s.name, 'employee_id', s.eid, 'person_id', s.person_id, 'company', s.company, 'dept', s.dept, 'position', coalesce(s.jd_title, s.family),
        'resignation_date', s.resignation_letter_date, 'last_day', s.resigned_date, 'reason', s.leaving_reason) order by s.company, s.resigned_date, s.name)
      from scoped s where s.resigned_date >= m1 and s.resignation_letter_date is not null and s.resignation_letter_date < m1), '[]'::jsonb),
    'transfers', coalesce((select jsonb_agg(t.j order by t.j->>'date', t.j->>'name') from (
        select jsonb_build_object('name', s.name, 'employee_id', s.eid, 'person_id', s.person_id, 'date', a.start_date,
          'from', private.cms_canon(cp.code), 'to', private.cms_canon(cn.code), 'dept', s.dept, 'position', coalesce(s.jd_title, s.family)) j
          from scoped b join public.eppd_assignments a on a.employment_id = b.employment_id and a.is_primary and a.start_date >= m0 and a.start_date < m1
          join public.eppd_companies cn on cn.id = a.company_id
          join lateral (select a2.company_id from public.eppd_assignments a2 where a2.employment_id = a.employment_id and a2.is_primary and a2.id <> a.id
                          and coalesce(a2.start_date, '1900-01-01') < a.start_date order by a2.start_date desc nulls last limit 1) prev on true
          join public.eppd_companies cp on cp.id = prev.company_id
          join scoped s on s.employment_id = b.employment_id
         where prev.company_id <> a.company_id) t), '[]'::jsonb),
    'totals', coalesce((select jsonb_agg(jsonb_build_object('company', x.company, 'opening', x.opening, 'joined', x.joined, 'left', x.left_, 'closing', x.closing) order by x.company) from (
        select s.company,
               count(*) filter (where s.join_date < m0 and (s.resigned_date is null or s.resigned_date >= m0)) opening,
               count(*) filter (where s.join_date >= m0 and s.join_date < m1) joined,
               count(*) filter (where s.resigned_date >= m0 and s.resigned_date < m1) left_,
               count(*) filter (where s.join_date < m1 and (s.resigned_date is null or s.resigned_date >= m1)) closing
          from scoped s group by s.company) x
        where x.opening + x.joined + x.left_ + x.closing > 0), '[]'::jsonb)));
end $f$;
revoke all on function public.cms_movement_report(date, text) from public, anon;
grant execute on function public.cms_movement_report(date, text) to authenticated;
