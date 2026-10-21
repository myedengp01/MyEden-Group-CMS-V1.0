-- MyEden Group CMS V1.0 · HR Letters centre (moved in from MEG-EAF V2)
-- Letters: HR drafts → submit → Admin / Super Admin / Director approves (never the drafter) → HR, Admin, Super Admin or a
--   Director issues. The approved wording is what gets issued; issued letters stay locked (void only, with a reason).
-- Templates: Draft → Pending review → Published → on/off → Retired. HR's new or changed templates need approval
--   (letters "A"); people with "A" may approve their own. Editing a published template keeps the old wording in use until the
--   change is approved. Uploaded Word files keep their layout ({{placeholders}} filled inside the .docx); each upload gets a
--   new code under its letter type (LOC_TP2, LOC_TP3 …). Templates never replace each other; retiring one needs approval.
-- Placeholders: the shared register (hr_letter_placeholders); protected ones cannot be changed.

-- ------------------------------------------------------------------ templates: lifecycle columns
alter table public.hr_letter_templates
  add column if not exists status text not null default 'published',
  add column if not exists letter_type text,
  add column if not exists format text not null default 'text',
  add column if not exists company_code text,
  add column if not exists source_path text,
  add column if not exists file_name text,
  add column if not exists created_by uuid,
  add column if not exists created_by_name text,
  add column if not exists created_at timestamptz default now(),
  add column if not exists submitted_at timestamptz,
  add column if not exists reviewed_by uuid,
  add column if not exists reviewed_by_name text,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text,
  add column if not exists pending jsonb,
  add column if not exists retire_request jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'hr_letter_templates_status_check') then
    alter table public.hr_letter_templates add constraint hr_letter_templates_status_check check (status in ('draft','pending','published','rejected','retired'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'hr_letter_templates_format_check') then
    alter table public.hr_letter_templates add constraint hr_letter_templates_format_check check (format in ('text','docx','pdf'));
  end if;
end $$;

update public.hr_letter_templates set letter_type = coalesce(letter_type, split_part(code, '_TP', 1)) where letter_type is null;

-- new letter types beyond the original 15 are allowed (codes in capitals; alternatives end in _TP<n>)
alter table public.hr_letter_templates drop constraint if exists hr_letter_templates_code_check;
alter table public.hr_letter_templates add constraint hr_letter_templates_code_check check (code ~ '^[A-Z][A-Z0-9]{0,11}(_[A-Z0-9]{1,11})?(_TP[0-9]{1,3})?$');

-- private storage for Word templates and issued Word letters, for CMS users
create policy "CMS letter sources read" on storage.objects for select to authenticated
  using (bucket_id = 'hr-letter-sources' and public.cms_can('letters', 'V'));
create policy "CMS letter sources upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'hr-letter-sources' and public.cms_can('letters', 'C')
              and name ~ '^cms/(templates|issued)/[0-9a-f-]{36}\.docx$');

-- issued letters stay locked, but can be voided (status only, wording untouched)
create or replace function public.hr_letters_protect_issued()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'issued' or old.issued_snapshot is not null then raise exception 'Issued letters are immutable' using errcode = '42501'; end if;
    return old;
  end if;
  if old.status = 'issued' or old.issued_snapshot is not null then
    if new.status in ('issued', 'void') and new.issued_snapshot is not distinct from old.issued_snapshot and new.fields = old.fields
       and new.employee_id = old.employee_id and new.template_code = old.template_code and new.template_version is not distinct from old.template_version then
      return new;
    end if;
    raise exception 'Issued letters are immutable' using errcode = '42501';
  end if;
  return new;
