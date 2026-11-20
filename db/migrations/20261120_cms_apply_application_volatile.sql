-- Full application failed to open: "cannot execute INSERT in a read-only transaction" (v2026.11.20).
-- cms_apply_application logs "full application opened" (private.cms_log, an insert), but was declared STABLE, so Postgres ran it
-- read-only. It is now VOLATILE; nothing else changes.
alter function public.cms_apply_application(uuid) volatile;
