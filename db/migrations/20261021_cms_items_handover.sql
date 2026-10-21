-- MyEden Group CMS V1.0 · Phase 4b · Items register and hand-over (PRI-006)
-- Every company item given to a person is recorded (email / system accounts, keys, access cards, thumb drives, devices,
-- uniforms, handbook …). The person confirms receipt in My Items (time stamp, optional photo). Changes during employment
-- are events on the item, never overwrites: returned, replaced, renewed, lost / damaged, moved to another person,
-- password changed (the password itself is NEVER stored). When the leaving date is confirmed, a hand-over is opened
-- automatically with a deadline; each item is received back, the person confirms, and the approver (or HR / Admin) approves.

-- ------------------------------------------------------------------ item types (Admin can add more)
create table if not exists public.cms_item_types (
  code text primary key,
  label text not null,
  category text not null default 'other' check (category in ('account','key','device','uniform','document','other')),
  must_return boolean not null default true,
  is_credential boolean not null default false,        -- an account: record password changes / resets (never the password)
  replacement_cost numeric(12,2),
  custodian text,                                        -- who looks after it: HR, Admin, IT, centre head
  is_active boolean not null default true,
  sort_order int not null default 100);
alter table public.cms_item_types enable row level security;
insert into public.cms_item_types (code, label, category, must_return, is_credential, custodian, sort_order) values
  ('EMAIL', 'Company email account', 'account', true, true, 'IT', 10),
  ('LOGIN', 'System login (other)', 'account', true, true, 'IT', 20),
  ('KEY', 'Key', 'key', true, false, 'Admin', 30),
  ('ACCESS_CARD', 'Access card / door fob', 'key', true, false, 'Admin', 40),
  ('THUMB_DRIVE', 'Thumb drive', 'device', true, false, 'IT', 50),
  ('LAPTOP', 'Laptop / computer', 'device', true, false, 'IT', 60),
  ('PHONE', 'Phone / tablet', 'device', true, false, 'IT', 70),
  ('UNIFORM', 'Uniform', 'uniform', true, false, 'HR', 80),
  ('NAME_TAG', 'Name tag', 'uniform', true, false, 'HR', 90),
  ('HANDBOOK', 'Employee handbook (printed)', 'document', true, false, 'HR', 100),
  ('OTHER', 'Other item', 'other', true, false, 'HR', 200)
on conflict (code) do nothing;

-- ------------------------------------------------------------------ items and their history
create table if not exists public.cms_items (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  type_code text not null references public.cms_item_types(code),
  description text,                      -- e.g. "clc@myeden.group", "Main door key HQ", "Size M polo x2"
  asset_tag text,                        -- serial / tag / key number
  quantity int not null default 1 check (quantity > 0),
  condition text,
  status text not null default 'issued' check (status in ('issued','held','returned','lost','damaged','transferred','written_off')),
  issued_on date not null default (now() at time zone 'Asia/Kuala_Lumpur')::date,
  issued_by uuid, issue_note text, issue_photo text,
  confirmed_at timestamptz, confirm_note text, confirm_photo text,          -- the person confirms receipt (locked)
  returned_on date, return_condition text, return_note text, return_photo text, received_by uuid, received_by_name text,
  return_confirmed_at timestamptz,                                          -- the person confirms the return record
  credential_changed_at timestamptz, credential_changed_by uuid,           -- last password change / reset (no password stored)
  replaces_id uuid references public.cms_items(id), replaced_by_id uuid references public.cms_items(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table public.cms_items enable row level security;
create index if not exists cms_items_person_idx on public.cms_items (person_id, status);

create table if not exists public.cms_item_events (
  id bigint generated always as identity primary key,
  item_id uuid not null references public.cms_items(id) on delete cascade,
  event text not null,                   -- issued, confirmed, returned, return_confirmed, replaced, renewed, lost, damaged, transferred, credential_changed, note, edited
  at timestamptz not null default now(), by_user uuid, by_name text,
  note text, photo text, payload jsonb not null default '{}'::jsonb);
alter table public.cms_item_events enable row level security;
create index if not exists cms_item_events_item_idx on public.cms_item_events (item_id, at);

create table if not exists public.cms_handovers (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  status text not null default 'open' check (status in ('open','approved','cancelled')),
  deadline date,
  approver_id uuid references public.employee_master(id) on delete set null,   -- who approves (default: reports to; HR / Admin can always approve)
  notes text,
  opened_at timestamptz not null default now(), opened_by uuid, opened_reason text,
  approved_at timestamptz, approved_by uuid, approved_by_name text, approve_note text,
  updated_at timestamptz not null default now());
alter table public.cms_handovers enable row level security;
create unique index if not exists cms_handovers_one_open on public.cms_handovers (person_id) where status = 'open';

-- ------------------------------------------------------------------ helpers
create or replace function private.cms_my_name()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select em.employee_name from public.cms_user_links l join public.employee_master em on em.id = l.employee_master_id where l.user_id = auth.uid() limit 1),
                  (select split_part(email, '@', 1) from auth.users where id = auth.uid()));
