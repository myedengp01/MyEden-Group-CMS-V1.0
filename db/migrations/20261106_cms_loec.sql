-- MyEden Group CMS V1.0 · v2026.11.06 · Offer letter (LOEC) prepared in the CMS (PRI-017), part-time sick leave (CLC 6 Nov 2026)
-- 1. Company details for letters (registration no., registered and business address, phone, email, handbook) on cms_companies,
--    and the old payroll companies Eden Childcare Center, Taska Genius Eden and White Feather Entertainment switched off (nobody is assigned).
-- 2. Part-time leave: sick leave the same as full time from leave year 2026; annual leave "same as full time" switched on from 2026.
-- 3. LOEC in the CMS: HR / Admin prepares from the application → Admin / Director approves → HR issues. The letter is the MEG-EAF V2
--    Combined Letter of Offer & Contract of Employment (Version 2.0) as it is. It is kept in eaf_loec_records (same row MEG-EAF V2 uses),
--    the terms are written back to the application, and the reference is the CMS letter number, e.g. MEG/HR/LOEC/2026/0007 (-R2 when reissued).
-- 4. On hire, the issued letter's terms fill the working days, weekly hours, probation, reporting line and allowances.
-- Additive only: new columns, updated policy values, new functions; no rows are removed.

-- 1 · company details ------------------------------------------------------------------------------------------------------------
alter table public.cms_companies add column if not exists registration_no text;
alter table public.cms_companies add column if not exists registered_address text;
alter table public.cms_companies add column if not exists business_address text;
alter table public.cms_companies add column if not exists phone text;
alter table public.cms_companies add column if not exists email text;
alter table public.cms_companies add column if not exists handbook text;
alter table public.cms_companies add column if not exists eaf_code text;

update public.cms_companies c set
  registration_no = coalesce(c.registration_no, v.reg), registered_address = coalesce(c.registered_address, v.regaddr),
  business_address = coalesce(c.business_address, v.addr), phone = coalesce(c.phone, v.phone), email = coalesce(c.email, v.email),
  handbook = coalesce(c.handbook, v.hb), eaf_code = coalesce(c.eaf_code, v.eaf)
from (values
  ('MEG', '201901034872 (1344202-X)', 'Forreststone Secretarial Services Plt, No. 20-02, Jalan Eco Cascadia 6/2, Taman Setia Eco Cascadia, 81100 Johor Bahru, Johor.',
          'No. 63, Jalan Indah 19/1, Taman Bukit Indah, 81200 Johor Bahru, Johor.', '+6016-2191170', 'contact.info@myeden.group', 'MyEden Group Employee Handbook v2.0', 'meg'),
  ('MEH', '202501000075 (1601490-W)', 'Forreststone Secretarial Services Plt, No. 20-02, Jalan Eco Cascadia 6/2, Taman Setia Eco Cascadia, 81100 Johor Bahru, Johor.',
          'No. 63, Jalan Indah 19/1, Taman Bukit Indah, 81200 Johor Bahru, Johor.', '+6016-2191170', 'contact.info@myeden.group', 'MyEden Group Employee Handbook v2.0', 'meh'),
  ('HD',  '202401021055 (1566904-W)', 'Forreststone Secretarial Services Plt, No. 20-02, Jalan Eco Cascadia 6/2, Taman Setia Eco Cascadia, 81100 Johor Bahru, Johor.',
          '14A, Jalan Indah 15/1, Taman Bukit Indah, 81200 Johor Bahru, Johor.', '+6018-4091170', 'happydinocamp@gmail.com', 'Happy Dino Employee Handbook & Child-Safe Event Code v1.0', 'hds'),
  ('ABP', '202501023777 (1625190-X)', 'Forreststone Secretarial Services Plt, No. 20-02, Jalan Eco Cascadia 6/2, Taman Setia Eco Cascadia, 81100 Johor Bahru, Johor.',
          '14A, Jalan Indah 15/1, Taman Bukit Indah, 79100 Iskandar Puteri, Johor.', '+6018-4191170', 'whitefeatherentmt2022@gmail.com', 'Aborne Project Employee Handbook & Event Professional Code v1.0', 'abn')
) as v(code, reg, regaddr, addr, phone, email, hb, eaf)
where c.code = v.code;

