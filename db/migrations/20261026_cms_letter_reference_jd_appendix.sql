-- MyEden Group CMS V1.0 · HR letters: a reference number for every letter, and the full JD for an appendix
-- 1. {{letter_reference}}: each letter gets its own reference number when the draft is first saved, e.g. MEG/HR/LOC_LOI/2026/0001
--    (company / HR / letter type / year / running number per company and year). It never changes afterwards and is kept with the letter.
-- 2. More JD placeholders, filled from the same approved JD as {{jd_title}} (the new position in a promotion / transfer letter,
--    else the current one): {{jd_department}}, {{jd_level}}, {{jd_reports_to}}, {{jd_purpose}}, {{jd_effective_date}},
--    {{jd_qualifications}}, {{jd_experience}} — so one template can carry the JD of any position, at any level, in an appendix.
-- 3. cms_letter_jd_titles(person): the approved JD job titles of the person's company, offered when typing the new position.

-- 1 · letter reference ------------------------------------------------------------------------------------------------------
alter table public.hr_letter_records add column if not exists reference text;
create unique index if not exists hr_letter_records_reference_key on public.hr_letter_records (reference) where reference is not null;

create table if not exists public.cms_letter_ref_counters (
  company_code text not null,
  year int not null,
  last_no int not null default 0,
  primary key (company_code, year)
);
alter table public.cms_letter_ref_counters enable row level security;
revoke all on public.cms_letter_ref_counters from anon, authenticated;

create or replace function private.cms_letter_reference_set() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $f$
declare y int := extract(year from (now() at time zone 'Asia/Kuala_Lumpur'))::int; n int; typ text; co text;
begin
  if tg_op = 'UPDATE' and old.reference is not null then new.reference := old.reference; end if;   -- never changes
  if new.reference is null and new.status in ('draft', 'pending_approval', 'approved') then
    co := coalesce(nullif(new.company_code, ''), 'MEG');
    select coalesce(t.letter_type, t.code) into typ from public.hr_letter_templates t where t.code = new.template_code;
    insert into public.cms_letter_ref_counters as c (company_code, year, last_no) values (co, y, 1)
      on conflict (company_code, year) do update set last_no = c.last_no + 1 returning last_no into n;
    new.reference := co || '/HR/' || coalesce(typ, new.template_code) || '/' || y || '/' || lpad(n::text, 4, '0');
  end if;
  if new.reference is not null then
    if new.fields->>'letter_reference' is distinct from new.reference then
      new.fields := coalesce(new.fields, '{}'::jsonb) || jsonb_build_object('letter_reference', new.reference);
    end if;
    if strpos(coalesce(new.source_snapshot->>'text', ''), '[Letter reference]') > 0 then
      new.source_snapshot := jsonb_set(new.source_snapshot, '{text}', to_jsonb(replace(new.source_snapshot->>'text', '[Letter reference]', new.reference)));
    end if;
    if strpos(coalesce(new.source_snapshot->>'text', ''), '{{letter_reference}}') > 0 then
      new.source_snapshot := jsonb_set(new.source_snapshot, '{text}', to_jsonb(replace(new.source_snapshot->>'text', '{{letter_reference}}', new.reference)));
    end if;
  end if;
  return new;
end $f$;
revoke all on function private.cms_letter_reference_set() from public, anon, authenticated;

do $m$ begin
  if not exists (select 1 from pg_trigger where tgname = 'hr_letters_reference' and tgrelid = 'public.hr_letter_records'::regclass) then
    create trigger hr_letters_reference before insert or update on public.hr_letter_records
      for each row execute function private.cms_letter_reference_set();
  end if;
end $m$;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, required, editable, protected, active) values
  ('letter_reference', 'Letter reference', 'This letter''s own reference number, given when the draft is first saved (e.g. MEG/HR/LOC_LOI/2026/0001)', 'text', 'calculation', 'letter_reference', false, false, false, true)
on conflict (key) do update set label = excluded.label, description = excluded.description, kind = excluded.kind, source = excluded.source,
  source_key = excluded.source_key, editable = false, active = true, updated_at = now();

-- 2 · more JD placeholders ---------------------------------------------------------------------------------------------------
insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, required, editable, protected, active) values
  ('jd_department', 'JD department', 'Department of the JD position (JD Manual)', 'text', 'employee', 'jd_department', false, true, false, true),
  ('jd_level', 'JD level', 'Level of the JD position, e.g. L3 (JD Manual)', 'text', 'employee', 'jd_level', false, true, false, true),
  ('jd_reports_to', 'JD reports to', 'Who the position reports to (JD Manual)', 'text', 'employee', 'jd_reports_to', false, true, false, true),
  ('jd_purpose', 'JD purpose of the role', 'Purpose of the position (JD Manual)', 'paragraph', 'employee', 'jd_purpose', false, true, false, true),
  ('jd_effective_date', 'JD effective date', 'Effective date of the JD version (JD Manual)', 'text', 'employee', 'jd_effective_date', false, true, false, true),
  ('jd_qualifications', 'JD minimum qualifications', 'Minimum qualifications of the position (JD Manual)', 'paragraph', 'employee', 'jd_qualifications', false, true, false, true),
  ('jd_experience', 'JD required experience', 'Required experience of the position (JD Manual)', 'paragraph', 'employee', 'jd_experience', false, true, false, true)
