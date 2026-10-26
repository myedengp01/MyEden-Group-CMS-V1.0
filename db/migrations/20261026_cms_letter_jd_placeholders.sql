-- MyEden Group CMS V1.0 · HR letters: duties, JD reference and version fetched from the JD Manual by job title
-- New / updated placeholders, filled automatically from the approved JD of the employee's own company:
--   {{jd_title}}             job title as in the JD Manual
--   {{jd_responsibilities}}  the JD's responsibilities, one lettered line each: "a. Title — Description"
--   {{jd_reference}}         JD reference (e.g. MEG-HR-JD-HRP-001)
--   {{jd_version}}           JD version (e.g. 3.2)
-- Which job title: for transfer / promotion letters the position chosen in the letter (new position); for every other
-- letter the employee's current job title (their Career Paths JD position first, else their job title on record).
-- Values are filled into the letter when it is drafted and saved with it, so a later JD change does not alter the letter.

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, required, editable, protected, active) values
  ('jd_title', 'JD job title', 'Job title as in the JD Manual (from the position in the letter, else the current job title)', 'text', 'employee', 'jd_title', true, true, false, true),
  ('jd_responsibilities', 'JD duties and responsibilities', 'The JD''s responsibilities, one lettered line each (title — description)', 'paragraph', 'employee', 'jd_responsibilities', true, true, false, true),
  ('jd_reference', 'JD reference', 'JD reference from the JD Manual', 'text', 'employee', 'jd_reference', true, true, false, true),
  ('jd_version', 'JD version', 'JD version from the JD Manual', 'text', 'employee', 'jd_version', true, true, false, true)
on conflict (key) do update set label = excluded.label, description = excluded.description, kind = excluded.kind, source = excluded.source,
  source_key = excluded.source_key, active = true, updated_at = now();

create or replace function private.cms_jd_key(t text) returns text language sql immutable as $f$
  select nullif(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '', 'g'), '') $f$;

-- the approved JD for a person: by position id, else by job title (given, else the person's own), in the person's company
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
    'jd_responsibilities', (select string_agg(case when r.rn <= 26 then chr(96 + r.rn::int) else r.rn::text end || '. ' || btrim(coalesce(r.title, '')) || coalesce(' — ' || nullif(btrim(r.description), ''), ''), E'\n' order by r.rn)
       from (select r0.*, row_number() over (order by r0.sequence, r0.id) rn from public.jd_responsibilities r0 where r0.position_id = jp.id) r));
end $f$;
revoke all on function public.cms_letter_jd_lookup(uuid, text, uuid) from public, anon;
grant execute on function public.cms_letter_jd_lookup(uuid, text, uuid) to authenticated;
