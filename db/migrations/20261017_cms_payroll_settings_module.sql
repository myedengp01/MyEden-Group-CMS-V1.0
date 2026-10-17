-- MyEden Group CMS V1.0 · v2026.10.17-17:30 · Payroll Settings permission row
insert into public.cms_modules (code, label, grp, phase, sort_order)
values ('payroll.settings', 'Payroll Settings', 'Payroll', 2, 51)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'payroll.settings', 'VCEADX'),
  ('admin', 'payroll.settings', 'VCEADX'),
  ('payroll', 'payroll.settings', 'V'),
  ('hr', 'payroll.settings', 'V')
on conflict (role_code, module_code) do nothing;
insert into public.cms_audit_log (action, entity, summary, details)
values ('system.setup', 'database', 'Added the Payroll Settings permission row (v2026.10.17-17:30)', '{"module":"payroll.settings"}');
