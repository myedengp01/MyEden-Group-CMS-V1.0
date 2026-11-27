-- Reminder Letter (RML) v2 (v2026.11.27): the working-hours paragraph is one editable field. Additive.
-- * {{working_hours_paragraph}} (paragraph, typed per letter): starts with CLC's wording, with the person's contracted hours from
--   their employment record (cms_letter_context); HR edits it freely in each letter.
-- * The Yes / No switch probation_hours_arrangement is relabelled "Include the working-hours paragraph" (Yes while on probation).
-- probation_hours_reason and probation_work_to stay in the register (the v1 template still uses them until it is replaced).

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable) values
  ('working_hours_paragraph', 'Working-hours paragraph', 'Printed when "Include the working-hours paragraph" is Yes. Edit it to suit the person.', 'paragraph', 'manual', '',
   'Under your contract of employment, your working hours are 8:00 a.m. to 6:00 p.m. daily. As the office is normally opened only at 8:30 a.m., and you will be given your own office keys and access only after you pass your probation, Management has verbally approved working hours of 8:30 a.m. to 6:30 p.m. for you during your probation. Once you are confirmed and given your own keys, your contracted working hours of 8:00 a.m. to 6:00 p.m. will apply.',
   true, true)
on conflict (key) do nothing;

update public.hr_letter_placeholders set label = 'Include the working-hours paragraph',
       description = 'Yes: the working-hours paragraph (and "report by" the probation start time) is printed; No: only the contracted hours. Yes while the person is on probation.',
       updated_at = now()
 where key = 'probation_hours_arrangement' and label = 'Different working hours during probation';

do $$ declare d text;
begin
  d := pg_get_functiondef('private.cms_letter_context(uuid)'::regprocedure);
  if strpos(d, 'working_hours_paragraph') = 0 then
    if strpos(d, '''last_working_day'',') = 0 then raise exception 'cms_letter_context: marker not found'; end if;
    d := replace(d, '''last_working_day'',',
      '''working_hours_paragraph'', case when (select work_from from job) is not null and (select work_to from job) is not null then
       ''Under your contract of employment, your working hours are '' || private.cms_ampm((select work_from from job)) || '' to '' || private.cms_ampm((select work_to from job))
       || '' daily. As the office is normally opened only at 8:30 a.m., and you will be given your own office keys and access only after you pass your probation, Management has verbally approved working hours of 8:30 a.m. to 6:30 p.m. for you during your probation. Once you are confirmed and given your own keys, your contracted working hours of ''
       || private.cms_ampm((select work_from from job)) || '' to '' || private.cms_ampm((select work_to from job)) || '' will apply.'' end,
    ''last_working_day'',');
    execute d;
  end if;
end $$;
