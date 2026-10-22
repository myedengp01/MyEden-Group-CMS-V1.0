-- MyEden Group CMS V1.0 · PRI-010 · Sync check (forms and MEG-EAF V2 running side by side with the CMS)
-- The forms (SCF, OTCF, MTCF, TEC, PRFAF) and MEG-EAF V2 write to the same database the CMS reads, so nothing is copied.
-- This check looks for anything that would make a record look different, or go missing, in the CMS:
--   records the CMS cannot place (company not recognised, claimant not matched to a person in the Employee Master),
--   statuses the CMS does not know, processing / payment marks with no claim, applications hired without a person record, …
-- It runs every night (23:30 Malaysia time) and whenever a Super Admin clicks "Run check now"; each run is kept, so the page
-- can show how long each form has been clean. CLC decides when a form is stable enough to switch staff to the CMS.

create table if not exists public.cms_sync_runs (
  id bigint generated always as identity primary key,
  run_at timestamptz not null default now(),
  run_by uuid,
  run_by_name text,
  results jsonb not null,
  issues int not null default 0);
alter table public.cms_sync_runs enable row level security;
create index if not exists cms_sync_runs_at on public.cms_sync_runs (run_at desc);

create or replace function private.cms_sync_compute()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare
  src record; v_rows jsonb; out jsonb := '[]'::jsonb; issues jsonb; v_total int; v_30 int; v_st jsonb; n int; smp jsonb;
  v_known text[] := array['submitted', 'pending', 'approved', 'disapproved', 'rejected', 'paid', 'disbursed', 'completed', 'done', 'processing', 'cancelled', 'returned'];
