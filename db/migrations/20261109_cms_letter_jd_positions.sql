-- MyEden Group CMS V1.0 · v2026.11.09 · Letters: "Link to a JD position…" when no JD is found (CLC 9 Nov 2026)
-- The approved JD Manual positions of the person's company, for the picker; saving uses cms_person_position_set (Career Paths, needs careers E).
create or replace function public.cms_letter_jd_positions(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code); perform private.cms_require('letters', 'V', co);
  return jsonb_build_object('can_set', public.cms_can('careers', 'E', co), 'title', em.approved_job_title,
    'current', (select pp.position_id from public.cms_person_position pp where pp.person_id = em.id),
    'positions', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'title', p.job_title, 'level', p.level, 'reference', p.reference, 'department', d.name)
        order by d.name nulls last, p.level, p.job_title)
      from public.jd_positions p join public.jd_entities e on e.id = p.entity_id left join public.jd_departments d on d.id = p.department_id
     where private.cms_canon(e.code) = co and p.status = 'approved' and (p.effective_date is null or p.effective_date <= (now() at time zone 'Asia/Kuala_Lumpur')::date)), '[]'::jsonb));
end $f$;
revoke all on function public.cms_letter_jd_positions(uuid) from public, anon; grant execute on function public.cms_letter_jd_positions(uuid) to authenticated;
