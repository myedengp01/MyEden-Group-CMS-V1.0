-- MyEden Group CMS V1.0 · Applications from people who are already employees (CLC 20 Nov 2026)
-- An application submitted by someone already on the Employee Master (form completed late, or made before the CMS) can be
-- linked to that person from Applications, at any stage: the application is attached to the record (Full application, photos,
-- IC images, family, education … then show on the profile), empty details on the record are filled from the application,
-- different details are only replaced when ticked with a reason, and a different IC number blocks the link.
-- No new person, Employee ID, payroll record, offer letter or handbook. Who: HR (Recruitment · edit), Admin, Directors.
-- Apply links can be made "for an existing employee": that person's submission links itself (same checks).
-- Unlink (Admin / Directors, with a reason) detaches the application again; values already filled stay.

-- ------------------------------------------------------------------ apply links for an existing employee
alter table public.eaf_v2_gateway_invitations add column if not exists for_person uuid references public.employee_master(id);

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_app_ic(a jsonb) returns text language sql immutable set search_path = pg_catalog, pg_temp as $$
  select nullif(regexp_replace(concat(a->>'ic1', a->>'ic2', a->>'ic3'), '\D', '', 'g'), '')
$$;

-- people on the Employee Master who look like the applicant: same IC (payroll record), same email, or same name
create or replace function private.cms_app_matches(p_app uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with a as (select id, payload p, private.cms_app_ic(payload) ic, private.cms_norm_name(coalesce(nullif(btrim(payload->>'nameEnglish'), ''), applicant_name)) nm,
                    lower(nullif(btrim(payload->>'email'), '')) mail from public.eaf_applications where id = p_app)
  select coalesce(jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'status', em.employment_status,
           'company', private.cms_canon(em.company_code), 'title', em.approved_job_title, 'start', em.start_date,
           'by', case when x.ic_same then 'IC' when a.mail is not null and lower(btrim(em.email)) = a.mail then 'email' else 'name' end,
           'linked_other', em.source_application_id is not null and em.source_application_id <> a.id)
         order by x.ic_same desc, em.start_date desc nulls last), '[]'::jsonb)
    from a cross join public.employee_master em
    cross join lateral (select exists (select 1 from public.eppd_employees ee join public.eppd_employee_private pv on pv.employee_id = ee.id
                          where ee.employee_master_id = em.id and a.ic is not null and regexp_replace(coalesce(pv.nric, ''), '\D', '', 'g') = a.ic) ic_same) x
   where em.source_application_id is distinct from a.id
     and (x.ic_same or private.cms_norm_name(em.employee_name) = a.nm or (a.mail is not null and lower(btrim(em.email)) = a.mail))
$$;

