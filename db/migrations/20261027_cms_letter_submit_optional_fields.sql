-- MyEden Group CMS V1.0 · HR letters: sending for approval no longer refuses a letter for optional placeholders
-- {{letter_reference}} is given when the draft is first saved, so a new letter sent straight for approval still had it empty and
-- was refused with "Fill in every field…". Only required placeholders must be filled; optional ones (letter reference, JD level …)
-- may still be empty. The reference is filled in by the database when the letter is saved.
do $m$ declare d text; n text;
begin
  d := pg_get_functiondef('public.cms_letter_save(jsonb)'::regprocedure);
  n := replace(d, $x$if (p->>'text') ~ '\{\{[a-z0-9_]+\}\}' then raise exception 'Fill in every field before submitting (some {{…}} are still empty).'; end if;$x$,
    $x$if exists (select 1 from regexp_matches(p->>'text', '\{\{([a-z0-9_]+)\}\}', 'g') mm
               where not exists (select 1 from public.hr_letter_placeholders h where h.key = mm[1] and not h.required)) then
      raise exception 'Fill in every field before submitting (still empty: %).', (select string_agg(distinct coalesce(h.label, mm[1]), ', ') from regexp_matches(p->>'text', '\{\{([a-z0-9_]+)\}\}', 'g') mm
        left join public.hr_letter_placeholders h on h.key = mm[1] where coalesce(h.required, true)); end if;$x$);
  if n = d then raise exception 'cms_letter_save patch point not found'; end if;
  execute n;
end $m$;
