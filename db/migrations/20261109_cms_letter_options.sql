-- MyEden Group CMS V1.0 · v2026.11.09 · HR letters: optional sections and Switch / Choice placeholders (CLC 9 Nov 2026)
-- A placeholder can be shown as a Yes/No switch or a choice list (hr_letter_options). Templates use them in optional sections:
--   [[IF key]] … [[END]]   [[IFNOT key]] … [[END]]   [[IF key=value]] … [[END]]   (marker alone on its line = a block; marker + text = that line only)
-- New placeholders for transfer letters with or without an increment; {{last_increment_date}} comes from the payroll salary history.
-- Additive: one table, functions, placeholder rows.

create table if not exists public.hr_letter_options (
  key text primary key references public.hr_letter_placeholders(key),
  type text not null default 'none' check (type in ('none', 'switch', 'choice')),
  options jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(), updated_by uuid);
alter table public.hr_letter_options enable row level security;
revoke all on public.hr_letter_options from anon, authenticated;

create or replace function public.cms_letter_options()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
begin
  perform private.cms_require('letters', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('key', key, 'type', type, 'options', options)) from public.hr_letter_options where type <> 'none'), '[]'::jsonb);
end $f$;
revoke all on function public.cms_letter_options() from public, anon;
grant execute on function public.cms_letter_options() to authenticated;

-- p_options: [{value, label}] for a choice; a switch is always yes / no
create or replace function public.cms_letter_option_save(p_key text, p_type text, p_options jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare opts jsonb;
begin
  perform private.cms_require('letters.placeholders', 'V');
  if not exists (select 1 from public.hr_letter_placeholders where key = p_key) then raise exception 'Placeholder not found.'; end if;
  if p_type not in ('none', 'switch', 'choice') then raise exception 'Unknown option type.'; end if;
  opts := case p_type when 'switch' then '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'::jsonb
    when 'choice' then (select coalesce(jsonb_agg(jsonb_build_object('value', left(btrim(x->>'value'), 40), 'label', left(btrim(coalesce(nullif(x->>'label', ''), x->>'value')), 80))), '[]'::jsonb)
                          from jsonb_array_elements(coalesce(p_options, '[]'::jsonb)) x where btrim(coalesce(x->>'value', '')) <> '')
    else '[]'::jsonb end;
  if p_type = 'choice' and jsonb_array_length(opts) < 2 then raise exception 'A choice needs at least two options.'; end if;
  if p_type = 'choice' and exists (select 1 from jsonb_array_elements(opts) x where x->>'value' !~ '^[a-z0-9_]+$') then raise exception 'Option values use lower-case letters, numbers and _ (the label can be anything).'; end if;
  insert into public.hr_letter_options (key, type, options, updated_at, updated_by) values (p_key, p_type, opts, now(), auth.uid())
  on conflict (key) do update set type = excluded.type, options = excluded.options, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('letter_placeholder.options', 'hr_letter_options', p_key, null, 'Placeholder {{' || p_key || '}} shown as ' || p_type, jsonb_build_object('options', opts));
end $f$;
revoke all on function public.cms_letter_option_save(text, text, jsonb) from public, anon;
grant execute on function public.cms_letter_option_save(text, text, jsonb) to authenticated;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('has_increment', 'Includes salary increment', 'Yes: the letter gives an increment (amount, %, revised basic). No: the basic stays and the next salary review is stated.', 'text', 'manual', '', 'no', true, true, true, false, gen_random_uuid(), now()),
  ('increment_timing', 'Increment takes effect', 'From the transfer date, or after the assessment / confirmation in the new position.', 'text', 'manual', '', 'after_confirmation', true, true, true, false, gen_random_uuid(), now()),
  ('last_increment_date', 'Last increment date', 'Date of the last salary increment, from the payroll salary history (can be changed).', 'date', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('next_review_cycle', 'Next salary review after (months)', 'Months after the last increment: 6, 9 or 12.', 'text', 'manual', '', '12', true, true, true, false, gen_random_uuid(), now()),
  ('assessment_months', 'Assessment period (months)', 'Length of the assessment in the new position (usually 3; can be extended to 6 in total).', 'number', 'manual', '', '3', true, true, true, false, gen_random_uuid(), now()),
  ('salary_after_transfer', 'Basic salary (new)', 'Worked out: the revised basic and from when, or the current basic unchanged.', 'text', 'calculation', '', '', true, false, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
insert into public.hr_letter_options (key, type, options) values
  ('has_increment', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('increment_timing', 'choice', '[{"value":"transfer","label":"From the transfer date"},{"value":"after_confirmation","label":"After the assessment / confirmation"}]'),
  ('next_review_cycle', 'choice', '[{"value":"6","label":"6 months"},{"value":"9","label":"9 months"},{"value":"12","label":"12 months"}]')
on conflict (key) do nothing;

-- the last increment from the payroll salary history (latest date the basic went up)
create or replace function private.cms_last_increment(p_person uuid) returns date language sql stable security definer set search_path = public, pg_temp as $$
  select max(z.effective_from) from (
    select h.effective_from, h.amount, lag(h.amount) over (order by h.effective_from) prev
      from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id join public.eppd_employments m on m.id = a.employment_id
      join public.eppd_employees ee on ee.id = m.employee_id where ee.employee_master_id = p_person) z
  where z.prev is not null and z.amount > z.prev and z.effective_from <= (now() at time zone 'Asia/Kuala_Lumpur')::date;
$$;
revoke all on function private.cms_last_increment(uuid) from public, anon, authenticated;
do $m$ declare src text;
begin
  select pg_get_functiondef('public.cms_letter_context(uuid)'::regprocedure) into src;
  if position('cms_last_increment' in src) = 0 then
    if position($o$  return private.cms_letter_context(p_person) || jsonb_build_object('_company',$o$ in src) = 0 then raise exception 'cms_letter_context has changed'; end if;
    execute replace(src, $o$  return private.cms_letter_context(p_person) || jsonb_build_object('_company',$o$,
      $n$  return private.cms_letter_context(p_person) || jsonb_build_object('last_increment_date', (select to_char(d, 'FMDD FMMonth YYYY') from private.cms_last_increment(p_person) d where d is not null)) || jsonb_build_object('_company',$n$);
  end if;
end $m$;
