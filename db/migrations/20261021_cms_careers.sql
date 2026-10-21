-- MyEden Group CMS V1.0 · Phase 5a · MyEden salary caps (PRI-008), staff timeline and Career Paths (PRI-007)
-- The JD Manual bands (MEG-EAF V2) stay as the market reference; beside each band a MyEden cap (min / max) that HR / Admin
-- edit, with effective date and history. Each person is placed on a JD position (matched by job title and employer, or set
-- by HR), so Career Paths shows their level, time in level, salary against the cap and the next level with its cap.

insert into public.cms_modules (code, grp, label, phase, sort_order)
values ('careers', 'Performance & Growth', 'Career Paths & salary caps', 5, 62)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('super_admin', 'careers', 'VCEADX'), ('admin', 'careers', 'VCEADX'), ('hr', 'careers', 'VCE'), ('director', 'careers', 'V')
on conflict do nothing;

create table if not exists public.cms_salary_caps (
  band_id uuid primary key references public.jd_salary_bands(id) on delete cascade,
  cap_min numeric(12,2), cap_max numeric(12,2),
  effective_from date, note text, updated_by uuid, updated_at timestamptz not null default now(),
  check (cap_min is null or cap_max is null or cap_max >= cap_min));
alter table public.cms_salary_caps enable row level security;

create table if not exists public.cms_salary_cap_history (
  id bigint generated always as identity primary key,
  band_id uuid not null references public.jd_salary_bands(id) on delete cascade,
  cap_min numeric(12,2), cap_max numeric(12,2), effective_from date, note text,
  changed_by uuid, changed_by_name text, changed_at timestamptz not null default now());
alter table public.cms_salary_cap_history enable row level security;

create table if not exists public.cms_person_position (
  person_id uuid primary key references public.employee_master(id) on delete cascade,
  position_id uuid not null references public.jd_positions(id) on delete cascade,
  since date, note text, set_by uuid, set_at timestamptz not null default now());
alter table public.cms_person_position enable row level security;

-- the JD position a person holds: set by HR, else matched by job title + employer
create or replace function private.cms_position_of(p_person uuid)
returns table(position_id uuid, auto boolean, since date)
language sql stable security definer set search_path = public, pg_temp as $$
  select pp.position_id, false, pp.since from public.cms_person_position pp where pp.person_id = p_person
  union all
  select p.id, true, null::date from public.employee_master em
    join public.jd_positions p on lower(btrim(p.job_title)) = lower(btrim(em.approved_job_title))
    join public.jd_entities e on e.id = p.entity_id and private.cms_canon(e.code) = private.cms_canon(em.company_code)
   where em.id = p_person and not exists (select 1 from public.cms_person_position x where x.person_id = p_person)
  limit 1;
$$;

