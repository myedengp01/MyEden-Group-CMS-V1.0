-- MyEden Group CMS V1.0 · v2026.11.03 · OTCF claims tied to the person (no more mistyped names)
-- 1. otcf_submissions.person_id: the Employee Master person the claim is for, chosen in the OTCF form from the CMS staff list.
-- 2. meg_staff_directory(): the staff list for the OTCF name field (current staff, and those who left in the last 4 months),
--    plus the signed-in user's own person, so the form can pre-select it. Names, Employee IDs and company only.
-- 3. cms_otcf_claimants(users): the person behind each claimant login, for the payroll "Pull approved OTCF" suggestions.
-- Additive only.
alter table public.otcf_submissions add column if not exists person_id uuid references public.employee_master(id);
create index if not exists otcf_submissions_person on public.otcf_submissions (person_id);

create or replace function public.meg_staff_directory()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $f$
  select jsonb_build_object(
    'me', (select ul.employee_master_id from public.cms_user_links ul where ul.user_id = auth.uid() limit 1),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code)) order by em.employee_name)
      from public.employee_master em
     where auth.uid() is not null and em.employee_name is not null
       and (em.employment_status in ('active', 'onboarding')
            or coalesce(em.actual_last_working_date, em.required_last_working_date) >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 120
            or exists (select 1 from public.eppd_employees ee join public.eppd_employments m on m.employee_id = ee.id
                        where ee.employee_master_id = em.id and (m.resigned_date is null or m.resigned_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 120)))), '[]'::jsonb));
$f$;
revoke all on function public.meg_staff_directory() from public, anon;
grant execute on function public.meg_staff_directory() to authenticated;

create or replace function public.cms_otcf_claimants(p_users uuid[], p_people uuid[] default '{}')
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
begin
  if not (public.cms_can('payroll', 'V') or public.cms_can('overtime', 'V')) then raise exception 'You do not have access to this.'; end if;
  return jsonb_build_object(
    'users', coalesce((select jsonb_agg(jsonb_build_object('user_id', ul.user_id, 'person_id', em.id, 'name', em.employee_name, 'employee_id', ee.id))
      from public.cms_user_links ul join public.employee_master em on em.id = ul.employee_master_id left join public.eppd_employees ee on ee.employee_master_id = em.id
     where ul.user_id = any(p_users)), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'name', em.employee_name, 'employee_id', ee.id))
      from public.employee_master em left join public.eppd_employees ee on ee.employee_master_id = em.id where em.id = any(p_people)), '[]'::jsonb));
end $f$;
revoke all on function public.cms_otcf_claimants(uuid[], uuid[]) from public, anon;
grant execute on function public.cms_otcf_claimants(uuid[], uuid[]) to authenticated;