end $$;

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_letter_type_title(p_type text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select title from public.hr_letter_templates where code = p_type;
$$;

create or replace function private.cms_letter_tpl_json(t public.hr_letter_templates)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('code', t.code, 'title', t.title, 'version', t.version, 'body', t.body, 'active', t.active, 'status', t.status,
    'letter_type', coalesce(t.letter_type, t.code), 'type_title', coalesce(private.cms_letter_type_title(coalesce(t.letter_type, t.code)), t.title),
    'format', t.format, 'company', t.company_code, 'source_path', t.source_path, 'file_name', t.file_name,
    'created_by', t.created_by, 'created_by_name', t.created_by_name, 'created_at', t.created_at, 'submitted_at', t.submitted_at,
    'reviewed_by_name', t.reviewed_by_name, 'reviewed_at', t.reviewed_at, 'review_note', t.review_note,
    'pending', t.pending, 'retire_request', t.retire_request, 'updated_at', t.updated_at,
    'versions', (select count(*) from public.hr_letter_template_versions v where v.code = t.code),
    'used', (select count(*) from public.hr_letter_records r where r.template_code = t.code and r.status = 'issued'));
$$;

-- ------------------------------------------------------------------ the HR Letters page
create or replace function public.cms_letters()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('letters', 'V');
  return jsonb_build_object('can_edit', public.cms_can('letters', 'C'), 'can_change', public.cms_can('letters', 'E'),
    'can_approve', public.cms_can('letters', 'A'), 'can_issue', public.cms_can('letters', 'C') or public.cms_can('letters', 'A'),
    'me', auth.uid(),
    'templates', coalesce((select jsonb_agg(private.cms_letter_tpl_json(t) order by coalesce(t.letter_type, t.code), t.code) from public.hr_letter_templates t), '[]'::jsonb),
    'placeholders', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'description', description, 'kind', kind, 'source', source, 'source_key', source_key,
        'required', required, 'editable', editable, 'protected', protected, 'active', active, 'default', default_value, 'revision', revision) order by key) from public.hr_letter_placeholders), '[]'::jsonb),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'person_id', l.employee_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
          'template', l.template_code, 'title', t.title, 'format', t.format, 'status', l.status, 'fields', l.fields,
          'text', coalesce(l.issued_snapshot->>'text', l.source_snapshot->>'text'), 'docx_path', l.issued_snapshot->>'docx_path',
          'created_at', l.created_at, 'created_by', l.created_by, 'created_by_name', l.source_snapshot->>'created_by_name',
          'submitted_at', l.source_snapshot->>'submitted_at', 'approved_at', l.approved_at, 'approved_by_name', l.source_snapshot->>'approved_by_name',
          'rejected', l.source_snapshot->'rejected', 'issued_at', l.issued_at, 'issued_by', l.issued_snapshot->>'issued_by_name',
          'void_reason', l.source_snapshot->>'void_reason', 'appraisal_id', l.source_snapshot->>'appraisal_id') order by coalesce(l.issued_at, l.updated_at, l.created_at) desc)
      from public.hr_letter_records l join public.employee_master em on em.id = l.employee_id left join public.hr_letter_templates t on t.code = l.template_code
      where private.cms_can_company('letters', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code), 'status', em.employment_status) order by em.employee_name)
      from public.employee_master em where em.employment_status in ('active','onboarding','former') and private.cms_can_company('letters', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $$;

-- counts for the bell
create or replace function public.cms_letters_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.cms_can('letters', 'V') then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'to_approve', case when public.cms_can('letters', 'A') then (select count(*) from public.hr_letter_records where status = 'pending_approval' and created_by is distinct from auth.uid()) else 0 end,
    'to_issue', case when public.cms_can('letters', 'C') or public.cms_can('letters', 'A') then (select count(*) from public.hr_letter_records where status = 'approved') else 0 end,
    'sent_back', (select count(*) from public.hr_letter_records where status = 'draft' and created_by = auth.uid() and source_snapshot ? 'rejected'),
    'templates_to_review', case when public.cms_can('letters', 'A') then (select count(*) from public.hr_letter_templates
        where status = 'pending' or pending ? 'submitted_at' or retire_request is not null) else 0 end);
end $$;

-- ------------------------------------------------------------------ templates
-- p: {code?, letter_type?, new_type?:{code,title}, title, format, body, company?, source_path?, file_name?, reason?, submit?}
create or replace function public.cms_letter_template_save(p jsonb)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hr_letter_templates; c text := nullif(p->>'code', ''); typ text := nullif(p->>'letter_type', ''); n int;
        fmt text := coalesce(nullif(p->>'format', ''), 'text'); sub boolean := coalesce((p->>'submit')::boolean, false);
        appr boolean := public.cms_can('letters', 'A'); v_body text := p->>'body'; ttl text := nullif(btrim(p->>'title'), '');
        me text := private.cms_my_name(); v text;
