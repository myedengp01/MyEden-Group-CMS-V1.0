-- MyEden Group CMS V1.0 · v2026.10.17-17:50 · dashboard claim figures follow the claim stages
-- (waiting for approval, ready to process, waiting for payment) and the signed-in user's CMS roles.

-- dashboard figures
create or replace function public.cms_dashboard()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb; v_c jsonb;
begin
  perform private.cms_require('dashboard', 'V');
  select jsonb_build_object(
    'people', (select jsonb_build_object(
                  'active', count(*) filter (where employment_status = 'active'),
                  'onboarding', count(*) filter (where employment_status = 'onboarding'),
                  'applicants', count(*) filter (where employment_status = 'applicant'),
                  'former', count(*) filter (where employment_status = 'former'),
                  'total', count(*)) from public.employee_master),
    'active_by_employer', (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
                  select private.cms_canon(company_code) c, count(*) n from public.employee_master
                  where employment_status = 'active' group by 1) x),
    'active_by_payer', (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
                  select coalesce(pp.paying_company_code, private.cms_canon(em.company_code)) c, count(*) n
                  from public.employee_master em left join public.cms_employee_payroll pp on pp.employee_master_id = em.id
                  where em.employment_status = 'active' group by 1) x),
    'positions', (select count(*) from public.jd_positions where status = 'approved'),
    'departments', (select count(*) from public.jd_departments),
    'applications_pending', (select count(*) from public.eaf_applications where status = 'pending'),
    'handbook_outstanding', (select count(*) from public.handbook_assignments
                  where revoked_at is null and status in ('assigned', 'viewed')),
    'logins', (select count(*) from auth.users),
    'logins_with_role', (select count(distinct user_id) from public.cms_user_roles where is_active),
    'logins_unlinked', (select count(*) from auth.users u where not exists (select 1 from public.cms_user_links l where l.user_id = u.id)),
    'recent', case when public.cms_can('admin.audit', 'V') then (
                  select coalesce(jsonb_agg(jsonb_build_object('at', a.at, 'actor', a.actor_email, 'action', a.action,
                         'summary', a.summary) order by a.id desc), '[]'::jsonb)
                  from (select * from public.cms_audit_log order by id desc limit 8) a)
               else '[]'::jsonb end,
    'snapshot', (select jsonb_build_object('id', id, 'taken_at', taken_at, 'label', label, 'summary', summary)
                 from public.cms_schema_snapshots order by id desc limit 1))
  into v;
  with w as materialized (select c.stage, c.form_code, c.amount, c.amount_unit from public.cms_claims() c
                           where c.stage in ('approval', 'processing', 'payment'))
  select jsonb_build_object(
    'claims_pending', (select count(*) from w),
    'claims_by_stage', (select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) from (select stage s, count(*) n from w group by 1) x),
    'claims_pending_by_form', (select coalesce(jsonb_object_agg(f, n), '{}'::jsonb) from (select form_code f, count(*) n from w group by 1) x),
    'claims_pending_amount', (select coalesce(sum(amount) filter (where amount_unit = 'RM'), 0) from w))
  into v_c;
  return v || v_c;
end $$;

notify pgrst, 'reload schema';