-- old payroll companies: Eden Childcare Center is Pusat Jagaan Kanak-Kanak Eden (MyEden Group), Taska Genius Eden is MyEden Group,
-- White Feather is no longer used. Only switched off when nobody is assigned to them.
update public.eppd_companies c set is_active = false
 where c.code in ('ECC', 'TGED', 'WFE') and c.is_active
   and not exists (select 1 from public.eppd_assignments a where a.company_id = c.id);
update public.cms_companies set name = 'Pusat Jagaan Kanak-Kanak Eden (Eden Childcare Center)' where code = 'PJKE' and name = 'Pusat Jagaan Kanak-Kanak Eden';

-- 2 · part-time leave --------------------------------------------------------------------------------------------------------------
update public.eppd_policies set value = coalesce(value, '{}'::jsonb)
  || jsonb_build_object('sl_same_as_ft_from', 2026, 'al_method', 'same_as_ft', 'al_method_from', 2026)
 where key = 'part_time';

-- 3 · LOEC prepared in the CMS -------------------------------------------------------------------------------------------------------
alter table public.eaf_loec_records add column if not exists source text;
alter table public.eaf_loec_records add column if not exists prepared_by uuid;
alter table public.eaf_loec_records add column if not exists submitted_at timestamptz;
alter table public.eaf_loec_records add column if not exists approved_by uuid;
alter table public.eaf_loec_records add column if not exists approved_at timestamptz;
alter table public.eaf_loec_records add column if not exists return_note text;
alter table public.eaf_loec_records add column if not exists issued_by uuid;

-- who approves: Admin or Director
create or replace function private.cms_loec_can_approve() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.cms_user_roles
    where user_id = auth.uid() and is_active and role_code in ('super_admin', 'admin', 'director'));
$$;
revoke all on function private.cms_loec_can_approve() from public, anon, authenticated;

create or replace function private.cms_loec_cms_code(p_eaf text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select code from public.cms_companies where eaf_code = lower(p_eaf) limit 1),
                  case lower(p_eaf) when 'meg' then 'MEG' when 'meh' then 'MEH' when 'hds' then 'HD' when 'abn' then 'ABP' end);
$$;
revoke all on function private.cms_loec_cms_code(text) from public, anon, authenticated;