begin
  if fmt not in ('text', 'docx') then raise exception 'Unknown template format.'; end if;
  if nullif(btrim(coalesce(v_body, '')), '') is null then raise exception 'The template has no wording.'; end if;
  if octet_length(v_body) > 100000 then raise exception 'The template is too long.'; end if;
  if v_body ~ '\{\{[^}]*[^a-z0-9_}][^}]*\}\}' then raise exception 'Placeholders use lower-case letters, numbers and _ only, like {{employee_name}}.'; end if;
  if exists (select 1 from regexp_matches(v_body, '\{\{([a-z0-9_]+)\}\}', 'g') m where not exists (select 1 from public.hr_letter_placeholders x where x.key = m[1] and x.active)) then
    raise exception 'Unknown placeholder(s): %. Create them in Placeholders first.',
      (select string_agg(distinct m[1], ', ') from regexp_matches(v_body, '\{\{([a-z0-9_]+)\}\}', 'g') m where not exists (select 1 from public.hr_letter_placeholders x where x.key = m[1] and x.active));
  end if;
  if fmt = 'docx' and (nullif(p->>'source_path', '') is null or p->>'source_path' !~ '^cms/templates/[0-9a-f-]{36}\.docx$') then raise exception 'Upload the Word file first.'; end if;

  if c is null then
    -- a new template: an alternative under an existing letter type, or a brand-new letter type
    perform private.cms_require('letters', 'C');
    if p ? 'new_type' then
      typ := upper(btrim(p->'new_type'->>'code'));
      if typ !~ '^[A-Z][A-Z0-9]{1,11}$' then raise exception 'The letter type code is 2–12 capital letters or numbers, e.g. LOA.'; end if;
      if exists (select 1 from public.hr_letter_templates where code = typ) then raise exception 'Letter type % already exists.', typ; end if;
      c := typ; ttl := coalesce(nullif(btrim(p->'new_type'->>'title'), ''), ttl);
    else
      if typ is null or not exists (select 1 from public.hr_letter_templates where code = typ) then raise exception 'Choose the letter type.'; end if;
      select coalesce(max(substring(code from '_TP([0-9]+)$')::int), 1) + 1 into n from public.hr_letter_templates where code ~ ('^' || typ || '_TP[0-9]+$');
      c := typ || '_TP' || n;
    end if;
    if ttl is null then raise exception 'Give the template a title.'; end if;
    v := gen_random_uuid()::text;
    insert into public.hr_letter_templates (code, title, version, body, active, status, letter_type, format, company_code, source_path, file_name,
                                            created_by, created_by_name, created_at, submitted_at, reviewed_by, reviewed_by_name, reviewed_at, updated_at)
    values (c, ttl, v, v_body, false, case when sub and appr then 'published' when sub then 'pending' else 'draft' end, coalesce(typ, c), fmt,
            nullif(p->>'company', ''), nullif(p->>'source_path', ''), nullif(p->>'file_name', ''), auth.uid(), me, now(),
            case when sub then now() end, case when sub and appr then auth.uid() end, case when sub and appr then me end, case when sub and appr then now() end, now());
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason) values (c, v, ttl, v_body, auth.uid(), coalesce(nullif(btrim(p->>'reason'), ''), 'Created in the CMS'));
    perform private.cms_log('letter_template.created', 'hr_letter_templates', c, nullif(p->>'company', ''),
      ttl || ' (' || c || ')' || case when sub and appr then ' created and published' when sub then ' sent for approval' else ' saved as a draft' end,
      jsonb_build_object('format', fmt, 'file', p->>'file_name'));
    return c;
  end if;

  -- changing an existing template
  perform private.cms_require('letters', 'E');
  select * into t from public.hr_letter_templates where code = c for update;
  if t.code is null then raise exception 'Template not found.'; end if;
  if t.status = 'retired' then raise exception 'This template is retired.'; end if;
  if t.status = 'published' then
    if nullif(btrim(coalesce(p->>'reason', '')), '') is null then raise exception 'Give the reason for the change.'; end if;
    if sub and appr then
      v := gen_random_uuid()::text;
      update public.hr_letter_templates set title = coalesce(ttl, title), body = p->>'body', version = v,
             source_path = coalesce(nullif(p->>'source_path', ''), source_path), file_name = coalesce(nullif(p->>'file_name', ''), file_name),
             pending = null, reviewed_by = auth.uid(), reviewed_by_name = me, reviewed_at = now(), review_note = null, updated_at = now()
       where code = c;
      insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason) values (c, v, coalesce(ttl, t.title), v_body, auth.uid(), btrim(p->>'reason'));
      perform private.cms_log('letter_template.changed', 'hr_letter_templates', c, t.company_code, coalesce(ttl, t.title) || ' (' || c || ') changed and published: ' || btrim(p->>'reason'), '{}'::jsonb);
    else
      update public.hr_letter_templates set pending = jsonb_build_object('title', coalesce(ttl, t.title), 'body', v_body,
               'source_path', coalesce(nullif(p->>'source_path', ''), t.source_path), 'file_name', coalesce(nullif(p->>'file_name', ''), t.file_name),
               'reason', btrim(p->>'reason'), 'by', auth.uid(), 'by_name', me, 'at', now()) || case when sub then jsonb_build_object('submitted_at', now()) else '{}'::jsonb end,
             updated_at = now()
       where code = c;
      perform private.cms_log('letter_template.change_requested', 'hr_letter_templates', c, t.company_code,
        coalesce(ttl, t.title) || ' (' || c || ') change ' || case when sub then 'sent for approval' else 'saved as a draft' end || ': ' || btrim(p->>'reason'), '{}'::jsonb);
    end if;
    return c;
  end if;
  -- draft / pending / rejected: change in place
  update public.hr_letter_templates set title = coalesce(ttl, title), body = p->>'body', company_code = case when p ? 'company' then nullif(p->>'company', '') else company_code end,
         source_path = coalesce(nullif(p->>'source_path', ''), source_path), file_name = coalesce(nullif(p->>'file_name', ''), file_name),
         status = case when sub and appr then 'published' when sub then 'pending' else 'draft' end,
         submitted_at = case when sub then now() else submitted_at end,
         reviewed_by = case when sub and appr then auth.uid() else reviewed_by end, reviewed_by_name = case when sub and appr then me else reviewed_by_name end,
         reviewed_at = case when sub and appr then now() else reviewed_at end, review_note = case when sub then null else review_note end, updated_at = now()
   where code = c;
  perform private.cms_log('letter_template.saved', 'hr_letter_templates', c, t.company_code,
    coalesce(ttl, t.title) || ' (' || c || ')' || case when sub and appr then ' published' when sub then ' sent for approval' else ' saved' end, '{}'::jsonb);
  return c;
