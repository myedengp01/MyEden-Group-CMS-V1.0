-- MyEden Group CMS V1.0 · PRI-011 · Employee profile: everything about a person on one page
-- Brings together the Employee Master, the payroll record, the MEG-EAF V2 application (photo, IC images, personal details,
-- family, education, work history, declarations) and CMS records (letters, appraisals, items, leave).
-- New special permissions (HR and above by default; assignable per role or per person):
--   people.personal       See personal details (address, race, religion, marital status, family, emergency contact,
--                         education, work history, declarations)
--   people.personal_edit  Edit personal details on the profile
--   people.photos         Upload the photo and ID images (IC front / back, passport)
-- IC / passport numbers and the IC / passport images follow "See IC and passport numbers"; bank follows "See bank";
-- salary follows "See salaries". Edits are kept in the CMS (cms_person_profile) and logged; the application is not changed.
-- Images uploaded in the CMS go to a private bucket (cms-profile-images/<person>/<kind>/<file>); images from the
-- application are read from the application when shown.

-- ------------------------------------------------------------------ permissions
insert into public.cms_modules (code, label, grp, phase, sort_order, kind, parent, acts, act_labels, description, from_phase, locked) values
  ('people.personal', 'See personal details', 'People & Employment', 4, 1009, 'special', 'people', 'V', '{}'::jsonb,
   'Address, race, religion, marital status, family, emergency contact, education, work history and declarations on the profile', null, false),
  ('people.personal_edit', 'Edit personal details', 'People & Employment', 4, 1010, 'special', 'people', 'V', '{}'::jsonb,
   'Change personal details, family, emergency contact, education and work history on the profile', null, false),
  ('people.photos', 'Upload photo and ID images', 'People & Employment', 4, 1011, 'special', 'people', 'V', '{}'::jsonb,
   'Upload or replace the passport-size photo, IC front / back and passport page', null, false)
on conflict (code) do nothing;

insert into public.cms_role_permissions (role_code, module_code, actions)
select r, m, 'V' from (values ('admin', 'people.personal'), ('hr', 'people.personal'), ('director', 'people.personal'),
  ('admin', 'people.personal_edit'), ('hr', 'people.personal_edit'), ('admin', 'people.photos'), ('hr', 'people.photos')) t(r, m)
where exists (select 1 from public.cms_roles where code = t.r)
on conflict (role_code, module_code) do nothing;
insert into public.cms_role_permission_defaults (role_code, module_code, actions)
select role_code, module_code, actions from public.cms_role_permissions where module_code in ('people.personal', 'people.personal_edit', 'people.photos') and actions <> ''
on conflict (role_code, module_code) do nothing;

-- ------------------------------------------------------------------ tables
create table if not exists public.cms_person_profile (
  person_id uuid primary key references public.employee_master(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_by uuid, updated_by_name text, updated_at timestamptz not null default now());
alter table public.cms_person_profile enable row level security;

create table if not exists public.cms_person_images (
  person_id uuid not null references public.employee_master(id) on delete cascade,
  kind text not null check (kind in ('photo', 'ic_front', 'ic_back', 'passport')),
  path text not null, uploaded_by uuid, uploaded_by_name text, uploaded_at timestamptz not null default now(),
  primary key (person_id, kind));
alter table public.cms_person_images enable row level security;

insert into storage.buckets (id, name, public) values ('cms-profile-images', 'cms-profile-images', false) on conflict (id) do nothing;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'CMS profile images read') then
    create policy "CMS profile images read" on storage.objects for select to authenticated using (
      bucket_id = 'cms-profile-images' and (
        ((storage.foldername(name))[2] = 'photo' and public.cms_can('people', 'V'))
        or ((storage.foldername(name))[2] in ('ic_front', 'ic_back', 'passport') and public.cms_can('people.ic', 'V'))));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'CMS profile images upload') then
    create policy "CMS profile images upload" on storage.objects for insert to authenticated with check (
      bucket_id = 'cms-profile-images' and public.cms_can('people.photos', 'V')
      and (storage.foldername(name))[2] in ('photo', 'ic_front', 'ic_back', 'passport')
      and exists (select 1 from public.employee_master e where e.id::text = (storage.foldername(name))[1]));
  end if;
end $p$;

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_nz(v text) returns text language sql immutable as $f$ select nullif(btrim(coalesce(v, '')), '') $f$;

