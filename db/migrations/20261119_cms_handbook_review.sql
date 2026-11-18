-- PRI-024 phase 5 (v2026.11.19): the handbooks themselves and each employee's handbook, read only, in the CMS.
-- Additive. HR, Admin and Directors (Employee Handbook: view) may open every issued handbook (English, 中文; Bahasa Malaysia is a
-- file in the CMS) and any employee's handbook with what they have and have not read. Nothing can be ticked or acknowledged for
-- someone else. Each opening of an employee's handbook is logged.

create or replace function public.handbook_can_view_status(p_user_id uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(public.eaf_v2_is_admin(p_user_id), false)
      or exists (select 1 from public.eaf_v2_staff_permissions p where p.user_id = p_user_id and coalesce(p.can_access_hr, false) = true)
      or (p_user_id is not null and p_user_id = auth.uid() and public.cms_can('handbook', 'V'));
$$;

-- reading the issued handbooks (the library): also for Employee Handbook (view)
do $$ declare d text;
begin
  d := pg_get_functiondef('public.handbook_admin_get_document(uuid, text)'::regprocedure);
  if strpos(d, 'cms_can(''handbook''') = 0 then
    d := replace(d, 'if not public.handbook_is_admin(auth.uid()) then', 'if not (public.handbook_is_admin(auth.uid()) or public.cms_can(''handbook'', ''V'')) then');
    if strpos(d, 'cms_can(''handbook''') = 0 then raise exception 'handbook_admin_get_document: marker not found'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.handbook_admin_versions()'::regprocedure);
  if strpos(d, 'cms_can(''handbook''') = 0 then
    d := replace(d, 'if not public.handbook_is_admin(auth.uid()) then', 'if not (public.handbook_is_admin(auth.uid()) or public.cms_can(''handbook'', ''V'')) then');
    if strpos(d, 'cms_can(''handbook''') = 0 then raise exception 'handbook_admin_versions: marker not found'; end if;
    execute d;
  end if;
end $$;

-- one employee's handbook: who, the dates, the rules and every section they ticked (with when)
create or replace function public.cms_handbook_review(p_assignment uuid) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.handbook_assignments; h public.handbook_versions; em public.employee_master; thr numeric; days int;
begin
  perform private.cms_require('handbook', 'V');
  select * into a from public.handbook_assignments where id = p_assignment; if a.id is null then raise exception 'Handbook assignment not found.'; end if;
  select * into h from public.handbook_versions where id = a.handbook_version_id;
  select * into em from public.employee_master where id = a.employee_id;
  if not public.cms_can('handbook', 'V', private.cms_canon(em.company_code)) then raise exception 'You do not have access to this.' using errcode = '42501'; end if;
  thr := coalesce(a.read_threshold_percent_override, h.default_read_threshold_percent, 90); days := coalesce(a.deadline_days_override, h.default_deadline_days);
  insert into public.handbook_audit_log (assignment_id, employee_id, actor_user_id, action, details) values (a.id, em.id, auth.uid(), 'cms_review_opened', '{}'::jsonb);
  perform private.cms_log('handbook.reviewed', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': handbook reading opened (read only)', jsonb_build_object('assignment_id', a.id));
  return jsonb_build_object(
    'employee', jsonb_build_object('person_id', em.id, 'employee_name', em.employee_name, 'employee_id', em.employee_id, 'company_code', em.company_code, 'job_title', em.approved_job_title,
       'department', em.department, 'employment_status', em.employment_status),
    'handbook', jsonb_build_object('id', h.id, 'handbook_code', h.handbook_code, 'title', h.title, 'version', h.version, 'issue_date', h.issue_date, 'effective_date', h.effective_date,
       'status', h.status, 'source_page_count', h.source_page_count, 'required_clause_count', h.required_clause_count, 'deadline_enabled', h.deadline_enabled,
       'default_deadline_days', h.default_deadline_days, 'default_read_threshold_percent', h.default_read_threshold_percent, 'auto_deem_enabled', h.auto_deem_enabled,
       'acknowledgement_text', h.acknowledgement_text),
    'assignment', jsonb_build_object('id', a.id, 'status', case when a.revoked_at is not null then 'revoked' else a.status end, 'assigned_at', a.assigned_at, 'due_at', a.due_at,
       'first_viewed_at', a.first_viewed_at, 'read_at', a.read_at, 'acknowledged_at', a.acknowledged_at, 'receipt_acknowledged_at', a.receipt_acknowledged_at,
       'receipt_typed_name', a.receipt_typed_name, 'deemed_received_at', a.deemed_received_at, 'deemed_read_at', a.deemed_read_at,
       'safeguarding_typed_name', a.safeguarding_typed_name, 'safeguarding_acknowledged_at', a.safeguarding_acknowledged_at, 'appendix_b_signed_at', a.appendix_b_signed_at,
       'revoked_at', a.revoked_at, 'revoked_reason', a.revoked_reason, 'effective_read_threshold_percent', thr, 'deadline_days', days,
       'own_rules', a.deadline_days_override is not null or a.read_threshold_percent_override is not null),
    'progress', coalesce((select jsonb_agg(jsonb_build_object('clause_key', p.clause_key, 'checked_at', p.checked_at) order by p.clause_key)
       from public.handbook_clause_progress p where p.assignment_id = a.id), '[]'::jsonb));
end $$;
revoke all on function public.cms_handbook_review(uuid) from public, anon;
grant execute on function public.cms_handbook_review(uuid) to authenticated;