$$;

create or replace function private.cms_item_log(p_item uuid, p_event text, p_note text default null, p_photo text default null, p_payload jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.cms_item_events (item_id, event, by_user, by_name, note, photo, payload)
  values (p_item, p_event, auth.uid(), private.cms_my_name(), nullif(btrim(p_note), ''), nullif(p_photo, ''), coalesce(p_payload, '{}'::jsonb));
$$;

create or replace function private.cms_photo_ok(p text)
returns text language plpgsql immutable as $$
begin
  if p is null or p = '' then return null; end if;
  if length(p) > 1500000 then raise exception 'The photo is too large.'; end if;
  if p !~ '^data:image/' then raise exception 'Attach a picture.'; end if;
  return p;
end $$;

create or replace function private.cms_item_json(i public.cms_items, p_photos boolean default false)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', i.id, 'person_id', i.person_id, 'type', i.type_code, 'type_label', t.label, 'category', t.category, 'must_return', t.must_return,
    'is_credential', t.is_credential, 'description', i.description, 'asset_tag', i.asset_tag, 'quantity', i.quantity, 'condition', i.condition,
    'status', i.status, 'issued_on', i.issued_on, 'issue_note', i.issue_note, 'confirmed_at', i.confirmed_at, 'confirm_note', i.confirm_note,
    'returned_on', i.returned_on, 'return_condition', i.return_condition, 'return_note', i.return_note, 'received_by_name', i.received_by_name,
    'return_confirmed_at', i.return_confirmed_at, 'credential_changed_at', i.credential_changed_at,
    'replaces_id', i.replaces_id, 'replaced_by_id', i.replaced_by_id,
    'photos', jsonb_build_object('issue', i.issue_photo is not null, 'confirm', i.confirm_photo is not null, 'return', i.return_photo is not null),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at, 'by', e.by_name, 'note', e.note, 'photo', e.photo is not null, 'id', e.id) order by e.at)
                         from public.cms_item_events e where e.item_id = i.id), '[]'::jsonb))
  from public.cms_item_types t where t.code = i.type_code;
$$;

