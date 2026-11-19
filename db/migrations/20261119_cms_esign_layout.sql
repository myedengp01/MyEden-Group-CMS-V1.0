-- E-signature size and place (v2026.11.19). Additive.
-- Each signatory and each company stamp keeps a default size and place on the letter (height and position in mm, measured from
-- the left end of the signing line; y = how far the picture's bottom sits above the line, negative = crossing it). Each letter may
-- adjust it (letter fields _esign_layout / offer letter term cmsEsignLayout); the layout used is kept on the letter when it is issued.

alter table public.cms_signatories add column if not exists layout jsonb;
alter table public.cms_company_stamps add column if not exists layout jsonb;

-- one picture's size and place, kept within limits: { h, x, y } in mm
create or replace function private.cms_esign_box(j jsonb) returns jsonb language sql immutable as $$
  select case when j is null or jsonb_typeof(j) <> 'object' or not (j ? 'h') then null else jsonb_build_object(
    'h', round(least(60, greatest(6, coalesce((j->>'h')::numeric, 35))), 1),
    'x', round(least(140, greatest(-10, coalesce((j->>'x')::numeric, 0))), 1),
    'y', round(least(50, greatest(-12, coalesce((j->>'y')::numeric, 0))), 1)) end;
$$;
-- a letter's layout: { sig: {h,x,y}, stamp: {h,x,y} }
create or replace function private.cms_esign_layout(j jsonb) returns jsonb language sql immutable as $$
  select case when j is null or jsonb_typeof(j) <> 'object' then null else
    nullif(jsonb_strip_nulls(jsonb_build_object('sig', private.cms_esign_box(j->'sig'), 'stamp', private.cms_esign_box(j->'stamp'))), '{}'::jsonb) end;
$$;

-- the default for a signatory (the signatory, Admin or a Director) and for a company stamp (Admin or a Director)
create or replace function public.cms_signatory_layout_set(p_signatory uuid, p_layout jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.cms_signatories; b jsonb := private.cms_esign_box(p_layout);
begin
  select * into s from public.cms_signatories where id = p_signatory; if s.id is null then raise exception 'Signatory not found.'; end if;
  if not private.cms_esign_can_edit(s.id) then raise exception 'Not allowed: only the signatory, Admin or a Director can set this' using errcode = '42501'; end if;
  update public.cms_signatories set layout = b, updated_by = auth.uid(), updated_at = now() where id = s.id;
  perform private.cms_log('esign.layout', 'cms_signatories', s.id::text, null, s.name || ': e-signature size and place ' || case when b is null then 'reset' else 'set' end, coalesce(b, '{}'::jsonb));
  return b;
end $$;

create or replace function public.cms_stamp_layout_set(p_company text, p_layout jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare st public.cms_company_stamps; b jsonb := private.cms_esign_box(p_layout);
begin
  if not private.cms_esign_manager() then raise exception 'Not allowed: managing company stamps' using errcode = '42501'; end if;
  select * into st from public.cms_company_stamps where company = upper(p_company) and retired_at is null order by created_at desc limit 1;
  if st.id is null then raise exception 'There is no company stamp for %.', p_company; end if;
  update public.cms_company_stamps set layout = b where id = st.id;
  perform private.cms_log('esign.stamp_layout', 'cms_company_stamps', st.id::text, st.company, st.company || ': company stamp size and place ' || case when b is null then 'reset' else 'set' end, coalesce(b, '{}'::jsonb));
  return b;
end $$;

-- the list carries the defaults
do $$ declare d text;
begin
  d := pg_get_functiondef('public.cms_signatories()'::regprocedure);
  if strpos(d, '''layout'', s.layout') = 0 then
    d := replace(d, '''uses'', case when private.cms_esign_can_edit(s.id)', '''layout'', s.layout, ''uses'', case when private.cms_esign_can_edit(s.id)');
    d := replace(d, '''path'', case when private.cms_esign_stamp_user() then x.path end)', '''path'', case when private.cms_esign_stamp_user() then x.path end, ''layout'', x.layout)');
    if strpos(d, '''layout'', s.layout') = 0 or strpos(d, '''layout'', x.layout') = 0 then raise exception 'cms_signatories: marker not found'; end if;
    execute d;
  end if;
end $$;

-- issuing: the size and place used are kept with the letter's e-signature record
create or replace function public.cms_letter_esign(p_id uuid, p_sig_path text, p_stamp_path text, p_layout jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e jsonb; lay jsonb := private.cms_esign_layout(p_layout);
begin
  e := public.cms_letter_esign(p_id, p_sig_path, p_stamp_path);
  if e is not null and lay is not null then
    update public.hr_letter_records set esign = esign || jsonb_build_object('layout', lay) where id = p_id returning esign into e;
  end if;
  return e;
end $$;

-- the offer letter keeps the stamp choice and the size and place
do $$ declare d text;
begin
  d := pg_get_functiondef('public.cms_loec_save(uuid, jsonb)'::regprocedure);
  if strpos(d, 'cmsEsignLayout') = 0 then
    d := replace(d, '''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation''];', '''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation'',''cmsEsignStamp'',''cmsEsignLayout''];');
    if strpos(d, 'cmsEsignLayout') = 0 then raise exception 'cms_loec_save: marker not found'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.cms_loec_get(uuid)'::regprocedure);
  if strpos(d, 'cmsEsignLayout') = 0 then
    d := replace(d, '''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation'']) k where p ? k)', '''cmsSignatoryId'',''cmsSignatoryName'',''cmsSignatoryDesignation'',''cmsEsignStamp'',''cmsEsignLayout'']) k where p ? k)');
    if strpos(d, 'cmsEsignLayout') = 0 then raise exception 'cms_loec_get: marker not found'; end if;
    execute d;
  end if;
end $$;

revoke all on function public.cms_signatory_layout_set(uuid, jsonb), public.cms_stamp_layout_set(text, jsonb), public.cms_letter_esign(uuid, text, text, jsonb) from public, anon;
grant execute on function public.cms_signatory_layout_set(uuid, jsonb), public.cms_stamp_layout_set(text, jsonb), public.cms_letter_esign(uuid, text, text, jsonb) to authenticated;
revoke all on function private.cms_esign_box(jsonb), private.cms_esign_layout(jsonb) from public, anon;
