-- MyEden Group CMS V1.0 · v2026.11.07 · Action Center › Claim settings also shows "SCF receipts required on every line" (PRI-010 F1)
create or replace function public.cms_claim_settings()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('history_months', (select claimant_history_months from public.meg_forms_settings where singleton limit 1),
    'scf_receipts_required', coalesce((select (value->>'receipts_required')::boolean from public.cms_settings where key = 'scf_settings'), true),
    'can_edit', public.cms_is_super_admin() or public.cms_can('admin.roles', 'E'))
  where public.cms_can('approvals', 'V');
$$;