end $$;

-- approve / reject a new template, a change to a published one, or a retirement request
create or replace function public.cms_letter_template_review(p_code text, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hr_letter_templates; me text := private.cms_my_name(); v text; what text;
begin
  perform private.cms_require('letters', 'A');
  select * into t from public.hr_letter_templates where code = p_code for update;
  if t.code is null then raise exception 'Template not found.'; end if;
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give the reason for sending it back.'; end if;
  if t.retire_request is not null then
    what := 'retirement';
    if p_approve then update public.hr_letter_templates set status = 'retired', active = false, retire_request = null, reviewed_by = auth.uid(), reviewed_by_name = me, reviewed_at = now(), review_note = nullif(btrim(p_note), ''), updated_at = now() where code = t.code;
    else update public.hr_letter_templates set retire_request = null, review_note = btrim(p_note), updated_at = now() where code = t.code; end if;
  elsif t.pending ? 'submitted_at' then
    what := 'change';
    if p_approve then
      v := gen_random_uuid()::text;
      update public.hr_letter_templates set title = t.pending->>'title', body = t.pending->>'body', version = v,
             source_path = nullif(t.pending->>'source_path', ''), file_name = nullif(t.pending->>'file_name', ''),
             pending = null, reviewed_by = auth.uid(), reviewed_by_name = me, reviewed_at = now(), review_note = nullif(btrim(p_note), ''), updated_at = now()
       where code = t.code;
      insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason) values (t.code, v, t.pending->>'title', t.pending->>'body', (t.pending->>'by')::uuid, t.pending->>'reason');
    else
      update public.hr_letter_templates set pending = (pending - 'submitted_at') || jsonb_build_object('rejected', btrim(p_note), 'rejected_by', me), updated_at = now() where code = t.code;
    end if;
  elsif t.status = 'pending' then
    what := 'new template';
    update public.hr_letter_templates set status = case when p_approve then 'published' else 'rejected' end, reviewed_by = auth.uid(), reviewed_by_name = me, reviewed_at = now(),
           review_note = nullif(btrim(p_note), ''), updated_at = now() where code = t.code;
  else
    raise exception 'Nothing is waiting for approval on this template.';
  end if;
  perform private.cms_log('letter_template.' || case when p_approve then 'approved' else 'sent_back' end, 'hr_letter_templates', t.code, t.company_code,
    t.title || ' (' || t.code || ') ' || what || case when p_approve then ' approved' else ' sent back: ' || btrim(p_note) end, '{}'::jsonb);
  return case when p_approve then 'approved' else 'sent_back' end;
