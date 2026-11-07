-- MyEden Group CMS V1.0 · v2026.11.07 · My Claims labels (CLC 7 Nov 2026)
-- A form with no approval step (SCF) no longer says "Approved"; drafts returned for revision say "Returned for changes".
-- (cms_scf_save's variable names were also corrected after the first apply: 20261107_cms_scf_new_fix_code / _fix_bank; the file
--  20261107_cms_scf_new.sql already holds the corrected version.)
do $m$ declare src text;
  o1 text := $o$when 'processing' then 'Approved · being processed' when 'payment' then 'Approved · waiting for payment'$o$;
  n1 text := $n$when 'processing' then case when v_ra then 'Approved · being processed' else 'Sent · being processed' end when 'payment' then case when v_ra then 'Approved · waiting for payment' else 'Processed · waiting for payment' end$n$;
  o2 text := $o$when 'draft' then 'Draft (not sent)'$o$;
  n2 text := $n$when 'draft' then case when lower(coalesce(j->>'revision_required', 'false')) = 'true' then 'Returned for changes' else 'Draft (not sent)' end$n$;
begin
  select pg_get_functiondef('public.cms_my_claims()'::regprocedure) into src;
  if position('Sent · being processed' in src) = 0 then
    if position(o1 in src) = 0 or position(o2 in src) = 0 then raise exception 'cms_my_claims has changed; labels not found'; end if;
    execute replace(replace(src, o1, n1), o2, n2);
  end if;
end $m$;
