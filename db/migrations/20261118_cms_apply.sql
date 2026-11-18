-- PRI-024 phases 2–3 (v2026.11.18): the application form (Apply Now) and the HR Staff parts of MEG-EAF V2 inside the CMS.
-- Additive. Same tables as MEG-EAF V2 (eaf_applications, eaf_drafts, eaf_v2_gateway_invitations), so nothing is copied and both run
-- side by side until each old page is switched over. Apply Now keeps its mode (invitation only): an applicant needs a valid apply link;
-- CMS staff with Recruitment (edit) can always open it. Drafts are never removed: a draft that became an application is marked
-- submitted (and no longer offered to resume).

-- ------------------------------------------------------------------ the gate (anon + signed in)
create or replace function private.cms_apply_staff() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and public.cms_can('recruitment', 'E');
$$;
create or replace function public.cms_apply_gate(p_token text default null) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_mode text; v_inv public.eaf_v2_gateway_invitations; v_tok uuid;
begin
  select mode into v_mode from public.eaf_v2_gateway_apps where app_code = 'apply';
  if private.cms_apply_staff() then return jsonb_build_object('ok', true, 'staff', true, 'mode', v_mode, 'name', private.cms_my_name()); end if;
  begin v_tok := nullif(btrim(p_token), '')::uuid; exception when others then v_tok := null; end;
  if v_mode = 'invitation_only' and v_tok is not null then
    select * into v_inv from public.eaf_v2_gateway_invitations where token = v_tok and revoked_at is null and expires_at > now() and use_count < max_uses;
    if v_inv.id is not null then return jsonb_build_object('ok', true, 'staff', false, 'mode', v_mode, 'company', lower(v_inv.company_code), 'expires_at', v_inv.expires_at); end if;
    return jsonb_build_object('ok', false, 'mode', v_mode, 'reason', 'link');
  end if;
  return jsonb_build_object('ok', false, 'mode', v_mode, 'reason', case when v_mode = 'invitation_only' then 'no_link' else 'closed' end);
end $$;

-- a submitted draft is no longer offered to resume (drafts are kept, never removed)
do $$ declare d text;
begin
  d := pg_get_functiondef('public.get_draft(text)'::regprocedure);
  if strpos(d, '_cms_submitted') = 0 then
    d := replace(d, 'select payload into result from eaf_drafts where draft_code = code;', 'select payload into result from eaf_drafts where draft_code = code and not (payload ? ''_cms_submitted'');');
    if strpos(d, '_cms_submitted') = 0 then raise exception 'get_draft: marker not found'; end if;
    execute d;
  end if;
end $$;
create or replace function private.cms_apply_mark_draft(p_code text, p_app uuid) returns void language sql security definer set search_path = public, pg_temp as $$
  update public.eaf_drafts set payload = payload || jsonb_build_object('_cms_submitted', now(), '_cms_application', p_app), updated_at = now()
   where draft_code = nullif(btrim(p_code), '') and not (payload ? '_cms_submitted');
$$;

-- ------------------------------------------------------------------ submitting (applicant with a link, or CMS staff)
create or replace function public.cms_apply_submit(p_payload jsonb, p_token text default null, p_draft_code text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare g jsonb := public.cms_apply_gate(p_token); v_id uuid; v_p jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if not coalesce((g->>'ok')::boolean, false) then raise exception 'This application form opens from the link HR sends you. Please contact MyEden Group HR.' using errcode = '42501'; end if;
  if jsonb_typeof(v_p) <> 'object' or nullif(btrim(v_p->>'nameEnglish'), '') is null then raise exception 'Fill in your name.'; end if;
  if octet_length(v_p::text) > 15000000 then raise exception 'The application is too large (photos too big). Please use smaller photos.'; end if;
  v_p := v_p - '_cms_submitted' - '_cms_application';
  if g->>'company' in ('meg', 'meh', 'hds', 'abn') then v_p := jsonb_set(v_p, '{companyCode}', to_jsonb(g->>'company'), true); end if;
  insert into public.eaf_applications (payload, status, workflow_stage) values (v_p || jsonb_build_object('_cms_source', case when (g->>'staff')::boolean then 'cms_staff' else 'cms_apply' end), 'pending', 'submitted')
  returning id into v_id;
  if not coalesce((g->>'staff')::boolean, false) then perform public.eaf_v2_gateway_consume_invitation(nullif(btrim(p_token), '')::uuid); end if;
  perform private.cms_apply_mark_draft(p_draft_code, v_id);
  return v_id;
end $$;

-- ------------------------------------------------------------------ HR: the full application, drafts, summary, apply links
create or replace function public.cms_apply_application(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.eaf_applications; co text;
begin
  select * into a from public.eaf_applications where id = p_id; if a.id is null then raise exception 'Application not found.'; end if;
  co := private.cms_canon(upper(coalesce(a.company_code, a.payload->>'companyCode', 'meg')));
  if not public.cms_can('recruitment', 'V', co) then raise exception 'You do not have access to this.' using errcode = '42501'; end if;
  perform private.cms_log('application.viewed', 'eaf_applications', a.id::text, co, upper(coalesce(a.applicant_name, '')) || ': full application opened', '{}'::jsonb);
  return jsonb_build_object('id', a.id, 'payload', a.payload, 'name', upper(coalesce(nullif(btrim(a.payload->>'nameEnglish'), ''), a.applicant_name)), 'company', co,
    'stage', coalesce(a.workflow_stage, 'submitted'), 'submitted_at', a.submitted_at);
end $$;

create or replace function public.cms_apply_drafts() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('recruitment', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.draft_code, 'name', upper(nullif(btrim(d.applicant_name), '')), 'contact', d.contact, 'email', d.email,
      'company', private.cms_canon(upper(coalesce(d.payload->>'companyCode', 'meg'))), 'post', d.payload->'cb_post', 'created_at', d.created_at, 'updated_at', d.updated_at, 'expires_at', d.expires_at,
      'expired', d.expires_at < now(), 'source', d.payload->>'_cms_source') order by d.updated_at desc)
    from public.eaf_drafts d where not (d.payload ? '_cms_submitted')), '[]'::jsonb);