-- open a hand-over for a person (used by the leaving-date triggers and by HR)
create or replace function private.cms_open_handover(p_person uuid, p_deadline date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare h uuid; em public.employee_master;
begin
  select id into h from public.cms_handovers where person_id = p_person and status = 'open';
  if h is not null then
    update public.cms_handovers set deadline = coalesce(deadline, p_deadline), updated_at = now() where id = h;
    return h;
  end if;
  select * into em from public.employee_master where id = p_person;
  insert into public.cms_handovers (person_id, deadline, approver_id, opened_by, opened_reason)
  values (p_person, p_deadline, em.reports_to_id, auth.uid(), p_reason) returning id into h;
  update public.employee_master set clearance_status = 'pending', updated_at = now() where id = p_person and clearance_status is distinct from 'cleared';
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (p_person, 'handover_opened', p_reason, jsonb_build_object('handover_id', h, 'deadline', p_deadline), auth.uid());
  return h;
end $$;

-- leaving date confirmed in payroll (MyPayroll / CMS) → hand-over opens automatically when the person holds items
create or replace function private.cms_handover_on_leaving()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare p uuid;
begin
  if new.resigned_date is null or (tg_op = 'UPDATE' and old.resigned_date is not distinct from new.resigned_date) then return new; end if;
  select employee_master_id into p from public.eppd_employees where id = new.employee_id;
  if p is not null and exists (select 1 from public.cms_items where person_id = p and status in ('issued','held')) then
    perform private.cms_open_handover(p, new.resigned_date, 'Leaving date confirmed: last day ' || to_char(new.resigned_date, 'DD Mon YYYY'));
  end if;
  return new;
end $$;
create or replace trigger cms_handover_on_leaving after insert or update of resigned_date on public.eppd_employments
  for each row execute function private.cms_handover_on_leaving();

create or replace function private.cms_handover_on_master()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare d date := coalesce(new.required_last_working_date, new.actual_last_working_date);
begin
  if d is null or (tg_op = 'UPDATE' and coalesce(old.required_last_working_date, old.actual_last_working_date) is not distinct from d) then return new; end if;
  if exists (select 1 from public.cms_items where person_id = new.id and status in ('issued','held')) then
    perform private.cms_open_handover(new.id, d, 'Leaving date confirmed: last day ' || to_char(d, 'DD Mon YYYY'));
  end if;
  return new;
end $$;
create or replace trigger cms_handover_on_master after update of required_last_working_date, actual_last_working_date on public.employee_master
  for each row execute function private.cms_handover_on_master();

-- who may approve a hand-over: HR / Admin (items E), the approver set on it, or anyone above the person in the Reports-to line
create or replace function private.cms_can_approve_handover(h public.cms_handovers)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me(); em public.employee_master;
begin
  select * into em from public.employee_master where id = h.person_id;
  if me is not null and me = h.person_id then return false; end if;          -- nobody approves their own hand-over
  if private.cms_can_company('assets', 'E', private.cms_canon(em.company_code)) then return true; end if;
  if me is null then return false; end if;
  if me = h.approver_id then return true; end if;
  return exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
                   select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
                 select 1 from up where id = me);
end $$;

-- ------------------------------------------------------------------ HR / Admin: Items & Hand-over page
create or replace function public.cms_items_admin()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('assets', 'V');
  return jsonb_build_object(
    'can_edit', public.cms_can('assets', 'E'), 'can_types', public.cms_can('assets', 'A'),
    'types', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.label) from public.cms_item_types t), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
          'status', em.employment_status, 'title', em.approved_job_title, 'items_on', private.cms_self_on(em.id, 'items'),
          'leaving', coalesce(em.required_last_working_date, em.actual_last_working_date,
                              (select max(m.resigned_date) from public.eppd_employments m join public.eppd_employees e on e.id = m.employee_id where e.employee_master_id = em.id and m.resigned_date >= (now() - interval '60 days')::date)))
        order by em.employee_name)
      from public.employee_master em
      where em.employment_status in ('active','onboarding') or exists (select 1 from public.cms_items i where i.person_id = em.id and i.status in ('issued','held'))), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(private.cms_item_json(i) order by i.issued_on desc, i.created_at desc)
      from public.cms_items i join public.employee_master em on em.id = i.person_id
      where private.cms_can_company('assets', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'person_id', h.person_id, 'name', em.employee_name, 'employee_id', em.employee_id,
          'status', h.status, 'deadline', h.deadline, 'approver_id', h.approver_id, 'approver', ap.employee_name, 'notes', h.notes,
          'opened_at', h.opened_at, 'opened_reason', h.opened_reason, 'approved_at', h.approved_at, 'approved_by', h.approved_by_name, 'approve_note', h.approve_note,
          'outstanding', (select count(*) from public.cms_items i where i.person_id = h.person_id and i.status in ('issued','held')),
          'unconfirmed', (select count(*) from public.cms_items i where i.person_id = h.person_id and i.status = 'returned' and i.return_confirmed_at is null and i.returned_on >= h.opened_at::date))
        order by (h.status = 'open') desc, h.deadline nulls last)
      from public.cms_handovers h join public.employee_master em on em.id = h.person_id left join public.employee_master ap on ap.id = h.approver_id
      where h.status <> 'cancelled' and (h.status = 'open' or h.approved_at > now() - interval '120 days')), '[]'::jsonb));