-- the radio answer, or the "other" text when the answer is Other
create or replace function private.cms_eaf_pick(a jsonb, k text, other text) returns text language sql immutable as $f$
  select case when lower(coalesce(a->>k, '')) in ('other', 'others') then coalesce(private.cms_nz(a->>other), a->>k) else private.cms_nz(a->>k) end $f$;

-- arrays of strings from the application's table rows, without empty / "N/A" rows
create or replace function private.cms_eaf_rows(a jsonb, k text) returns setof jsonb language sql immutable as $f$
  select r from jsonb_array_elements(case when jsonb_typeof(a->k) = 'array' then a->k else '[]'::jsonb end) r
   where jsonb_typeof(r) = 'array' and exists (select 1 from jsonb_array_elements_text(r) with ordinality x(v, i) where i > 1 and private.cms_nz(v) is not null
     and upper(btrim(v)) not in ('N/A', 'NA', '-', 'NIL', 'NONE')) $f$;

-- ------------------------------------------------------------------ the profile
create or replace function public.cms_person_profile(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare
  em public.employee_master; co text; a jsonb := '{}'::jsonb; d jsonb := '{}'::jsonb; ee public.eppd_employees; pv public.eppd_employee_private;
  v_app public.eaf_applications; pe record; boss text; unit text; unit_name text; paying text;
  c_personal boolean; c_edit boolean; c_photos boolean; c_ic boolean; c_bank boolean; c_sal boolean; c_pay boolean; c_leave boolean;
  c_letters boolean; c_appr boolean; c_items boolean; c_docs boolean;
  imgs jsonb := '{}'::jsonb; k text; v_last bigint; out jsonb;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  co := private.cms_canon(em.company_code);
  perform private.cms_require('people', 'V', co);
  c_personal := public.cms_can('people.personal', 'V'); c_edit := public.cms_can('people.personal_edit', 'V') and public.cms_can('people', 'V', co);
  c_photos := public.cms_can('people.photos', 'V'); c_ic := public.cms_can('people.ic', 'V'); c_bank := public.cms_can('people.bank', 'V');
  c_sal := public.cms_can('people.salary', 'V'); c_pay := public.cms_can('payroll', 'V'); c_leave := public.cms_can('leave', 'V') or c_pay;
  c_letters := public.cms_can('letters', 'V', co); c_appr := public.cms_can('performance', 'V'); c_items := public.cms_can('assets', 'V'); c_docs := public.cms_can('documents', 'V');

  if em.source_application_id is not null then
    select * into v_app from public.eaf_applications where id = em.source_application_id;
    a := coalesce(v_app.payload, '{}'::jsonb);
  end if;
  select coalesce(data, '{}'::jsonb) into d from public.cms_person_profile where person_id = p_person; d := coalesce(d, '{}'::jsonb);
  select * into ee from public.eppd_employees where employee_master_id = p_person order by id desc limit 1;
  if ee.id is not null then select * into pv from public.eppd_employee_private where employee_id = ee.id; end if;
  select b.employee_name into boss from public.employee_master b where b.id = em.reports_to_id;
  select pp.unit_code, u.name, pp.paying_company_code into unit, unit_name, paying
    from public.cms_employee_payroll pp left join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person;
  select * into pe from private.cms_probation_end(p_person);

  -- images: uploaded in the CMS first, else the application's
  foreach k in array array['photo', 'ic_front', 'ic_back', 'passport'] loop
    if k <> 'photo' and not c_ic then continue; end if;
    imgs := imgs || jsonb_build_object(k, coalesce(
      (select jsonb_build_object('source', 'upload', 'path', i.path, 'at', i.uploaded_at, 'by', i.uploaded_by_name) from public.cms_person_images i where i.person_id = p_person and i.kind = k),
      case when length(coalesce(a->>(case k when 'photo' then 'photoData' when 'ic_front' then 'idFrontData' when 'ic_back' then 'idBackData' else '-' end), '')) > 100
        then jsonb_build_object('source', 'application') end));
  end loop;

  out := jsonb_build_object(
    'can', jsonb_build_object('personal', c_personal, 'edit', c_edit, 'photos', c_photos, 'ic', c_ic, 'bank', c_bank, 'salary', c_sal, 'pay', c_pay, 'leave', c_leave,
      'letters', c_letters, 'appraisals', c_appr, 'items', c_items, 'documents', c_docs),
    'head', jsonb_build_object('id', em.id, 'name', em.employee_name, 'chinese_name', coalesce(private.cms_nz(d->>'chinese_name'), private.cms_nz(ee.chinese_name), private.cms_nz(a->>'nameChinese')),
      'employee_id', em.employee_id, 'previous_id', em.previous_employee_id, 'title', em.approved_job_title, 'level', nullif(split_part(coalesce(em.job_title_level, ''), '|', 1), ''),
      'unit', unit, 'unit_name', unit_name, 'department', em.department, 'company', co,
      'company_name', (select name from public.cms_companies where code = co), 'paying', paying, 'status', em.employment_status, 'start', em.start_date,
      'group_start', em.original_group_join_date, 'confirmation', em.confirmation_status, 'confirmation_date', em.confirmation_date,
      'boss_id', em.reports_to_id, 'boss', boss, 'source', em.source_type, 'eppd_employee_id', ee.id,
      'gender', coalesce(em.gender_code, ee.gender)),
    'images', imgs,
    'application', case when v_app.id is not null then jsonb_build_object('id', v_app.id, 'submitted_at', v_app.submitted_at, 'stage', v_app.workflow_stage,
      'position', v_app.position_applied, 'signed', length(coalesce(a->>'sigData', '')) > 100) end,
    'edited', (select jsonb_build_object('by', updated_by_name, 'at', updated_at) from public.cms_person_profile where person_id = p_person));

  if c_personal then
    out := out || jsonb_build_object(
      'personal', jsonb_strip_nulls(jsonb_build_object(
        'gender', case coalesce(em.gender_code, ee.gender, upper(left(a->>'radio_gender', 1))) when 'M' then 'Male' when 'F' then 'Female' end,
        'dob', coalesce(pv.dob::text, private.cms_nz(a->>'dob')),
        'race', coalesce(private.cms_nz(d->>'race'), private.cms_nz(ee.race), private.cms_eaf_pick(a, 'radio_race', 'raceOther')),
        'religion', coalesce(private.cms_nz(d->>'religion'), private.cms_eaf_pick(a, 'radio_religion', 'religionOther')),
        'marital', coalesce(private.cms_nz(d->>'marital'), private.cms_nz(ee.marital_status), private.cms_eaf_pick(a, 'radio_marital', 'maritalOther')),
        'nationality', coalesce(private.cms_nz(d->>'nationality'), private.cms_nz(ee.nationality), case when lower(coalesce(a->>'usingPassport', '')) in ('true', 'yes', '1') then 'Non-Malaysian' end),
        'phone', coalesce(private.cms_nz(d->>'phone'), private.cms_nz(em.contact), private.cms_nz(ee.phone), private.cms_nz(a->>'contact')),
        'email', coalesce(private.cms_nz(d->>'email'), private.cms_nz(em.email), private.cms_nz(ee.email), private.cms_nz(a->>'email')),
        'address', coalesce(d->'address', case when private.cms_nz(a->>'addr1') is not null then jsonb_strip_nulls(jsonb_build_object('line1', private.cms_nz(a->>'addr1'), 'line2', private.cms_nz(a->>'addr2'),
            'line3', private.cms_nz(a->>'addr3'), 'postcode_town', private.cms_nz(a->>'postcodeTown'), 'state', private.cms_nz(a->>'addrState'))) end,
          case when private.cms_nz(pv.home_address) is not null then jsonb_build_object('line1', pv.home_address) end),
        'nric', case when c_ic then coalesce(private.cms_nz(pv.nric), private.cms_nz(concat_ws('-', private.cms_nz(a->>'ic1'), private.cms_nz(a->>'ic2'), private.cms_nz(a->>'ic3')))) end,
        'passport', case when c_ic then coalesce(private.cms_nz(d->>'passport'), private.cms_nz(pv.passport_no), private.cms_nz(a->>'passport')) end)),
      'family', jsonb_build_object(
        'members', coalesce(d->'family', (select jsonb_agg(jsonb_build_object('name', r->>1, 'age', r->>2, 'status', r->>3, 'relation', r->>4)) from private.cms_eaf_rows(a, 'familyRows') r), '[]'::jsonb),
        'children', coalesce(private.cms_nz(d->>'children'), private.cms_nz(a->>'children')),
        'spouse', private.cms_nz(pv.spouse_name),
        'emergency', coalesce(d->'emergency', case when private.cms_nz(pv.emergency_name) is not null then jsonb_build_object('name', pv.emergency_name, 'relation', pv.emergency_relation, 'phone', pv.emergency_phone) end)),
      'background', jsonb_build_object(
        'education', coalesce(d->'education', (select jsonb_agg(jsonb_build_object('level', r->>1, 'school', r->>2, 'location', r->>3, 'from', r->>4, 'to', r->>5,
            'graduated', coalesce(private.cms_nz(r->>6), private.cms_nz(r->>7)))) from private.cms_eaf_rows(a, 'academicRows') r), '[]'::jsonb),
        'work', coalesce(d->'work', (select jsonb_agg(jsonb_build_object('from', r->>0, 'to', r->>1, 'employer', r->>2, 'contact', r->>3, 'title', r->>4, 'address', r->>5,
            'salary', case when c_sal then r->>6 end, 'duties', r->>7, 'reason', r->>8)) from jsonb_array_elements(case when jsonb_typeof(a->'workExpData') = 'array' then a->'workExpData' else '[]'::jsonb end) r
           where jsonb_typeof(r) = 'array' and private.cms_nz(r->>2) is not null), '[]'::jsonb),
        'spoken', coalesce(private.cms_nz(d->>'spoken'), nullif(concat_ws(', ', (select string_agg(x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(a->'cb_spoken') = 'array' then a->'cb_spoken' else '[]'::jsonb end) x where lower(x) <> 'other'), private.cms_nz(a->>'spokenOther')), '')),
        'written', coalesce(private.cms_nz(d->>'written'), nullif(concat_ws(', ', (select string_agg(x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(a->'cb_written') = 'array' then a->'cb_written' else '[]'::jsonb end) x where lower(x) <> 'other'), private.cms_nz(a->>'writtenOther')), '')),
        'skills', coalesce(private.cms_nz(d->>'skills'), private.cms_nz(a->>'specialSkills')),
        'declarations', case when v_app.id is not null then jsonb_build_array(
          jsonb_build_object('q', 'Undischarged bankrupt', 'a', a->>'radio_q1'), jsonb_build_object('q', 'Convicted of a criminal offence', 'a', a->>'radio_q2'),
          jsonb_build_object('q', 'Serious illness', 'a', a->>'radio_q3'), jsonb_build_object('q', 'Physical handicap', 'a', a->>'radio_q4'),
          jsonb_build_object('q', 'Details given', 'a', private.cms_nz(a->>'yesDetails'))) end));
  end if;

  -- employment periods (payroll), probation, notice, leaving
  out := out || jsonb_build_object('employment', jsonb_build_object(
    'periods', coalesce((select jsonb_agg(jsonb_build_object('join', m.join_date, 'resigned', m.resigned_date, 'confirmation', m.confirmation_status, 'confirmed', m.confirmed_date,
        'job_status', m.job_status, 'title', t.name, 'department', dp.code, 'notice_until', m.notice_until, 'letter', m.resignation_letter_date,
        'leaving_reason', m.leaving_reason, 'rehire', m.rehire_eligibility, 'hours', case when m.work_from is not null then to_char(m.work_from, 'HH24:MI') || '–' || to_char(m.work_to, 'HH24:MI') end,
        'paid_by', (select jsonb_agg(jsonb_build_object('company', c.short_name, 'from', s.start_date, 'to', s.end_date) order by s.start_date nulls first) from public.eppd_assignments s join public.eppd_companies c on c.id = s.company_id where s.employment_id = m.id))
        order by m.join_date desc nulls last)
      from public.eppd_employments m left join public.eppd_job_titles t on t.id = m.job_title_id left join public.eppd_departments dp on dp.id = m.department_id
      where m.employee_id = ee.id), '[]'::jsonb),
    'probation_end', pe.end_date, 'probation_source', pe.source,
    'notice', case when em.notice_period_value is not null then em.notice_period_value || ' ' || coalesce(em.notice_period_unit, '') end,
    'exit', jsonb_strip_nulls(jsonb_build_object('reason', em.exit_reason, 'notes', em.exit_notes, 'clearance', em.clearance_status, 'last_day', em.actual_last_working_date))));

  if c_sal and ee.id is not null then
    select m.id into v_last from public.eppd_employments m where m.employee_id = ee.id order by (m.resigned_date is null) desc, m.join_date desc nulls last limit 1;
    out := out || jsonb_build_object('pay', jsonb_build_object(
      'history', coalesce((select jsonb_agg(jsonb_build_object('from', h.effective_from, 'amount', h.amount, 'basis', h.pay_basis, 'reason', coalesce(h.reason, h.note), 'company', c.short_name) order by h.effective_from desc)
        from public.eppd_salary_history h join public.eppd_assignments s on s.id = h.assignment_id join public.eppd_companies c on c.id = s.company_id where s.employment_id = v_last), '[]'::jsonb),
      'allowances', coalesce((select jsonb_agg(jsonb_build_object('name', pt.name, 'amount', al.amount, 'from', al.start_date, 'to', al.end_date) order by al.start_date desc nulls last)
        from public.eppd_allowances al join public.eppd_assignments s on s.id = al.assignment_id left join public.eppd_payment_types pt on pt.id = al.payment_type_id
        where s.employment_id = v_last and (al.end_date is null or al.end_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date)), '[]'::jsonb)));
  end if;
  if ee.id is not null and (c_bank or c_ic) then
    out := out || jsonb_build_object('ids', jsonb_strip_nulls(jsonb_build_object(
      'bank', case when c_bank then (select label from public.eppd_lookups where category = 'bank' and code = pv.bank_code limit 1) end,
      'bank_code', case when c_bank then pv.bank_code end, 'account', case when c_bank then pv.bank_account_no end,
      'epf', case when c_ic then pv.epf_no end, 'socso', case when c_ic then coalesce(pv.socso_no, regexp_replace(coalesce(pv.nric, ''), '\D', '', 'g')) end, 'tax', case when c_ic then pv.tax_no end)));
  end if;
  if c_leave and ee.id is not null then
    out := out || jsonb_build_object('leave_taken', coalesce((select jsonb_object_agg(leave_type, d2) from (select l.leave_type, sum(l.days) d2 from public.eppd_leave_records l
       where l.employee_id = ee.id and l.status <> 'cancelled' and l.date_from >= date_trunc('year', (now() at time zone 'Asia/Kuala_Lumpur'))::date group by 1) z), '{}'::jsonb));
  end if;
  if c_letters then
    out := out || jsonb_build_object('letters', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'title', coalesce(t.title, r.template_code), 'status', r.status,
        'at', coalesce(r.issued_at, r.updated_at, r.created_at)) order by coalesce(r.issued_at, r.updated_at, r.created_at) desc)
      from public.hr_letter_records r left join public.hr_letter_templates t on t.code = r.template_code where r.employee_id = p_person), '[]'::jsonb));
  end if;
  if c_appr then
    out := out || jsonb_build_object('appraisals', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'year', x.year, 'status', x.status, 'rating', x.rating,
        'at', coalesce(x.approved_at, x.updated_at)) order by coalesce(x.approved_at, x.updated_at) desc) from public.cms_appraisals x where x.person_id = p_person), '[]'::jsonb));
  end if;
  if c_items then
    out := out || jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('type', i.type_code, 'description', i.description, 'tag', i.asset_tag, 'status', i.status,
        'issued', i.issued_on, 'returned', i.returned_on) order by i.issued_on desc nulls last) from public.cms_items i where i.person_id = p_person), '[]'::jsonb));
  end if;
  return out;
