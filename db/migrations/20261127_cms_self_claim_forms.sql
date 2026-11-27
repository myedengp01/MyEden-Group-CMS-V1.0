-- Self-service: each claim form is switched on per person; My Rewards has its own switch (v2026.11.27). Additive patches.
-- New self-service parts: claims_scf, claims_otcf, claims_mtcf, claims_tec (replacing the single 'claims' part) and rewards.
-- * A person's own claim (SCF / OTCF / MTCF / TEC) needs that form's part switched on for them. A role permission on the form no
--   longer opens the person's own claims (it still governs claims for other people, the Claims page, approving and paying).
-- * My Claims needs at least one claim form switched on; My Rewards needs 'rewards'.
-- * Tutors keep their own TEC claims through their tutor login (unchanged).
-- Data (run separately, with CLC's approval, recorded in the Audit Log): old 'claims' switches off, Payslips / EA off for the people
-- who got them from the invite defaults, invite defaults = Profile and Handbook.

create or replace function private.cms_claim_part(p_module text) returns text language sql immutable set search_path = pg_catalog as $$
  select case p_module when 'scf' then 'claims_scf' when 'overtime' then 'claims_otcf' when 'otcf' then 'claims_otcf'
                       when 'mtcf' then 'claims_mtcf' when 'tec' then 'claims_tec' when 'tec-v2' then 'claims_tec' end
$$;

create or replace function private.cms_self_claims_any(p_person uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_self_access where person_id = p_person and enabled and part in ('claims_scf', 'claims_otcf', 'claims_mtcf', 'claims_tec'))
$$;

do $$ declare d text; f text;
begin
  -- the person's own claim: that form's switch only
  foreach f in array array['private.cms_claim_who(uuid,text)', 'private.cms_scf_who(uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if strpos(d, 'cms_claim_part(') = 0 then
      if f like '%claim_who%' then
        if strpos(d, 'elsif not (private.cms_self_on(pid, ''claims'') or public.cms_can(p_module, ''C'')) then') = 0 then raise exception '%: marker not found', f; end if;
        d := replace(d, 'elsif not (private.cms_self_on(pid, ''claims'') or public.cms_can(p_module, ''C'')) then
    raise exception ''Claims are not switched on for you. Ask HR.'';',
          'elsif not private.cms_self_on(pid, private.cms_claim_part(p_module)) then
    raise exception ''This claim form is not switched on for you. Ask HR.'';');
      else
        if strpos(d, 'elsif not (private.cms_self_on(pid, ''claims'') or public.cms_can(''scf'', ''C'')) then') = 0 then raise exception '%: marker not found', f; end if;
        d := replace(d, 'elsif not (private.cms_self_on(pid, ''claims'') or public.cms_can(''scf'', ''C'')) then
    raise exception ''Claims are not switched on for you. Ask HR.'';',
          'elsif not private.cms_self_on(pid, private.cms_claim_part(''scf'')) then
    raise exception ''This claim form is not switched on for you. Ask HR.'';');
      end if;
      if strpos(d, 'cms_claim_part(') = 0 then raise exception '%: not patched', f; end if;
      execute d;
    end if;
  end loop;

  -- My Claims: at least one claim form switched on
  d := pg_get_functiondef('public.cms_my_claims()'::regprocedure);
  if strpos(d, 'cms_self_claims_any') = 0 then
    if strpos(d, 'declare v uuid := private.cms_self_require(''claims'');') = 0 then raise exception 'cms_my_claims: marker not found'; end if;
    d := replace(d, 'declare v uuid := private.cms_self_require(''claims'');', 'declare v uuid := private.cms_me();');
    d := regexp_replace(d, '\nbegin\n', E'\nbegin\n  if v is null then raise exception ''This login is not linked to an employee record.''; end if;\n  if not private.cms_self_claims_any(v) then raise exception ''Claims are not switched on for you. Ask HR.''; end if;\n');
    if strpos(d, 'cms_self_claims_any') = 0 then raise exception 'cms_my_claims: not patched'; end if;
    execute d;
  end if;

  -- My Rewards: its own switch
  foreach f in array array['public.cms_rw_ref_submit(jsonb)', 'public.cms_rw_my_rewards()', 'public.cms_rw_att_apply(date,text)', 'public.cms_rw_att_withdraw(uuid)',
                           'public.cms_rw_my_awards()', 'public.cms_rw_nominate(uuid,uuid,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if strpos(d, 'cms_self_require(''claims'')') > 0 then
      d := replace(d, 'cms_self_require(''claims'')', 'cms_self_require(''rewards'')'); execute d;
    end if;
  end loop;

  -- the parts HR can switch, and the invite defaults
  d := pg_get_functiondef('public.cms_self_set(uuid[],text,boolean)'::regprocedure);
  if strpos(d, 'claims_scf') = 0 then
    if strpos(d, '''certs'',''claims_co'')') = 0 then raise exception 'cms_self_set: marker not found'; end if;
    d := replace(d, '(''profile'',''payslips'',''ea'',''salary'',''leave'',''claims'',''items'',''handbook'',''certs'',''claims_co'')',
      '(''profile'',''payslips'',''ea'',''salary'',''leave'',''items'',''handbook'',''certs'',''claims_co'',''claims_scf'',''claims_otcf'',''claims_mtcf'',''claims_tec'',''rewards'')');
    if strpos(d, 'claims_scf') = 0 then raise exception 'cms_self_set: not patched'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.cms_invite_defaults_set(jsonb)'::regprocedure);
  if strpos(d, 'claims_scf') = 0 then
    if strpos(d, '(''profile'', ''payslips'', ''ea'', ''salary'', ''items'', ''claims'', ''leave'', ''handbook'', ''certs'')') = 0 then raise exception 'cms_invite_defaults_set: marker not found'; end if;
    d := replace(d, '(''profile'', ''payslips'', ''ea'', ''salary'', ''items'', ''claims'', ''leave'', ''handbook'', ''certs'')',
      '(''profile'', ''payslips'', ''ea'', ''salary'', ''items'', ''leave'', ''handbook'', ''certs'', ''claims_scf'', ''claims_otcf'', ''claims_mtcf'', ''claims_tec'', ''rewards'')');
    execute d;
  end if;
end $$;

-- the parts a person can have (the check constraint is replaced, data untouched; 'claims' stays allowed for the old rows, now all off;
-- 'claims_co' was offered on the page but missing here)
alter table public.cms_self_access drop constraint if exists cms_self_access_part_check;
alter table public.cms_self_access add constraint cms_self_access_part_check check (part = any (array['profile', 'payslips', 'ea', 'salary', 'leave', 'claims', 'items', 'handbook', 'certs',
  'claims_co', 'claims_scf', 'claims_otcf', 'claims_mtcf', 'claims_tec', 'rewards']));