end $$;

create or replace function public.cms_apply_draft(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d public.eaf_drafts;
begin
  perform private.cms_require('recruitment', 'V');
  select * into d from public.eaf_drafts where id = p_id; if d.id is null then raise exception 'Draft not found.'; end if;
  return jsonb_build_object('id', d.id, 'code', d.draft_code, 'payload', d.payload, 'submitted', d.payload ? '_cms_submitted', 'updated_at', d.updated_at, 'expires_at', d.expires_at);
end $$;

-- save a draft (p_id null = a new one, e.g. imported from a JSON backup); returns the draft id
create or replace function public.cms_apply_draft_save(p_id uuid, p_data jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.eaf_drafts; v_code text; v_p jsonb := coalesce(p_data, '{}'::jsonb) - '_cms_submitted' - '_cms_application';
begin
  perform private.cms_require('recruitment', 'E');
  if jsonb_typeof(v_p) <> 'object' then raise exception 'This is not an application form backup.'; end if;
  if p_id is not null then
    select * into d from public.eaf_drafts where id = p_id; if d.id is null then raise exception 'Draft not found.'; end if;
    if d.payload ? '_cms_submitted' then raise exception 'This draft was already submitted as an application.'; end if;
    v_code := d.draft_code;
  end if;
  v_code := public.save_draft(coalesce(v_code, ''), v_p || jsonb_build_object('_cms_source', coalesce(v_p->>'_cms_source', 'cms_staff')));
  select * into d from public.eaf_drafts where draft_code = v_code;
  perform private.cms_log(case when p_id is null then 'application_draft.imported' else 'application_draft.saved' end, 'eaf_drafts', d.id::text, null,
    coalesce(nullif(upper(btrim(d.applicant_name)), ''), 'Draft') || case when p_id is null then ': draft added in the CMS' else ': draft saved in the CMS' end, '{}'::jsonb);
  return d.id;
end $$;

create or replace function public.cms_apply_draft_submit(p_id uuid, p_data jsonb) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.eaf_drafts; v_app uuid;
begin
  perform private.cms_require('recruitment', 'E');
  select * into d from public.eaf_drafts where id = p_id for update; if d.id is null then raise exception 'Draft not found.'; end if;
  if d.payload ? '_cms_submitted' then raise exception 'This draft was already submitted as an application.'; end if;
  v_app := public.cms_apply_submit(coalesce(p_data, d.payload), null, d.draft_code);
  perform private.cms_log('application_draft.submitted', 'eaf_applications', v_app::text, null, coalesce(nullif(upper(btrim(p_data->>'nameEnglish')), ''), 'Draft') || ': draft submitted as an application in the CMS', jsonb_build_object('draft', d.id));
  return v_app;
end $$;

create or replace function public.cms_apply_summary() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare pay boolean := public.cms_can('recruitment', 'E');
begin
  perform private.cms_require('recruitment', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', upper(coalesce(nullif(btrim(p->>'nameEnglish'), ''), a.applicant_name)), 'name_zh', p->>'nameChinese',
      'ic', coalesce(nullif(concat_ws('-', nullif(p->>'ic1', ''), nullif(p->>'ic2', ''), nullif(p->>'ic3', '')), ''), p->>'passport'), 'dob', p->>'dob',
      'email', p->>'email', 'contact', p->>'contact', 'gender', p->>'radio_gender', 'race', p->>'radio_race',
      'address', nullif(concat_ws(', ', nullif(p->>'addr1', ''), nullif(p->>'addr2', ''), nullif(p->>'addr3', ''), nullif(p->>'postcodeTown', ''), nullif(p->>'addrState', '')), ''),
      'start', coalesce(nullif(p->>'finalStart', ''), nullif(p->>'startDate', '')), 'salary', case when pay then nullif(p->>'finalSalary', '') end,
      'title', coalesce(nullif(p->>'v2ResolvedJobTitle', ''), nullif(p->>'approvedJobTitle', '')), 'post', p->'cb_post',
      'hours', nullif(concat_ws(' – ', nullif(p->>'finalFrom', ''), nullif(p->>'finalTo', '')), ''), 'department', p->>'finalDept', 'decision', p->>'decision',
      'stage', coalesce(a.workflow_stage, 'submitted'), 'company', private.cms_canon(upper(coalesce(a.company_code, p->>'companyCode', 'meg'))), 'submitted_at', a.submitted_at)
      order by a.submitted_at desc nulls last)
    from public.eaf_applications a cross join lateral (select coalesce(a.payload, '{}'::jsonb) p) x
    where public.cms_can('recruitment', 'V', private.cms_canon(upper(coalesce(a.company_code, x.p->>'companyCode', 'meg'))))), '[]'::jsonb);
