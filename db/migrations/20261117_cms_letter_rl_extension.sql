-- MyEden Group CMS V1.0 · v2026.11.17 · Resignation acceptance (RL, RL_TP2): a longer notice proposed by the employee, accepted or declined;
-- leave across two years when the notice runs into the next year (CLC 17 Nov 2026).
-- · Switch "Extended notice requested" (notice_extension): none (default, the wording as before) / accepted / declined. The notice follows
--   the employment contract and the Employee Handbook; when the Company accepts the longer notice, the last day is the employee's date.
-- · When the last day falls in the next year (al_split): the current year's balance is not carried forward — taken by 31 Dec or paid
--   in the January payroll; the final-salary leave covers the next year only.
-- Additive: new placeholders and options; the two templates are changed through cms_letter_template_save (new version, logged).
insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('notice_extension', 'Extended notice requested', 'The employee proposed a longer notice than the contract: accepted or declined by the Company. None = the usual wording.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('requested_notice_period', 'Notice proposed by the employee', 'As in the resignation letter, e.g. 12 weeks.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('requested_last_date', 'Last day proposed by the employee', 'Worked out from the notice start and the notice proposed; editable.', 'date', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('requested_last_day', 'Proposed last day (weekday)', 'Weekday of the proposed last day.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('contract_last_date', 'Last day by the contract', 'Notice start + the notice in the contract / Employee Handbook.', 'date', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('contract_last_day', 'Last day by the contract (weekday)', 'Weekday of the contractual last day.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_split', 'Leave across two years', 'Set automatically: yes when the last day is in the next year.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_year_current', 'Current leave year', 'The year the notice starts.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_year_next', 'Next leave year', 'The year the employment ends.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_balance_current', 'Current year annual leave balance', 'Full-year entitlement less leave taken; taken by 31 Dec or paid in the January payroll.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_current_payout_month', 'Payroll paying the current year balance', 'e.g. January 2027.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now()),
  ('al_next_period', 'Next year leave period', 'e.g. 1 January 2027 to 3 February 2027.', 'text', 'manual', '', '', false, true, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
insert into public.hr_letter_options (key, type, options) values
  ('notice_extension', 'choice', '[{"value":"none","label":"None"},{"value":"accepted","label":"Accepted"},{"value":"declined","label":"Declined"}]'),
  ('al_split', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]')
on conflict (key) do nothing;
-- Template wording (applied 17 Nov 2026 with cms_letter_template_save as CLC, published; the previous wording is kept in
-- hr_letter_template_versions): section 1 gets [[IFNOT notice_extension=accepted]]/[[IFNOT notice_extension=declined]] around the
-- usual sentence plus an "accepted" and a "declined" paragraph; section 2 gets an [[IF al_split]] table (current-year balance, next-year
-- pro-rated leave) and the sentence that the current-year balance is taken by 31 Dec or paid in the January payroll.
