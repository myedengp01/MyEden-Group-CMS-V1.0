-- PRI-024 phase 5 (v2026.11.19): JD Manual bookmarks in the CMS (one list per person; switching off keeps the row, marked off).
-- Existing MEG-EAF V2 JD bookmarks were copied in.
create table if not exists public.cms_jd_marks (
  user_id uuid not null, position_id uuid not null references public.jd_positions(id),
  marked boolean not null default true, updated_at timestamptz not null default now(),
  primary key (user_id, position_id));
alter table public.cms_jd_marks enable row level security;
insert into public.cms_jd_marks (user_id, position_id, marked, updated_at)
select b.user_id, b.position_id, true, now() from public.jd_bookmarks b where exists (select 1 from public.jd_positions p where p.id = b.position_id)
on conflict do nothing;
create or replace function public.cms_jd_marks_get() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(position_id), '[]'::jsonb) from public.cms_jd_marks where user_id = auth.uid() and marked;
$$;
create or replace function public.cms_jd_mark(p_position uuid, p_on boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not (public.cms_can('jd', 'V') or public.cms_can('recruitment', 'V')) then raise exception 'Not allowed' using errcode = '42501'; end if;
  insert into public.cms_jd_marks (user_id, position_id, marked, updated_at) values (auth.uid(), p_position, coalesce(p_on, true), now())
  on conflict (user_id, position_id) do update set marked = excluded.marked, updated_at = now();
end $$;
revoke all on function public.cms_jd_marks_get(), public.cms_jd_mark(uuid, boolean) from public, anon;
grant execute on function public.cms_jd_marks_get(), public.cms_jd_mark(uuid, boolean) to authenticated;
