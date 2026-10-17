-- MyEden Group CMS V1.0 · Phase 0 patch 2 · fixed search_path on the audit-log guard (security advisor)
alter function private.cms_audit_no_change() set search_path = pg_catalog, pg_temp;
