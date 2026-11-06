-- MyEden Group CMS V1.0 · v2026.11.06 · Offer letter (LOEC): the job title is the approved JD position (CLC 6 Nov 2026)
-- The letter prints MEG-EAF V2's "Resolved Position (for letter)" (v2ResolvedJobTitle, e.g. Kindergarten Associate), not the
-- general position family (approvedJobTitle, e.g. Kindergarten (Ages 4-6)). cms_loec_save now saves v2ResolvedJobTitle with the
-- terms, so an issued letter keeps it. Additive: the function is patched in place.
do $m$
declare src text; old text := $o$keys text[] := array['letterDate','approvedJobTitle','jobTitleLevel',$o$;
begin
  select pg_get_functiondef('public.cms_loec_save(uuid, jsonb)'::regprocedure) into src;
  if position('v2ResolvedJobTitle' in src) = 0 then
    if position(old in src) = 0 then raise exception 'cms_loec_save has changed; keys line not found'; end if;
    execute replace(src, old, $n$keys text[] := array['letterDate','approvedJobTitle','v2ResolvedJobTitle','jobTitleLevel',$n$);
  end if;
end $m$;
