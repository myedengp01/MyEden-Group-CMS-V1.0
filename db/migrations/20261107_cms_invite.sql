-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-019 Invite to the CMS (CLC 7 Nov 2026)
-- HR invites a person from their profile or from Self-service Access (one, selected, or everyone without a login).
-- The invite email (sent by the cms-invite function through Supabase sign-in, from noreply@mail.myeden.group) lets them choose a password.
-- At the invite the login is linked to the person, gets the Staff role for the person's own company (only if the login has no role yet)
-- and the default self-service parts (only parts never set for that person, so a part HR switched off stays off).
-- Their approver is their "Reports to" (already used by leave, items and appraisals). Higher roles stay granted by hand.
-- A person who already has a login: it is linked and given the same access; if it was never used, a "set your password" email is sent.
-- Defaults (which parts new staff get) are a setting, changed by a Super Admin in Self-service Access.
-- Additive: new table, setting and functions.

insert into public.cms_settings (key, value) values
  ('invite_defaults', '{"parts": ["profile", "payslips", "ea", "claims", "handbook"], "staff_role": true}'::jsonb)
on conflict (key) do nothing;

create table if not exists public.cms_invites (
  person_id uuid primary key references public.employee_master(id) on delete cascade,
  email text not null, user_id uuid, mode text not null,          -- mode: invited (new login) · reset (existing, never used) · linked (existing, in use)
  sent_count int not null default 0, first_at timestamptz not null default now(), last_at timestamptz not null default now(),
  invited_by uuid, invited_by_name text
);
alter table public.cms_invites enable row level security;
revoke all on public.cms_invites from anon, authenticated;

create or replace function private.cms_can_invite() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_is_super_admin() or public.cms_can('selfservice', 'E') or public.cms_can('admin.roles', 'E');
$$;
revoke all on function private.cms_can_invite() from public, anon, authenticated;

-- the person's email (Employee Master, then payroll, then the application) and any login already using it
create or replace function public.cms_invite_prepare(p_person uuid, p_email text default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $f$
declare em public.employee_master; mail text; uid uuid; linked uuid; used boolean;
begin
  if not private.cms_can_invite() then raise exception 'You cannot invite people to the CMS.'; end if;
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  if em.employment_status = 'former' then raise exception '% has left; former staff are not invited.', em.employee_name; end if;
  mail := lower(btrim(coalesce(nullif(btrim(p_email), ''), nullif(btrim(em.email), ''),
            (select nullif(btrim(e.email), '') from public.eppd_employees e where e.employee_master_id = em.id and nullif(btrim(e.email), '') is not null limit 1),
            (select nullif(btrim(a.payload->>'email'), '') from public.eaf_applications a where a.id = em.source_application_id))));
  if mail is null or mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'No valid email for %. Add it to their record or type it in.', em.employee_name; end if;
  select user_id into linked from public.cms_user_links where employee_master_id = em.id limit 1;
  select u.id, u.last_sign_in_at is not null into uid, used from auth.users u where lower(u.email) = mail limit 1;
  if linked is not null and uid is distinct from linked then
    raise exception '% is already linked to another login (%).', em.employee_name, (select email from auth.users where id = linked); end if;
  if uid is not null and exists (select 1 from public.cms_user_links l where l.user_id = uid and l.employee_master_id <> em.id) then
    raise exception 'The login % belongs to another person.', mail; end if;
  return jsonb_build_object('person_id', em.id, 'name', em.employee_name, 'email', mail, 'user_id', uid, 'used', coalesce(used, false),
    'company', private.cms_canon(em.company_code), 'reports_to', em.reports_to_id is not null);
end $f$;
revoke all on function public.cms_invite_prepare(uuid, text) from public, anon;
grant execute on function public.cms_invite_prepare(uuid, text) to authenticated;

-- after the email: link, Staff role, default parts, record the invite
create or replace function public.cms_invite_finish(p_person uuid, p_user uuid, p_mode text)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $f$
declare em public.employee_master; mail text; d jsonb; co text; parts text[]; added text[] := '{}'; p text; role_added boolean := false;
begin
  if not private.cms_can_invite() then raise exception 'You cannot invite people to the CMS.'; end if;
  if p_mode not in ('invited', 'reset', 'linked') then raise exception 'Unknown mode.'; end if;
  select * into em from public.employee_master where id = p_person;
  select email into mail from auth.users where id = p_user;
  if em.id is null or mail is null then raise exception 'Person or login not found.'; end if;
  if exists (select 1 from public.cms_user_links where user_id = p_user and employee_master_id <> p_person)
     or exists (select 1 from public.cms_user_links where employee_master_id = p_person and user_id <> p_user) then
    raise exception 'This login or person is already linked elsewhere.'; end if;
  co := private.cms_canon(em.company_code);
  d := coalesce((select value from public.cms_settings where key = 'invite_defaults'), '{}'::jsonb);
  insert into public.cms_user_links (user_id, employee_master_id, method, linked_by, linked_at) values (p_user, p_person, 'manual', auth.uid(), now())   -- allowed link methods: manual / email_match
  on conflict (user_id) do nothing;
  if coalesce((d->>'staff_role')::boolean, true) and not exists (select 1 from public.cms_user_roles where user_id = p_user and is_active) then
    insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_by, granted_at)
    values (p_user, 'staff', case when co is null then null else array[co] end, true, 'Invited to the CMS', auth.uid(), now())
    on conflict (user_id, role_code) do update set is_active = true, companies = excluded.companies, note = excluded.note, granted_by = excluded.granted_by,
      granted_at = now(), revoked_by = null, revoked_at = null;
    role_added := true;
  end if;
  select coalesce(array_agg(x), '{}') into parts from jsonb_array_elements_text(coalesce(d->'parts', '[]'::jsonb)) x;
  foreach p in array parts loop
    if not exists (select 1 from public.cms_self_access where person_id = p_person and part = p) then
      insert into public.cms_self_access (person_id, part, enabled, changed_by, changed_at) values (p_person, p, true, auth.uid(), now());
      added := added || p;
    end if;
  end loop;
  insert into public.cms_invites (person_id, email, user_id, mode, sent_count, invited_by, invited_by_name)
  values (p_person, mail, p_user, p_mode, case when p_mode = 'linked' then 0 else 1 end, auth.uid(), private.cms_user_name(auth.uid()))
  on conflict (person_id) do update set email = excluded.email, user_id = excluded.user_id, mode = excluded.mode,
    sent_count = public.cms_invites.sent_count + excluded.sent_count, last_at = now(), invited_by = excluded.invited_by, invited_by_name = excluded.invited_by_name;
  perform private.cms_log('user.invite', 'employee_master', p_person::text, co,
    em.employee_name || case p_mode when 'invited' then ' invited to the CMS (' when 'reset' then ' sent a set-password email (' else ' linked to their login (' end || mail || ')',
    jsonb_build_object('mode', p_mode, 'staff_role', role_added, 'parts', to_jsonb(added)));
  return jsonb_build_object('staff_role', role_added, 'parts', to_jsonb(added), 'reports_to', em.reports_to_id is not null);
