-- MyEden Group CMS V1.0 · v2026.11.18 · OTCF total hours kept to two decimals (CLC 18 Nov 2026).
-- otcf_submissions.total_hours was numeric(6,1): a month total of 9.75 h was saved as 9.8 (header and lists only — payroll prices the
-- lines, so pay was not affected). Now numeric(7,2). all_submissions_view reads the column, so it is dropped and created again with the
-- same definition and the same grants. The two claims saved rounded are corrected from their lines:
-- OTCF-HDS-20261110-0926-B7 (SEE HOI YONG, Nov 2026) 9.8 → 9.75 and OTCF-MEG-20260903-0908-Q6 (PIONG RUI GEN, Aug 2026, approved) 2.8 → 2.75.
do $v$ declare def text; owner text;
begin
  select pg_get_viewdef('public.all_submissions_view'::regclass, true), pg_get_userbyid(relowner) into def, owner from pg_class where oid = 'public.all_submissions_view'::regclass;
  drop view public.all_submissions_view;
  alter table public.otcf_submissions alter column total_hours type numeric(7,2);
  execute 'create view public.all_submissions_view as ' || def;
  execute format('alter view public.all_submissions_view owner to %I', owner);
  grant all on public.all_submissions_view to anon, authenticated, service_role;
end $v$;

alter table public.otcf_submissions disable trigger otcf_submissions_set_updated_at;
update public.otcf_submissions s set total_hours = x.sum_hrs
  from (select id, (select coalesce(sum(coalesce(nullif(li->>'actualHrs', ''), nullif(li->>'totalHrs', ''))::numeric), 0) from jsonb_array_elements(line_items) li) sum_hrs
          from public.otcf_submissions where serial_no in ('OTCF-HDS-20261110-0926-B7', 'OTCF-MEG-20260903-0908-Q6')) x
 where s.id = x.id and s.total_hours <> x.sum_hrs;
alter table public.otcf_submissions enable trigger otcf_submissions_set_updated_at;