end $$;

create or replace function public.cms_item_photo(p_item uuid, p_kind text, p_event bigint default null)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare i public.cms_items; em public.employee_master;
begin
  select * into i from public.cms_items where id = p_item;
  if i.id is null then raise exception 'Item not found.'; end if;
  select * into em from public.employee_master where id = i.person_id;
  if i.person_id is distinct from private.cms_me() and not private.cms_can_company('assets', 'V', private.cms_canon(em.company_code)) then raise exception 'Not allowed.'; end if;
  if p_event is not null then return (select photo from public.cms_item_events where id = p_event and item_id = i.id); end if;
  return case p_kind when 'issue' then i.issue_photo when 'confirm' then i.confirm_photo when 'return' then i.return_photo end;
end $$;

-- issue items to a person (one or several)
create or replace function public.cms_item_issue(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; t public.cms_item_types; v uuid;
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('assets', 'E', private.cms_canon(em.company_code));
  select * into t from public.cms_item_types where code = p->>'type' and is_active;
  if t.code is null then raise exception 'Choose the item type.'; end if;
  if t.code = 'OTHER' and nullif(btrim(p->>'description'), '') is null then raise exception 'Describe the item.'; end if;
  insert into public.cms_items (person_id, type_code, description, asset_tag, quantity, condition, issued_on, issued_by, issue_note, issue_photo, replaces_id)
  values (em.id, t.code, nullif(btrim(p->>'description'), ''), nullif(btrim(p->>'asset_tag'), ''), coalesce(nullif(p->>'quantity', '')::int, 1),
          coalesce(nullif(btrim(p->>'condition'), ''), 'Good'), coalesce(nullif(p->>'issued_on', '')::date, (now() at time zone 'Asia/Kuala_Lumpur')::date),
          auth.uid(), nullif(btrim(p->>'note'), ''), private.cms_photo_ok(p->>'photo'), nullif(p->>'replaces_id', '')::uuid)
  returning id into v;
  perform private.cms_item_log(v, 'issued', p->>'note', p->>'photo', jsonb_build_object('quantity', coalesce(nullif(p->>'quantity', '')::int, 1)));
  perform private.cms_log('item.issued', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || t.label || coalesce(' · ' || nullif(btrim(p->>'description'), ''), '') || ' issued', jsonb_build_object('item_id', v));
  return v;
end $$;

-- everything else HR / Admin does to an item
create or replace function public.cms_item_action(p_item uuid, p_action text, p jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.cms_items; em public.employee_master; t public.cms_item_types; v uuid := p_item; to_em public.employee_master; d date;
begin
  select * into i from public.cms_items where id = p_item for update;
  if i.id is null then raise exception 'Item not found.'; end if;
  select * into em from public.employee_master where id = i.person_id;
  select * into t from public.cms_item_types where code = i.type_code;
  perform private.cms_require('assets', 'E', private.cms_canon(em.company_code));
  d := coalesce(nullif(p->>'date', '')::date, (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if p_action = 'return' then
    if i.status not in ('issued','held') then raise exception 'This item is not with the person.'; end if;
    update public.cms_items set status = 'returned', returned_on = d, return_condition = coalesce(nullif(btrim(p->>'condition'), ''), 'Good'),
           return_note = nullif(btrim(p->>'note'), ''), return_photo = private.cms_photo_ok(p->>'photo'), received_by = auth.uid(),
           received_by_name = coalesce(nullif(btrim(p->>'received_by'), ''), private.cms_my_name()), return_confirmed_at = null, updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'returned', p->>'note', p->>'photo', jsonb_build_object('condition', p->>'condition', 'received_by', coalesce(nullif(btrim(p->>'received_by'), ''), private.cms_my_name())));
  elsif p_action in ('lost','damaged') then
    if i.status not in ('issued','held') then raise exception 'This item is not with the person.'; end if;
    if nullif(btrim(p->>'note'), '') is null then raise exception 'Say what happened.'; end if;
    update public.cms_items set status = p_action, returned_on = d, return_note = btrim(p->>'note'), return_photo = private.cms_photo_ok(p->>'photo'), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, p_action, p->>'note', p->>'photo', jsonb_build_object('deduction_ref', p->>'deduction_ref'));
  elsif p_action = 'replace' then
    -- the old one comes back (or is lost / damaged) and a new one is issued in its place
    if i.status not in ('issued','held') then raise exception 'This item is not with the person.'; end if;
    update public.cms_items set status = coalesce(nullif(p->>'old_status', ''), 'returned'), returned_on = d, return_note = coalesce(nullif(btrim(p->>'note'), ''), 'Replaced'),
           received_by = auth.uid(), received_by_name = private.cms_my_name(), updated_at = now() where id = i.id;
    insert into public.cms_items (person_id, type_code, description, asset_tag, quantity, condition, issued_on, issued_by, issue_note, issue_photo, replaces_id)
    values (i.person_id, i.type_code, coalesce(nullif(btrim(p->>'description'), ''), i.description), nullif(btrim(p->>'asset_tag'), ''), coalesce(nullif(p->>'quantity', '')::int, i.quantity),
            'Good', d, auth.uid(), nullif(btrim(p->>'note'), ''), private.cms_photo_ok(p->>'photo'), i.id) returning id into v;
    update public.cms_items set replaced_by_id = v where id = i.id;
    perform private.cms_item_log(i.id, 'replaced', p->>'note', null, jsonb_build_object('new_item', v));
    perform private.cms_item_log(v, 'issued', coalesce(nullif(btrim(p->>'note'), ''), 'Replacement'), p->>'photo', jsonb_build_object('replaces', i.id));
  elsif p_action = 'renew' then
    perform private.cms_item_log(i.id, 'renewed', p->>'note', p->>'photo', '{}'::jsonb);
    update public.cms_items set updated_at = now(), condition = coalesce(nullif(btrim(p->>'condition'), ''), condition) where id = i.id;
  elsif p_action = 'transfer' then
    if i.status not in ('issued','held') then raise exception 'This item is not with the person.'; end if;
    select * into to_em from public.employee_master where id = (p->>'to_person')::uuid;
    if to_em.id is null or to_em.id = i.person_id then raise exception 'Choose who receives the item.'; end if;
    perform private.cms_require('assets', 'E', private.cms_canon(to_em.company_code));
    update public.cms_items set status = 'transferred', returned_on = d, return_note = 'Moved to ' || to_em.employee_name, received_by = auth.uid(), received_by_name = private.cms_my_name(), updated_at = now() where id = i.id;
    insert into public.cms_items (person_id, type_code, description, asset_tag, quantity, condition, issued_on, issued_by, issue_note, replaces_id)
    values (to_em.id, i.type_code, i.description, i.asset_tag, i.quantity, i.condition, d, auth.uid(), coalesce(nullif(btrim(p->>'note'), ''), 'Moved from ' || em.employee_name), i.id) returning id into v;
    update public.cms_items set replaced_by_id = v where id = i.id;
    perform private.cms_item_log(i.id, 'transferred', p->>'note', null, jsonb_build_object('to', to_em.employee_name, 'new_item', v));
    perform private.cms_item_log(v, 'issued', 'Moved from ' || em.employee_name, null, jsonb_build_object('from_item', i.id));
  elsif p_action = 'credential' then
    if not t.is_credential then raise exception 'Only accounts have passwords.'; end if;
    if coalesce(p->>'note', '') ~* '(password|pwd|pass)\s*[:=]' then raise exception 'Do not type the password here: only record that it was changed.'; end if;
    update public.cms_items set credential_changed_at = now(), credential_changed_by = auth.uid(), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'credential_changed', coalesce(nullif(btrim(p->>'note'), ''), 'Password changed / reset'), null, jsonb_build_object('who', p->>'who'));
  elsif p_action = 'note' then
    if nullif(btrim(p->>'note'), '') is null then raise exception 'Write the note.'; end if;
    perform private.cms_item_log(i.id, 'note', p->>'note', p->>'photo', '{}'::jsonb);
  elsif p_action = 'edit' then
    update public.cms_items set description = coalesce(nullif(btrim(p->>'description'), ''), description), asset_tag = nullif(btrim(coalesce(p->>'asset_tag', asset_tag)), ''),
           quantity = coalesce(nullif(p->>'quantity', '')::int, quantity), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'edited', p->>'note', null, p - 'photo');
  elsif p_action = 'write_off' then
    if nullif(btrim(p->>'note'), '') is null then raise exception 'Give the reason.'; end if;
    update public.cms_items set status = 'written_off', returned_on = d, return_note = btrim(p->>'note'), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'written_off', p->>'note', null, '{}'::jsonb);
  else raise exception 'Unknown action %', p_action;
  end if;
  perform private.cms_log('item.' || p_action, 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || t.label || coalesce(' · ' || i.description, '') || ' — ' || p_action, jsonb_build_object('item_id', i.id, 'new_item', nullif(v, i.id)));
  return v;
