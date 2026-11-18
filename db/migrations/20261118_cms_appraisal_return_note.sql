-- v2026.11.18 · Returned reviews show who returned them, when and why (until HR checks the review again).
-- Adds cms_appraisals.returned_at / returned_by_name; cms_appraisal_approve (return) fills them and logs an employee event;
-- cms_probation_check and cms_appraisal_review clear them; cms_appraisal returns them. Applied as migration cms_appraisal_return_note
-- (marker-guarded patches of the live functions — see Supabase for the exact statements).
alter table public.cms_appraisals add column if not exists returned_at timestamptz;
alter table public.cms_appraisals add column if not exists returned_by_name text;