-- move the application on the recruitment workflow (only along the allowed steps), with a note on the history line
create or replace function private.cms_app_stage(p_app uuid, p_to text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $f$
declare cur text;
begin
  select workflow_stage into cur from public.eaf_applications where id = p_app for update;
  if cur is null or cur = p_to or not public.eaf_workflow_transition_allowed(cur, p_to) then return; end if;
  update public.eaf_applications set workflow_stage = p_to,
         payload = case when p_to = 'shortlisted' then jsonb_set(coalesce(payload, '{}'::jsonb), '{decision}', to_jsonb('Approved'::text), true) else payload end,
         updated_at = now()
   where id = p_app;
  update public.eaf_application_events set note = p_note
   where id = (select id from public.eaf_application_events where application_id = p_app and to_stage = p_to order by created_at desc limit 1);
end $f$;
revoke all on function private.cms_app_stage(uuid, text, text) from public, anon, authenticated;

-- everything the LOEC window needs
create or replace function public.cms_loec_get(p_application uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare a public.eaf_applications; co text; p jsonb;
begin
  select * into a from public.eaf_applications where id = p_application;
  if a.id is null then raise exception 'Application not found.'; end if;
  co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  if not (public.cms_can('recruitment', 'V', co) or public.cms_can('onboarding', 'V', co) or private.cms_loec_can_approve()) then
    raise exception 'You do not have access to this.'; end if;
  p := coalesce(a.payload, '{}'::jsonb);
  return jsonb_build_object(
    'application_id', a.id, 'company', co, 'eaf_company', lower(coalesce(a.company_code, p->>'companyCode', 'meg')), 'stage', coalesce(a.workflow_stage, 'submitted'),
    'decision', p->>'decision', 'position_applied', a.position_applied,
    'applicant', jsonb_build_object('name', upper(coalesce(nullif(btrim(p->>'nameEnglish'), ''), a.applicant_name)), 'chinese_name', p->>'nameChinese',
       'gender', p->>'radio_gender', 'marital', p->>'radio_marital', 'ic1', p->>'ic1', 'ic2', p->>'ic2', 'ic3', p->>'ic3', 'passport', p->>'passport',
       'addr1', p->>'addr1', 'addr2', p->>'addr2', 'addr3', p->>'addr3', 'postcode_town', p->>'postcodeTown', 'state', p->>'addrState'),
    'terms', (select coalesce(jsonb_object_agg(k, p->k), '{}'::jsonb) from unnest(array['letterDate','approvedJobTitle','v2ResolvedJobTitle','jobTitleLevel','v2JdId','v2JdReference',
       'finalDept','finalStart','v2EmploymentType','v2FixedTermEnd','v2ProbationMonths','v2ProbationNotice','v2ProbationNoticeUnit','v2PayBasis','finalSalary','finalSalaryWords',
       'v2FixedAllowance','v2OtherAllowance','finalFrom','finalTo','v2Session2Enabled','v2Session2From','v2Session2To','v2WorkingDays','v2WorkingScheduleNote','v2DailyHours',
       'workLocation','workLocationOther','workLocationOtherText','reportingName','reportingTitle','v2OtCategory','v2Handbook','appendix1Text','v2Appendices',
       'cmsTitle','cmsWeeklyHours','cmsSigningCompany']) k where p ? k),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'eaf', c.eaf_code, 'name', c.name, 'registration_no', c.registration_no,
       'registered_address', c.registered_address, 'business_address', c.business_address, 'handbook', c.handbook) order by c.sort_order), '[]'::jsonb)
       from public.cms_companies c where c.is_active and c.eaf_code is not null),
    'records', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'document_id', l.document_id, 'revision', l.revision, 'status', l.status, 'company', l.company_code,
       'source', coalesce(l.source, 'eaf'), 'terms', l.terms_snapshot, 'jd_id', l.jd_id, 'jd_reference', l.jd_reference, 'created_at', l.created_at, 'updated_at', l.updated_at,
       'prepared_by', private.cms_user_name(l.prepared_by), 'submitted_at', l.submitted_at, 'approved_by', private.cms_user_name(l.approved_by), 'approved_at', l.approved_at,
       'return_note', l.return_note, 'issued_at', l.issued_at, 'issued_by', private.cms_user_name(l.issued_by)) order by l.revision desc)
       from public.eaf_loec_records l where l.application_id = a.id), '[]'::jsonb),
    'can_prepare', public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co),
    'can_approve', private.cms_loec_can_approve(),
    'can_see_pay', public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co) or private.cms_loec_can_approve());
end $f$;
revoke all on function public.cms_loec_get(uuid) from public, anon;
grant execute on function public.cms_loec_get(uuid) to authenticated;

