-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-017 (CLC 7 Nov 2026)
-- 1. Offer letter (LOEC) optional clauses 5.5 overtime, 7.4 annual leave pro-rated, 15.4 excess leave on leaving: saved with the terms
--    (cmsClauseOt, cmsClauseAlProrate, cmsClauseAlExcess; ticked by default).
-- 2. Offer letters are prepared only in the CMS: setting loec_builder = cms. MEG-EAF V2 shows a notice with a link to the CMS, and a guard
--    stops any new offer letter record (or revision) being created outside the CMS. Signed copy, verification and stamp duty still work there.
-- Additive only.
create table if not exists public.cms_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.cms_settings enable row level security;
revoke all on public.cms_settings from anon, authenticated;

insert into public.cms_settings (key, value) values
  ('loec_builder', jsonb_build_object('mode', 'cms', 'link', 'https://myedengp01.github.io/MyEden-Group-CMS-V1.0/app/#/loec?app='))
on conflict (key) do nothing;

-- read by MEG-EAF V2 and the CMS (signed-in users only)
create or replace function public.cms_setting_get(p_key text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select value from public.cms_settings where key = p_key and auth.uid() is not null;
$$;
revoke all on function public.cms_setting_get(text) from public, anon;
grant execute on function public.cms_setting_get(text) to authenticated;

-- changed by a Super Admin only
create or replace function public.cms_setting_set(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can change this setting.'; end if;
  if p_key not in ('loec_builder') then raise exception 'Unknown setting.'; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $f$;
revoke all on function public.cms_setting_set(text, jsonb) from public, anon;
grant execute on function public.cms_setting_set(text, jsonb) to authenticated;

-- new offer letters only from the CMS while loec_builder = cms
create or replace function private.cms_loec_cms_only() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if coalesce((select value->>'mode' from public.cms_settings where key = 'loec_builder'), 'both') = 'cms'
     and coalesce(new.source, 'eaf') <> 'cms' then
    raise exception 'Offer letters (LOEC) are now prepared and issued in the MyEden Group CMS. Open the applicant there: Recruitment › Applications › Prepare offer letter.';
  end if;
  return new;
end $f$;
drop trigger if exists trg_cms_loec_cms_only on public.eaf_loec_records;
create trigger trg_cms_loec_cms_only before insert on public.eaf_loec_records for each row execute function private.cms_loec_cms_only();

-- the clause choices travel with the terms
do $m$
declare src text;
begin
  select pg_get_functiondef('public.cms_loec_save(uuid, jsonb)'::regprocedure) into src;
  if position('cmsClauseOt' in src) = 0 then
    if position($o$'cmsTitle','cmsWeeklyHours','cmsSigningCompany'];$o$ in src) = 0 then raise exception 'cms_loec_save keys not found'; end if;
    execute replace(src, $o$'cmsTitle','cmsWeeklyHours','cmsSigningCompany'];$o$, $n$'cmsTitle','cmsWeeklyHours','cmsSigningCompany','cmsClauseOt','cmsClauseAlProrate','cmsClauseAlExcess'];$n$);
  end if;
  select pg_get_functiondef('public.cms_loec_get(uuid)'::regprocedure) into src;
  if position('cmsClauseOt' in src) = 0 then
    if position($o$'cmsTitle','cmsWeeklyHours','cmsSigningCompany']) k$o$ in src) = 0 then raise exception 'cms_loec_get keys not found'; end if;
    execute replace(src, $o$'cmsTitle','cmsWeeklyHours','cmsSigningCompany']) k$o$, $n$'cmsTitle','cmsWeeklyHours','cmsSigningCompany','cmsClauseOt','cmsClauseAlProrate','cmsClauseAlExcess']) k$n$);
  end if;
end $m$;
