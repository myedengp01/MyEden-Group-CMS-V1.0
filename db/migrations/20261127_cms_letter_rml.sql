-- Reminder Letter (Attendance & Punctuality), letter type RML (v2026.11.27). Additive.
-- * New placeholders for the RML Word template (the template itself is uploaded in HR Letters › Templates and approved there):
--   the message date, the late arrivals typed one per line (a paragraph: one Word paragraph per line), their number and total
--   minutes, the contracted and the probation working hours, the reason for the probation hours, the return-by date, and three
--   Yes / No switches (probation hours arrangement, probation review sentence, unearned wages sentence).
-- * cms_letter_context also gives:
--   - contract_work_from / contract_work_to: the person's working hours from their employment record, e.g. "8:00 a.m.";
--   - probation_hours_arrangement / probation_review_note: 'yes' while the person is on probation (not confirmed, probation end
--     today or later), else 'no';
--   - _home_address: the payroll home address, or else the residential address from the personal details (was payroll only).

create or replace function private.cms_ampm(t time) returns text language sql immutable set search_path = pg_catalog as $$
  select case when t is null then null else to_char(t, 'FMHH12:MI') || case when extract(hour from t) < 12 then ' a.m.' else ' p.m.' end end
$$;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable) values
  ('lateness_message_date', 'Date of the message exchange', 'The date Management raised the late attendance with the employee (e.g. by WhatsApp)', 'date', 'manual', '', '', true, true),
  ('lateness_records', 'Late arrivals (one per line)', 'One line per late day, e.g. "1. Date: 05/11/2026 – Arrived at 9:04 a.m. (Expected: 8:30 a.m.; late by approximately 34 minutes)". Each line becomes its own line in the letter.', 'paragraph', 'manual', '', '', true, true),
  ('lateness_count', 'Number of late arrivals', 'How many late days are listed', 'number', 'manual', '', '', true, true),
  ('lateness_total_minutes', 'Total minutes late', 'The minutes late added up', 'number', 'manual', '', '', true, true),
  ('contract_work_from', 'Contracted start time', 'From the employment record, e.g. 8:00 a.m.', 'text', 'employee', 'contract_work_from', '', true, true),
  ('contract_work_to', 'Contracted end time', 'From the employment record, e.g. 6:00 p.m.', 'text', 'employee', 'contract_work_to', '', true, true),
  ('probation_hours_arrangement', 'Different working hours during probation', 'Yes: the letter explains the working hours approved for the probation period', 'text', 'manual', '', 'no', true, true),
  ('probation_work_from', 'Probation start time', 'Start time approved during probation', 'text', 'manual', '', '8:30 a.m.', true, true),
  ('probation_work_to', 'Probation end time', 'End time approved during probation', 'text', 'manual', '', '6:30 p.m.', true, true),
  ('probation_hours_reason', 'Reason for the probation working hours', 'Shown before "Management has verbally approved working hours of …"', 'paragraph', 'manual', '',
     'As the office is normally opened only at 8:30 a.m., and you will be given your own office keys and access only after you pass your probation', true, true),
  ('probation_review_note', 'Mention the probation review', 'Yes: adds "Your punctuality during this period will also be taken into account in your probation review."', 'text', 'manual', '', 'no', true, true),
  ('unearned_wages_note', 'Unearned wages reminder', 'Yes: future late time may be adjusted from pay as unearned wages', 'text', 'manual', '', 'yes', true, true),
  ('return_by_date', 'Return the signed copy by', 'The date the employee returns the signed acknowledgement to HR', 'date', 'manual', '', '', true, true)
on conflict (key) do nothing;

insert into public.hr_letter_options (key, type, options) values
  ('probation_hours_arrangement', 'switch', '[{"label":"Yes","value":"yes"},{"label":"No","value":"no"}]'),
  ('probation_review_note', 'switch', '[{"label":"Yes","value":"yes"},{"label":"No","value":"no"}]'),
  ('unearned_wages_note', 'switch', '[{"label":"Yes","value":"yes"},{"label":"No","value":"no"}]')
on conflict (key) do nothing;

do $$ declare d text;
begin
  d := pg_get_functiondef('private.cms_letter_context(uuid)'::regprocedure);
  if strpos(d, 'contract_work_from') = 0 then
    if strpos(d, 'select t.name title, dp.name dept from public.eppd_employments m') = 0 then raise exception 'cms_letter_context: job marker not found'; end if;
    if strpos(d, '''_home_address'', (select home_address from pv),') = 0 then raise exception 'cms_letter_context: address marker not found'; end if;
    if strpos(d, '''last_working_day'',') = 0 then raise exception 'cms_letter_context: last marker not found'; end if;
    d := replace(d, 'select t.name title, dp.name dept from public.eppd_employments m', 'select t.name title, dp.name dept, m.work_from, m.work_to from public.eppd_employments m');
    d := replace(d, '''_home_address'', (select home_address from pv),',
      '''_home_address'', coalesce(nullif(btrim((select home_address from pv)), ''''), (select nullif(btrim(pd.residential_address), '''') from public.employee_personal_details pd where pd.employee_id_ref = p_person limit 1)),');
    d := replace(d, '''last_working_day'',',
      '''contract_work_from'', private.cms_ampm((select work_from from job)), ''contract_work_to'', private.cms_ampm((select work_to from job)),
    ''probation_hours_arrangement'', case when em.confirmation_date is null and coalesce((select end_date from pe) >= (now() at time zone ''Asia/Kuala_Lumpur'')::date, false) then ''yes'' else ''no'' end,
    ''probation_review_note'', case when em.confirmation_date is null and coalesce((select end_date from pe) >= (now() at time zone ''Asia/Kuala_Lumpur'')::date, false) then ''yes'' else ''no'' end,
    ''last_working_day'',');
    execute d;
  end if;
end $$;
