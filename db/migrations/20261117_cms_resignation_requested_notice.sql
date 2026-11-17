-- MyEden Group CMS V1.0 · v2026.11.17 · Resignation: the notice stated in the employee's letter and the Company's decision on a longer
-- notice (CLC 17 Nov 2026). When the employee's date is later than the contractual notice end, HR must choose: accepted (her date becomes
-- the agreed notice end) or declined (the notice follows the contract and the Employee Handbook). Changeable; each save is logged.
-- Additive: two columns; cms_resignation_save patched in place (marker-guarded).
alter table public.cms_resignations add column if not exists requested_notice text;
alter table public.cms_resignations add column if not exists extension_decision text;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'cms_resignations_extension_decision_check') then
    alter table public.cms_resignations add constraint cms_resignations_extension_decision_check check (extension_decision is null or extension_decision in ('accepted', 'declined')); end if;
end $c$;
do $m$ declare src text; o1 text; o2 text; o3 text;
begin
  select pg_get_functiondef('public.cms_resignation_save(uuid,jsonb)'::regprocedure) into src;
  if position('extension_decision' in src) > 0 then return; end if;
  o1 := $o$v_rehire text := nullif(p->>'rehire', '');$o$;
  o2 := $o$  if v_reason is null then raise exception 'Choose the reason for leaving.'; end if;$o$;
  o3 := $o$  update public.eppd_employments set resignation_letter_date = v_letter,$o$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 or position(o3 in src) = 0 then raise exception 'cms_resignation_save has changed'; end if;
  src := replace(src, o1, o1 || $n$ v_reqn text := nullif(btrim(coalesce(p->>'requested_notice', '')), ''); v_dec text := nullif(p->>'extension_decision', '');$n$);
  src := replace(src, o2, o2 || $n$
  if v_dec is not null and v_dec not in ('accepted', 'declined') then raise exception 'Unknown decision on the longer notice.'; end if;
  if v_req is not null and v_req > v_end and v_dec is distinct from 'declined' then
    raise exception 'The employee asked for a later last day (%) than the notice end (%). Choose whether the Company accepts the longer notice she stated.', to_char(v_req, 'DD Mon YYYY'), to_char(v_end, 'DD Mon YYYY'); end if;
  if v_dec = 'accepted' and v_req is not null and v_end <> v_req then raise exception 'Accepted: the notice end must be the date the employee asked for (%).', to_char(v_req, 'DD Mon YYYY'); end if;$n$);
  src := replace(src, o3, $n$  update public.cms_resignations set requested_notice = v_reqn, extension_decision = case when v_req is not null and (v_req > v_end or v_dec = 'accepted') then v_dec end where id = v_id;
$n$ || o3);
  execute src;
end $m$;
