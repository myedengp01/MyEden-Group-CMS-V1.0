-- MyEden Group CMS V1.0 · v2026.11.09 · Letters: {{department}} / {{current_department}} show the centre / department name, not its code (CLC 9 Nov 2026)
-- e.g. "E6" → "Taska Genius Eden" (the same name as Facts: cms_employee_payroll unit → cms_units; else the code on the record → cms_units).
-- One-off (applied separately, 9 Nov 2026, on CLC's approval): Sia Beng Fang's job title Senior Playgroup Mentor → Senior Playgroup Teacher (L3),
-- Career Paths JD MEG-HR-JD-PG-003 since 1 Mar 2026 ("Mentor" renamed "Teacher"); logged on her profile.
do $m$ declare src text; o1 text; n1 text;
begin
  select pg_get_functiondef('private.cms_letter_context(uuid)'::regprocedure) into src;
  if position('cms_units' in src) > 0 then return; end if;
  o1 := $o$'department', coalesce(em.department, (select dept from job)), 'current_department', coalesce(em.department, (select dept from job)),$o$;
  n1 := $n$'department', coalesce((select u.name from public.cms_employee_payroll pp join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person limit 1),
                       (select u.name from public.cms_units u where u.code = em.department limit 1), em.department, (select dept from job)),
    'current_department', coalesce((select u.name from public.cms_employee_payroll pp join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person limit 1),
                       (select u.name from public.cms_units u where u.code = em.department limit 1), em.department, (select dept from job)),$n$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_context has changed'; end if;
  execute replace(src, o1, n1);
end $m$;