end $$;

-- switch a published template on / off (which ones can be used for letters)
create or replace function public.cms_letter_template_switch(p_code text, p_on boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hr_letter_templates;
begin
  perform private.cms_require('letters', 'A');
  select * into t from public.hr_letter_templates where code = p_code for update;
  if t.code is null then raise exception 'Template not found.'; end if;
  if p_on and t.status <> 'published' then raise exception 'Only a published template can be switched on.'; end if;
  update public.hr_letter_templates set active = p_on, updated_at = now() where code = t.code;
  perform private.cms_log('letter_template.' || case when p_on then 'on' else 'off' end, 'hr_letter_templates', t.code, t.company_code,
    t.title || ' (' || t.code || ') switched ' || case when p_on then 'on' else 'off' end, '{}'::jsonb);
end $$;

-- ask to retire a template (people with approval rights retire it straight away)
create or replace function public.cms_letter_template_retire(p_code text, p_reason text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hr_letter_templates; me text := private.cms_my_name();
begin
  perform private.cms_require('letters', 'E');
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for retiring it.'; end if;
  select * into t from public.hr_letter_templates where code = p_code for update;
  if t.code is null or t.status = 'retired' then raise exception 'Template not found or already retired.'; end if;
  if exists (select 1 from public.hr_letter_records where template_code = t.code and status in ('draft', 'pending_approval', 'approved')) then
    raise exception 'Letters using this template are still in progress — issue or cancel them first.';
  end if;
  if public.cms_can('letters', 'A') or t.status in ('draft', 'rejected') then
    update public.hr_letter_templates set status = 'retired', active = false, retire_request = null, review_note = btrim(p_reason), reviewed_by = auth.uid(), reviewed_by_name = me, reviewed_at = now(), updated_at = now() where code = t.code;
    perform private.cms_log('letter_template.retired', 'hr_letter_templates', t.code, t.company_code, t.title || ' (' || t.code || ') retired: ' || btrim(p_reason), '{}'::jsonb);
    return 'retired';
  end if;
  update public.hr_letter_templates set retire_request = jsonb_build_object('reason', btrim(p_reason), 'by', auth.uid(), 'by_name', me, 'at', now()), updated_at = now() where code = t.code;
  perform private.cms_log('letter_template.retire_requested', 'hr_letter_templates', t.code, t.company_code, t.title || ' (' || t.code || ') retirement requested: ' || btrim(p_reason), '{}'::jsonb);
  return 'requested';
end $$;

-- version history of one template
create or replace function public.cms_letter_template_history(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('letters', 'V');
  return coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'title', v.title, 'body', v.body, 'reason', v.reason, 'at', v.created_at,
      'by', coalesce((select em.employee_name from public.cms_user_links l join public.employee_master em on em.id = l.employee_master_id where l.user_id = v.actor_id limit 1),
                     (select u.email from auth.users u where u.id = v.actor_id)), 'current', v.version = t.version) order by v.created_at desc)
    from public.hr_letter_template_versions v join public.hr_letter_templates t on t.code = v.code where v.code = p_code), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------------ placeholders