end $f$;
revoke all on function public.cms_invite_finish(uuid, uuid, text) from public, anon;
grant execute on function public.cms_invite_finish(uuid, uuid, text) to authenticated;

-- invite state per person (for Self-service Access and the profile)
create or replace function public.cms_invite_status()
returns jsonb language sql stable security definer set search_path = public, auth, pg_temp as $$
  select case when private.cms_can_invite() or public.cms_can('selfservice', 'V') then jsonb_build_object(
    'can_invite', private.cms_can_invite(), 'can_defaults', public.cms_is_super_admin(),
    'defaults', coalesce((select value from public.cms_settings where key = 'invite_defaults'), '{}'::jsonb),
    'people', coalesce((select jsonb_object_agg(em.id, jsonb_build_object(
        'login', u.email, 'signed_in', u.last_sign_in_at is not null, 'last_sign_in', u.last_sign_in_at,
        'invited_at', i.last_at, 'sent', i.sent_count, 'mode', i.mode,
        'email', lower(coalesce(nullif(btrim(em.email), ''), (select nullif(btrim(e.email), '') from public.eppd_employees e where e.employee_master_id = em.id and nullif(btrim(e.email), '') is not null limit 1)))))
      from public.employee_master em
      left join public.cms_user_links l on l.employee_master_id = em.id left join auth.users u on u.id = l.user_id
      left join public.cms_invites i on i.person_id = em.id
      where em.employment_status <> 'former' or l.user_id is not null), '{}'::jsonb)) end;
$$;
revoke all on function public.cms_invite_status() from public, anon;
grant execute on function public.cms_invite_status() to authenticated;

create or replace function public.cms_invite_defaults_set(p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare bad text;
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change the invite defaults.'; end if;
  if jsonb_typeof(p->'parts') <> 'array' then raise exception 'Parts must be a list.'; end if;
  select x into bad from jsonb_array_elements_text(p->'parts') x where x not in ('profile', 'payslips', 'ea', 'salary', 'items', 'claims', 'leave', 'handbook', 'certs') limit 1;
  if bad is not null then raise exception 'Unknown part %', bad; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by)
  values ('invite_defaults', jsonb_build_object('parts', p->'parts', 'staff_role', coalesce((p->>'staff_role')::boolean, true)), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('settings.invite_defaults', 'cms_settings', 'invite_defaults', null, 'Invite defaults changed', p);
end $f$;
revoke all on function public.cms_invite_defaults_set(jsonb) from public, anon;
grant execute on function public.cms_invite_defaults_set(jsonb) to authenticated;
