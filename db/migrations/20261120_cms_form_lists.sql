-- Form lists kept in the CMS (PRI-025 phase 2, v2026.11.20). Additive; nothing is deleted.
-- The MTCF rate per km of each company and the TEC course and standard lists were only editable in the MEG-MTCF / MEG-TEC-V2
-- "Manage" windows. They are now kept in the CMS Action Center (Claim settings), by whoever may change claim settings.
-- A course or standard is retired (soft flag), never deleted, so claims already made keep their wording.

alter table public.tec_v2_courses add column if not exists retired_at timestamptz;
alter table public.tec_v2_standards add column if not exists retired_at timestamptz;

-- the TEC form offers only the lists in use
do $$ declare d text;
begin
  d := pg_get_functiondef('public.cms_tec_context(uuid, uuid)'::regprocedure);
  if strpos(d, 'retired_at is null') = 0 then
    d := replace(d, 'order by name) from public.tec_v2_courses)', 'order by name) from public.tec_v2_courses where retired_at is null)');
    d := replace(d, 'order by sort_order, name) from public.tec_v2_standards)', 'order by sort_order, name) from public.tec_v2_standards where retired_at is null)');
    if (length(d) - length(replace(d, 'retired_at is null', ''))) / length('retired_at is null') <> 2 then raise exception 'cms_tec_context: markers not found'; end if;
    execute d;
  end if;
end $$;

create or replace function private.cms_form_lists_edit() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_is_super_admin() or public.cms_can('admin.roles', 'E');
$$;

create or replace function public.cms_form_lists() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('approvals', 'V');
  return jsonb_build_object('can_edit', private.cms_form_lists_edit(),
    'rates', coalesce((select jsonb_agg(jsonb_build_object('company', r.company_code, 'rate', r.rate_rm_per_km, 'updated_at', r.updated_at) order by r.company_code) from public.mtcf_rates r), '[]'::jsonb),
    'courses', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'code', c.code, 'retired', c.retired_at is not null) order by c.retired_at is not null, c.name) from public.tec_v2_courses c), '[]'::jsonb),
    'standards', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'sort', s.sort_order, 'retired', s.retired_at is not null) order by s.retired_at is not null, s.sort_order, s.name) from public.tec_v2_standards s), '[]'::jsonb));
end $$;

create or replace function public.cms_mtcf_rate_set(p_company text, p_rate numeric) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := private.cms_scf_code(p_company); v_old numeric;
begin
  if not private.cms_form_lists_edit() then raise exception 'Not allowed: changing claim settings' using errcode = '42501'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 10 then raise exception 'Rate per km: 0.00 to 10.00.'; end if;
  select rate_rm_per_km into v_old from public.mtcf_rates where company_code = v_code;
  insert into public.mtcf_rates (company_code, rate_rm_per_km, updated_by, updated_at) values (v_code, round(p_rate, 2), auth.uid(), now())
  on conflict (company_code) do update set rate_rm_per_km = excluded.rate_rm_per_km, updated_by = excluded.updated_by, updated_at = now();
  perform private.cms_log('mtcf.rate', 'mtcf_rates', v_code, private.cms_canon(v_code), v_code || ': mileage rate RM ' || coalesce(v_old::text, '—') || ' → RM ' || round(p_rate, 2) || ' per km', jsonb_build_object('before', v_old, 'after', round(p_rate, 2)));
end $$;

create or replace function public.cms_tec_course_save(p_id uuid, p_name text, p_code text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := nullif(btrim(coalesce(p_name, '')), ''); v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
begin
  if not private.cms_form_lists_edit() then raise exception 'Not allowed: changing claim settings' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Give the course a name.'; end if;
  if exists (select 1 from public.tec_v2_courses where lower(name) = lower(v_name) and id is distinct from p_id) then raise exception 'There is already a course called %.', v_name; end if;
  if p_id is null then insert into public.tec_v2_courses (name, code, created_by) values (v_name, v_code, auth.uid()) returning id into v_id;
  else update public.tec_v2_courses set name = v_name, code = v_code where id = p_id returning id into v_id; if v_id is null then raise exception 'Course not found.'; end if; end if;
  perform private.cms_log('tec.course', 'tec_v2_courses', v_id::text, null, 'TEC course ' || v_name || coalesce(' (' || v_code || ')', '') || case when p_id is null then ' added' else ' saved' end, '{}'::jsonb);
  return v_id;
end $$;

create or replace function public.cms_tec_standard_save(p_id uuid, p_name text, p_sort int) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if not private.cms_form_lists_edit() then raise exception 'Not allowed: changing claim settings' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Give the standard a name.'; end if;
  if exists (select 1 from public.tec_v2_standards where lower(name) = lower(v_name) and id is distinct from p_id) then raise exception 'There is already a standard called %.', v_name; end if;
  if p_id is null then insert into public.tec_v2_standards (name, sort_order, created_by) values (v_name, coalesce(p_sort, (select coalesce(max(sort_order), 0) + 1 from public.tec_v2_standards)), auth.uid()) returning id into v_id;
  else update public.tec_v2_standards set name = v_name, sort_order = coalesce(p_sort, sort_order) where id = p_id returning id into v_id; if v_id is null then raise exception 'Standard not found.'; end if; end if;
  perform private.cms_log('tec.standard', 'tec_v2_standards', v_id::text, null, 'TEC standard ' || v_name || case when p_id is null then ' added' else ' saved' end, '{}'::jsonb);
  return v_id;
end $$;

-- retire (or bring back) a course or a standard; claims already made keep it
create or replace function public.cms_tec_list_retire(p_kind text, p_id uuid, p_retire boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text;
begin
  if not private.cms_form_lists_edit() then raise exception 'Not allowed: changing claim settings' using errcode = '42501'; end if;
  if p_kind = 'course' then update public.tec_v2_courses set retired_at = case when p_retire then now() end where id = p_id returning name into v_name;
  elsif p_kind = 'standard' then update public.tec_v2_standards set retired_at = case when p_retire then now() end where id = p_id returning name into v_name;
  else raise exception 'Unknown list.'; end if;
  if v_name is null then raise exception 'Not found.'; end if;
  perform private.cms_log('tec.' || p_kind, 'tec_v2_' || p_kind || 's', p_id::text, null, 'TEC ' || p_kind || ' ' || v_name || case when p_retire then ' retired' else ' back in use' end, '{}'::jsonb);
end $$;

revoke all on function public.cms_form_lists(), public.cms_mtcf_rate_set(text, numeric), public.cms_tec_course_save(uuid, text, text), public.cms_tec_standard_save(uuid, text, int), public.cms_tec_list_retire(text, uuid, boolean) from public, anon;
grant execute on function public.cms_form_lists(), public.cms_mtcf_rate_set(text, numeric), public.cms_tec_course_save(uuid, text, text), public.cms_tec_standard_save(uuid, text, int), public.cms_tec_list_retire(text, uuid, boolean) to authenticated;
revoke all on function private.cms_form_lists_edit() from public, anon;