-- the details compared when linking: record value, application value, where an empty record value is filled
create or replace function private.cms_app_link_fields(p_app uuid, p_person uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a jsonb; em public.employee_master; ee public.eppd_employees; pv public.eppd_employee_private; d jsonb; pass boolean; v_out jsonb := '[]'::jsonb;
  f record;
begin
  select payload into a from public.eaf_applications where id = p_app; a := coalesce(a, '{}'::jsonb);
  select * into em from public.employee_master where id = p_person;
  select * into ee from public.eppd_employees where employee_master_id = p_person order by id desc limit 1;
  if ee.id is not null then select * into pv from public.eppd_employee_private where employee_id = ee.id; end if;
  select data into d from public.cms_person_profile where person_id = p_person; d := coalesce(d, '{}'::jsonb);
  pass := lower(coalesce(a->>'usingPassport', '')) in ('true', 'yes', '1');
  for f in select * from (values
      ('email', 'Email', coalesce(private.cms_nz(em.email), private.cms_nz(ee.email)), private.cms_nz(a->>'email'), 'master', true),
      ('phone', 'Phone', coalesce(private.cms_nz(em.contact), private.cms_nz(ee.phone)), private.cms_nz(a->>'contact'), 'master', true),
      ('gender', 'Gender', case em.gender_code when 'M' then 'Male' when 'F' then 'Female' end,
         case upper(left(coalesce(a->>'radio_gender', ''), 1)) when 'M' then 'Male' when 'F' then 'Female' end, 'master', true),
      ('chinese_name', 'Chinese name', coalesce(private.cms_nz(d->>'chinese_name'), private.cms_nz(ee.chinese_name)), private.cms_nz(a->>'nameChinese'), 'profile', true),
      ('nric', 'IC number', private.cms_nz(pv.nric), case when not pass and private.cms_app_ic(a) is not null then concat_ws('-', a->>'ic1', a->>'ic2', a->>'ic3') end, 'payroll', false),
      ('passport', 'Passport number', private.cms_nz(pv.passport_no), case when pass then private.cms_nz(a->>'passport') end, 'payroll', true),
      ('dob', 'Date of birth', pv.dob::text, private.cms_nz(a->>'dob'), 'payroll', true),
      ('address', 'Home address', private.cms_nz(pv.home_address),
         nullif(concat_ws(', ', private.cms_nz(a->>'addr1'), private.cms_nz(a->>'addr2'), private.cms_nz(a->>'addr3'), private.cms_nz(a->>'postcodeTown'), private.cms_nz(a->>'addrState')), ''), 'payroll', true)
    ) t(k, label, rec, app, target, can_replace)
  loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', f.k, 'label', f.label, 'record', f.rec, 'application', f.app, 'can_replace', f.can_replace,
      'action', case
        when f.app is null then 'none'
        when f.target = 'payroll' and ee.id is null then 'no_payroll'
        when f.rec is null then 'fill'
        when (f.k in ('phone', 'nric') and regexp_replace(f.rec, '\D', '', 'g') = regexp_replace(f.app, '\D', '', 'g'))
          or lower(regexp_replace(f.rec, '\s+', ' ', 'g')) = lower(regexp_replace(f.app, '\s+', ' ', 'g')) then 'same'
        else 'differs' end));
  end loop;
  return v_out;
end $$;