end $$;

create or replace function public.cms_item_type_save(p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c text := upper(regexp_replace(coalesce(nullif(p->>'code', ''), p->>'label'), '[^A-Za-z0-9]+', '_', 'g'));
begin
  perform private.cms_require('assets', 'A');
  if nullif(btrim(p->>'label'), '') is null then raise exception 'Name the item type.'; end if;
  insert into public.cms_item_types (code, label, category, must_return, is_credential, replacement_cost, custodian, is_active, sort_order)
  values (left(c, 30), btrim(p->>'label'), coalesce(nullif(p->>'category', ''), 'other'), coalesce((p->>'must_return')::boolean, true), coalesce((p->>'is_credential')::boolean, false),
          nullif(p->>'replacement_cost', '')::numeric, nullif(btrim(p->>'custodian'), ''), coalesce((p->>'is_active')::boolean, true), coalesce(nullif(p->>'sort_order', '')::int, 150))
  on conflict (code) do update set label = excluded.label, category = excluded.category, must_return = excluded.must_return, is_credential = excluded.is_credential,
     replacement_cost = excluded.replacement_cost, custodian = excluded.custodian, is_active = excluded.is_active;
  perform private.cms_log('item_type.saved', 'cms_item_types', left(c, 30), null, 'Item type ' || btrim(p->>'label') || ' saved', p);
end $$;

-- hand-over: open by hand, change deadline / approver / notes, approve, cancel
create or replace function public.cms_handover_save(p_person uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; h uuid;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('assets', 'E', private.cms_canon(em.company_code));
  h := private.cms_open_handover(em.id, nullif(p->>'deadline', '')::date, coalesce(nullif(btrim(p->>'reason'), ''), 'Opened by HR'));
  update public.cms_handovers set deadline = coalesce(nullif(p->>'deadline', '')::date, deadline),
         approver_id = case when p ? 'approver_id' then nullif(p->>'approver_id', '')::uuid else approver_id end,
         notes = case when p ? 'notes' then nullif(btrim(p->>'notes'), '') else notes end, updated_at = now()
   where id = h;
  perform private.cms_log('handover.saved', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': hand-over updated', p);
  return h;
end $$;

create or replace function public.cms_handover_approve(p_id uuid, p_note text default null, p_cancel boolean default false)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare h public.cms_handovers; em public.employee_master; n int;
begin
  select * into h from public.cms_handovers where id = p_id for update;
  if h.id is null or h.status <> 'open' then raise exception 'Hand-over not found or already closed.'; end if;
  select * into em from public.employee_master where id = h.person_id;
  if p_cancel then
    perform private.cms_require('assets', 'E', private.cms_canon(em.company_code));
    update public.cms_handovers set status = 'cancelled', approve_note = nullif(btrim(p_note), ''), updated_at = now() where id = h.id;
    update public.employee_master set clearance_status = null where id = em.id and clearance_status = 'pending';
    perform private.cms_log('handover.cancelled', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': hand-over cancelled', jsonb_build_object('note', p_note));
    return;
  end if;
  if not private.cms_can_approve_handover(h) then raise exception 'You cannot approve this hand-over.'; end if;
  select count(*) into n from public.cms_items where person_id = h.person_id and status in ('issued','held');
  if n > 0 and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception '% item(s) are still with % — record them as returned, lost or written off first, or give the reason for approving anyway.', n, em.employee_name;
  end if;
  update public.cms_handovers set status = 'approved', approved_at = now(), approved_by = auth.uid(), approved_by_name = private.cms_my_name(),
         approve_note = nullif(btrim(p_note), ''), updated_at = now() where id = h.id;
  update public.employee_master set clearance_status = 'cleared', updated_at = now() where id = em.id;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'handover_approved', coalesce(nullif(btrim(p_note), ''), 'Hand-over approved'), jsonb_build_object('handover_id', h.id, 'outstanding', n), auth.uid());
  perform private.cms_log('handover.approved', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': hand-over approved by ' || private.cms_my_name() || case when n > 0 then ' (' || n || ' item(s) not returned)' else '' end, jsonb_build_object('note', p_note));
end $$;

-- ------------------------------------------------------------------ staff: My Items
create or replace function public.cms_my_items()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('items'); me uuid := private.cms_me();
begin
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(private.cms_item_json(i) order by (i.status in ('issued','held')) desc, i.issued_on desc) from public.cms_items i where i.person_id = v), '[]'::jsonb),
    'handover', (select jsonb_build_object('id', h.id, 'deadline', h.deadline, 'notes', h.notes, 'approver', ap.employee_name, 'opened_at', h.opened_at)
                 from public.cms_handovers h left join public.employee_master ap on ap.id = h.approver_id where h.person_id = v and h.status = 'open'),
    -- hand-overs this person may approve (as approver or higher in the Reports-to line)
    'to_approve', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', em.employee_name, 'employee_id', em.employee_id, 'deadline', h.deadline,
          'outstanding', (select count(*) from public.cms_items i where i.person_id = h.person_id and i.status in ('issued','held')),
          'items', (select coalesce(jsonb_agg(jsonb_build_object('label', t.label, 'description', i.description, 'status', i.status, 'returned_on', i.returned_on)), '[]'::jsonb)
                    from public.cms_items i join public.cms_item_types t on t.code = i.type_code where i.person_id = h.person_id and (i.status in ('issued','held') or i.returned_on >= h.opened_at::date))))
      from public.cms_handovers h join public.employee_master em on em.id = h.person_id
      where h.status = 'open' and h.person_id <> me
        and (h.approver_id = me or exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
                 select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
               select 1 from up where id = me))), '[]'::jsonb));