-- current salary (latest salary record on a live paying assignment; joint payment adds up)
create or replace function private.cms_person_salary(p_person uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when count(*) = 0 then null else jsonb_build_object('amount', sum(amount), 'basis', min(pay_basis), 'from', max(effective_from)) end
  from (select distinct on (a.id) h.amount, h.pay_basis, h.effective_from
          from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id
          join public.eppd_employments m on m.id = a.employment_id join public.eppd_employees e on e.id = m.employee_id
         where e.employee_master_id = p_person and (a.end_date is null or a.end_date >= current_date) and (m.resigned_date is null or m.resigned_date >= current_date)
           and h.effective_from <= current_date
         order by a.id, h.effective_from desc, h.id desc) x;
$$;

create or replace function public.cms_careers()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare pay boolean;
begin
  perform private.cms_require('careers', 'V');
  pay := public.cms_can('payroll.increments', 'V') or public.cms_can('careers', 'E');
  return jsonb_build_object('can_edit', public.cms_can('careers', 'E'), 'can_pay', pay,
    'positions', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'reference', p.reference, 'title', p.job_title, 'level', p.level,
          'company', private.cms_canon(e.code), 'department', d.name, 'department_id', d.id, 'status', p.status, 'career_path', p.career_path,
          'bands', case when pay then coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'tier', b.tier, 'min', b.salary_min, 'max', b.salary_max, 'range', b.display_range,
                         'cap_min', c.cap_min, 'cap_max', c.cap_max, 'cap_from', c.effective_from, 'cap_note', c.note, 'cap_at', c.updated_at) order by b.sequence)
                       from public.jd_salary_bands b left join public.cms_salary_caps c on c.band_id = b.id where b.position_id = p.id), '[]'::jsonb) else '[]'::jsonb end)
        order by e.code, d.name, p.level, p.reference)
      from public.jd_positions p join public.jd_entities e on e.id = p.entity_id left join public.jd_departments d on d.id = p.department_id
      where coalesce(p.status, 'active') not in ('archived','retired')), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
          'status', em.employment_status, 'title', em.approved_job_title, 'department', em.department, 'start', coalesce(em.original_group_join_date, em.start_date),
          'position_id', pos.position_id, 'auto', pos.auto, 'since', coalesce(pos.since, em.start_date),
          'salary', case when pay then private.cms_person_salary(em.id) end) order by em.employee_name)
      from public.employee_master em left join lateral (select * from private.cms_position_of(em.id)) pos on true
      where em.employment_status in ('active','onboarding') and private.cms_can_company('careers', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $$;

create or replace function public.cms_salary_cap_save(p_band uuid, p_min numeric, p_max numeric, p_from date default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.jd_salary_bands; pos public.jd_positions;
begin
  perform private.cms_require('careers', 'E');
  select * into b from public.jd_salary_bands where id = p_band;
  if b.id is null then raise exception 'Salary band not found.'; end if;
  if p_min is not null and p_max is not null and p_max < p_min then raise exception 'The maximum is below the minimum.'; end if;
  if (p_min is not null and p_min < 0) or (p_max is not null and p_max < 0) then raise exception 'Amounts cannot be negative.'; end if;
  select * into pos from public.jd_positions where id = b.position_id;
  insert into public.cms_salary_caps (band_id, cap_min, cap_max, effective_from, note, updated_by, updated_at)
  values (b.id, p_min, p_max, coalesce(p_from, current_date), nullif(btrim(p_note), ''), auth.uid(), now())
  on conflict (band_id) do update set cap_min = excluded.cap_min, cap_max = excluded.cap_max, effective_from = excluded.effective_from,
     note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  insert into public.cms_salary_cap_history (band_id, cap_min, cap_max, effective_from, note, changed_by, changed_by_name)
  values (b.id, p_min, p_max, coalesce(p_from, current_date), nullif(btrim(p_note), ''), auth.uid(), private.cms_my_name());
  perform private.cms_log('salary_cap.saved', 'jd_salary_bands', b.id::text, null,
    'MyEden cap ' || pos.job_title || ' (' || coalesce(pos.level, '') || ', ' || b.tier || '): ' || coalesce(p_min::text, '—') || ' – ' || coalesce(p_max::text, '—'),
    jsonb_build_object('min', p_min, 'max', p_max, 'from', p_from, 'note', p_note));
end $$;

create or replace function public.cms_salary_cap_history(p_band uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('careers', 'E');
  return coalesce((select jsonb_agg(jsonb_build_object('min', cap_min, 'max', cap_max, 'from', effective_from, 'note', note, 'by', changed_by_name, 'at', changed_at) order by changed_at desc)
    from public.cms_salary_cap_history where band_id = p_band), '[]'::jsonb);
end $$;

create or replace function public.cms_person_position_set(p_person uuid, p_position uuid, p_since date default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; pos public.jd_positions;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('careers', 'E', private.cms_canon(em.company_code));
  if p_position is null then
    raise exception 'Choose the JD position.';
  else
    select * into pos from public.jd_positions where id = p_position;
    if pos.id is null then raise exception 'JD position not found.'; end if;
    insert into public.cms_person_position (person_id, position_id, since, note, set_by, set_at)
    values (em.id, pos.id, p_since, nullif(btrim(p_note), ''), auth.uid(), now())
    on conflict (person_id) do update set position_id = excluded.position_id, since = excluded.since, note = excluded.note, set_by = excluded.set_by, set_at = now();
  end if;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'jd_position_set', coalesce(nullif(btrim(p_note), ''), 'JD position: ' || coalesce(pos.job_title || ' (' || pos.level || ')', 'cleared')),
          jsonb_build_object('position_id', p_position, 'since', p_since, 'reference', pos.reference), auth.uid());
  perform private.cms_log('person.position', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': JD position ' || coalesce(pos.reference || ' ' || pos.job_title || ' (' || pos.level || ')', 'cleared'), jsonb_build_object('position_id', p_position, 'since', p_since));
end $$;

-- everything that happened to a person, oldest first
create or replace function public.cms_person_timeline(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare em public.employee_master; pay boolean;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('careers', 'V', private.cms_canon(em.company_code));
  pay := public.cms_can('payroll.increments', 'V') or public.cms_can('careers', 'E');
  return coalesce((select jsonb_agg(x order by x->>'at', x->>'kind') from (
    -- recruitment (MEG-EAF V2)
    select jsonb_build_object('at', a.submitted_at, 'kind', 'recruit', 'title', 'Applied', 'note', a.position_applied) x
      from public.eaf_applications a where a.id = em.source_application_id and a.submitted_at is not null
    union all select jsonb_build_object('at', l.issued_at, 'kind', 'recruit', 'title', 'Offer letter issued', 'note', l.document_id)
      from public.eaf_loec_records l where l.application_id = em.source_application_id and l.issued_at is not null and l.status not in ('superseded','cancelled')
    union all select jsonb_build_object('at', l.employee_signed_date, 'kind', 'recruit', 'title', 'Offer accepted (signed)', 'note', l.document_id)
      from public.eaf_loec_records l where l.application_id = em.source_application_id and l.employee_signed_date is not null and l.status not in ('superseded','cancelled')
    -- employment periods (payroll)
    union all select jsonb_build_object('at', m.join_date, 'kind', 'job', 'title', 'Joined', 'note', concat_ws(' · ', t.name, d.code, c.short_name))
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id left join public.eppd_job_titles t on t.id = m.job_title_id
      left join public.eppd_departments d on d.id = m.department_id left join lateral (select c2.short_name from public.eppd_assignments a2 join public.eppd_companies c2 on c2.id = a2.company_id where a2.employment_id = m.id order by a2.is_primary desc limit 1) c on true
     where e.employee_master_id = em.id and m.join_date is not null
    union all select jsonb_build_object('at', m.confirmed_date, 'kind', 'job', 'title', 'Confirmed', 'note', null)
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.confirmed_date is not null
    union all select jsonb_build_object('at', m.resignation_letter_date, 'kind', 'leave', 'title', 'Resignation letter', 'note', null)
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.resignation_letter_date is not null
    union all select jsonb_build_object('at', m.resigned_date, 'kind', 'leave', 'title', 'Last working day', 'note', concat_ws(' · ', (select label from public.eppd_lookups where category = 'leaving_reason' and code = m.leaving_reason limit 1), m.leaving_note))
      from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.resigned_date is not null
    -- salary
    union all select jsonb_build_object('at', h.effective_from, 'kind', 'pay', 'title', coalesce(nullif(h.reason, ''), 'Salary'), 'amount', h.amount, 'basis', h.pay_basis, 'note', h.note)
      from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id join public.eppd_employments m on m.id = a.employment_id
      join public.eppd_employees e on e.id = m.employee_id where pay and e.employee_master_id = em.id
    -- CMS events (Employee ID, JD position, hand-over, rehire …)
    union all select jsonb_build_object('at', ev.created_at, 'kind', 'event', 'title', initcap(replace(ev.event_type, '_', ' ')), 'note', ev.note, 'type', ev.event_type)
      from public.employee_events ev where ev.employee_id_ref = em.id
       and ev.event_type not in ('payslip_viewed','profile_change_requested','employee_leave_recorded','employee_leave_balance_set','employee_medical_leave_details_set')
    -- items
    union all select jsonb_build_object('at', i.issued_on, 'kind', 'item', 'title', 'Item issued', 'note', concat_ws(' · ', t.label, i.description))
      from public.cms_items i join public.cms_item_types t on t.code = i.type_code where i.person_id = em.id
    union all select jsonb_build_object('at', i.returned_on, 'kind', 'item', 'title', 'Item ' || i.status, 'note', concat_ws(' · ', t.label, i.description))
      from public.cms_items i join public.cms_item_types t on t.code = i.type_code where i.person_id = em.id and i.returned_on is not null
  ) q where x->>'at' is not null), '[]'::jsonb);
end $$;

-- MyEden caps for one JD position (JD Manual window)
create or replace function public.cms_position_caps(p_position uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not (public.cms_can('careers', 'V') or public.cms_can('jd', 'V')) then return '[]'::jsonb; end if;
  if not (public.cms_can('payroll.increments', 'V') or public.cms_can('careers', 'E')) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('band_id', b.id, 'tier', b.tier, 'cap_min', c.cap_min, 'cap_max', c.cap_max) order by b.sequence)
    from public.jd_salary_bands b left join public.cms_salary_caps c on c.band_id = b.id where b.position_id = p_position), '[]'::jsonb);
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_careers()','cms_salary_cap_save(uuid, numeric, numeric, date, text)','cms_salary_cap_history(uuid)',
    'cms_person_position_set(uuid, uuid, date, text)','cms_person_timeline(uuid)','cms_position_caps(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
