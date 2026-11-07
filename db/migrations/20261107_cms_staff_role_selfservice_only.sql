-- MyEden Group CMS V1.0 · v2026.11.07 · Staff role: self-service only (CLC 7 Nov 2026)
-- The Staff role dated from before self-service and opened office pages (group dashboard, everyone's claims, leave requests, handbook admin).
-- Staff now see only My Home and the self-service parts switched on for them (their own records), plus Employment Act & Calculators.
-- Admin can still change the Staff role in Users, Roles & Access. Rows are kept (actions emptied), nothing deleted.
-- Checked first in a rolled-back run: the 3 Staff logins went from dashboard, handbook, leave, overtime, scf, mtcf, tec, prfaf, hrlaw to hrlaw only.
update public.cms_role_permissions set actions = ''
 where role_code = 'staff' and module_code in ('dashboard', 'handbook', 'leave', 'overtime', 'scf', 'mtcf', 'tec', 'prfaf') and actions <> '';