-- p: {key, label, description?, kind, source, source_key?, required, editable, active, default?, revision? (when changing), reason}
create or replace function public.cms_letter_placeholder_save(p jsonb)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.hr_letter_placeholders; k text := lower(btrim(p->>'key')); v_kind text := coalesce(nullif(p->>'kind', ''), 'text'); src text := coalesce(nullif(p->>'source', ''), 'manual');
begin
  perform private.cms_require('letters', 'E');
  if k !~ '^[a-z][a-z0-9_]{0,79}$' then raise exception 'The placeholder name uses lower-case letters, numbers and _, starting with a letter, e.g. probation_months.'; end if;
  if nullif(btrim(coalesce(p->>'label', '')), '') is null then raise exception 'Give the placeholder a label.'; end if;
  if v_kind not in ('text','paragraph','date','money','percentage','number') then raise exception 'Unknown type.'; end if;
  if src not in ('manual','employee','calculation','default') then raise exception 'Unknown source.'; end if;
  select * into x from public.hr_letter_placeholders where key = k for update;
  if x.key is null then
    insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at, updated_by)
    values (k, btrim(p->>'label'), coalesce(nullif(btrim(p->>'description'), ''), btrim(p->>'label')), v_kind, src, coalesce(btrim(p->>'source_key'), ''), coalesce(p->>'default', ''),
            coalesce((p->>'required')::boolean, true), coalesce((p->>'editable')::boolean, true), true, false, gen_random_uuid(), now(), auth.uid());
    perform private.cms_log('letter_placeholder.created', 'hr_letter_placeholders', k, null, 'Placeholder {{' || k || '}} created: ' || btrim(p->>'label'), p);
    return k;
  end if;
  if x.protected then raise exception '{{%}} is a protected placeholder (filled from the Employee Master) and cannot be changed.', k; end if;
  if nullif(p->>'revision', '') is not null and x.revision::text <> p->>'revision' then raise exception 'Someone else changed this placeholder — reload and try again.'; end if;
  if nullif(btrim(coalesce(p->>'reason', '')), '') is null then raise exception 'Give the reason for the change.'; end if;
  if not coalesce((p->>'active')::boolean, true) and exists (select 1 from public.hr_letter_templates t where t.status in ('published','pending','draft') and strpos(t.body, '{{' || k || '}}') > 0) then
    raise exception 'Templates still use {{%}} — take it out of them before switching it off.', k;
  end if;
  update public.hr_letter_placeholders set label = btrim(p->>'label'), description = coalesce(nullif(btrim(p->>'description'), ''), btrim(p->>'label')), kind = v_kind, source = src,
         source_key = coalesce(btrim(p->>'source_key'), ''), default_value = coalesce(p->>'default', ''), required = coalesce((p->>'required')::boolean, required),
         editable = coalesce((p->>'editable')::boolean, editable), active = coalesce((p->>'active')::boolean, active), revision = gen_random_uuid(), updated_at = now(), updated_by = auth.uid()
   where key = k;
  insert into public.hr_letter_admin_audit (actor_id, action, object_key, before_value, after_value, reason)
  values (auth.uid(), 'placeholder_saved', k, to_jsonb(x), p, btrim(p->>'reason'));
  perform private.cms_log('letter_placeholder.changed', 'hr_letter_placeholders', k, null, 'Placeholder {{' || k || '}} changed: ' || btrim(p->>'reason'), p);
  return k;
end $$;

