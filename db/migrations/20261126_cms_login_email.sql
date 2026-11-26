-- MyEden Group CMS V1.0 · PRI-029 Change login email (CLC 26 Nov 2026)
-- A person's (or tutor's) CMS sign-in email can be changed from their profile.
--   * permission `users.email` (Change login email): Super Admin / Admin by default; Admin may give it to HR or anyone.
--   * login never used  -> changed at once; a set-password email goes to the new address (that is the confirmation).
--   * login in use      -> nothing changes until the person opens the one-time link sent to the new address (48 h);
--                          then the old address gets a notice.
--   * new address already has a confirmed login of its own -> "use this existing login": the link and roles move to it,
--                          the old login is blocked (never deleted).
--   * the Employee Master / payroll / personal-profile email (or the tutor's email) still showing the old address follows.
-- The auth change itself is done by the `cms-login-email` Edge Function with the service key; every check runs here first.

insert into public.cms_modules (code, label, grp, phase, sort_order, locked, description, acts, kind, parent, act_labels)
select 'users.email', 'Change login email', 'People & Employment', 0, 1006, false,
  'Change the email a person or tutor signs in with (confirmed from the new address when the login is in use)', 'V', 'special', 'people', '{}'::jsonb
where not exists (select 1 from public.cms_modules where code = 'users.email');
insert into public.cms_role_permissions (role_code, module_code, actions)
select r, 'users.email', 'V' from (values ('super_admin'), ('admin')) v(r)
where not exists (select 1 from public.cms_role_permissions where module_code = 'users.email' and role_code = v.r);

create table if not exists public.cms_login_email_changes (
  id uuid primary key default gen_random_uuid(),
  person_id uuid references public.employee_master(id),
  tutor_id uuid,
  user_id uuid not null,                 -- the login being changed (or, for 'existing', the login being retired)
  target_user_id uuid,                   -- 'existing': the login that takes over
  old_email text not null,
  new_email text not null,
  mode text not null check (mode in ('direct', 'confirm', 'existing')),
  status text not null default 'pending' check (status in ('pending', 'done', 'cancelled', 'failed')),
  token_hash text,
  expires_at timestamptz,
  reason text,
  source text not null default 'profile' check (source in ('profile', 'request', 'tutor')),
  requested_by uuid, requested_by_name text, requested_at timestamptz not null default now(),
  sent_count int not null default 0, last_sent_at timestamptz,
  done_at timestamptz, cancelled_by uuid, cancelled_at timestamptz, cancel_reason text, error text
);
alter table public.cms_login_email_changes enable row level security;
revoke all on public.cms_login_email_changes from anon, authenticated;
create unique index if not exists cms_login_email_one_pending on public.cms_login_email_changes (user_id) where status = 'pending';

-- the login of a person or a tutor, with what matters for the change
create or replace function private.cms_login_target(p_person uuid, p_tutor uuid) returns jsonb
language sql stable security definer set search_path = public, auth, pg_temp as $$
  select case when p_person is not null then
    (select jsonb_build_object('kind', 'person', 'id', em.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'status', em.employment_status,
        'company', private.cms_canon(em.company_code), 'record_email', em.email,
        'user_id', u.id, 'login_email', u.email, 'created', u.created_at, 'last_sign_in', u.last_sign_in_at, 'used', u.last_sign_in_at is not null,
        'roles', (select coalesce(jsonb_agg(r.role_code order by r.role_code), '[]'::jsonb) from public.cms_user_roles r where r.user_id = u.id and r.is_active))
       from public.employee_master em left join public.cms_user_links l on l.employee_master_id = em.id left join auth.users u on u.id = l.user_id
      where em.id = p_person)
  else
    (select jsonb_build_object('kind', 'tutor', 'id', t.id, 'name', t.name, 'status', case when t.is_active then 'active' else 'former' end,
        'company', private.cms_canon(t.company_code), 'record_email', t.email,
        'user_id', u.id, 'login_email', u.email, 'created', u.created_at, 'last_sign_in', u.last_sign_in_at, 'used', u.last_sign_in_at is not null,
        'roles', (select coalesce(jsonb_agg(r.role_code order by r.role_code), '[]'::jsonb) from public.cms_user_roles r where r.user_id = u.id and r.is_active))
       from public.cms_tutors t left join public.cms_tutor_links l on l.tutor_id = t.id left join auth.users u on u.id = l.user_id
      where t.id = p_tutor)
  end
$$;

-- what the window shows: the login, a pending change, and whether the caller may change it
create or replace function public.cms_login_email_info(p_person uuid default null, p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare t jsonb; c public.cms_login_email_changes;
begin
  if not public.cms_can('users.email', 'V') then return jsonb_build_object('can', false); end if;
  t := private.cms_login_target(p_person, p_tutor);
  if t is null then raise exception 'Not found.'; end if;
  select * into c from public.cms_login_email_changes where user_id = (t->>'user_id')::uuid and status = 'pending' order by requested_at desc limit 1;
  return jsonb_build_object('can', true, 'target', t,
    'pending', case when c.id is not null then jsonb_build_object('id', c.id, 'new_email', c.new_email, 'mode', c.mode, 'requested_at', c.requested_at,
      'by', c.requested_by_name, 'expires_at', c.expires_at, 'expired', c.expires_at < now(), 'sent_count', c.sent_count) end,
    'history', (select coalesce(jsonb_agg(jsonb_build_object('at', coalesce(x.done_at, x.cancelled_at, x.requested_at), 'old', x.old_email, 'new', x.new_email,
        'status', x.status, 'mode', x.mode, 'by', x.requested_by_name) order by x.requested_at desc), '[]'::jsonb)
      from (select * from public.cms_login_email_changes where coalesce(person_id::text, tutor_id::text) = coalesce(p_person::text, p_tutor::text) order by requested_at desc limit 10) x));
end $$;

-- checks a new address; returns the mode it would take
create or replace function private.cms_login_email_mode(t jsonb, p_new text) returns jsonb
language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare v text := lower(btrim(coalesce(p_new, ''))); u auth.users; other text;
begin
  if t is null then raise exception 'Not found.'; end if;
  if t->>'user_id' is null then raise exception '% has no CMS login yet: use Invite to the CMS instead.', t->>'name'; end if;
  if t->>'status' = 'former' then raise exception '% has left; the login email of former staff is not changed.', t->>'name'; end if;
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Type a valid email address.'; end if;
  if v = lower(t->>'login_email') then raise exception 'That is already their login email.'; end if;
  if (t->>'user_id')::uuid = auth.uid() then raise exception 'You cannot change your own login email here: ask another Admin.'; end if;
  if (t->'roles') ?| array['super_admin', 'admin'] and not public.cms_is_super_admin() then
    raise exception 'Only a Super Admin can change the login email of an Admin or Super Admin.'; end if;
  select em.employee_name into other from public.employee_master em where lower(btrim(em.email)) = v and (t->>'kind' <> 'person' or em.id <> (t->>'id')::uuid) limit 1;
  if other is not null then raise exception '% is the email of another person (%).', v, other; end if;
  select * into u from auth.users where lower(email) = v limit 1;
  if u.id is null then
    return jsonb_build_object('mode', case when (t->>'used')::boolean then 'confirm' else 'direct' end);
  end if;
  if exists (select 1 from public.cms_user_links where user_id = u.id) or exists (select 1 from public.cms_tutor_links where user_id = u.id) then
    raise exception 'The login % already belongs to another person in the CMS.', v; end if;
  if u.email_confirmed_at is null then raise exception 'A login with % exists but was never confirmed, so it cannot be used. Ask an Admin to look at it.', v; end if;
  if exists (select 1 from public.cms_user_roles r where r.user_id = u.id and r.is_active and r.role_code in ('super_admin', 'admin')) then
    raise exception 'The login % has an Admin role; it cannot be taken over here.', v; end if;
  return jsonb_build_object('mode', 'existing', 'existing', jsonb_build_object('user_id', u.id, 'created', u.created_at, 'last_sign_in', u.last_sign_in_at,
    'name', u.raw_user_meta_data->>'full_name'));
end $$;

create or replace function public.cms_login_email_check(p_new text, p_person uuid default null, p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if not public.cms_can('users.email', 'V') then raise exception 'Changing login emails needs the permission Change login email.'; end if;
  return private.cms_login_email_mode(private.cms_login_target(p_person, p_tutor), p_new);
end $$;

-- the records' email that still shows the old address (or nothing) follows the login
create or replace function private.cms_login_email_records(c public.cms_login_email_changes) returns text[]
language plpgsql security definer set search_path = public, pg_temp as $$
declare done text[] := '{}'; n int;
begin
  if c.person_id is not null then
    update public.employee_master set email = c.new_email, updated_at = now() where id = c.person_id and (email is null or lower(email) = lower(c.old_email));
    get diagnostics n = row_count; if n > 0 then done := done || 'Employee Master'::text; end if;
    update public.eppd_employees set email = c.new_email where employee_master_id = c.person_id and (email is null or lower(email) = lower(c.old_email));
    get diagnostics n = row_count; if n > 0 then done := done || 'payroll'::text; end if;
    update public.cms_person_profile set data = data || jsonb_build_object('email', c.new_email), updated_at = now()
     where person_id = c.person_id and lower(coalesce(data->>'email', '')) = lower(c.old_email);
    get diagnostics n = row_count; if n > 0 then done := done || 'personal profile'::text; end if;
    update public.cms_invites set email = c.new_email, user_id = coalesce(c.target_user_id, c.user_id), last_at = now() where person_id = c.person_id;
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (c.person_id, 'login_email_changed', 'CMS login email changed from ' || c.old_email || ' to ' || c.new_email ||
            case c.mode when 'confirm' then ' (confirmed from the new address)' when 'existing' then ' (moved to the login they already had)' else '' end ||
            coalesce(': ' || c.reason, ''), jsonb_build_object('change_id', c.id, 'mode', c.mode), c.requested_by);
  else
    update public.cms_tutors set email = c.new_email, updated_at = now() where id = c.tutor_id and (email is null or lower(email) = lower(c.old_email));
    get diagnostics n = row_count; if n > 0 then done := done || 'tutor record'::text; end if;
  end if;
  return done;
end $$;

-- start a change (as the signed-in caller). Returns what the Edge Function must do next; for 'confirm' the one-time token.
create or replace function public.cms_login_email_start(p_new text, p_reason text, p_person uuid default null, p_tutor uuid default null, p_source text default 'profile')
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare t jsonb; m jsonb; v text := lower(btrim(coalesce(p_new, ''))); c public.cms_login_email_changes; tok text; recs text[]; r record; co text;
begin
  if not public.cms_can('users.email', 'V') then raise exception 'Changing login emails needs the permission Change login email.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason.'; end if;
  t := private.cms_login_target(p_person, p_tutor); m := private.cms_login_email_mode(t, v);
  co := t->>'company';
  if exists (select 1 from public.cms_login_email_changes where user_id = (t->>'user_id')::uuid and status = 'pending') then
    raise exception 'A change is already waiting for confirmation. Resend or cancel it first.'; end if;
  insert into public.cms_login_email_changes (person_id, tutor_id, user_id, target_user_id, old_email, new_email, mode, reason, source, requested_by, requested_by_name)
  values (p_person, p_tutor, (t->>'user_id')::uuid, (m->'existing'->>'user_id')::uuid, t->>'login_email', v, m->>'mode', btrim(p_reason),
          case when p_tutor is not null then 'tutor' else coalesce(nullif(p_source, ''), 'profile') end, auth.uid(), private.cms_my_name())
  returning * into c;
  if c.mode = 'confirm' then
    tok := encode(extensions.gen_random_bytes(24), 'hex');
    update public.cms_login_email_changes set token_hash = encode(extensions.digest(tok, 'sha256'), 'hex'), expires_at = now() + interval '48 hours', sent_count = 1, last_sent_at = now()
     where id = c.id;
    perform private.cms_log('user.email_change_requested', 'auth.users', c.user_id::text, co,
      (t->>'name') || ': login email change to ' || v || ' requested; waiting for confirmation from the new address (' || btrim(p_reason) || ')', jsonb_build_object('change_id', c.id, 'old', c.old_email));
  elsif c.mode = 'existing' then
    -- move the link and the active roles to the login they already have, block the old one (never deleted)
    if c.person_id is not null then update public.cms_user_links set user_id = c.target_user_id, linked_by = auth.uid(), linked_at = now() where user_id = c.user_id;
    else update public.cms_tutor_links set user_id = c.target_user_id where user_id = c.user_id; end if;
    for r in select * from public.cms_user_roles where user_id = c.user_id and is_active loop
      insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_by, granted_at)
      values (c.target_user_id, r.role_code, r.companies, true, 'Moved from the old login (login email change)', auth.uid(), now())
      on conflict (user_id, role_code) do update set is_active = true, companies = excluded.companies, note = excluded.note, granted_by = excluded.granted_by,
        granted_at = now(), revoked_by = null, revoked_at = null;
    end loop;
    update public.cms_user_roles set is_active = false, revoked_by = auth.uid(), revoked_at = now(), note = 'Login retired: moved to ' || v where user_id = c.user_id and is_active;
    update auth.users set banned_until = '2999-12-31'::timestamptz, recovery_token = '', confirmation_token = '', updated_at = now() where id = c.user_id;
    update public.cms_login_email_changes set status = 'done', done_at = now() where id = c.id returning * into c;
    recs := private.cms_login_email_records(c);
    perform private.cms_log('user.email_changed', 'auth.users', c.user_id::text, co,
      (t->>'name') || ': CMS access moved from the login ' || c.old_email || ' to their existing login ' || v || '; the old login is blocked' ||
      case when cardinality(recs) > 0 then '; updated ' || array_to_string(recs, ', ') else '' end || ' (' || btrim(p_reason) || ')',
      jsonb_build_object('change_id', c.id, 'target_user', c.target_user_id));
  else
    perform private.cms_log('user.email_change_requested', 'auth.users', c.user_id::text, co,
      (t->>'name') || ': login email change to ' || v || ' (login never used: changed at once, set-password email to the new address) (' || btrim(p_reason) || ')',
      jsonb_build_object('change_id', c.id, 'old', c.old_email));
  end if;
  return jsonb_build_object('id', c.id, 'mode', c.mode, 'user_id', c.user_id, 'old_email', c.old_email, 'new_email', v, 'name', t->>'name', 'token', tok,
    'records', to_jsonb(coalesce(recs, '{}')));
end $$;

-- a new link for a waiting change (as the caller)
create or replace function public.cms_login_email_resend(p_id uuid) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_login_email_changes; tok text := encode(extensions.gen_random_bytes(24), 'hex'); nm text;
begin
  if not public.cms_can('users.email', 'V') then raise exception 'Changing login emails needs the permission Change login email.'; end if;
  select * into c from public.cms_login_email_changes where id = p_id and status = 'pending' and mode = 'confirm' for update;
  if c.id is null then raise exception 'Nothing is waiting for confirmation.'; end if;
  update public.cms_login_email_changes set token_hash = encode(extensions.digest(tok, 'sha256'), 'hex'), expires_at = now() + interval '48 hours',
         sent_count = sent_count + 1, last_sent_at = now() where id = p_id;
  nm := coalesce((select employee_name from public.employee_master where id = c.person_id), (select name from public.cms_tutors where id = c.tutor_id));
  perform private.cms_log('user.email_change_resent', 'auth.users', c.user_id::text, null, nm || ': confirmation link sent again to ' || c.new_email, jsonb_build_object('change_id', c.id));
  return jsonb_build_object('id', c.id, 'new_email', c.new_email, 'name', nm, 'token', tok);
end $$;

create or replace function public.cms_login_email_cancel(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_login_email_changes; nm text;
begin
  if not public.cms_can('users.email', 'V') then raise exception 'Changing login emails needs the permission Change login email.'; end if;
  select * into c from public.cms_login_email_changes where id = p_id and status = 'pending' for update;
  if c.id is null then raise exception 'Nothing is waiting.'; end if;
  update public.cms_login_email_changes set status = 'cancelled', token_hash = null, cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = p_id;
  nm := coalesce((select employee_name from public.employee_master where id = c.person_id), (select name from public.cms_tutors where id = c.tutor_id));
  perform private.cms_log('user.email_change_cancelled', 'auth.users', c.user_id::text, null, nm || ': login email change to ' || c.new_email || ' cancelled' || coalesce(' (' || nullif(btrim(p_reason), '') || ')', ''),
    jsonb_build_object('change_id', c.id));
end $$;

-- ---------------------------------------------------------------- for the Edge Function only (service role)
-- the waiting change behind a link (checks it is real and not expired)
create or replace function public.cms_login_email_by_token(p_token text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_login_email_changes;
begin
  select * into c from public.cms_login_email_changes where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and status = 'pending' and mode = 'confirm';
  if c.id is null then
    raise exception 'This link is not valid any more. It may have been used already, replaced by a newer email, or cancelled.'; end if;
  if c.expires_at < now() then raise exception 'This link has expired. Ask HR or Admin to send a new one.'; end if;
  return jsonb_build_object('id', c.id, 'user_id', c.user_id, 'old_email', c.old_email, 'new_email', c.new_email,
    'name', coalesce((select employee_name from public.employee_master where id = c.person_id), (select name from public.cms_tutors where id = c.tutor_id)));
end $$;

-- the login has been changed (direct or confirmed): close the change and bring the records along
create or replace function public.cms_login_email_finish(p_id uuid) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_login_email_changes; recs text[]; nm text; co text;
begin
  update public.cms_login_email_changes set status = 'done', done_at = now(), token_hash = null where id = p_id and status = 'pending' returning * into c;
  if c.id is null then raise exception 'Nothing is waiting.'; end if;
  recs := private.cms_login_email_records(c);
  select employee_name, private.cms_canon(company_code) into nm, co from public.employee_master where id = c.person_id;
  if nm is null then select name, private.cms_canon(company_code) into nm, co from public.cms_tutors where id = c.tutor_id; end if;
  perform private.cms_log('user.email_changed', 'auth.users', c.user_id::text, co,
    nm || ': CMS login email changed from ' || c.old_email || ' to ' || c.new_email ||
    case c.mode when 'confirm' then ' (confirmed by the person from the new address)' else ' (login never used)' end ||
    case when cardinality(recs) > 0 then '; updated ' || array_to_string(recs, ', ') else '' end || '. Requested by ' || coalesce(c.requested_by_name, '—') || ': ' || coalesce(c.reason, ''),
    jsonb_build_object('change_id', c.id));
  return jsonb_build_object('name', nm, 'old_email', c.old_email, 'new_email', c.new_email, 'records', to_jsonb(recs));
end $$;

create or replace function public.cms_login_email_failed(p_id uuid, p_error text) returns void language sql security definer set search_path = public, pg_temp as $$
  update public.cms_login_email_changes set status = case when mode = 'direct' then 'failed' else status end, error = left(p_error, 500) where id = p_id;
$$;

revoke all on function private.cms_login_target(uuid, uuid), private.cms_login_email_mode(jsonb, text), private.cms_login_email_records(public.cms_login_email_changes) from public, anon, authenticated;
revoke all on function public.cms_login_email_info(uuid, uuid), public.cms_login_email_check(text, uuid, uuid), public.cms_login_email_start(text, text, uuid, uuid, text),
  public.cms_login_email_resend(uuid), public.cms_login_email_cancel(uuid, text) from public, anon;
grant execute on function public.cms_login_email_info(uuid, uuid), public.cms_login_email_check(text, uuid, uuid), public.cms_login_email_start(text, text, uuid, uuid, text),
  public.cms_login_email_resend(uuid), public.cms_login_email_cancel(uuid, text) to authenticated;
revoke all on function public.cms_login_email_by_token(text), public.cms_login_email_finish(uuid), public.cms_login_email_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.cms_login_email_by_token(text), public.cms_login_email_finish(uuid), public.cms_login_email_failed(uuid, text) to service_role;
