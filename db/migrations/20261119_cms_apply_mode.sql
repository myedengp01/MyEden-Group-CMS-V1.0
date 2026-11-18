-- PRI-024 phase 5 (v2026.11.19): Apply Now open (invitation only) or closed — set by a Super Admin in Applications › Apply links.
create or replace function public.cms_apply_mode_set(p_mode text) returns text language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.cms_is_super_admin() then raise exception 'Only a Super Admin can open or close Apply Now.' using errcode = '42501'; end if;
  if p_mode not in ('invitation_only', 'disabled') then raise exception 'Apply Now is either invitation only or closed.'; end if;
  update public.eaf_v2_gateway_apps set mode = p_mode, updated_at = now(), updated_by = auth.uid() where app_code = 'apply';
  perform private.cms_log('apply.mode', 'eaf_v2_gateway_apps', 'apply', null, 'Apply Now ' || case when p_mode = 'disabled' then 'closed' else 'open by apply link (invitation only)' end, '{}'::jsonb);
  return p_mode;
end $$;
revoke all on function public.cms_apply_mode_set(text) from public, anon;
grant execute on function public.cms_apply_mode_set(text) to authenticated;
