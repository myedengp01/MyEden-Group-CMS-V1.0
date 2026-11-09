-- MyEden Group CMS V1.0 · v2026.11.09 · Letter of Promotion (senior) with the increment in two parts (CLC 9 Nov 2026)
-- The total senior increment is paid {{probation_increment_pct}} % during the probation (from the promotion date) and the rest after confirmation.
-- The share is set by Admin: HR Letters › Placeholders › "Increment paid during probation (%)" › default value (60). HR cannot change it in a letter.
-- The confirmation letter (senior) based on such a letter fills its increment with the balance.
insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('senior_increment', 'Senior increment, total (RM a month)', 'The whole increment for the senior position; paid in two parts (during probation / after confirmation).', 'money', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('probation_increment_pct', 'Increment paid during probation (%)', 'Share of the senior increment paid from the promotion date; the rest after confirmation. Set by Admin (default value), the same for every letter.', 'percentage', 'manual', '', '60', true, false, true, false, gen_random_uuid(), now()),
  ('confirmation_increment_pct', 'Increment paid after confirmation (%)', '100 less the share paid during probation.', 'percentage', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now()),
  ('probation_increment', 'Increment during probation (RM)', 'Senior increment × the share paid during probation.', 'money', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now()),
  ('confirmation_increment', 'Increment after confirmation (RM)', 'The rest of the senior increment, paid from the confirmation date.', 'money', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now()),
  ('basic_during_probation', 'Basic during probation (RM)', 'Current basic + the increment during probation.', 'money', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now()),
  ('basic_after_confirmation', 'Basic after confirmation (RM)', 'Current basic + the whole senior increment.', 'money', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