-- ------------------------------------------------------------------ letters: draft → submit → approve → issue
-- p: {id?, person_id, template, fields, text, appraisal_id?, submit?}
create or replace function public.cms_letter_save(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; t public.hr_letter_templates; l public.hr_letter_records; v uuid := nullif(p->>'id', '')::uuid;
        sub boolean := coalesce((p->>'submit')::boolean, false); ap uuid := nullif(p->>'appraisal_id', '')::uuid; snap jsonb;
begin
  if coalesce((p->>'issue')::boolean, false) then raise exception 'Letters are now approved before they are issued: save the draft and submit it.'; end if;
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('letters', 'C', private.cms_canon(em.company_code));
  select * into t from public.hr_letter_templates where code = p->>'template';
  if t.code is null then raise exception 'Choose the letter.'; end if;
  if t.status <> 'published' or not t.active then raise exception 'This template is not switched on for use.'; end if;
  if sub then
    if nullif(p->>'text', '') is null then raise exception 'Nothing to submit.'; end if;
    if (p->>'text') ~ '\{\{[a-z0-9_]+\}\}' then raise exception 'Fill in every field before submitting (some {{…}} are still empty).'; end if;
  end if;
  if v is not null then
    select * into l from public.hr_letter_records where id = v for update;
    if l.id is null or l.status <> 'draft' then raise exception 'Only a draft can be changed.'; end if;
    if l.created_by is distinct from auth.uid() and not public.cms_can('letters', 'E') then raise exception 'Only the person who drafted it can change this letter.'; end if;
    ap := coalesce(ap, nullif(l.source_snapshot->>'appraisal_id', '')::uuid);
  end if;
  snap := jsonb_build_object('source', 'cms', 'appraisal_id', ap, 'text', p->>'text', 'company', p->'company',
            'created_by_name', coalesce(l.source_snapshot->>'created_by_name', private.cms_my_name()))
          || case when sub then jsonb_build_object('submitted_at', now(), 'submitted_by_name', private.cms_my_name()) else '{}'::jsonb end;
  if v is null then
    insert into public.hr_letter_records (employee_id, company_code, template_code, template_version, status, fields, source_snapshot, created_by)
    values (em.id, private.cms_canon(em.company_code), t.code, t.version, case when sub then 'pending_approval' else 'draft' end, coalesce(p->'fields', '{}'::jsonb), snap, auth.uid())
    returning id into v;
  else
    update public.hr_letter_records set employee_id = em.id, company_code = private.cms_canon(em.company_code), template_code = t.code, template_version = t.version,
           status = case when sub then 'pending_approval' else 'draft' end, fields = coalesce(p->'fields', fields), source_snapshot = snap, updated_at = now()
     where id = v;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (v, auth.uid(), case when sub then 'submitted_for_approval' else 'draft_saved' end, jsonb_build_object('source', 'cms'));
  if sub then
    perform private.cms_log('letter.submitted', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || t.title || ' sent for approval', jsonb_build_object('letter_id', v));
  end if;
  return v;
end $$;

create or replace function public.cms_letter_decide(p_id uuid, p_approve boolean, p_reason text default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.hr_letter_records; em public.employee_master; t public.hr_letter_templates;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  perform private.cms_require('letters', 'A', private.cms_canon(em.company_code));
  if l.status <> 'pending_approval' then raise exception 'This letter is not waiting for approval.'; end if;
  if l.created_by = auth.uid() then raise exception 'You drafted this letter — someone else must approve it.'; end if;
  select * into t from public.hr_letter_templates where code = l.template_code;
  if p_approve then
    if t.version is distinct from l.template_version then raise exception 'The template changed after this letter was drafted — send it back so the drafter can refresh it.'; end if;
    update public.hr_letter_records set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now(),
           source_snapshot = source_snapshot || jsonb_build_object('approved_by_name', private.cms_my_name(), 'approved_text', source_snapshot->>'text') - 'rejected'
     where id = l.id;
  else
    if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for sending it back.'; end if;
    update public.hr_letter_records set status = 'draft', updated_at = now(),
           source_snapshot = source_snapshot || jsonb_build_object('rejected', jsonb_build_object('reason', btrim(p_reason), 'by', private.cms_my_name(), 'at', now()))
     where id = l.id;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), case when p_approve then 'approved' else 'rejected' end, jsonb_build_object('reason', p_reason, 'source', 'cms'));
  perform private.cms_log('letter.' || case when p_approve then 'approved' else 'sent_back' end, 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || t.title || case when p_approve then ' approved' else ' sent back: ' || btrim(p_reason) end, jsonb_build_object('letter_id', l.id));
  return case when p_approve then 'approved' else 'draft' end;
end $$;

