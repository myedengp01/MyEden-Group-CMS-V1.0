-- MyEden Group CMS V1.0 · v2026.11.16 · profile header gives the last working day, so former staff show their final length of service
-- (service shown as nY nM nD, start day counted as day 1; CLC 16 Nov 2026). Patch in place, marker-guarded.
do $m$ declare src text;
begin
  select pg_get_functiondef('public.cms_person_profile(uuid)'::regprocedure) into src;
  if position('''last_day'', em.actual_last_working_date' in src) > 0 then return; end if;
  if position('''start'', em.start_date,' in src) = 0 then raise exception 'cms_person_profile has changed'; end if;
  execute replace(src, '''start'', em.start_date,', '''start'', em.start_date, ''last_day'', em.actual_last_working_date,');
end $m$;
