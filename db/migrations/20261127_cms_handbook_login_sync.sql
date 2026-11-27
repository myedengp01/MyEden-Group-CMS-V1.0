-- Handbook follows the person's CMS login; blocked logins in Users (v2026.11.27). Additive.
-- The Handbook reader (handbook_my_assignment and the other handbook_* functions) finds a person's assignment by the login stored
-- on it (handbook_assignments.auth_user_id). An assignment made before the person had a linked login, or kept after their link moved
-- to another login, could not be opened from My Handbook. Now:
--   * a new or changed assignment with no login takes the person's linked CMS login;
--   * when a login is linked to a person (or the link moves to another login), their open assignments take that login.
-- Users: cms_users gives 'blocked' (the login is banned, e.g. retired after a login email change); cms_link_user refuses to link a
-- blocked login to a person.

create or replace function private.cms_hb_assignment_login() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.auth_user_id is null and new.employee_id is not null then
    new.auth_user_id := (select l.user_id from public.cms_user_links l where l.employee_master_id = new.employee_id);
  end if;
  return new;
end $$;

create or replace function private.cms_hb_link_login() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.handbook_assignments a set auth_user_id = new.user_id, updated_at = now()
   where a.employee_id = new.employee_master_id and a.revoked_at is null and a.auth_user_id is distinct from new.user_id;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'cms_hb_assignment_login' and tgrelid = 'public.handbook_assignments'::regclass) then
    create trigger cms_hb_assignment_login before insert or update of employee_id, auth_user_id on public.handbook_assignments
      for each row execute function private.cms_hb_assignment_login();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'cms_hb_link_login' and tgrelid = 'public.cms_user_links'::regclass) then
    create trigger cms_hb_link_login after insert or update of user_id, employee_master_id on public.cms_user_links
      for each row execute function private.cms_hb_link_login();
  end if;
end $$;

do $$ declare d text;
begin
  d := pg_get_functiondef('public.cms_users()'::regprocedure);
  if strpos(d, '''blocked''') = 0 then
    if strpos(d, '''last_sign_in_at'', u.last_sign_in_at,') = 0 then raise exception 'cms_users: marker not found'; end if;
    d := replace(d, '''last_sign_in_at'', u.last_sign_in_at,', '''last_sign_in_at'', u.last_sign_in_at, ''blocked'', coalesce(u.banned_until > now(), false),');
    execute d;
  end if;
  d := pg_get_functiondef('public.cms_link_user(uuid,uuid)'::regprocedure);
  if strpos(d, 'This login is blocked') = 0 then
    if strpos(d, '  select employee_name into v_name from public.employee_master where id = p_person;') = 0 then raise exception 'cms_link_user: marker not found'; end if;
    d := replace(d, '  select employee_name into v_name from public.employee_master where id = p_person;',
      '  if exists (select 1 from auth.users where id = p_user and banned_until > now()) then raise exception ''This login is blocked and cannot be linked to a person.''; end if;
  select employee_name into v_name from public.employee_master where id = p_person;');
    execute d;
  end if;
end $$;