on conflict (key) do update set label = excluded.label, description = excluded.description, kind = excluded.kind, source = excluded.source,
  source_key = excluded.source_key, active = true, updated_at = now();

create or replace function public.cms_letter_jd_lookup(p_person uuid, p_title text default null, p_position uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; co text; v_title text; v_from text; jp public.jd_positions; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('letters', 'V', co);
  if p_position is not null then
    select p.* into jp from public.jd_positions p join public.jd_entities e on e.id = p.entity_id
     where p.id = p_position and p.status = 'approved' and e.code = co;
    v_from := 'position chosen in the letter';
  end if;
  if jp.id is null and private.cms_nz(p_title) is not null then
    v_title := p_title; v_from := 'position in the letter';
  elsif jp.id is null then
    select p.* into jp from public.cms_person_position pp join public.jd_positions p on p.id = pp.position_id join public.jd_entities e on e.id = p.entity_id
     where pp.person_id = p_person and p.status = 'approved' and e.code = co;
    v_from := 'Career Paths position';
    if jp.id is null then
      v_title := coalesce(private.cms_nz(em.approved_job_title), (select t.name from public.eppd_employees ee join public.eppd_employments m on m.employee_id = ee.id
        join public.eppd_job_titles t on t.id = m.job_title_id where ee.employee_master_id = p_person order by (m.resigned_date is null) desc, m.join_date desc nulls last limit 1));
      v_from := 'current job title';
    end if;
  end if;
  if jp.id is null and v_title is not null then
    select p.* into jp from public.jd_positions p join public.jd_entities e on e.id = p.entity_id
     where e.code = co and p.status = 'approved' and private.cms_jd_key(p.job_title) = private.cms_jd_key(v_title)
       and (p.effective_date is null or p.effective_date <= v_today)
     order by p.effective_date desc nulls last, p.version desc limit 1;
  end if;
  if jp.id is null then
    return jsonb_build_object('found', false, 'title', v_title, 'company', co, 'from', v_from);
  end if;
  return jsonb_build_object('found', true, 'from', v_from, 'position_id', jp.id, 'company', co,
    'jd_title', jp.job_title, 'jd_reference', jp.reference, 'jd_version', jp.version,
    'jd_department', (select d.name from public.jd_departments d where d.id = jp.department_id),
    'jd_level', private.cms_nz(jp.level), 'jd_reports_to', private.cms_nz(jp.reports_to), 'jd_purpose', private.cms_nz(jp.purpose),
    'jd_effective_date', case when jp.effective_date is not null then private.cms_ldate(jp.effective_date) end,
    'jd_qualifications', private.cms_nz(jp.minimum_qualifications), 'jd_experience', private.cms_nz(jp.required_experience),
    'jd_responsibilities', (select string_agg(case when r.rn <= 26 then chr(96 + r.rn::int) else r.rn::text end || '. ' || btrim(coalesce(r.title, '')) || coalesce(' — ' || nullif(btrim(r.description), ''), ''), E'\n' order by r.rn)
       from (select r0.*, row_number() over (order by r0.sequence, r0.id) rn from public.jd_responsibilities r0 where r0.position_id = jp.id) r));
end $f$;
revoke all on function public.cms_letter_jd_lookup(uuid, text, uuid) from public, anon;
grant execute on function public.cms_letter_jd_lookup(uuid, text, uuid) to authenticated;

-- 3 · approved JD job titles of the person's company, every level -----------------------------------------------------------
create or replace function public.cms_letter_jd_titles(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare co text; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select private.cms_canon(company_code) into co from public.employee_master where id = p_person;
  if co is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('letters', 'V', co);
  return coalesce((select jsonb_agg(jsonb_build_object('title', x.job_title, 'level', x.level, 'department', x.dept) order by x.level, x.job_title)
    from (select distinct on (private.cms_jd_key(p.job_title)) p.job_title, p.level, d.name dept
            from public.jd_positions p join public.jd_entities e on e.id = p.entity_id left join public.jd_departments d on d.id = p.department_id
           where e.code = co and p.status = 'approved' and (p.effective_date is null or p.effective_date <= v_today)
           order by private.cms_jd_key(p.job_title), p.effective_date desc nulls last, p.version desc) x), '[]'::jsonb);
end $f$;
revoke all on function public.cms_letter_jd_titles(uuid) from public, anon;
grant execute on function public.cms_letter_jd_titles(uuid) to authenticated;
