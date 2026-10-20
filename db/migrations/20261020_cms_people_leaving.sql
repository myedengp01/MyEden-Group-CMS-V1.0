-- MyEden Group CMS V1.0 · View People: leaving reason, rehire eligibility and number of periods from payroll (PRI-002).
-- New function, so the People list keeps working if it is missing (it is merged in when present).
create or replace function public.cms_people_leaving()
returns table (id uuid, leaving_reason text, leaving_label text, leaving_note text, rehire text, rehire_note text, periods int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform private.cms_require('people', 'V');
  return query
  select em.id, le.leaving_reason, lk.label::text, le.leaving_note, le.rehire_eligibility, le.rehire_note,
         (select count(*)::int from public.eppd_employments m2 where m2.employee_id = ee.id)
  from public.employee_master em
  join public.eppd_employees ee on ee.employee_master_id = em.id
  join lateral (select e.* from public.eppd_employments e where e.employee_id = ee.id
                order by e.join_date desc nulls last, e.id desc limit 1) le on true
  left join public.eppd_lookups lk on lk.category = 'leaving_reason' and lk.code = le.leaving_reason;
end $$;
revoke all on function public.cms_people_leaving() from public, anon;
grant execute on function public.cms_people_leaving() to authenticated;