-- save the draft (and optionally send it for approval). p: { terms:{…payload keys}, company:'meg'|'meh'|'hds'|'abn', submit:bool }
create or replace function public.cms_loec_save(p_application uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare a public.eaf_applications; co text; l public.eaf_loec_records; t jsonb := coalesce(p->'terms', '{}'::jsonb); v_co text := lower(coalesce(p->>'company', ''));
  keys text[] := array['letterDate','approvedJobTitle','jobTitleLevel','v2JdId','v2JdReference','finalDept','finalStart','v2EmploymentType','v2FixedTermEnd','v2ProbationMonths',
    'v2ProbationNotice','v2ProbationNoticeUnit','v2PayBasis','finalSalary','finalSalaryWords','v2FixedAllowance','v2OtherAllowance','finalFrom','finalTo','v2Session2Enabled',
    'v2Session2From','v2Session2To','v2WorkingDays','v2WorkingScheduleNote','v2DailyHours','workLocation','workLocationOther','workLocationOtherText','reportingName',
    'reportingTitle','v2OtCategory','v2Handbook','appendix1Text','cmsTitle','cmsWeeklyHours','cmsSigningCompany'];
  k text; pay jsonb; n int; y int := extract(year from (now() at time zone 'Asia/Kuala_Lumpur'))::int; ref text; cc text; v_rev int;
begin
  select * into a from public.eaf_applications where id = p_application for update;
  if a.id is null then raise exception 'Application not found.'; end if;
  co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  if not (public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co)) then raise exception 'You cannot prepare offer letters for this company.'; end if;
  if v_co not in ('meg', 'meh', 'hds', 'abn') then raise exception 'Choose the company the letter is issued under.'; end if;
  if exists (select 1 from public.employee_master where source_application_id = a.id) then raise exception 'This applicant is already hired; the offer letter can no longer be changed here.'; end if;
  -- terms back to the application, so MEG-EAF V2 shows the same values
  pay := coalesce(a.payload, '{}'::jsonb);
  foreach k in array keys loop if t ? k then pay := jsonb_set(pay, array[k], t->k, true); end if; end loop;
  pay := jsonb_set(pay, '{cmsSigningCompany}', to_jsonb(v_co), true);
  update public.eaf_applications set payload = pay, updated_at = now() where id = a.id;
  t := (select coalesce(jsonb_object_agg(k2, pay->k2), '{}'::jsonb) from unnest(keys) k2 where pay ? k2);
  -- the open draft (if any)
  select * into l from public.eaf_loec_records where application_id = a.id and status = 'draft' order by revision desc limit 1 for update;
  if l.id is not null and l.company_code <> v_co then
    -- the employer of a letter cannot change: the old draft is cancelled and a new one started
    update public.eaf_loec_records set status = 'cancelled', return_note = 'Company changed in the CMS', updated_by = auth.uid() where id = l.id;
    l := null;
  end if;
  if l.id is null then
    if exists (select 1 from public.eaf_loec_records where application_id = a.id and status not in ('draft', 'cancelled', 'superseded')) then
      raise exception 'An offer letter has already been issued. Use “New revision” to change it.'; end if;
    select coalesce(max(revision), 0) + 1 into v_rev from public.eaf_loec_records where application_id = a.id;
    -- the base number is kept for every revision of the same offer under the same company: MEG/HR/LOEC/2026/0007, then …-R2
    cc := private.cms_loec_cms_code(v_co);
    select regexp_replace(document_id, '-R[0-9]+$', '') into ref from public.eaf_loec_records
     where application_id = a.id and document_id like cc || '/HR/LOEC/%' order by revision limit 1;
    if ref is null then
      insert into public.cms_letter_ref_counters as c (company_code, year, last_no) values (cc, y, 1)
        on conflict (company_code, year) do update set last_no = c.last_no + 1 returning last_no into n;
      ref := cc || '/HR/LOEC/' || y || '/' || lpad(n::text, 4, '0');
    end if;
    insert into public.eaf_loec_records (application_id, company_code, document_id, revision, template_version, status, jd_id, jd_reference, terms_snapshot,
                                         source, prepared_by, updated_by)
    values (a.id, v_co, case when v_rev = 1 or not exists (select 1 from public.eaf_loec_records where document_id = ref) then ref else ref || '-R' || v_rev end,
            v_rev, '2.0', 'draft', nullif(t->>'v2JdId', '')::uuid, nullif(t->>'v2JdReference', ''), t, 'cms', auth.uid(), auth.uid())
    returning * into l;
  else
    update public.eaf_loec_records set terms_snapshot = t, jd_id = nullif(t->>'v2JdId', '')::uuid, jd_reference = nullif(t->>'v2JdReference', ''),
           source = coalesce(source, 'cms'), prepared_by = coalesce(prepared_by, auth.uid()), approved_by = null, approved_at = null, submitted_at = null, updated_by = auth.uid()
     where id = l.id returning * into l;
  end if;
  if coalesce((p->>'submit')::boolean, false) then
    update public.eaf_loec_records set submitted_at = now(), return_note = null where id = l.id returning * into l;
  end if;
  -- the application moves to "Preparing offer" (Approved → Shortlisted first when it was still New / Under review / KIV)
  if coalesce(a.workflow_stage, 'submitted') in ('submitted', 'under_review', 'kiv') then
    perform private.cms_app_stage(a.id, 'shortlisted', 'Decision Approved; offer letter started in the CMS');
  end if;
  perform private.cms_app_stage(a.id, 'offer_preparation', 'Offer letter ' || l.document_id || ' prepared in the CMS');
  return jsonb_build_object('id', l.id, 'document_id', l.document_id, 'revision', l.revision, 'submitted', l.submitted_at is not null);