end $f$;
revoke all on function public.cms_person_profile(uuid) from public, anon;
grant execute on function public.cms_person_profile(uuid) to authenticated;

-- an image from the application (shown on demand, so the profile itself stays small)
create or replace function public.cms_person_eaf_image(p_person uuid, p_kind text)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; a jsonb;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('people', 'V', private.cms_canon(em.company_code));
  if p_kind <> 'photo' and not public.cms_can('people.ic', 'V') then raise exception 'Seeing ID images needs "See IC and passport numbers".' using errcode = '42501'; end if;
  select payload into a from public.eaf_applications where id = em.source_application_id;
  return case p_kind when 'photo' then a->>'photoData' when 'ic_front' then a->>'idFrontData' when 'ic_back' then a->>'idBackData' when 'signature' then a->>'sigData' end;
end $f$;
revoke all on function public.cms_person_eaf_image(uuid, text) from public, anon;
grant execute on function public.cms_person_eaf_image(uuid, text) to authenticated;

-- save personal details (only the keys below); an empty value clears the CMS edit so the application / payroll value shows again
create or replace function public.cms_person_profile_save(p_person uuid, p_data jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; cur jsonb; nxt jsonb; k text; v_name text;
  allowed text[] := array['chinese_name', 'race', 'religion', 'marital', 'nationality', 'passport', 'phone', 'email', 'address', 'family', 'children',
                          'emergency', 'education', 'work', 'spoken', 'written', 'skills'];
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('people', 'V', private.cms_canon(em.company_code));
  if not public.cms_can('people.personal_edit', 'V') then raise exception 'Changing personal details needs "Edit personal details".' using errcode = '42501'; end if;
  if p_data ? 'passport' and not public.cms_can('people.ic', 'V') then raise exception 'Changing the passport number needs "See IC and passport numbers".' using errcode = '42501'; end if;
  select coalesce(data, '{}'::jsonb) into cur from public.cms_person_profile where person_id = p_person; cur := coalesce(cur, '{}'::jsonb); nxt := cur;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then raise exception 'Unknown field: %', k; end if;
    if p_data->k is null or p_data->k = 'null'::jsonb or p_data->>k = '' then nxt := nxt - k; else nxt := nxt || jsonb_build_object(k, p_data->k); end if;
  end loop;
  select coalesce(e.employee_name, u.email) into v_name from auth.users u left join public.cms_user_links l on l.user_id = u.id left join public.employee_master e on e.id = l.employee_master_id where u.id = auth.uid();
  insert into public.cms_person_profile (person_id, data, updated_by, updated_by_name, updated_at) values (p_person, nxt, auth.uid(), v_name, now())
  on conflict (person_id) do update set data = excluded.data, updated_by = excluded.updated_by, updated_by_name = excluded.updated_by_name, updated_at = now();
  perform private.cms_log('person.profile', 'employee_master', p_person::text, private.cms_canon(em.company_code),
    em.employee_name || ': personal details changed (' || (select string_agg(x, ', ') from jsonb_object_keys(p_data) x) || ')' || coalesce(' · ' || p_note, ''),
    jsonb_build_object('fields', (select jsonb_agg(x) from jsonb_object_keys(p_data) x)));
end $f$;
revoke all on function public.cms_person_profile_save(uuid, jsonb, text) from public, anon;
grant execute on function public.cms_person_profile_save(uuid, jsonb, text) to authenticated;

-- record an uploaded image (the file is uploaded first to cms-profile-images/<person>/<kind>/...)
create or replace function public.cms_person_image_set(p_person uuid, p_kind text, p_path text)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; v_name text;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('people', 'V', private.cms_canon(em.company_code));
  if not public.cms_can('people.photos', 'V') then raise exception 'Uploading photos and ID images needs "Upload photo and ID images".' using errcode = '42501'; end if;
  if p_kind not in ('photo', 'ic_front', 'ic_back', 'passport') then raise exception 'Unknown image kind.'; end if;
  if split_part(p_path, '/', 1) <> p_person::text or split_part(p_path, '/', 2) <> p_kind then raise exception 'Unexpected file path.'; end if;
  select coalesce(e.employee_name, u.email) into v_name from auth.users u left join public.cms_user_links l on l.user_id = u.id left join public.employee_master e on e.id = l.employee_master_id where u.id = auth.uid();
  insert into public.cms_person_images (person_id, kind, path, uploaded_by, uploaded_by_name, uploaded_at) values (p_person, p_kind, p_path, auth.uid(), v_name, now())
  on conflict (person_id, kind) do update set path = excluded.path, uploaded_by = excluded.uploaded_by, uploaded_by_name = excluded.uploaded_by_name, uploaded_at = now();
  perform private.cms_log('person.image', 'employee_master', p_person::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || replace(p_kind, '_', ' ') || ' uploaded', jsonb_build_object('kind', p_kind, 'path', p_path));
end $f$;
revoke all on function public.cms_person_image_set(uuid, text, text) from public, anon;
grant execute on function public.cms_person_image_set(uuid, text, text) to authenticated;
