-- MyEden Group CMS V1.0 · Phase 4d · My Leave (built, switched OFF: leave runs in another system for now)
-- Staff apply in My Leave (part "leave" must be switched on). Approver = anyone above the person in the Reports-to line
-- (directors, the highest rank, can approve anyone below them);
-- a director is approved by the other director or HR; a person with no Reports-to is approved by HR. Nobody approves their own.
-- Approved leave is NOT written to payroll automatically: HR keys it into payroll by hand and ticks "added to payroll".

create table if not exists public.cms_leave_requests (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  leave_type text not null,
  date_from date not null, date_to date not null, half_day boolean not null default false,
  days numeric(5,1) not null check (days > 0),
  reason text, attachment text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_at timestamptz not null default now(), requested_by uuid,
  decided_by uuid, decided_by_name text, decided_at timestamptz, decision_note text,
  payroll_done boolean not null default false, payroll_done_at timestamptz, payroll_done_by uuid,
  check (date_to >= date_from));
alter table public.cms_leave_requests enable row level security;
create index if not exists cms_leave_requests_person_idx on public.cms_leave_requests (person_id, status);

-- may the signed-in person decide this request?
create or replace function private.cms_leave_can_decide(p_person uuid)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me(); em public.employee_master; hr boolean;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null or (me is not null and me = p_person) then return false; end if;
  -- directors are the highest rank: they can approve everyone below them (and each other)
  if me is not null and private.cms_person_is_director(me) then return true; end if;
  hr := private.cms_can_company('leave', 'E', private.cms_canon(em.company_code));
  if private.cms_person_is_director(p_person) then return hr; end if;
  if em.reports_to_id is null then return hr; end if;
  return me is not null and exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
           select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
         select 1 from up where id = me);
end $$;

create or replace function private.cms_leave_json(r public.cms_leave_requests)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.id, 'person_id', r.person_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'type', r.leave_type, 'type_label', (select label from public.eppd_lookups where category = 'leave_type' and code = r.leave_type limit 1),
    'from', r.date_from, 'to', r.date_to, 'half_day', r.half_day, 'days', r.days, 'reason', r.reason, 'has_attachment', r.attachment is not null,
    'status', r.status, 'requested_at', r.requested_at, 'decided_by', r.decided_by_name, 'decided_at', r.decided_at, 'decision_note', r.decision_note,
    'payroll_done', r.payroll_done, 'payroll_done_at', r.payroll_done_at, 'can_decide', r.status = 'pending' and private.cms_leave_can_decide(r.person_id))
  from public.employee_master em where em.id = r.person_id;
$$;

create or replace function public.cms_my_leave()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('leave'); y date := date_trunc('year', (now() at time zone 'Asia/Kuala_Lumpur'))::date;
begin
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order, label) from public.eppd_lookups where category = 'leave_type' and is_active), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(private.cms_leave_json(r) order by r.date_from desc) from public.cms_leave_requests r where r.person_id = v), '[]'::jsonb),
    'taken', coalesce((select jsonb_object_agg(t, d) from (select l.leave_type t, sum(l.days) d from public.eppd_leave_records l
        join public.eppd_employees e on e.id = l.employee_id where e.employee_master_id = v and l.date_from >= y and l.status = 'taken' group by 1) x), '{}'::jsonb),
    'approvers', (select case when private.cms_person_is_director(v) then 'The other director, or HR'
                              when em.reports_to_id is null then 'HR'
                              else (select string_agg(n, ' → ' order by depth) from (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
                                     select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
                                    select m.employee_name n, up.depth from up join public.employee_master m on m.id = up.id) z) end
                  from public.employee_master em where em.id = v),
    'to_approve', coalesce((select jsonb_agg(private.cms_leave_json(r) order by r.date_from) from public.cms_leave_requests r
        where r.status = 'pending' and r.person_id <> v and private.cms_leave_can_decide(r.person_id)), '[]'::jsonb));
end $$;

create or replace function public.cms_my_leave_apply(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('leave'); f date := nullif(p->>'from', '')::date; t date := nullif(p->>'to', '')::date; d numeric; id_ uuid;
begin
  if not exists (select 1 from public.eppd_lookups where category = 'leave_type' and code = p->>'type' and is_active) then raise exception 'Choose the type of leave.'; end if;
  if f is null then raise exception 'Choose the first day.'; end if;
  t := coalesce(t, f);
  if t < f then raise exception 'The last day is before the first day.'; end if;
  d := coalesce(nullif(p->>'days', '')::numeric, case when coalesce((p->>'half_day')::boolean, false) then 0.5 else (t - f + 1) end);
  if d <= 0 or d > (t - f + 1) then raise exception 'Check the number of days.'; end if;
  if exists (select 1 from public.cms_leave_requests where person_id = v and status in ('pending','approved') and daterange(date_from, date_to, '[]') && daterange(f, t, '[]')) then
    raise exception 'You already have leave on some of these days.';
  end if;
  if p->>'type' in ('SL','HPL') and nullif(p->>'attachment', '') is null then raise exception 'Attach the medical certificate (MC).'; end if;
  insert into public.cms_leave_requests (person_id, leave_type, date_from, date_to, half_day, days, reason, attachment, requested_by)
  values (v, p->>'type', f, t, coalesce((p->>'half_day')::boolean, false), d, nullif(btrim(p->>'reason'), ''), private.cms_photo_ok(p->>'attachment'), auth.uid())
  returning id into id_;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v, 'leave_requested', 'Leave requested in self-service', jsonb_build_object('request_id', id_, 'type', p->>'type', 'from', f, 'to', t, 'days', d), auth.uid());
  return id_;