-- what the profile shows from the application by itself once linked (where the CMS has nothing of its own)
create or replace function private.cms_app_link_auto(p_app uuid, p_person uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with a as (select coalesce(payload, '{}'::jsonb) p from public.eaf_applications where id = p_app),
       d as (select coalesce((select data from public.cms_person_profile where person_id = p_person), '{}'::jsonb) d)
  select coalesce(jsonb_agg(l order by o), '[]'::jsonb) from a, d, lateral (values
    (1, 'Passport-size photo', length(coalesce(p->>'photoData', '')) > 100 and not exists (select 1 from public.cms_person_images i where i.person_id = p_person and i.kind = 'photo')),
    (2, 'IC images', length(coalesce(p->>'idFrontData', '')) > 100 and not exists (select 1 from public.cms_person_images i where i.person_id = p_person and i.kind = 'ic_front')),
    (3, 'Race, religion, marital status', coalesce(p->>'radio_race', p->>'radio_religion', p->>'radio_marital', '') <> '' and coalesce(d->>'race', d->>'religion', d->>'marital', '') = ''),
    (4, 'Family', jsonb_typeof(p->'familyRows') is not null and d->'family' is null),
    (5, 'Education', jsonb_typeof(p->'academicRows') is not null and d->'education' is null),
    (6, 'Work history', jsonb_typeof(p->'workExpData') = 'array' and d->'work' is null),
    (7, 'Languages and skills', coalesce(p->>'cb_spoken', p->>'specialSkills', '') <> '' and coalesce(d->>'spoken', d->>'skills', '') = ''),
    (8, 'Declarations and signature', length(coalesce(p->>'sigData', '')) > 100)) v(o, l, ok)
  where ok
$$;

create or replace function private.cms_app_link_ok(p_app uuid, p_person uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select (public.cms_can('recruitment', 'E', private.cms_app_company(p_app)) or private.cms_is_admin_or_director())
     and (p_person is null or public.cms_can('people', 'V', (select private.cms_canon(company_code) from public.employee_master where id = p_person)))
$$;

-- why a link cannot be made (null = it can)
create or replace function private.cms_app_link_block(p_app uuid, p_person uuid) returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; em public.employee_master; f jsonb;
begin
  select * into a from public.eaf_applications where id = p_app;
  if a.id is null then return 'Application not found.'; end if;
  select * into em from public.employee_master where id = p_person;
  if em.id is null then return 'Person not found.'; end if;
  if em.source_application_id = a.id then return 'This application is already linked to ' || em.employee_name || '.'; end if;
  if em.source_application_id is not null then return em.employee_name || ' already has an application linked. Admin can unlink it first.'; end if;
  if exists (select 1 from public.employee_master x where x.source_application_id = a.id) then return 'This application is already linked to another employee.'; end if;
  if exists (select 1 from public.eaf_loec_records l where l.application_id = a.id and l.status not in ('draft', 'superseded', 'cancelled')) then
    return 'An offer letter was issued from this application: it belongs to the hiring steps, not to an existing employee.'; end if;
  select x into f from jsonb_array_elements(private.cms_app_link_fields(p_app, p_person)) x where x->>'key' = 'nric';
  if f->>'action' = 'differs' then return 'The IC number on the application is different from the IC number on the payroll record. This may be a different person: check the record first.'; end if;
  return null;
end $$;

-- link (no permission check here: the public functions check it); fills empty details, replaces ticked ones
create or replace function private.cms_app_link_do(p_app uuid, p_person uuid, p_replace text[], p_reason text, p_how text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; em public.employee_master; ee public.eppd_employees; v_block text; f jsonb; k text; v text; done text[] := '{}'; repl text[] := '{}';
  v_co text; v_who text := coalesce(private.cms_my_name(), case when p_how = 'apply_link' then 'the employee (apply link)' end);
begin
  v_block := private.cms_app_link_block(p_app, p_person);
  if v_block is not null then raise exception '%', v_block; end if;
  select * into a from public.eaf_applications where id = p_app for update;
  select * into em from public.employee_master where id = p_person for update;
  select * into ee from public.eppd_employees where employee_master_id = p_person order by id desc limit 1;
  v_co := private.cms_canon(em.company_code);
  if coalesce(array_length(p_replace, 1), 0) > 0 and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for replacing details on the record.'; end if;
  for f in select x from jsonb_array_elements(private.cms_app_link_fields(p_app, p_person)) x loop
    k := f->>'key'; v := f->>'application';
    -- the same email / phone already on the payroll record: also keep it on the Employee Master (used to recognise the person)
    if f->>'action' = 'same' and k = 'email' and em.email is null then update public.employee_master set email = lower(btrim(v)) where id = em.id; end if;
    if f->>'action' = 'same' and k = 'phone' and em.contact is null then update public.employee_master set contact = btrim(v) where id = em.id; end if;
    if not (f->>'action' = 'fill' or (f->>'action' = 'differs' and (f->>'can_replace')::boolean and k = any(coalesce(p_replace, '{}')))) then continue; end if;
    if k = 'email' then update public.employee_master set email = lower(btrim(v)) where id = em.id;
    elsif k = 'phone' then update public.employee_master set contact = btrim(v) where id = em.id;
    elsif k = 'gender' then update public.employee_master set gender_code = left(v, 1) where id = em.id;
    elsif k = 'chinese_name' then
      insert into public.cms_person_profile (person_id, data, updated_by, updated_by_name) values (em.id, jsonb_build_object('chinese_name', v), auth.uid(), v_who)
      on conflict (person_id) do update set data = public.cms_person_profile.data || jsonb_build_object('chinese_name', v), updated_by = auth.uid(), updated_by_name = v_who, updated_at = now();
    elsif ee.id is not null and k in ('nric', 'passport', 'dob', 'address') then
      insert into public.eppd_employee_private (employee_id) values (ee.id) on conflict (employee_id) do nothing;
      if k = 'nric' then update public.eppd_employee_private set nric = v, updated_at = now() where employee_id = ee.id;
      elsif k = 'passport' then update public.eppd_employee_private set passport_no = v, updated_at = now() where employee_id = ee.id;
      elsif k = 'dob' then update public.eppd_employee_private set dob = v::date, updated_at = now() where employee_id = ee.id;
      else update public.eppd_employee_private set home_address = v, updated_at = now() where employee_id = ee.id; end if;
    else continue; end if;
    if f->>'action' = 'fill' then done := done || (f->>'label'); else repl := repl || (f->>'label'); end if;
  end loop;
  update public.employee_master set source_application_id = a.id, updated_at = now() where id = em.id;
  update public.eaf_applications set workflow_stage = 'completed', updated_at = now(),
         payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('_cms_existing', jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id,
           'name', em.employee_name, 'at', now(), 'by', v_who, 'how', p_how, 'filled', to_jsonb(done), 'replaced', to_jsonb(repl), 'reason', nullif(btrim(coalesce(p_reason, '')), '')))
   where id = a.id;
  update public.eaf_application_events set note = 'Linked to the existing employee ' || em.employee_name || coalesce(' (' || em.employee_id || ')', '')
   where id = (select id from public.eaf_application_events where application_id = a.id and to_stage = 'completed' order by created_at desc limit 1);
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'application_linked', 'Application form linked to the existing employee record' ||
          case when cardinality(done) > 0 then ' · filled: ' || array_to_string(done, ', ') else '' end ||
          case when cardinality(repl) > 0 then ' · replaced: ' || array_to_string(repl, ', ') else '' end,
          jsonb_build_object('application_id', a.id, 'how', p_how, 'filled', to_jsonb(done), 'replaced', to_jsonb(repl), 'reason', p_reason), auth.uid());
  perform private.cms_log('person.application_linked', 'employee_master', em.id::text, v_co,
    em.employee_name || coalesce(' (' || em.employee_id || ')', '') || ': application linked as an existing employee' ||
    case when cardinality(done) > 0 then '; filled ' || array_to_string(done, ', ') else '' end ||
    case when cardinality(repl) > 0 then '; replaced ' || array_to_string(repl, ', ') else '' end,
    jsonb_build_object('application_id', a.id, 'how', p_how, 'reason', p_reason));
  return jsonb_build_object('filled', to_jsonb(done), 'replaced', to_jsonb(repl), 'employee_id', em.employee_id, 'name', em.employee_name);
end $$;

-- ------------------------------------------------------------------ RPCs
create or replace function public.cms_app_link_preview(p_app uuid, p_person uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; em public.employee_master; c_ic boolean := public.cms_can('people.ic', 'V'); v_fields jsonb;
begin
  select * into a from public.eaf_applications where id = p_app;
  if a.id is null then raise exception 'Application not found.'; end if;
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  if not private.cms_app_link_ok(p_app, p_person) then raise exception 'Linking applications needs Recruitment · edit (HR), Admin or Director.'; end if;
  select coalesce(jsonb_agg(case when x->>'key' in ('nric', 'passport') and not c_ic then
      x || jsonb_build_object('record', case when x->>'record' is not null then '•••• ' || right(x->>'record', 4) end,
                              'application', case when x->>'application' is not null then '•••• ' || right(x->>'application', 4) end) else x end), '[]'::jsonb)
    into v_fields from jsonb_array_elements(private.cms_app_link_fields(p_app, p_person)) x;
  return jsonb_build_object(
    'application', jsonb_build_object('id', a.id, 'name', upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)),
       'company', private.cms_app_company(a.id), 'submitted_at', a.submitted_at, 'stage', a.workflow_stage),
    'person', jsonb_build_object('id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
       'status', em.employment_status, 'title', em.approved_job_title, 'start', em.start_date),
    'same_name', private.cms_norm_name(em.employee_name) = private.cms_norm_name(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)),
    'block', private.cms_app_link_block(p_app, p_person), 'fields', v_fields, 'auto', private.cms_app_link_auto(p_app, p_person));
