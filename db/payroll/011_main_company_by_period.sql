-- MyEden Group CMS V1.0 · run once in the Supabase SQL editor (project vzngfswtofegimfcoigx), then "Run".
-- Lets the "main paying company" change from a payroll month while the old company keeps its mark for its own months.
--
-- Before: one main company per employment, ever (unique index), so a transfer had to clear the old company's mark.
-- After:  one main company per employment per period: two records may both be main only if their dates do not overlap.
-- No data changes. Also removes two CMS functions that are re-created with new columns / a month (the People page
-- falls back to its older list until they are back, a few minutes later).

create extension if not exists btree_gist with schema extensions;

alter table public.eppd_assignments
  add constraint eppd_assignments_one_main_per_period
  exclude using gist (employment_id with =, daterange(start_date, end_date, '[]') with &&) where (is_primary);

drop index if exists public.eppd_assignments_one_primary;

drop function if exists public.cms_people_list();
drop function if exists public.cms_pay_set_main(bigint, text);

-- check: should return one row, eppd_assignments_one_main_per_period
select conname from pg_constraint where conrelid = 'public.eppd_assignments'::regclass and conname = 'eppd_assignments_one_main_per_period';