end $$;

create or replace function public.cms_apply_links() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('recruitment', 'V');
  return jsonb_build_object('mode', (select mode from public.eaf_v2_gateway_apps where app_code = 'apply'), 'can_edit', public.cms_can('recruitment', 'E'),
    'links', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'token', i.token, 'company', lower(i.company_code), 'expires_at', i.expires_at, 'max_uses', i.max_uses,
       'use_count', i.use_count, 'created_at', i.created_at, 'by', private.cms_user_name(i.created_by), 'revoked_at', i.revoked_at,
       'status', case when i.revoked_at is not null then 'revoked' when i.expires_at <= now() then 'expired' when i.use_count >= i.max_uses then 'used' else 'active' end) order by i.created_at desc)
      from public.eaf_v2_gateway_invitations i), '[]'::jsonb));
end $$;
create or replace function public.cms_apply_link_create(p_company text, p_expires timestamptz, p_max int) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.eaf_v2_gateway_invitations; c text := lower(btrim(p_company));
begin
  perform private.cms_require('recruitment', 'E');
  if c not in ('meg', 'meh', 'hds', 'abn') then raise exception 'Choose the company.'; end if;
  if p_expires is null or p_expires <= now() then raise exception 'The link must be valid until a later date.'; end if;
  if coalesce(p_max, 0) < 1 or p_max > 1000 then raise exception 'Uses: 1 to 1000.'; end if;
  insert into public.eaf_v2_gateway_invitations (token, app_code, company_code, expires_at, max_uses, use_count, created_by)
  values (gen_random_uuid(), 'apply', c, p_expires, p_max, 0, auth.uid()) returning * into r;
  perform private.cms_log('apply_link.created', 'eaf_v2_gateway_invitations', r.id::text, private.cms_canon(upper(c)), 'Apply link for ' || upper(c) || ', ' || p_max || ' use(s), until ' || to_char(p_expires at time zone 'Asia/Kuala_Lumpur', 'DD Mon YYYY HH24:MI'), '{}'::jsonb);
  return jsonb_build_object('id', r.id, 'token', r.token);
end $$;
create or replace function public.cms_apply_link_revoke(p_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('recruitment', 'E');
  update public.eaf_v2_gateway_invitations set revoked_at = now(), revoked_by = auth.uid() where id = p_id and revoked_at is null;
  perform private.cms_log('apply_link.revoked', 'eaf_v2_gateway_invitations', p_id::text, null, 'Apply link revoked', '{}'::jsonb);
end $$;

revoke all on function public.cms_apply_gate(text), public.cms_apply_submit(jsonb, text, text) from public;
grant execute on function public.cms_apply_gate(text), public.cms_apply_submit(jsonb, text, text) to anon, authenticated;
revoke all on function public.cms_apply_application(uuid), public.cms_apply_drafts(), public.cms_apply_draft(uuid), public.cms_apply_draft_save(uuid, jsonb),
  public.cms_apply_draft_submit(uuid, jsonb), public.cms_apply_summary(), public.cms_apply_links(), public.cms_apply_link_create(text, timestamptz, int), public.cms_apply_link_revoke(uuid) from public, anon;
grant execute on function public.cms_apply_application(uuid), public.cms_apply_drafts(), public.cms_apply_draft(uuid), public.cms_apply_draft_save(uuid, jsonb),
  public.cms_apply_draft_submit(uuid, jsonb), public.cms_apply_summary(), public.cms_apply_links(), public.cms_apply_link_create(text, timestamptz, int), public.cms_apply_link_revoke(uuid) to authenticated;
