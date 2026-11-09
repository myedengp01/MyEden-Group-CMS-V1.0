-- MyEden Group CMS V1.0 · v2026.11.09 · Letter of Confirmation — Senior Position (Word, with optional sections) (CLC 9 Nov 2026)
-- New switches / choices: after_promotion, probation_extended, increment_start (confirmation / next_month / other), allowance_change (+ allowance
-- name, amount, date), include_jd, review_cycle (6 / 9 / 12), review_from (confirmation / increment). Probation placeholders relabelled so they
-- read right for a promotion and for a direct senior hire. "Update records from this letter": the next review follows the letter's cycle and date.
insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('after_promotion', 'Confirmation after a promotion', 'Yes: the letter refers to the promotion letter. No: a direct senior hire on probation.', 'text', 'manual', '', 'yes', true, true, true, false, gen_random_uuid(), now()),
  ('probation_extended', 'Probation was extended', 'Yes: says the probation was extended to its end date.', 'text', 'manual', '', 'no', true, true, true, false, gen_random_uuid(), now()),
  ('increment_start', 'Increment starts', 'On the confirmation date, the 1st of the following month, or another date.', 'text', 'manual', '', 'confirmation', true, true, true, false, gen_random_uuid(), now()),
  ('allowance_change', 'Allowance change', 'Yes: adds an allowance (name, amount a month, from a date) to the letter. The letter only: payroll is not changed.', 'text', 'manual', '', 'no', true, true, true, false, gen_random_uuid(), now()),
  ('allowance_name', 'Allowance name', 'e.g. Position allowance', 'text', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('allowance_amount', 'Allowance (RM a month)', 'Monthly amount of the allowance', 'money', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('allowance_effective_date', 'Allowance from', 'Date the allowance starts', 'date', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('include_jd', 'Include JD appendix', 'Yes: the Job Description from the JD Manual is attached as Appendix 1.', 'text', 'manual', '', 'yes', true, true, true, false, gen_random_uuid(), now()),
  ('review_cycle', 'Performance and salary review every (months)', '6, 9 or 12 months', 'text', 'manual', '', '6', true, true, true, false, gen_random_uuid(), now()),
  ('review_from', 'Next review counted from', 'The confirmation date, or the increment date.', 'text', 'manual', '', 'confirmation', true, true, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
insert into public.hr_letter_options (key, type, options) values
  ('after_promotion', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('probation_extended', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('allowance_change', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('include_jd', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('increment_start', 'choice', '[{"value":"confirmation","label":"On the confirmation date"},{"value":"next_month","label":"1st of the following month"},{"value":"other","label":"Another date"}]'),
  ('review_cycle', 'choice', '[{"value":"6","label":"6 months"},{"value":"9","label":"9 months"},{"value":"12","label":"12 months"}]'),
  ('review_from', 'choice', '[{"value":"confirmation","label":"The confirmation date"},{"value":"increment","label":"The increment date"}]')
on conflict (key) do nothing;
update public.hr_letter_placeholders set label = 'Probation / assessment start', revision = gen_random_uuid(), updated_at = now() where key = 'promotion_probation_start' and label = 'promotion probation start';
update public.hr_letter_placeholders set label = 'Probation / assessment end', revision = gen_random_uuid(), updated_at = now() where key = 'promotion_probation_end' and label = 'promotion probation end';
update public.hr_letter_placeholders set label = 'Probation period (e.g. 3 months)', revision = gen_random_uuid(), updated_at = now() where key = 'promotion_probation_period' and label = 'promotion probation period';

do $m$ declare src text; o1 text; n1 text; o2 text; n2 text; o3 text; n3 text;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position($k$f->>'review_cycle'$k$ in src) > 0 then return; end if;
  o1 := $o$'label', 'Next salary review', 'interval', 'M12',
      'next', (v_sal + interval '12 months')::date,$o$;
  n1 := $n$'label', 'Next salary review', 'interval', case when f->>'review_cycle' in ('6', '9', '12') then 'M' || (f->>'review_cycle') else 'M12' end,
      'next', coalesce(private.cms_parse_date(f->>'next_review_date'), (v_sal + interval '12 months')::date),$n$;
  o2 := $o$'after', 'Every 12 months, next review ' || to_char((v_sal + interval '12 months')::date, 'DD Mon YYYY'),$o$;
  n2 := $n$'after', 'Every ' || coalesce(nullif(f->>'review_cycle', ''), '12') || ' months, next review ' || to_char(coalesce(private.cms_parse_date(f->>'next_review_date'), (v_sal + interval '12 months')::date), 'DD Mon YYYY'),$n$;
  o3 := $o$case when f->>'next_review_cycle' in ('6', '9', '12') then 'M' || (f->>'next_review_cycle') else 'M12' end$o$;
  n3 := $n$case when coalesce(f->>'review_cycle', f->>'next_review_cycle') in ('6', '9', '12') then 'M' || coalesce(f->>'review_cycle', f->>'next_review_cycle') else 'M12' end$n$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 or position(o3 in src) = 0 then raise exception 'cms_letter_apply_preview has changed'; end if;
  execute replace(replace(replace(src, o1, n1), o2, n2), o3, n3);
end $m$;
