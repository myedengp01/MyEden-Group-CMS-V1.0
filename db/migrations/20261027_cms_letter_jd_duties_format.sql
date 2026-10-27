-- MyEden Group CMS V1.0 · HR letters: {{jd_responsibilities}} in the JD Manual's own layout
-- Each duty is numbered with its title on one line (bold in Word letters) and its description on the next line, indented:
--   1. Check-In, Check-Out & Supervision
--       Receive, account for and supervise assigned students ...
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.cms_letter_jd_lookup(uuid,text,uuid)'::regprocedure);
  n := replace(d, $x$string_agg(case when r.rn <= 26 then chr(96 + r.rn::int) else r.rn::text end || '. ' || btrim(coalesce(r.title, '')) || coalesce(' — ' || nullif(btrim(r.description), ''), ''), E'\n' order by r.rn)$x$,
    $x$string_agg(r.rn::text || '. ' || btrim(coalesce(r.title, '')) || coalesce(E'\n    ' || nullif(btrim(r.description), ''), ''), E'\n' order by r.rn)$x$);
  if n = d then raise exception 'cms_letter_jd_lookup patch point not found'; end if;
  execute n;
end $m$;
update public.hr_letter_placeholders set description = 'The JD''s responsibilities as in the JD Manual: numbered titles (bold in Word letters), each with its description on the next line', updated_at = now()
 where key = 'jd_responsibilities';
