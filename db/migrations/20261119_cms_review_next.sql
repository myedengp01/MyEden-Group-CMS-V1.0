-- Next salary review follows the review cycle (v2026.11.19). Additive patch.
-- "Update records from this letter": the suggested next review was always the salary date + 12 months, whatever cycle the letter
-- states. It is now the salary date + the letter's cycle (6, 9 or 12 months; 12 if none), unless the letter states a date itself.
-- The item also carries 'base' (the date the cycle counts from) and 'stated' (the letter gives the date), so the page can follow a
-- change of "Review every".
do $$ declare d text; n int;
begin
  d := pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure);
  if strpos(d, '''base'', v_sal') = 0 then
    n := (length(d) - length(replace(d, '(v_sal + interval ''12 months'')::date', ''))) / length('(v_sal + interval ''12 months'')::date');
    if n <> 2 then raise exception 'cms_letter_apply_preview: expected 2 markers, found %', n; end if;
    d := replace(d, '(v_sal + interval ''12 months'')::date',
      '(v_sal + make_interval(months => case when f->>''review_cycle'' in (''6'', ''9'', ''12'') then (f->>''review_cycle'')::int else 12 end))::date');
    d := replace(d, '''next'', coalesce(private.cms_parse_date(f->>''next_review_date''), (v_sal + make_interval',
      '''base'', v_sal, ''stated'', private.cms_parse_date(f->>''next_review_date'') is not null, ''next'', coalesce(private.cms_parse_date(f->>''next_review_date''), (v_sal + make_interval');
    if strpos(d, '''base'', v_sal') = 0 then raise exception 'cms_letter_apply_preview: marker not found'; end if;
    execute d;
  end if;
end $$;