end $$;

create or replace function public.cms_my_leave_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('leave');
begin
  update public.cms_leave_requests set status = 'cancelled', decided_at = now(), decided_by = auth.uid(), decided_by_name = private.cms_my_name()
   where id = p_id and person_id = v and status = 'pending';
  if not found then raise exception 'Only a request still waiting can be cancelled.'; end if;
end $$;

create or replace function public.cms_leave_decide(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_leave_requests; em public.employee_master;
begin
  select * into r from public.cms_leave_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'Request not found or already decided.'; end if;
  if not private.cms_leave_can_decide(r.person_id) then raise exception 'You cannot approve this leave.'; end if;
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give the reason.'; end if;
  select * into em from public.employee_master where id = r.person_id;
  update public.cms_leave_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_by_name = private.cms_my_name(),
         decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '') where id = r.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, case when p_approve then 'leave_approved' else 'leave_rejected' end, coalesce(nullif(btrim(p_note), ''), 'Leave ' || case when p_approve then 'approved' else 'rejected' end),
          jsonb_build_object('request_id', r.id, 'by', private.cms_my_name()), auth.uid());
  perform private.cms_log(case when p_approve then 'leave.approved' else 'leave.rejected' end, 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || r.leave_type || ' ' || to_char(r.date_from, 'DD Mon') || coalesce('–' || nullif(to_char(r.date_to, 'DD Mon YYYY'), to_char(r.date_from, 'DD Mon YYYY')), ' ' || to_char(r.date_from, 'YYYY'))
    || ' (' || r.days || ' d) ' || case when p_approve then 'approved' else 'rejected' end || ' by ' || private.cms_my_name(), jsonb_build_object('request_id', r.id));
end $$;

-- HR: all requests, and the manual "added to payroll" tick
create or replace function public.cms_leave_requests()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('leave', 'V');
  return jsonb_build_object('can_edit', public.cms_can('leave', 'E'),
    'requests', coalesce((select jsonb_agg(private.cms_leave_json(r) order by r.date_from desc) from public.cms_leave_requests r join public.employee_master em on em.id = r.person_id
                          where private.cms_can_company('leave', 'V', private.cms_canon(em.company_code)) and (r.status <> 'cancelled' or r.requested_at > now() - interval '30 days')), '[]'::jsonb));
end $$;

create or replace function public.cms_leave_payroll_done(p_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.cms_leave_requests; em public.employee_master;
begin
  select * into r from public.cms_leave_requests where id = p_id for update;
  if r.id is null or r.status <> 'approved' then raise exception 'Only approved leave can be marked.'; end if;
  select * into em from public.employee_master where id = r.person_id;
  perform private.cms_require('leave', 'E', private.cms_canon(em.company_code));
  update public.cms_leave_requests set payroll_done = p_done, payroll_done_at = case when p_done then now() end, payroll_done_by = case when p_done then auth.uid() end where id = r.id;
  perform private.cms_log('leave.payroll', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': leave ' || to_char(r.date_from, 'DD Mon YYYY') || case when p_done then ' added to payroll' else ' not in payroll' end, jsonb_build_object('request_id', r.id));
end $$;

create or replace function public.cms_leave_attachment(p_id uuid)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.cms_leave_requests; em public.employee_master;
begin
  select * into r from public.cms_leave_requests where id = p_id;
  if r.id is null then raise exception 'Not found.'; end if;
  select * into em from public.employee_master where id = r.person_id;
  if r.person_id is distinct from private.cms_me() and not private.cms_leave_can_decide(r.person_id)
     and not private.cms_can_company('leave', 'V', private.cms_canon(em.company_code)) then raise exception 'Not allowed.'; end if;
  return r.attachment;
end $$;

create or replace function public.cms_leave_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  return jsonb_build_object(
    'to_approve', (select count(*) from public.cms_leave_requests r where r.status = 'pending' and private.cms_leave_can_decide(r.person_id)),
    'to_payroll', case when public.cms_can('leave', 'E') then (select count(*) from public.cms_leave_requests where status = 'approved' and not payroll_done) else 0 end);
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_my_leave()','cms_my_leave_apply(jsonb)','cms_my_leave_cancel(uuid)','cms_leave_decide(uuid, boolean, text)','cms_leave_requests()',
    'cms_leave_payroll_done(uuid, boolean)','cms_leave_attachment(uuid)','cms_leave_pending()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