end $$;

create or replace function public.cms_my_item_confirm(p_item uuid, p_note text default null, p_photo text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('items'); i public.cms_items;
begin
  select * into i from public.cms_items where id = p_item and person_id = v for update;
  if i.id is null then raise exception 'Item not found.'; end if;
  if i.status = 'issued' then
    update public.cms_items set status = 'held', confirmed_at = now(), confirm_note = nullif(btrim(p_note), ''), confirm_photo = private.cms_photo_ok(p_photo), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'confirmed', coalesce(nullif(btrim(p_note), ''), 'Received'), p_photo, '{}'::jsonb);
  elsif i.status in ('returned','transferred') and i.return_confirmed_at is null then
    update public.cms_items set return_confirmed_at = now(), updated_at = now() where id = i.id;
    perform private.cms_item_log(i.id, 'return_confirmed', coalesce(nullif(btrim(p_note), ''), 'Hand-over confirmed'), p_photo, '{}'::jsonb);
  else raise exception 'Nothing to confirm for this item.';
  end if;
end $$;

-- staff can report a problem (lost / damaged / not received): it is a note on the item for HR
create or replace function public.cms_my_item_report(p_item uuid, p_note text, p_photo text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('items');
begin
  if not exists (select 1 from public.cms_items where id = p_item and person_id = v) then raise exception 'Item not found.'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say what happened.'; end if;
  perform private.cms_item_log(p_item, 'reported', p_note, private.cms_photo_ok(p_photo), '{}'::jsonb);
end $$;

-- ------------------------------------------------------------------ reminders
create or replace function public.cms_items_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me();
begin
  return jsonb_build_object(
    'mine_to_confirm', case when me is not null and private.cms_self_on(me, 'items') then
        (select count(*) from public.cms_items where person_id = me and (status = 'issued' or (status in ('returned','transferred') and return_confirmed_at is null and returned_on > now() - interval '60 days'))) else 0 end,
    'my_handover', case when me is not null and private.cms_self_on(me, 'items') then (select deadline from public.cms_handovers where person_id = me and status = 'open') end,
    'to_approve', case when me is not null then (select count(*) from public.cms_handovers h join public.employee_master em on em.id = h.person_id
        where h.status = 'open' and h.person_id <> me and (h.approver_id = me or exists (with recursive up(id, depth) as (select em.reports_to_id, 0 union all
                 select m.reports_to_id, up.depth + 1 from public.employee_master m join up on m.id = up.id where m.reports_to_id is not null and up.depth < 50)
               select 1 from up where id = me))
          and not exists (select 1 from public.cms_items i where i.person_id = h.person_id and i.status in ('issued','held'))) else 0 end,
    'hr_unconfirmed', case when public.cms_can('assets', 'E') then (select count(*) from public.cms_items where status = 'issued' and created_at < now() - interval '3 days') else 0 end,
    'hr_handover_due', case when public.cms_can('assets', 'E') then (select count(*) from public.cms_handovers where status = 'open' and deadline <= (now() at time zone 'Asia/Kuala_Lumpur')::date + 7) else 0 end,
    'hr_handover_ready', case when public.cms_can('assets', 'E') then (select count(*) from public.cms_handovers h where status = 'open'
        and not exists (select 1 from public.cms_items i where i.person_id = h.person_id and i.status in ('issued','held'))) else 0 end);
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_items_admin()','cms_item_photo(uuid, text, bigint)','cms_item_issue(jsonb)','cms_item_action(uuid, text, jsonb)','cms_item_type_save(jsonb)',
    'cms_handover_save(uuid, jsonb)','cms_handover_approve(uuid, text, boolean)','cms_my_items()','cms_my_item_confirm(uuid, text, text)','cms_my_item_report(uuid, text, text)','cms_items_pending()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
