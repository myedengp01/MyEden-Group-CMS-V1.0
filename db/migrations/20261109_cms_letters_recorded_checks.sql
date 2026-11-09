-- MyEden Group CMS V1.0 · v2026.11.09 · Recorded letters: date checks; Update records: "no change" for the same position (CLC 9 Nov 2026)
-- 1. cms_letter_record refuses key dates that cannot be read or are before 2000, and a probation end before its start.
-- 2. cms_letter_apply_preview: the position item says when the title is already the same ('same' = true; the screen leaves it unticked).
-- 3. One-off (applied separately, 9 Nov 2026, on CLC's approval): MEG/HR/LOP/2026/0007 dates corrected in place
--    (1 March 2 → 1 March 2026; 31 August 1902 → 31 August 2026), immutability trigger off/on in the same transaction, logged as "corrected".
do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_record(jsonb)'::regprocedure) into src;
  if position('cannot be read' in src) > 0 then return; end if;
  o1 := $o$  v_snap := jsonb_build_object('letter_date', v_date,$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_record has changed'; end if;
  execute replace(src, o1, $n$  if v_date < date '2000-01-01' then raise exception 'The letter date cannot be before 2000.'; end if;
  if exists (select 1 from jsonb_each_text(v_fields) e where e.key in ('effective_date', 'promotion_probation_start', 'promotion_probation_end', 'increment_effective_date')
              and (private.cms_parse_date(e.value) is null or private.cms_parse_date(e.value) < date '2000-01-01' or private.cms_parse_date(e.value) > date '2100-01-01')) then
    raise exception 'A date in the key terms cannot be read or is before 2000 — check the dates (e.g. 1 March 2026).'; end if;
  if private.cms_parse_date(v_fields->>'promotion_probation_end') < private.cms_parse_date(v_fields->>'promotion_probation_start') then
    raise exception 'The probation ends before it starts.'; end if;
$n$ || o1);
end $m$;
do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position('''same''' in src) > 0 then return; end if;
  o1 := $o$'position_id', v_pos.id, 'reference', v_pos.reference, 'allowed',$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_apply_preview has changed'; end if;
  execute replace(src, o1, $n$'position_id', v_pos.id, 'reference', v_pos.reference, 'same', lower(btrim(v_title)) = lower(btrim(coalesce(em.approved_job_title, ''))), 'allowed',$n$);
end $m$;