end $f$;
revoke all on function public.cms_loec_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_loec_save(uuid, jsonb) to authenticated;

-- Admin / Director: approve, or send back with a note
create or replace function public.cms_loec_decide(p_loec uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.eaf_loec_records;
begin
  if not private.cms_loec_can_approve() then raise exception 'Only an Admin or Director can approve offer letters.'; end if;
  select * into l from public.eaf_loec_records where id = p_loec for update;
  if l.id is null or l.status <> 'draft' or l.submitted_at is null then raise exception 'This offer letter is not waiting for approval.'; end if;
  if p_approve then
    update public.eaf_loec_records set approved_by = auth.uid(), approved_at = now(), return_note = null, updated_by = auth.uid() where id = l.id;
  else
    if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say what needs changing.'; end if;
    update public.eaf_loec_records set submitted_at = null, approved_by = null, approved_at = null, return_note = btrim(p_note), updated_by = auth.uid() where id = l.id;
  end if;
end $f$;
revoke all on function public.cms_loec_decide(uuid, boolean, text) from public, anon;
grant execute on function public.cms_loec_decide(uuid, boolean, text) to authenticated;

-- HR / Admin issues an approved letter: the terms are frozen and the application moves to "Offer issued"
create or replace function public.cms_loec_issue(p_loec uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.eaf_loec_records; a public.eaf_applications; co text;
begin
  select * into l from public.eaf_loec_records where id = p_loec for update;
  if l.id is null then raise exception 'Offer letter not found.'; end if;
  select * into a from public.eaf_applications where id = l.application_id;
  co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  if not (public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co) or private.cms_loec_can_approve()) then raise exception 'You cannot issue offer letters for this company.'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft can be issued.'; end if;
  if l.approved_at is null then raise exception 'An Admin or Director must approve the letter first.'; end if;
  if l.terms_snapshot is null or l.terms_snapshot = '{}'::jsonb then raise exception 'The letter has no terms.'; end if;
  update public.eaf_loec_records set status = 'issued', issued_at = now(), issued_by = auth.uid(), stamp_status = coalesce(stamp_status, 'pending'), updated_by = auth.uid() where id = l.id;
  perform private.cms_app_stage(a.id, 'offer_issued', 'Offer letter ' || l.document_id || ' issued in the CMS');
end $f$;
revoke all on function public.cms_loec_issue(uuid) from public, anon;
grant execute on function public.cms_loec_issue(uuid) to authenticated;

-- a new revision of an issued letter: the issued one is superseded, a new draft starts from its terms (…-R2)
create or replace function public.cms_loec_revise(p_loec uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.eaf_loec_records; a public.eaf_applications; co text; v_rev int; base text; nl public.eaf_loec_records;
begin
  select * into l from public.eaf_loec_records where id = p_loec for update;
  if l.id is null then raise exception 'Offer letter not found.'; end if;
  select * into a from public.eaf_applications where id = l.application_id;
  co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  if not (public.cms_can('recruitment', 'E', co) or public.cms_can('onboarding', 'E', co)) then raise exception 'You cannot change offer letters for this company.'; end if;
  if l.status not in ('issued', 'signed_uploaded', 'verified', 'stamp_pending', 'stamped', 'completed') then raise exception 'Only an issued letter can be revised.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for the new revision.'; end if;
  if exists (select 1 from public.eaf_loec_records where application_id = l.application_id and status = 'draft') then raise exception 'A draft revision already exists.'; end if;
  update public.eaf_loec_records set status = 'superseded', superseded_at = now(), return_note = btrim(p_reason), updated_by = auth.uid() where id = l.id;
  select coalesce(max(revision), 0) + 1 into v_rev from public.eaf_loec_records where application_id = l.application_id;
  base := regexp_replace(l.document_id, '-R[0-9]+$', '');
  insert into public.eaf_loec_records (application_id, company_code, document_id, revision, template_version, status, jd_id, jd_reference, terms_snapshot, source, prepared_by, updated_by)
  values (l.application_id, l.company_code, base || '-R' || v_rev, v_rev, '2.0', 'draft', l.jd_id, l.jd_reference, l.terms_snapshot, 'cms', auth.uid(), auth.uid())
  returning * into nl;
  return jsonb_build_object('id', nl.id, 'document_id', nl.document_id);
end $f$;
revoke all on function public.cms_loec_revise(uuid, text) from public, anon;
grant execute on function public.cms_loec_revise(uuid, text) to authenticated;

-- letters waiting for approval / to issue (bell)
create or replace function public.cms_loec_pending()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'to_approve', case when private.cms_loec_can_approve() then (select count(*) from public.eaf_loec_records where status = 'draft' and submitted_at is not null and approved_at is null) else 0 end,
    'to_issue', case when public.cms_can('recruitment', 'E') or public.cms_can('onboarding', 'E') then (select count(*) from public.eaf_loec_records where status = 'draft' and approved_at is not null) else 0 end);
$$;
revoke all on function public.cms_loec_pending() from public, anon;
grant execute on function public.cms_loec_pending() to authenticated;

-- 4 · on hire: the issued letter's terms that the hire form does not carry -------------------------------------------------------
-- p: { work_days, weekly_hours, part_time:bool, probation_months, reporting_name, reporting_title, employment_type,
--      allowances:[{payment_type_id, amount, note}] } — HR confirms each in the hire window
create or replace function public.cms_hire_loec_apply(p_person uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare em public.employee_master; ee public.eppd_employees; m public.eppd_employments; asg bigint; x jsonb;
begin
  perform private.cms_require('onboarding', 'E');
  select * into em from public.employee_master where id = p_person for update;
  if em.id is null then raise exception 'Person not found.'; end if;
  select * into ee from public.eppd_employees where employee_master_id = em.id order by id limit 1;
  select * into m from public.eppd_employments where employee_id = ee.id order by join_date desc, id desc limit 1;
  update public.employee_master set
    reporting_name = coalesce(nullif(p->>'reporting_name', ''), reporting_name), reporting_title = coalesce(nullif(p->>'reporting_title', ''), reporting_title),
    employment_type = coalesce(nullif(p->>'employment_type', ''), employment_type),
    probation_end_date = case when nullif(p->>'probation_months', '') is not null and start_date is not null
                              then ((start_date + make_interval(months => (p->>'probation_months')::int))::date - 1) else probation_end_date end
   where id = em.id;
  if m.id is not null then
    update public.eppd_employments set
      work_days_per_week = coalesce(nullif(p->>'work_days', '')::numeric, work_days_per_week),
      weekly_hours = coalesce(nullif(p->>'weekly_hours', '')::numeric, weekly_hours),
      hours_class = case when coalesce((p->>'part_time')::boolean, false) then 'PT' else hours_class end,
      hours_class_reason = case when coalesce((p->>'part_time')::boolean, false) then 'Part-time offer letter' else hours_class_reason end,
      hours_class_by = case when coalesce((p->>'part_time')::boolean, false) then auth.uid() else hours_class_by end,
      hours_class_at = case when coalesce((p->>'part_time')::boolean, false) then now() else hours_class_at end
     where id = m.id;
    select id into asg from public.eppd_assignments where employment_id = m.id and is_primary order by id limit 1;
    for x in select * from jsonb_array_elements(coalesce(p->'allowances', '[]'::jsonb)) loop
      if nullif(x->>'payment_type_id', '') is not null and coalesce(nullif(x->>'amount', '')::numeric, 0) > 0 and asg is not null then
        insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, note)
        values (asg, (x->>'payment_type_id')::bigint, (x->>'amount')::numeric, coalesce(m.join_date, em.start_date), coalesce(nullif(x->>'note', ''), 'From the offer letter'));
      end if;
    end loop;
  end if;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'offer_terms_applied', 'Terms from the offer letter applied on hire', p, auth.uid());
end $f$;
revoke all on function public.cms_hire_loec_apply(uuid, jsonb) from public, anon;
grant execute on function public.cms_hire_loec_apply(uuid, jsonb) to authenticated;