-- issue an approved letter: the approved wording is stored word for word (plus the filled Word file for Word templates)
create or replace function public.cms_letter_issue(p_id uuid, p_docx_path text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.hr_letter_records; em public.employee_master; t public.hr_letter_templates; ap uuid;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  if not (public.cms_can('letters', 'C', private.cms_canon(em.company_code)) or public.cms_can('letters', 'A', private.cms_canon(em.company_code))) then
    raise exception 'Not allowed: issuing HR letters' using errcode = '42501';
  end if;
  if l.status <> 'approved' then raise exception 'Only an approved letter can be issued.'; end if;
  select * into t from public.hr_letter_templates where code = l.template_code;
  if t.format = 'docx' and (p_docx_path is null or p_docx_path !~ ('^cms/issued/' || l.id::text || '\.docx$')) then raise exception 'The filled Word letter was not saved — try again.'; end if;
  update public.hr_letter_records set status = 'issued', issued_by = auth.uid(), issued_at = now(), updated_at = now(),
         issued_snapshot = jsonb_build_object('text', coalesce(l.source_snapshot->>'approved_text', l.source_snapshot->>'text'), 'issued_by_name', private.cms_my_name(),
                                              'company', l.source_snapshot->'company', 'template_version', l.template_version, 'format', t.format, 'docx_path', p_docx_path,
                                              'approved_by_name', l.source_snapshot->>'approved_by_name')
   where id = l.id;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'issued', jsonb_build_object('source', 'cms'));
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'hr_letter_issued', t.title, jsonb_build_object('letter_id', l.id, 'template', t.code), auth.uid());
  perform private.cms_log('letter.issued', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || t.title || ' issued', jsonb_build_object('letter_id', l.id));
  ap := nullif(l.source_snapshot->>'appraisal_id', '')::uuid;
  if ap is not null and coalesce(t.letter_type, t.code) = 'PEL' then
    update public.cms_appraisals set letter_issued_at = now(), letter_ref = l.id::text, letter_by = auth.uid(), updated_at = now()
     where id = ap and person_id = em.id and recommendation = 'extend' and letter_issued_at is null;
  end if;
end $$;

create or replace function public.cms_letter_void(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.hr_letter_records; em public.employee_master;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null or l.status = 'void' then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  perform private.cms_require('letters', 'E', private.cms_canon(em.company_code));
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  if l.status = 'issued' then
    update public.hr_letter_records set status = 'void', updated_at = now() where id = l.id;
  else
    update public.hr_letter_records set status = 'void', updated_at = now(), source_snapshot = source_snapshot || jsonb_build_object('void_reason', btrim(p_reason)) where id = l.id;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'void', jsonb_build_object('reason', p_reason, 'source', 'cms'));
  perform private.cms_log('letter.void', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': letter cancelled (' || btrim(p_reason) || ')', jsonb_build_object('letter_id', l.id));
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_letters()','cms_letters_pending()','cms_letter_template_save(jsonb)','cms_letter_template_review(text, boolean, text)',
    'cms_letter_template_switch(text, boolean)','cms_letter_template_retire(text, text)','cms_letter_template_history(text)','cms_letter_placeholder_save(jsonb)',
    'cms_letter_save(jsonb)','cms_letter_decide(uuid, boolean, text)','cms_letter_issue(uuid, text)','cms_letter_void(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;

-- ------------------------------------------------------------------ MEG-EAF V2 letter pages retired: their write functions now point to the CMS
do $l$ declare r record;
begin
  for r in select p.oid, p.proname, pg_get_function_arguments(p.oid) args, pg_get_function_result(p.oid) res
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('hr_letters_admin_save_draft','hr_letters_admin_submit_draft','hr_letters_admin_decide','hr_letters_admin_issue',
             'hr_letters_admin_draft_edit','hr_letters_admin_template_save','hr_letters_placeholder_save','hr_letters_register_template','hr_letters_publish_template',
             'hr_letters_register_signed_copy') loop
    execute format('create or replace function public.%I(%s) returns %s language plpgsql security definer set search_path = public as $f$ begin raise exception %L using errcode = %L; end $f$',
                   r.proname, r.args, r.res, 'HR Letters has moved to the MyEden Group CMS (HR Letters). Please use the CMS.', '42501');
  end loop;
end $l$;