begin
  for src in select * from (values
      ('scf', 'scf_submissions', 'Staff Claim (SCF)'), ('otcf', 'otcf_submissions', 'Overtime (OTCF)'), ('mtcf', 'mtcf_submissions', 'Mileage (MTCF)'),
      ('tec', 'tec_submissions', 'Teacher Tuition (TEC V1)'), ('tec-v2', 'tec_v2_submissions', 'Teacher Tuition (TEC)'),
      ('prfaf', 'prfaf_submissions', 'Purchase & Funding (PRFAF)')) s(code, tbl, label)
  loop
    if to_regclass('public.' || src.tbl) is null then continue; end if;
    issues := '[]'::jsonb;
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('id', j->>'id', 'serial', coalesce(j->>'serial_no', (select string_agg(distinct e->>'serial_no', ', ') from jsonb_array_elements(coalesce(j->'pages', '[]'::jsonb)) e), j->>'id'),
             'status', lower(coalesce(j->>'status', '')), 'company', nullif(btrim(j->>'company_code'), ''),
             'claimant', coalesce(nullif(j->>'claimed_by', ''), nullif(j->>'claimant_name', ''), nullif(j->>'emp_name', ''), nullif(j->>'teacher_name', ''), nullif(j->>'submitted_by_name', '')),
             'at', coalesce(public.meg_forms_try_timestamptz(j->>'submitted_at'), public.meg_forms_try_timestamptz(j->>'created_at')))), '[]'::jsonb)
        from (select to_jsonb(t) j from public.%I t) x
       where nullif(j->>'deleted_at', '') is null and lower(coalesce(j->>'status', '')) <> 'draft'$q$, src.tbl) into v_rows;
    select count(*), count(*) filter (where at >= now() - interval '30 days') into v_total, v_30 from jsonb_to_recordset(v_rows) r0(id text, serial text, status text, company text, claimant text, at timestamptz);
    select coalesce(jsonb_object_agg(coalesce(nullif(status, ''), '(blank)'), c), '{}'::jsonb) into v_st from (select status, count(*) c from jsonb_to_recordset(v_rows) r0(id text, serial text, status text, company text, claimant text, at timestamptz) group by 1) z;

    -- company the CMS does not recognise: hidden from people whose role covers only some companies
    select count(*), coalesce(jsonb_agg(serial || ' · ' || coalesce(company, 'no company')) filter (where rn <= 5), '[]') into n, smp
      from (select *, row_number() over (order by at desc) rn from jsonb_to_recordset(v_rows) r(id text, serial text, status text, company text, claimant text, at timestamptz)
             where r.company is null or not exists (select 1 from public.cms_companies c where c.code = private.cms_canon(r.company))) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'company', 'label', 'Company not recognised (hidden from company-limited roles)', 'count', n, 'sample', smp); end if;

    -- claimant not matched to a person in the Employee Master: not linked to the person's records in the CMS
    select count(*), coalesce(jsonb_agg(serial || ' · ' || coalesce(claimant, 'no name')) filter (where rn <= 5), '[]') into n, smp
      from (select *, row_number() over (order by at desc) rn from jsonb_to_recordset(v_rows) r(id text, serial text, status text, company text, claimant text, at timestamptz)
             where not exists (select 1 from private.cms_claim_person(coalesce(r.claimant, '')) p where p.id is not null)) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'person', 'label', 'Claimant not matched to a person', 'count', n, 'sample', smp); end if;

    -- a status the CMS does not know
    select count(*), coalesce(jsonb_agg(serial || ' · ' || coalesce(nullif(status, ''), 'blank')) filter (where rn <= 5), '[]') into n, smp
      from (select *, row_number() over (order by at desc) rn from jsonb_to_recordset(v_rows) r(id text, serial text, status text, company text, claimant text, at timestamptz) where not (r.status = any (v_known))) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'status', 'label', 'Status the CMS does not know', 'count', n, 'sample', smp); end if;

    -- processing / payment marks that point at no claim
    select count(*) into n from (select submission_id from public.meg_forms_processing where form_code = src.code
                                 union select submission_id from public.meg_forms_finance_status where form_code = src.code) m
     where not exists (select 1 from jsonb_to_recordset(v_rows) r(id text, serial text, status text, company text, claimant text, at timestamptz) where r.id = m.submission_id);
    if n > 0 then issues := issues || jsonb_build_object('code', 'orphan', 'label', 'Processing or payment marks with no claim (deleted or draft claim)', 'count', n, 'sample', '[]'::jsonb); end if;

    -- paid in the finance table but the form still shows it waiting
    select count(*) into n from public.meg_forms_finance_status f join jsonb_to_recordset(v_rows) r(id text, serial text, status text, company text, claimant text, at timestamptz) on r.id = f.submission_id
     where f.form_code = src.code and f.payment_done and r.status in ('submitted', 'pending')
       and coalesce((select c.requires_approval from public.meg_forms_workflow_config c where c.form_code = src.code), true);
    if n > 0 then issues := issues || jsonb_build_object('code', 'paid_unapproved', 'label', 'Marked paid but still waiting for approval in the form', 'count', n, 'sample', '[]'::jsonb); end if;

    out := out || jsonb_build_object('code', src.code, 'label', src.label, 'kind', 'form', 'total', v_total, 'last30', v_30, 'in_cms', v_total,
      'statuses', v_st, 'issues', issues, 'clean', jsonb_array_length(issues) = 0);
  end loop;

  -- MEG-EAF V2 applications
  if to_regclass('public.eaf_applications') is not null then
    issues := '[]'::jsonb;
    select count(*), count(*) filter (where submitted_at >= now() - interval '30 days') into v_total, v_30 from public.eaf_applications;
    select coalesce(jsonb_object_agg(s, c), '{}'::jsonb) into v_st from (select coalesce(workflow_stage, 'submitted') s, count(*) c from public.eaf_applications group by 1) z;
    select count(*), coalesce(jsonb_agg(applicant_name || ' · ' || coalesce(company_code, payload->>'companyCode', 'no company')) filter (where rn <= 5), '[]') into n, smp
      from (select a.*, row_number() over (order by submitted_at desc) rn from public.eaf_applications a
             where not exists (select 1 from public.cms_companies c where c.code = private.cms_canon(coalesce(a.company_code, a.payload->>'companyCode', 'meg')))) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'company', 'label', 'Company not recognised', 'count', n, 'sample', smp); end if;
    select count(*), coalesce(jsonb_agg(applicant_name) filter (where rn <= 5), '[]') into n, smp
      from (select a.*, row_number() over (order by submitted_at desc) rn from public.eaf_applications a
             where a.workflow_stage = 'completed' and not exists (select 1 from public.employee_master em where em.source_application_id = a.id)) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'hired', 'label', 'Completed in MEG-EAF but no person in the Employee Master', 'count', n, 'sample', smp); end if;
    select count(*), coalesce(jsonb_agg(employee_name) filter (where rn <= 5), '[]') into n, smp
      from (select em.*, row_number() over (order by em.start_date desc nulls last) rn from public.employee_master em
             where em.source_application_id is not null and not exists (select 1 from public.eaf_applications a where a.id = em.source_application_id)) z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'lost_app', 'label', 'Person linked to an application that no longer exists', 'count', n, 'sample', smp); end if;
    select count(*), coalesce(jsonb_agg(applicant_name) filter (where rn <= 5), '[]') into n, smp
      from (select a.*, row_number() over (order by updated_at) rn from public.eaf_applications a
             where a.workflow_stage = 'ready_for_onboarding' and a.updated_at < now() - interval '14 days') z;
    if n > 0 then issues := issues || jsonb_build_object('code', 'stuck', 'label', 'Ready for onboarding for more than 14 days', 'count', n, 'sample', smp); end if;
    out := out || jsonb_build_object('code', 'eaf', 'label', 'MEG-EAF V2 applications', 'kind', 'eaf', 'total', v_total, 'last30', v_30, 'in_cms', v_total,
      'statuses', v_st, 'issues', issues, 'clean', jsonb_array_length(issues) = 0);
  end if;
  return out;
