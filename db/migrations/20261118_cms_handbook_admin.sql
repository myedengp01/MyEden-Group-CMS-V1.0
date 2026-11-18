-- PRI-024 phase 4 (v2026.11.18): Employee Handbook administration in the CMS (Employee Handbook page).
-- Additive. CMS users with Employee Handbook (edit) are handbook administrators (the MEG-EAF V2 handbook functions accept them),
-- so HR assigns, takes back, sets due dates and the reading rules from the CMS. Hiring already assigns the handbook of the
-- employer (trigger trg_handbook_auto_assign_employee, unchanged).

create or replace function public.handbook_is_admin(p_user_id uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(public.eaf_v2_is_admin(p_user_id), false)
      or (p_user_id is not null and p_user_id = auth.uid() and public.cms_can('handbook', 'E'));
$$;

-- the progress list carries the assignment and its own rules
do $$ declare d text;
begin
  d := pg_get_functiondef('public.cms_handbook_progress()'::regprocedure);
  if strpos(d, '''assignment_id''') = 0 then
    d := replace(d, '''version'', v.title || '' '' || v.version,', '''version'', v.title || '' '' || v.version, ''assignment_id'', a.id, ''version_id'', v.id, ''deadline_days'', a.deadline_days_override, ''read_threshold'', a.read_threshold_percent_override,
      ''deadline_enabled'', v.deadline_enabled, ''default_days'', v.default_deadline_days, ''default_threshold'', v.default_read_threshold_percent, ''receipt_at'', a.receipt_acknowledged_at,');
    if strpos(d, '''assignment_id''') = 0 then raise exception 'cms_handbook_progress: marker not found'; end if;
    execute d;
  end if;
end $$;

-- the handbook versions and their rules, for the settings window
create or replace function public.cms_handbook_admin() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('handbook', 'V');
  return jsonb_build_object('can_edit', public.cms_can('handbook', 'E'),
    'versions', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'code', h.handbook_code, 'title', h.title, 'version', h.version, 'status', h.status,
        'companies', to_jsonb(h.legal_employer_codes), 'effective_date', h.effective_date, 'clauses', h.required_clause_count, 'pages', h.source_page_count,
        'deadline_enabled', h.deadline_enabled, 'days', h.default_deadline_days, 'threshold', h.default_read_threshold_percent, 'auto_deem', h.auto_deem_enabled,
        'assigned', (select count(*) from public.handbook_assignments a where a.handbook_version_id = h.id and a.revoked_at is null),
        'acknowledged', (select count(*) from public.handbook_assignments a where a.handbook_version_id = h.id and a.revoked_at is null and coalesce(a.acknowledged_at, a.receipt_acknowledged_at) is not null))
      order by h.handbook_code, h.version) from public.handbook_versions h), '[]'::jsonb));
end $$;

create or replace function public.cms_handbook_version_set(p_id uuid, p_deadline_enabled boolean, p_days int, p_threshold numeric, p_auto_deem boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare h public.handbook_versions;
begin
  perform private.cms_require('handbook', 'E');
  select * into h from public.handbook_versions where id = p_id; if h.id is null then raise exception 'Handbook not found.'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Days to read: 1 to 365.'; end if;
  if p_threshold is null or p_threshold < 1 or p_threshold > 100 then raise exception 'Read at least: 1 to 100 %%.'; end if;
  update public.handbook_versions set deadline_enabled = coalesce(p_deadline_enabled, deadline_enabled), default_deadline_days = p_days,
         default_read_threshold_percent = p_threshold, auto_deem_enabled = coalesce(p_auto_deem, auto_deem_enabled), updated_at = now() where id = h.id;
  insert into public.handbook_audit_log (actor_user_id, action, details)
  values (auth.uid(), 'cms_version_rules', jsonb_build_object('handbook_version_id', h.id, 'deadline_enabled', p_deadline_enabled, 'days', p_days, 'threshold', p_threshold, 'auto_deem', p_auto_deem));
  perform private.cms_log('handbook.rules', 'handbook_versions', h.id::text, null, h.title || ' ' || h.version || ': reading rules changed', jsonb_build_object('deadline_enabled', p_deadline_enabled, 'days', p_days, 'threshold', p_threshold, 'auto_deem', p_auto_deem));
end $$;

-- assign (or give back) the employer's current handbook to one person — the same as hiring does
create or replace function public.cms_handbook_assign(p_person uuid) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; v_h public.handbook_versions; v_id uuid;
begin
  perform private.cms_require('handbook', 'E');
  select * into em from public.employee_master where id = p_person; if em.id is null then raise exception 'Person not found.'; end if;
  if em.employment_status not in ('active', 'onboarding') then raise exception '% is not active.', em.employee_name; end if;
  select * into v_h from public.handbook_versions h where h.status = 'issued' and upper(em.company_code) = any(h.legal_employer_codes) order by h.effective_date desc nulls last, h.created_at desc limit 1;
  if v_h.id is null then raise exception 'There is no handbook for %.', em.company_code; end if;
  insert into public.handbook_assignments (handbook_version_id, employee_id, company_code, status, assigned_by, due_at)
  values (v_h.id, em.id, upper(em.company_code), 'assigned', auth.uid(), case when v_h.deadline_enabled then now() + make_interval(days => coalesce(v_h.default_deadline_days, 7)) end)
  on conflict (handbook_version_id, employee_id) do update set company_code = excluded.company_code, revoked_at = null, revoked_by = null, revoked_reason = null,
    status = case when public.handbook_assignments.status = 'revoked' then 'assigned' else public.handbook_assignments.status end,
    due_at = coalesce(public.handbook_assignments.due_at, excluded.due_at), updated_at = now()
  returning id into v_id;
  insert into public.handbook_audit_log (actor_user_id, action, details) values (auth.uid(), 'cms_assign', jsonb_build_object('assignment_id', v_id, 'employee_id', em.id));
  perform private.cms_log('handbook.assigned', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || v_h.title || ' ' || v_h.version || ' assigned', '{}'::jsonb);
  return v_id;
end $$;

revoke all on function public.cms_handbook_admin(), public.cms_handbook_version_set(uuid, boolean, int, numeric, boolean), public.cms_handbook_assign(uuid) from public, anon;
grant execute on function public.cms_handbook_admin(), public.cms_handbook_version_set(uuid, boolean, int, numeric, boolean), public.cms_handbook_assign(uuid) to authenticated;