end $$;

create or replace function public.cms_app_link(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_app uuid := (p->>'application')::uuid; v_person uuid := (p->>'person')::uuid; v_rep text[];
begin
  if not private.cms_app_link_ok(v_app, v_person) then raise exception 'Linking applications needs Recruitment · edit (HR), Admin or Director.'; end if;
  select coalesce(array_agg(x), '{}') into v_rep from jsonb_array_elements_text(coalesce(p->'replace', '[]'::jsonb)) x;
  return private.cms_app_link_do(v_app, v_person, v_rep, p->>'reason', 'hr');
end $$;

create or replace function public.cms_app_unlink(p_app uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; em public.employee_master;
begin
  if not private.cms_is_admin_or_director() then raise exception 'Only Admin or a Director can unlink an application.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  select * into a from public.eaf_applications where id = p_app for update;
  if a.id is null or not (a.payload ? '_cms_existing') then raise exception 'This application was not linked as an existing employee.'; end if;
  select * into em from public.employee_master where source_application_id = a.id for update;
  if em.id is not null then update public.employee_master set source_application_id = null, updated_at = now() where id = em.id; end if;
  update public.eaf_applications set workflow_stage = 'submitted', updated_at = now(),
         payload = (payload - '_cms_existing') || jsonb_build_object('_cms_unlinked', jsonb_build_object('person_id', em.id, 'at', now(), 'by', private.cms_my_name(), 'reason', btrim(p_reason)))
   where id = a.id;
  update public.eaf_application_events set note = 'Unlinked from ' || coalesce(em.employee_name, 'the employee') || ': ' || btrim(p_reason)
   where id = (select id from public.eaf_application_events where application_id = a.id and to_stage = 'submitted' order by created_at desc limit 1);
  if em.id is not null then
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (em.id, 'application_unlinked', 'Application form unlinked: ' || btrim(p_reason), jsonb_build_object('application_id', a.id), auth.uid());
  end if;
  perform private.cms_log('person.application_unlinked', 'eaf_applications', a.id::text, private.cms_app_company(a.id),
    coalesce(em.employee_name, 'Application') || ': application unlinked (details already filled stay)', jsonb_build_object('person_id', em.id, 'reason', p_reason));
end $$;

-- an apply link for one existing employee (one use, their company); their submission links itself
create or replace function public.cms_apply_link_for(p_person uuid, p_expires timestamptz) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; c text; r public.eaf_v2_gateway_invitations;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  if not ((public.cms_can('recruitment', 'E') or private.cms_is_admin_or_director()) and public.cms_can('people', 'V', private.cms_canon(em.company_code))) then
    raise exception 'Making apply links needs Recruitment · edit (HR), Admin or Director.'; end if;
  if em.source_application_id is not null then raise exception '% already has an application form linked.', em.employee_name; end if;
  if p_expires is null or p_expires <= now() then raise exception 'The link must be valid until a later date.'; end if;
  select x into c from unnest(array['meg', 'meh', 'hds', 'abn']) x where private.cms_canon(upper(x)) = private.cms_canon(em.company_code) limit 1;
  insert into public.eaf_v2_gateway_invitations (token, app_code, company_code, expires_at, max_uses, use_count, created_by, for_person)
  values (gen_random_uuid(), 'apply', coalesce(c, 'meg'), p_expires, 1, 0, auth.uid(), em.id) returning * into r;
  perform private.cms_log('apply_link.created', 'eaf_v2_gateway_invitations', r.id::text, private.cms_canon(em.company_code),
    'Apply link for the existing employee ' || em.employee_name || coalesce(' (' || em.employee_id || ')', '') || ', until ' || to_char(p_expires at time zone 'Asia/Kuala_Lumpur', 'DD Mon YYYY HH24:MI'), '{}'::jsonb);
  return jsonb_build_object('id', r.id, 'token', r.token);
end $$;

-- the links list shows who a link is for
do $m$ declare d text := pg_get_functiondef('public.cms_apply_links()'::regprocedure); n text;
begin
  if position('for_person' in d) > 0 then return; end if;
  n := replace(d, $x$'status', case when i.revoked_at$x$, $x$'for', (select jsonb_build_object('id', e.id, 'name', e.employee_name, 'employee_id', e.employee_id) from public.employee_master e where e.id = i.for_person),
       'status', case when i.revoked_at$x$);
  if n = d then raise exception 'cms_apply_links patch point not found'; end if;
  execute n;
end $m$;

-- a submission from a link made for an existing employee links itself (if the checks pass); otherwise it waits in Applications
do $m$ declare d text := pg_get_functiondef('public.cms_apply_submit(jsonb,text,text)'::regprocedure); n text;
begin
  if position('for_person' in d) > 0 then return; end if;
  n := replace(d, $x$  perform private.cms_apply_mark_draft(p_draft_code, v_id);$x$, $x$  perform private.cms_apply_mark_draft(p_draft_code, v_id);
  declare v_for uuid; begin
    begin select for_person into v_for from public.eaf_v2_gateway_invitations where token = nullif(btrim(p_token), '')::uuid; exception when others then v_for := null; end;
    if v_for is not null then
      update public.eaf_applications set payload = payload || jsonb_build_object('_cms_for_person', v_for) where id = v_id;
      if private.cms_app_link_block(v_id, v_for) is null then
        begin perform private.cms_app_link_do(v_id, v_for, '{}', null, 'apply_link'); exception when others then null; end;
      end if;
    end if;
  end;$x$);
  if n = d then raise exception 'cms_apply_submit patch point not found'; end if;
  execute n;
end $m$;

-- the Applications list: possible existing employees, and applications linked as existing employees
do $m$ declare d text := pg_get_functiondef('public.cms_recruit_applications()'::regprocedure); n text;
begin
  if position('_cms_existing' in d) > 0 then return; end if;
  n := replace(d, $x$'handoff', h.handoff_status,$x$, $x$'handoff', h.handoff_status,
      'existing', a.payload->'_cms_existing',
      'matches', case when em.id is null and coalesce(a.workflow_stage, 'submitted') not in ('completed', 'rejected') then private.cms_app_matches(a.id) else '[]'::jsonb end,$x$);
  if n = d then raise exception 'cms_recruit_applications patch point not found'; end if;
  execute n;
end $m$;

do $m$ declare d text := pg_get_functiondef('public.cms_recruit_application(uuid)'::regprocedure); n text;
begin
  if position('_cms_existing' in d) > 0 then return; end if;
  n := replace(d, $x$    'events', coalesce($x$, $x$    'existing', p->'_cms_existing', 'unlinked', p->'_cms_unlinked',
    'for_person', (select jsonb_build_object('id', e.id, 'name', e.employee_name, 'employee_id', e.employee_id) from public.employee_master e where e.id = (p->>'_cms_for_person')::uuid),
    'matches', case when coalesce(a.workflow_stage, 'submitted') not in ('completed', 'rejected') and not exists (select 1 from public.employee_master x where x.source_application_id = a.id)
                    then private.cms_app_matches(a.id) else '[]'::jsonb end,
    'can_link', private.cms_app_link_ok(a.id, null), 'can_unlink', private.cms_is_admin_or_director(),
    'events', coalesce($x$);
  if n = d then raise exception 'cms_recruit_application patch point not found'; end if;
  execute n;
end $m$;

revoke all on function private.cms_app_ic(jsonb), private.cms_app_matches(uuid), private.cms_app_link_fields(uuid, uuid), private.cms_app_link_auto(uuid, uuid),
  private.cms_app_link_ok(uuid, uuid), private.cms_app_link_block(uuid, uuid), private.cms_app_link_do(uuid, uuid, text[], text, text) from public, anon, authenticated;
revoke all on function public.cms_app_link_preview(uuid, uuid), public.cms_app_link(jsonb), public.cms_app_unlink(uuid, text), public.cms_apply_link_for(uuid, timestamptz) from public, anon;
grant execute on function public.cms_app_link_preview(uuid, uuid), public.cms_app_link(jsonb), public.cms_app_unlink(uuid, text), public.cms_apply_link_for(uuid, timestamptz) to authenticated;