end $f$;

-- record a run (used by the nightly job and by "Run check now")
create or replace function private.cms_sync_record(p_by uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare r jsonb := private.cms_sync_compute();
begin
  insert into public.cms_sync_runs (run_by, run_by_name, results, issues)
  values (p_by, p_name, r, (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(r) s, jsonb_array_elements(s->'issues') x));
  return r;
end $f$;

-- the page: latest run, how long each source has been clean, the last 60 runs; p_run = true runs a new check first
create or replace function public.cms_sync_check(p_run boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_last public.cms_sync_runs;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can open the sync check.' using errcode = '42501'; end if;
  if p_run then
    perform private.cms_sync_record(auth.uid(), (select coalesce(em.employee_name, u.email) from auth.users u left join public.cms_user_links l on l.user_id = u.id
      left join public.employee_master em on em.id = l.employee_master_id where u.id = auth.uid()));
    perform private.cms_log('sync.check', 'sync', null, null, 'Ran the sync check', '{}'::jsonb);
  end if;
  select * into v_last from public.cms_sync_runs order by run_at desc limit 1;
  return jsonb_build_object(
    'last', case when v_last.id is null then null else jsonb_build_object('run_at', v_last.run_at, 'by', coalesce(v_last.run_by_name, 'Nightly check'), 'results', v_last.results, 'issues', v_last.issues) end,
    'clean_since', (select coalesce(jsonb_object_agg(code, since), '{}'::jsonb) from (
        select s->>'code' code,
               (select min(r2.run_at) from public.cms_sync_runs r2 where r2.run_at > coalesce((select max(r3.run_at) from public.cms_sync_runs r3, jsonb_array_elements(r3.results) s3
                   where s3->>'code' = s->>'code' and not (s3->>'clean')::boolean), '-infinity'::timestamptz)) since
          from jsonb_array_elements(coalesce(v_last.results, '[]'::jsonb)) s) z where since is not null),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('run_at', run_at, 'by', coalesce(run_by_name, 'Nightly check'), 'issues', issues,
        'by_source', (select jsonb_object_agg(s->>'code', jsonb_build_object('clean', (s->>'clean')::boolean, 'n', (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(s->'issues') x))) from jsonb_array_elements(results) s))
        order by run_at desc), '[]'::jsonb) from (select * from public.cms_sync_runs order by run_at desc limit 60) h));
end $f$;
revoke all on function public.cms_sync_check(boolean) from public, anon;
grant execute on function public.cms_sync_check(boolean) to authenticated;

-- nightly at 23:30 Malaysia time (15:30 UTC)
do $c$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and not exists (select 1 from cron.job where jobname = 'cms-sync-check-nightly') then
    perform cron.schedule('cms-sync-check-nightly', '30 15 * * *', $j$select private.cms_sync_record(null, 'Nightly check')$j$);
  end if;
end $c$;

-- first run now, so the page has something to show
select private.cms_sync_record(null, 'First check (at install)');
