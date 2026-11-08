-- MyEden Group CMS V1.0 · v2026.11.08 · PRI-010 F1 — Purchasing & Petty Cash (new PRFAF), release 1 (CLC 8 Nov 2026)
-- Purchase Request (PR) → Finance review → approval by amount (≤ RM 1,000 Finance · above: a Director · above RM 5,000: both Directors;
-- nobody approves their own) → release from a company bank account (one server step, posted to the books) → purchaser acknowledges → purchasing.
-- Each purchaser keeps a petty-cash balance per company (no returns): the next request uses it first. Double-entry books (pr_journal / lines):
-- bank, petty cash (per purchaser and company) and expense accounts, each line tagged with company, department and event; posted entries cannot
-- be changed (corrections by reversal). Settlement, verification, statements, reports and year-end closing come in release 2.
-- Members: the "purchasing" permission (default: logins of active HQ / E8 staff; Admin adds more). Finance: "purchasing.finance". Directors: the
-- Director role. Settings: "purchasing.settings". Additive: new tables, functions, modules, permissions and a private file bucket.

create table if not exists public.pr_bank_accounts (
  id uuid primary key default gen_random_uuid(), company_code text not null, kind text not null default 'bank' check (kind in ('bank', 'cash')),
  bank_name text, account_name text not null, last4 text check (last4 is null or last4 ~ '^[0-9]{4}$'), notes text,
  is_active boolean not null default true, created_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.pr_categories (
  id uuid primary key default gen_random_uuid(), name text not null, sort_order int not null default 100, is_asset boolean not null default false,
  remark_required boolean not null default false, is_active boolean not null default true, created_at timestamptz not null default now());
create unique index if not exists uq_pr_categories_name on public.pr_categories (lower(name));
create table if not exists public.pr_events (
  id uuid primary key default gen_random_uuid(), company_code text not null, name text not null, budget numeric(12,2) not null default 0 check (budget >= 0),
  date_from date, date_to date, status text not null default 'proposed' check (status in ('proposed', 'active', 'closed', 'rejected')), notes text,
  proposed_by uuid, proposed_by_name text, decided_by uuid, decided_by_name text, decided_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.pr_requests (
  id uuid primary key default gen_random_uuid(), pr_no text not null unique, company_code text not null, department text, event_id uuid references public.pr_events(id),
  category_id uuid references public.pr_categories(id), purpose text not null default '', justification text, required_by date,
  urgency text not null default 'normal' check (urgency in ('normal', 'urgent')),
  pay_type text not null default 'advance' check (pay_type in ('advance', 'supplier', 'reimburse')), supplier_name text, supplier_details text,
  requester_uid uuid not null, requester_name text not null, status text not null default 'draft'
    check (status in ('draft', 'finance', 'directors', 'approved', 'released', 'purchasing', 'settlement', 'closed', 'returned', 'disapproved', 'cancelled')),
  est_total numeric(12,2) not null default 0, approved_amount numeric(12,2), level text check (level in ('finance', 'director', 'both')),
  balance_used numeric(12,2) not null default 0, release_amount numeric(12,2) not null default 0, quotes jsonb not null default '[]'::jsonb,
  reviewed_by uuid, reviewed_by_name text, reviewed_at timestamptz, approvals jsonb not null default '[]'::jsonb,
  return_reason text, disapprove_reason text,
  release_entry_id uuid, released_amount numeric(12,2), release_bank_id uuid references public.pr_bank_accounts(id), release_date date, release_ref text,
  release_to text, release_slip text, released_by uuid, released_by_name text, released_at timestamptz,
  acknowledged_at timestamptz, settle_due date, settled_at timestamptz, closed_at timestamptz, submitted_at timestamptz,
  log jsonb not null default '[]'::jsonb, deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists ix_pr_requests_requester on public.pr_requests (requester_uid);
create index if not exists ix_pr_requests_status on public.pr_requests (status) where deleted_at is null;
create table if not exists public.pr_items (
  id uuid primary key default gen_random_uuid(), request_id uuid not null references public.pr_requests(id) on delete cascade, sort_order int not null default 0,
  description text not null default '', supplier text, qty numeric(12,2) not null default 1, est_unit numeric(12,2) not null default 0,
  est_total numeric(12,2) not null default 0, link text, photo_path text, category_id uuid references public.pr_categories(id),
  act_qty numeric(12,2), act_unit numeric(12,2), act_total numeric(12,2), receipt_no text, receipt_path text, no_receipt_reason text,
  verify_status text check (verify_status in ('accepted', 'queried')), verify_note text);
create index if not exists ix_pr_items_request on public.pr_items (request_id);
create sequence if not exists public.pr_journal_seq;
create table if not exists public.pr_journal (
  id uuid primary key default gen_random_uuid(), entry_no text not null unique, entry_date date not null,
  kind text not null check (kind in ('release', 'purchase', 'reimburse', 'return', 'adjust', 'reversal', 'opening', 'closing')),
  request_id uuid references public.pr_requests(id), memo text, reverses uuid references public.pr_journal(id),
  posted_by uuid, posted_by_name text, posted_at timestamptz not null default now());
create table if not exists public.pr_journal_lines (
  id uuid primary key default gen_random_uuid(), entry_id uuid not null references public.pr_journal(id), line_no int not null,
  account_kind text not null check (account_kind in ('bank', 'float', 'expense')), company_code text not null,
  bank_account_id uuid references public.pr_bank_accounts(id), holder_uid uuid, holder_name text, category_id uuid references public.pr_categories(id),
  department text, event_id uuid references public.pr_events(id),
  debit numeric(12,2) not null default 0 check (debit >= 0), credit numeric(12,2) not null default 0 check (credit >= 0), memo text,
  check (debit = 0 or credit = 0),
  check ((account_kind = 'bank' and bank_account_id is not null) or (account_kind = 'float' and holder_uid is not null) or (account_kind = 'expense' and category_id is not null)));
create index if not exists ix_pr_lines_entry on public.pr_journal_lines (entry_id);
create index if not exists ix_pr_lines_float on public.pr_journal_lines (holder_uid, company_code) where account_kind = 'float';

do $m$ declare t text; begin
  foreach t in array array['pr_bank_accounts', 'pr_categories', 'pr_events', 'pr_requests', 'pr_items', 'pr_journal', 'pr_journal_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $m$;
revoke all on sequence public.pr_journal_seq from anon, authenticated;

-- posted entries are permanent: corrections are reversal entries
create or replace function private.pr_journal_locked() returns trigger language plpgsql as $f$
begin raise exception 'Posted entries in the books cannot be changed or removed. Post a reversal instead.'; end $f$;
do $m$ begin
  if not exists (select 1 from pg_trigger where tgname = 'pr_journal_no_change') then
    create trigger pr_journal_no_change before update or delete on public.pr_journal for each row execute function private.pr_journal_locked(); end if;
  if not exists (select 1 from pg_trigger where tgname = 'pr_journal_lines_no_change') then
    create trigger pr_journal_lines_no_change before update or delete on public.pr_journal_lines for each row execute function private.pr_journal_locked(); end if;
end $m$;

insert into public.cms_modules (code, label, grp, phase, sort_order, kind, acts, description, act_labels) values
  ('purchasing', 'Purchase Requests', 'Forms & Claims', 4, 44, 'section', 'VCX', 'Purchase requests and petty cash (new PRFAF): make requests, events and budgets', '{"C":"Make purchase requests","X":"Export"}'),
  ('purchasing.finance', 'Purchasing: Finance', 'Forms & Claims', 4, 1044, 'special', 'VE', 'Review, approve up to the Finance limit, release funds, see the books', '{"V":"See the books and all requests","E":"Review, approve, release, post"}'),
  ('purchasing.settings', 'Purchasing: settings', 'Forms & Claims', 4, 1045, 'special', 'VE', 'Bank accounts, categories, approval limits, members, events', '{"E":"Change purchasing settings and members"}')
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('admin', 'purchasing', 'VCX'), ('admin', 'purchasing.finance', 'V'), ('admin', 'purchasing.settings', 'VE'),
  ('finance', 'purchasing', 'VC'), ('finance', 'purchasing.finance', 'VE'),
  ('director', 'purchasing', 'VC'), ('director', 'purchasing.finance', 'V')
on conflict (role_code, module_code) do nothing;
-- members by default: logins of active Admin department (HQ / E8) staff
insert into public.cms_user_permissions (user_id, module_code, actions, note, granted_at)
select distinct l.user_id, 'purchasing', 'VC', 'Admin department (HQ) — default purchasing member', now()
  from public.cms_user_links l join public.employee_master e on e.id = l.employee_master_id
 where e.employment_status = 'active' and upper(coalesce(e.department, '')) in ('HQ', 'E8')
on conflict do nothing;

insert into public.cms_settings (key, value) values ('pr_settings',
  '{"finance_limit": 1000, "dual_limit": 5000, "tolerance_pct": 10, "quote1": 1000, "quote3": 5000, "settle_days": 7}'::jsonb) on conflict (key) do nothing;

insert into public.pr_categories (name, sort_order, is_asset, remark_required) values
  ('Teaching & learning materials', 10, false, false), ('Stationery & printing', 20, false, false), ('Office supplies', 30, false, false),
  ('Cleaning & hygiene', 40, false, false), ('Children''s food & snacks', 50, false, false), ('Refreshments (staff & guests)', 60, false, false),
  ('Kitchen & pantry', 70, false, false), ('Repairs & maintenance', 80, false, false), ('Small equipment & furniture', 90, false, false),
  ('Fixed assets', 100, true, false), ('IT, software & subscriptions', 110, false, false), ('Utilities & telco', 120, false, false),
  ('Transport, fuel, toll & parking', 130, false, false), ('Postage & courier', 140, false, false), ('Events & celebrations', 150, false, false),
  ('Gifts, prizes & door gifts', 160, false, false), ('Marketing & advertising', 170, false, false), ('Uniforms & merchandise', 180, false, false),
  ('Health, safety & first aid', 190, false, false), ('Licences, permits & government fees', 200, false, false), ('Staff welfare & training', 210, false, false),
  ('Miscellaneous', 990, false, true)
on conflict do nothing;

-- ---------------------------------------------------------------- helpers
create or replace function private.pr_cfg() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select value from public.cms_settings where key = 'pr_settings'), '{}'::jsonb);
$$;
create or replace function private.pr_is_director(p_uid uuid default auth.uid()) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_user_roles where user_id = p_uid and role_code = 'director' and is_active);
$$;
create or replace function private.pr_user_can(p_uid uuid, p_module text, p_action text) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.cms_user_roles where user_id = p_uid and role_code = 'super_admin' and is_active)
      or exists (select 1 from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                 where ur.user_id = p_uid and ur.is_active and rp.module_code = p_module and strpos(rp.actions, upper(p_action)) > 0)
      or exists (select 1 from public.cms_user_permissions up where up.user_id = p_uid and up.module_code = p_module and strpos(up.actions, upper(p_action)) > 0);
$$;
create or replace function private.pr_roles() returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('member', public.cms_can('purchasing', 'C'), 'finance', public.cms_can('purchasing.finance', 'E'),
    'books', public.cms_can('purchasing.finance', 'V'), 'director', private.pr_is_director(), 'settings', public.cms_can('purchasing.settings', 'E'));
$$;
create or replace function private.pr_float(p_uid uuid, p_co text) returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(debit - credit), 0) from public.pr_journal_lines where account_kind = 'float' and holder_uid = p_uid and company_code = p_co;
$$;
-- balance free to use: petty cash minus what open requests (approved → settlement) are already spending from it
create or replace function private.pr_available(p_uid uuid, p_co text, p_except uuid default null) returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select private.pr_float(p_uid, p_co) - coalesce((select sum(balance_used + coalesce(released_amount, 0)) from public.pr_requests
    where requester_uid = p_uid and company_code = p_co and pay_type = 'advance' and deleted_at is null and status in ('approved', 'released', 'purchasing', 'settlement')
      and id is distinct from p_except), 0);
$$;
create or replace function private.pr_level(p_amt numeric) returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_amt <= coalesce((private.pr_cfg()->>'finance_limit')::numeric, 1000) then 'finance'
              when p_amt <= coalesce((private.pr_cfg()->>'dual_limit')::numeric, 5000) then 'director' else 'both' end;
$$;
create or replace function private.pr_can_see(r public.pr_requests) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select r.requester_uid = auth.uid() or public.cms_can('purchasing.finance', 'V') or private.pr_is_director() or public.cms_can('purchasing.settings', 'E');
$$;
create or replace function private.pr_log(p_id uuid, p_what text, p_note text default null) returns void language sql security definer set search_path = public, pg_temp as $$
  update public.pr_requests set log = log || jsonb_build_array(jsonb_build_object('at', now(), 'by', private.cms_user_name(auth.uid()), 'what', p_what, 'note', p_note)), updated_at = now() where id = p_id;
$$;
-- post one balanced entry: lines [{account_kind, company_code, bank_account_id?, holder_uid?, holder_name?, category_id?, department?, event_id?, debit, credit, memo?}]
create or replace function private.pr_post(p_kind text, p_date date, p_request uuid, p_memo text, p_lines jsonb, p_reverses uuid default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid; dr numeric; cr numeric; ln jsonb; n int := 0;
begin
  select coalesce(sum(round(coalesce((x->>'debit')::numeric, 0), 2)), 0), coalesce(sum(round(coalesce((x->>'credit')::numeric, 0), 2)), 0) into dr, cr from jsonb_array_elements(p_lines) x;
  if dr <> cr or dr <= 0 then raise exception 'The entry does not balance (debit % · credit %).', dr, cr; end if;
  insert into public.pr_journal (entry_no, entry_date, kind, request_id, memo, reverses, posted_by, posted_by_name)
  values ('JV-' || to_char(p_date, 'YYYYMM') || '-' || lpad(nextval('public.pr_journal_seq')::text, 5, '0'), p_date, p_kind, p_request, p_memo, p_reverses, auth.uid(), private.cms_user_name(auth.uid()))
  returning id into v;
  for ln in select x from jsonb_array_elements(p_lines) x loop
    n := n + 1;
    insert into public.pr_journal_lines (entry_id, line_no, account_kind, company_code, bank_account_id, holder_uid, holder_name, category_id, department, event_id, debit, credit, memo)
    values (v, n, ln->>'account_kind', ln->>'company_code', nullif(ln->>'bank_account_id', '')::uuid, nullif(ln->>'holder_uid', '')::uuid, ln->>'holder_name',
            nullif(ln->>'category_id', '')::uuid, nullif(ln->>'department', ''), nullif(ln->>'event_id', '')::uuid,
            round(coalesce((ln->>'debit')::numeric, 0), 2), round(coalesce((ln->>'credit')::numeric, 0), 2), ln->>'memo');
  end loop;
  return v;
end $f$;
do $m$ declare f text; begin
  foreach f in array array['private.pr_cfg()', 'private.pr_user_can(uuid,text,text)', 'private.pr_is_director(uuid)', 'private.pr_roles()', 'private.pr_float(uuid,text)', 'private.pr_available(uuid,text,uuid)', 'private.pr_level(numeric)',
    'private.pr_can_see(public.pr_requests)', 'private.pr_log(uuid,text,text)', 'private.pr_post(text,date,uuid,text,jsonb,uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
end $m$;

-- ---------------------------------------------------------------- context, settings, members
create or replace function public.cms_pr_context()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare r jsonb := private.pr_roles();
begin
  if not ((r->>'member')::boolean or (r->>'books')::boolean or (r->>'director')::boolean or (r->>'settings')::boolean) then raise exception 'Purchasing is not open to you. Ask Admin.'; end if;
  return jsonb_build_object('roles', r, 'settings', private.pr_cfg(), 'me', auth.uid(), 'my_name', private.cms_user_name(auth.uid()),
    'my_department', (select department from public.employee_master where id = private.cms_me_person()),
    'companies', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort_order) from public.cms_companies where is_active),
    'departments', (select jsonb_agg(d order by d) from (select distinct upper(btrim(department)) d from public.employee_master where employment_status = 'active' and department ~ '^(E[0-9]+\+?|HQ)$' union select 'HQ') z),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'is_asset', is_asset, 'remark_required', remark_required, 'active', is_active) order by sort_order, name) from public.pr_categories), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'company', e.company_code, 'name', e.name, 'budget', e.budget, 'date_from', e.date_from, 'date_to', e.date_to, 'status', e.status,
        'committed', (select coalesce(sum(coalesce(q.approved_amount, q.est_total)), 0) from public.pr_requests q where q.event_id = e.id and q.deleted_at is null and q.status not in ('draft', 'returned', 'disapproved', 'cancelled'))) order by e.date_from desc nulls last, e.name)
      from public.pr_events e where e.status in ('active', 'proposed', 'closed')), '[]'::jsonb),
    'floats', coalesce((select jsonb_object_agg(company_code, bal) from (select company_code, sum(debit - credit) bal from public.pr_journal_lines where account_kind = 'float' and holder_uid = auth.uid() group by 1) z), '{}'::jsonb),
    'available', coalesce((select jsonb_object_agg(c.code, private.pr_available(auth.uid(), c.code)) from public.cms_companies c where c.is_active), '{}'::jsonb),
    'banks', case when (r->>'books')::boolean or (r->>'settings')::boolean then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'company', company_code, 'kind', kind, 'bank', bank_name, 'name', account_name, 'last4', last4, 'notes', notes, 'active', is_active) order by company_code, bank_name, account_name) from public.pr_bank_accounts), '[]'::jsonb) end,
    'directors', (select coalesce(jsonb_agg(private.cms_user_name(user_id)), '[]'::jsonb) from public.cms_user_roles where role_code = 'director' and is_active));
end $f$;

create or replace function public.cms_pr_settings_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare v jsonb := private.pr_cfg(); k text;
begin
  if not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can change the purchasing settings.'; end if;
  foreach k in array array['finance_limit', 'dual_limit', 'tolerance_pct', 'quote1', 'quote3', 'settle_days'] loop
    if p ? k then
      if public.meg_forms_try_numeric(p->>k) is null or (p->>k)::numeric < 0 then raise exception 'Enter a number for %.', k; end if;
      v := v || jsonb_build_object(k, round((p->>k)::numeric, 2));
    end if;
  end loop;
  if (v->>'dual_limit')::numeric < (v->>'finance_limit')::numeric then raise exception 'The both-Directors limit must be above the Finance limit.'; end if;
  if (v->>'quote3')::numeric < (v->>'quote1')::numeric then raise exception 'The 3-quotation amount must be above the 1-quotation amount.'; end if;
  if (v->>'tolerance_pct')::numeric > 100 then raise exception 'The tolerance is a percentage (0 to 100).'; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by) values ('pr_settings', v, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('settings.purchasing', 'cms_settings', 'pr_settings', null, 'Purchasing settings changed', p);
  return v;
end $f$;

create or replace function public.cms_pr_members()
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $f$
begin
  if not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can see the purchasing members.'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('uid', u.uid, 'name', private.cms_user_name(u.uid), 'email', au.email,
        'member', private.pr_user_can(u.uid, 'purchasing', 'C'), 'finance', private.pr_user_can(u.uid, 'purchasing.finance', 'E'),
        'director', private.pr_is_director(u.uid), 'via_role', not exists (select 1 from public.cms_user_permissions p where p.user_id = u.uid and p.module_code like 'purchasing%' and p.actions <> ''),
        'department', (select e.department from public.cms_user_links l join public.employee_master e on e.id = l.employee_master_id where l.user_id = u.uid limit 1)) order by private.cms_user_name(u.uid))
      from (select distinct uid from (
              select user_id uid from public.cms_user_permissions where module_code in ('purchasing', 'purchasing.finance') and actions <> ''
              union select ur.user_id from public.cms_user_roles ur join public.cms_role_permissions rp on rp.role_code = ur.role_code
                where ur.is_active and rp.module_code in ('purchasing', 'purchasing.finance') and (strpos(rp.actions, 'C') > 0 or strpos(rp.actions, 'E') > 0)) z) u
      left join auth.users au on au.id = u.uid), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('uid', l.user_id, 'name', e.employee_name, 'department', e.department) order by e.employee_name)
      from public.cms_user_links l join public.employee_master e on e.id = l.employee_master_id where e.employment_status = 'active'), '[]'::jsonb));
end $f$;

-- p_role: 'member' | 'finance' | 'none'
create or replace function public.cms_pr_member_set(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can change the purchasing members.'; end if;
  if p_role not in ('member', 'finance', 'none') then raise exception 'Unknown role.'; end if;
  if not exists (select 1 from public.cms_user_links where user_id = p_user) then raise exception 'Only staff with a CMS login can be purchasing members.'; end if;
  insert into public.cms_user_permissions (user_id, module_code, actions, note, granted_by, granted_at)
  values (p_user, 'purchasing', case when p_role = 'none' then '' else 'VC' end, 'Purchasing member (set in Purchasing › Settings)', auth.uid(), now())
  on conflict (user_id, module_code) do update set actions = excluded.actions, granted_by = auth.uid(), granted_at = now(), note = excluded.note;
  insert into public.cms_user_permissions (user_id, module_code, actions, note, granted_by, granted_at)
  values (p_user, 'purchasing.finance', case when p_role = 'finance' then 'VE' else '' end, 'Purchasing Finance (set in Purchasing › Settings)', auth.uid(), now())
  on conflict (user_id, module_code) do update set actions = excluded.actions, granted_by = auth.uid(), granted_at = now(), note = excluded.note;
  perform private.cms_log('purchasing.member', 'cms_user_permissions', p_user::text, null, private.cms_user_name(p_user) || ' set as purchasing ' || p_role, jsonb_build_object('role', p_role));
end $f$;

create or replace function public.cms_pr_bank_save(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid := p_id;
begin
  if not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can change the bank accounts.'; end if;
  if not exists (select 1 from public.cms_companies where code = p->>'company') then raise exception 'Choose the company.'; end if;
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Enter the account name.'; end if;
  if coalesce(p->>'last4', '') <> '' and p->>'last4' !~ '^[0-9]{4}$' then raise exception 'Enter only the last 4 digits of the account number.'; end if;
  if v is null then
    insert into public.pr_bank_accounts (company_code, kind, bank_name, account_name, last4, notes, created_by)
    values (p->>'company', coalesce(nullif(p->>'kind', ''), 'bank'), nullif(btrim(p->>'bank'), ''), btrim(p->>'name'), nullif(p->>'last4', ''), nullif(btrim(p->>'notes'), ''), auth.uid()) returning id into v;
  else
    update public.pr_bank_accounts set company_code = p->>'company', kind = coalesce(nullif(p->>'kind', ''), kind), bank_name = nullif(btrim(p->>'bank'), ''), account_name = btrim(p->>'name'),
      last4 = nullif(p->>'last4', ''), notes = nullif(btrim(p->>'notes'), ''), is_active = coalesce((p->>'active')::boolean, is_active), updated_at = now() where id = v;
    if not found then raise exception 'Account not found.'; end if;
  end if;
  perform private.cms_log('purchasing.bank', 'pr_bank_accounts', v::text, p->>'company', 'Purchasing bank account ' || btrim(p->>'name') || case when p_id is null then ' added' else ' updated' end, p);
  return v;
end $f$;

create or replace function public.cms_pr_category_save(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid := p_id;
begin
  if not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can change the categories.'; end if;
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Enter the category name.'; end if;
  if v is null then
    insert into public.pr_categories (name, sort_order, is_asset, remark_required) values (btrim(p->>'name'), coalesce((p->>'sort')::int, 500), coalesce((p->>'is_asset')::boolean, false), coalesce((p->>'remark_required')::boolean, false)) returning id into v;
  else
    update public.pr_categories set name = btrim(p->>'name'), sort_order = coalesce((p->>'sort')::int, sort_order), is_asset = coalesce((p->>'is_asset')::boolean, is_asset),
      remark_required = coalesce((p->>'remark_required')::boolean, remark_required), is_active = coalesce((p->>'active')::boolean, is_active) where id = v;
    if not found then raise exception 'Category not found.'; end if;
  end if;
  return v;
end $f$;

-- events: members propose (status proposed); Admin (settings) or a Director creates / approves / rejects / closes and sets the budget
create or replace function public.cms_pr_event_save(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid := p_id; boss boolean := public.cms_can('purchasing.settings', 'E') or private.pr_is_director(); e public.pr_events; st text := coalesce(nullif(p->>'status', ''), case when boss then 'active' else 'proposed' end);
begin
  if not (boss or public.cms_can('purchasing', 'C')) then raise exception 'You cannot add events.'; end if;
  if not exists (select 1 from public.cms_companies where code = p->>'company') then raise exception 'Choose the company.'; end if;
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Enter the event name.'; end if;
  if public.meg_forms_try_numeric(p->>'budget') is null or (p->>'budget')::numeric < 0 then raise exception 'Enter the budget.'; end if;
  if not boss and st <> 'proposed' then raise exception 'Only Admin or a Director can approve an event.'; end if;
  if v is not null then
    select * into e from public.pr_events where id = v for update;
    if e.id is null then raise exception 'Event not found.'; end if;
    if not boss and not (e.proposed_by = auth.uid() and e.status = 'proposed') then raise exception 'Only Admin or a Director can change this event.'; end if;
  end if;
  if v is null then
    insert into public.pr_events (company_code, name, budget, date_from, date_to, status, notes, proposed_by, proposed_by_name, decided_by, decided_by_name, decided_at)
    values (p->>'company', btrim(p->>'name'), round((p->>'budget')::numeric, 2), nullif(p->>'date_from', '')::date, nullif(p->>'date_to', '')::date, st, nullif(btrim(p->>'notes'), ''),
            auth.uid(), private.cms_user_name(auth.uid()), case when st <> 'proposed' then auth.uid() end, case when st <> 'proposed' then private.cms_user_name(auth.uid()) end, case when st <> 'proposed' then now() end)
    returning id into v;
  else
    update public.pr_events set company_code = p->>'company', name = btrim(p->>'name'), budget = round((p->>'budget')::numeric, 2), date_from = nullif(p->>'date_from', '')::date,
      date_to = nullif(p->>'date_to', '')::date, notes = nullif(btrim(p->>'notes'), ''), status = st, updated_at = now(),
      decided_by = case when st <> e.status then auth.uid() else decided_by end, decided_by_name = case when st <> e.status then private.cms_user_name(auth.uid()) else decided_by_name end,
      decided_at = case when st <> e.status then now() else decided_at end where id = v;
  end if;
  perform private.cms_log('purchasing.event', 'pr_events', v::text, p->>'company', 'Event ' || btrim(p->>'name') || ' (' || st || ', budget RM ' || to_char(round((p->>'budget')::numeric, 2), 'FM999,999,990.00') || ')', p);
  return v;
end $f$;

-- ---------------------------------------------------------------- requests
create or replace function public.cms_pr_list(p_scope text default 'mine')
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare r jsonb := private.pr_roles(); me uuid := auth.uid();
begin
  if p_scope not in ('mine', 'queue', 'all') then raise exception 'Unknown list.'; end if;
  if p_scope = 'all' and not ((r->>'books')::boolean or (r->>'director')::boolean or (r->>'settings')::boolean) then raise exception 'You can see only your own requests.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'pr_no', q.pr_no, 'company', q.company_code, 'department', q.department, 'purpose', q.purpose,
      'event', (select name from public.pr_events where id = q.event_id), 'requester', q.requester_name, 'status', q.status, 'est_total', q.est_total,
      'approved_amount', q.approved_amount, 'release_amount', q.release_amount, 'level', q.level, 'pay_type', q.pay_type, 'urgency', q.urgency,
      'required_by', q.required_by, 'submitted_at', q.submitted_at, 'updated_at', q.updated_at, 'mine', q.requester_uid = me,
      'approvals', jsonb_array_length(q.approvals)) order by coalesce(q.submitted_at, q.created_at) desc)
    from public.pr_requests q
    where q.deleted_at is null and case p_scope
      when 'mine' then q.requester_uid = me
      when 'all' then q.status <> 'draft' or q.requester_uid = me
      else q.requester_uid <> me and (
           (q.status = 'finance' and (r->>'finance')::boolean)
        or (q.status = 'directors' and (r->>'director')::boolean and not exists (select 1 from jsonb_array_elements(q.approvals) a where (a->>'uid')::uuid = me and a->>'role' = 'director'))
        or (q.status = 'approved' and (r->>'finance')::boolean)) end), '[]'::jsonb);
end $f$;

create or replace function public.cms_pr_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; r jsonb := private.pr_roles(); me uuid := auth.uid(); mine boolean; signed boolean;
begin
  select * into q from public.pr_requests where id = p_id and deleted_at is null;
  if q.id is null or not private.pr_can_see(q) then raise exception 'Request not found.'; end if;
  mine := q.requester_uid = me;
  signed := exists (select 1 from jsonb_array_elements(q.approvals) a where (a->>'uid')::uuid = me and a->>'role' = 'director');
  return to_jsonb(q) - 'log' || jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'request_id' order by i.sort_order) from public.pr_items i where i.request_id = q.id), '[]'::jsonb),
    'event', (select jsonb_build_object('id', e.id, 'name', e.name, 'budget', e.budget, 'status', e.status, 'date_to', e.date_to,
        'committed', (select coalesce(sum(coalesce(x.approved_amount, x.est_total)), 0) from public.pr_requests x where x.event_id = e.id and x.deleted_at is null and x.status not in ('draft', 'returned', 'disapproved', 'cancelled'))) from public.pr_events e where e.id = q.event_id),
    'category', (select name from public.pr_categories where id = q.category_id),
    'company_name', (select name from public.cms_companies where code = q.company_code),
    'balance_now', private.pr_float(q.requester_uid, q.company_code), 'available', private.pr_available(q.requester_uid, q.company_code, q.id),
    'bank', (select jsonb_build_object('bank', bank_name, 'name', account_name, 'last4', last4) from public.pr_bank_accounts where id = q.release_bank_id),
    'requester_bank', case when (r->>'finance')::boolean and q.status = 'approved' then (select jsonb_build_object('bank', coalesce(lk.label, pv.bank_code), 'acct', pv.bank_account_no, 'holder', em.employee_name)
        from public.cms_user_links l join public.employee_master em on em.id = l.employee_master_id join public.eppd_employees ee on ee.employee_master_id = em.id
        join public.eppd_employee_private pv on pv.employee_id = ee.id left join public.eppd_lookups lk on lk.category = 'bank' and lk.code = pv.bank_code
       where l.user_id = q.requester_uid and nullif(btrim(pv.bank_account_no), '') is not null order by ee.id desc limit 1) end,
    'log', q.log, 'mine', mine,
    'can', jsonb_build_object(
      'edit', mine and q.status in ('draft', 'returned'),
      'cancel', (mine and q.status in ('draft', 'finance', 'directors', 'returned', 'approved')) or ((r->>'finance')::boolean and q.status = 'approved'),
      'review', not mine and q.status = 'finance' and (r->>'finance')::boolean,
      'approve', not mine and ((q.status = 'finance' and q.level = 'finance' and (r->>'finance')::boolean) or (q.status = 'directors' and (r->>'director')::boolean and not signed)),
      'release', q.status = 'approved' and (r->>'finance')::boolean and not mine,
      'acknowledge', mine and q.status = 'released'));
end $f$;

-- p: company, department, event_id, category_id, purpose, justification, required_by, urgency, pay_type, supplier_name, supplier_details, quotes [{path,name}],
--    items [{description, supplier, qty, est_unit, link, photo_path, category_id}]
create or replace function public.cms_pr_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; co text := p->>'company'; it jsonb; n int := 0; tot numeric := 0; qt numeric; un numeric; cfg jsonb := private.pr_cfg();
  v_no text; ev public.pr_events; nq int := jsonb_array_length(coalesce(p->'quotes', '[]'::jsonb)); my text := to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYYYMM');
begin
  if not public.cms_can('purchasing', 'C') then raise exception 'You are not a purchasing member. Ask Admin.'; end if;
  if p_id is not null then
    select * into q from public.pr_requests where id = p_id and deleted_at is null for update;
    if q.id is null then raise exception 'Request not found.'; end if;
    if q.requester_uid <> auth.uid() then raise exception 'Only the person who made this request can change it.'; end if;
    if q.status not in ('draft', 'returned') then raise exception 'This request has been sent and can no longer be changed.'; end if;
  end if;
  if not exists (select 1 from public.cms_companies where code = co and is_active) then raise exception 'Choose the company.'; end if;
  if nullif(p->>'event_id', '') is not null then
    select * into ev from public.pr_events where id = (p->>'event_id')::uuid;
    if ev.id is null or ev.status not in ('active', 'proposed') then raise exception 'The event is not open.'; end if;
    if ev.company_code <> co then raise exception 'The event belongs to another company.'; end if;
  end if;
  if coalesce(p->>'pay_type', 'advance') not in ('advance', 'supplier', 'reimburse') then raise exception 'Choose how it will be paid.'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'quotes', '[]'::jsonb)) x where coalesce(x->>'path', '') !~ ('^' || coalesce(p_id::text, '-') || '/')) then raise exception 'A quotation is not stored with this request.'; end if;
  if q.id is null then
    loop
      n := n + 1;
      v_no := co || '-PR-' || my || '-' || lpad(((select count(*) from public.pr_requests where pr_no like co || '-PR-' || my || '-%') + n)::text, 4, '0');
      exit when not exists (select 1 from public.pr_requests where pr_no = v_no);
    end loop;
    insert into public.pr_requests (pr_no, company_code, requester_uid, requester_name) values (v_no, co, auth.uid(), private.cms_user_name(auth.uid())) returning * into q;
  end if;
  delete from public.pr_items where request_id = q.id;
  n := 0;
  for it in select x from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) x loop
    n := n + 1;
    if n > 60 then raise exception 'At most 60 items in one request.'; end if;
    qt := round(coalesce(public.meg_forms_try_numeric(it->>'qty'), 0), 2); un := round(coalesce(public.meg_forms_try_numeric(it->>'est_unit'), 0), 2);
    if qt < 0 or un < 0 or qt * un > 1000000 then raise exception 'Item %: quantity or price is not valid.', n; end if;
    if coalesce(it->>'photo_path', '') <> '' and it->>'photo_path' !~ ('^' || q.id::text || '/') then raise exception 'Item %: the photo is not stored with this request.', n; end if;
    insert into public.pr_items (request_id, sort_order, description, supplier, qty, est_unit, est_total, link, photo_path, category_id)
    values (q.id, n, left(btrim(coalesce(it->>'description', '')), 300), nullif(left(btrim(coalesce(it->>'supplier', '')), 120), ''), qt, un, round(qt * un, 2),
            nullif(left(btrim(coalesce(it->>'link', '')), 500), ''), nullif(it->>'photo_path', ''), nullif(it->>'category_id', '')::uuid);
    tot := tot + round(qt * un, 2);
  end loop;
  update public.pr_requests set company_code = co, department = nullif(btrim(coalesce(p->>'department', '')), ''), event_id = nullif(p->>'event_id', '')::uuid,
    category_id = nullif(p->>'category_id', '')::uuid, purpose = left(btrim(coalesce(p->>'purpose', '')), 300), justification = nullif(left(btrim(coalesce(p->>'justification', '')), 1000), ''),
    required_by = nullif(p->>'required_by', '')::date, urgency = coalesce(nullif(p->>'urgency', ''), 'normal'), pay_type = coalesce(nullif(p->>'pay_type', ''), 'advance'),
    supplier_name = nullif(btrim(coalesce(p->>'supplier_name', '')), ''), supplier_details = nullif(btrim(coalesce(p->>'supplier_details', '')), ''),
    quotes = coalesce(p->'quotes', '[]'::jsonb), est_total = tot, level = private.pr_level(tot),
    pr_no = case when status = 'draft' and company_code <> co then co || substr(pr_no, position('-PR-' in pr_no)) else pr_no end, updated_at = now()
  where id = q.id returning * into q;
  if p_submit then
    if q.purpose = '' then raise exception 'Enter what the purchase is for.'; end if;
    if q.department is null then raise exception 'Choose the department.'; end if;
    if q.category_id is null then raise exception 'Choose the category.'; end if;
    if n = 0 then raise exception 'Add at least one item.'; end if;
    if exists (select 1 from public.pr_items where request_id = q.id and (description = '' or qty <= 0 or est_unit <= 0)) then raise exception 'Every item needs a description, quantity and estimated price.'; end if;
    if q.pay_type = 'supplier' and q.supplier_name is null then raise exception 'Enter the supplier to be paid.'; end if;
    if (select remark_required from public.pr_categories where id = q.category_id) and coalesce(q.justification, '') = '' then raise exception 'This category needs a remark: say what it is for.'; end if;
    if tot >= coalesce((cfg->>'quote3')::numeric, 5000) and nq < 3 then raise exception 'From RM % attach 3 quotations (now %).', to_char((cfg->>'quote3')::numeric, 'FM999,990'), nq;
    elsif tot >= coalesce((cfg->>'quote1')::numeric, 1000) and nq < 1 then raise exception 'From RM % attach a quotation.', to_char((cfg->>'quote1')::numeric, 'FM999,990'); end if;
    update public.pr_requests set status = 'finance', submitted_at = now(), return_reason = null, approvals = '[]'::jsonb, approved_amount = null where id = q.id returning * into q;
    perform private.pr_log(q.id, 'Submitted to Finance', 'RM ' || to_char(tot, 'FM999,999,990.00'));
    perform private.cms_log('purchasing.submitted', 'pr_requests', q.id::text, co, 'Purchase request ' || q.pr_no || ' submitted (RM ' || to_char(tot, 'FM999,999,990.00') || ')', jsonb_build_object('level', q.level));
  end if;
  return jsonb_build_object('id', q.id, 'pr_no', q.pr_no, 'status', q.status, 'est_total', q.est_total, 'level', q.level, 'balance', private.pr_available(q.requester_uid, co, q.id));
end $f$;

create or replace function private.pr_approved(p_id uuid, p_amount numeric) returns text
language plpgsql security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; bal numeric; rel numeric := 0; used numeric := 0; st text;
begin
  select * into q from public.pr_requests where id = p_id;
  bal := private.pr_available(q.requester_uid, q.company_code, q.id);
  if q.pay_type = 'advance' then used := greatest(0, least(bal, p_amount)); rel := greatest(0, p_amount - bal);
  elsif q.pay_type = 'supplier' then rel := p_amount; end if;
  st := case when rel > 0 then 'approved' else 'purchasing' end;
  update public.pr_requests set status = st, approved_amount = p_amount, balance_used = used, release_amount = rel,
    settle_due = case when st = 'purchasing' then greatest((now() at time zone 'Asia/Kuala_Lumpur')::date, coalesce((select date_to from public.pr_events where id = q.event_id), '1900-01-01'))
                      + coalesce((private.pr_cfg()->>'settle_days')::int, 7) end where id = p_id;
  return st;
end $f$;
revoke all on function private.pr_approved(uuid, numeric) from public, anon, authenticated;

-- actions: forward · approve {amount?, note?} · return {reason} · disapprove {reason} · release {bank_id, amount, date, ref, to, slip} · acknowledge · cancel {reason?} · discard
create or replace function public.cms_pr_act(p_id uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; r jsonb := private.pr_roles(); me uuid := auth.uid(); nm text := private.cms_user_name(auth.uid()); amt numeric; st text; ndir int;
  bk public.pr_bank_accounts; ent uuid; d date; mail text := null;
begin
  select * into q from public.pr_requests where id = p_id and deleted_at is null for update;
  if q.id is null or not private.pr_can_see(q) then raise exception 'Request not found.'; end if;
  if p_action in ('forward', 'approve', 'return', 'disapprove', 'release') and q.requester_uid = me then raise exception 'You cannot approve or release your own request.'; end if;
  case p_action
  when 'forward' then
    if q.status <> 'finance' or not (r->>'finance')::boolean then raise exception 'Only Finance can pass this request on.'; end if;
    if q.level = 'finance' then raise exception 'This amount is within the Finance limit: approve it.'; end if;
    update public.pr_requests set status = 'directors', reviewed_by = me, reviewed_by_name = nm, reviewed_at = now() where id = q.id;
    perform private.pr_log(q.id, 'Reviewed by Finance, sent to ' || case q.level when 'both' then 'both Directors' else 'a Director' end, nullif(btrim(coalesce(p->>'note', '')), ''));
    st := 'directors'; mail := 'forwarded';
  when 'approve' then
    amt := round(coalesce(public.meg_forms_try_numeric(p->>'amount'), coalesce(q.approved_amount, q.est_total)), 2);
    if amt <= 0 or amt > q.est_total then raise exception 'The approved amount must be above 0 and not more than the request (RM %).', to_char(q.est_total, 'FM999,999,990.00'); end if;
    if q.status = 'finance' then
      if not (r->>'finance')::boolean or q.level <> 'finance' then raise exception 'This request needs a Director''s approval.'; end if;
      update public.pr_requests set reviewed_by = me, reviewed_by_name = nm, reviewed_at = now(),
        approvals = approvals || jsonb_build_array(jsonb_build_object('uid', me, 'name', nm, 'role', 'finance', 'amount', amt, 'at', now(), 'note', nullif(btrim(coalesce(p->>'note', '')), ''))) where id = q.id;
      perform private.pr_log(q.id, 'Approved by Finance', 'RM ' || to_char(amt, 'FM999,999,990.00'));
      st := private.pr_approved(q.id, amt); mail := 'approved';
    elsif q.status = 'directors' then
      if not (r->>'director')::boolean then raise exception 'Only a Director can approve this request.'; end if;
      if exists (select 1 from jsonb_array_elements(q.approvals) a where (a->>'uid')::uuid = me and a->>'role' = 'director') then raise exception 'You have already approved this request.'; end if;
      update public.pr_requests set approved_amount = least(coalesce(approved_amount, amt), amt),
        approvals = approvals || jsonb_build_array(jsonb_build_object('uid', me, 'name', nm, 'role', 'director', 'amount', amt, 'at', now(), 'note', nullif(btrim(coalesce(p->>'note', '')), ''))) where id = q.id returning * into q;
      perform private.pr_log(q.id, 'Approved by Director ' || nm, 'RM ' || to_char(amt, 'FM999,999,990.00'));
      select count(*) into ndir from jsonb_array_elements(q.approvals) a where a->>'role' = 'director';
      if q.level = 'both' and private.pr_level(q.approved_amount) = 'both' and ndir < 2 then st := 'directors'; mail := 'second';
      else st := private.pr_approved(q.id, q.approved_amount); mail := 'approved'; end if;
    else raise exception 'This request is not waiting for approval.'; end if;
  when 'return', 'disapprove' then
    if not ((q.status = 'finance' and (r->>'finance')::boolean) or (q.status = 'directors' and (r->>'director')::boolean)) then raise exception 'This request is not with you.'; end if;
    if btrim(coalesce(p->>'reason', '')) = '' then raise exception 'Give the reason.'; end if;
    st := case p_action when 'return' then 'returned' else 'disapproved' end;
    update public.pr_requests set status = st, return_reason = case when st = 'returned' then btrim(p->>'reason') else return_reason end,
      disapprove_reason = case when st = 'disapproved' then btrim(p->>'reason') else disapprove_reason end where id = q.id;
    perform private.pr_log(q.id, case st when 'returned' then 'Returned for changes by ' else 'Disapproved by ' end || nm, btrim(p->>'reason'));
    mail := st;
  when 'release' then
    if q.status <> 'approved' or not (r->>'finance')::boolean then raise exception 'Only Finance can release funds for an approved request.'; end if;
    select * into bk from public.pr_bank_accounts where id = nullif(p->>'bank_id', '')::uuid and is_active;
    if bk.id is null then raise exception 'Choose the account the money is paid from.'; end if;
    if bk.company_code <> q.company_code then raise exception 'Pay from an account of % (the request''s company).', q.company_code; end if;
    amt := round(coalesce(public.meg_forms_try_numeric(p->>'amount'), q.release_amount), 2);
    if amt <= 0 then raise exception 'Enter the amount released.'; end if;
    if amt > q.approved_amount then raise exception 'You cannot release more than approved (RM %).', to_char(q.approved_amount, 'FM999,999,990.00'); end if;
    d := coalesce(nullif(p->>'date', '')::date, (now() at time zone 'Asia/Kuala_Lumpur')::date);
    if d > (now() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'The release date is in the future.'; end if;
    if btrim(coalesce(p->>'ref', '')) = '' and bk.kind = 'bank' then raise exception 'Enter the transfer reference.'; end if;
    if coalesce(p->>'slip', '') <> '' and p->>'slip' !~ ('^' || q.id::text || '/') then raise exception 'The transfer slip is not stored with this request.'; end if;
    if q.pay_type = 'supplier' then
      ent := private.pr_post('release', d, q.id, 'Paid to supplier ' || coalesce(q.supplier_name, '') || ' for ' || q.pr_no, jsonb_build_array(
        jsonb_build_object('account_kind', 'expense', 'company_code', q.company_code, 'category_id', q.category_id, 'department', q.department, 'event_id', q.event_id, 'debit', amt, 'memo', q.pr_no || ' · ' || q.purpose),
        jsonb_build_object('account_kind', 'bank', 'company_code', q.company_code, 'bank_account_id', bk.id, 'department', q.department, 'event_id', q.event_id, 'credit', amt, 'memo', coalesce(p->>'ref', ''))));
    else
      ent := private.pr_post('release', d, q.id, 'Funds released to ' || q.requester_name || ' for ' || q.pr_no, jsonb_build_array(
        jsonb_build_object('account_kind', 'float', 'company_code', q.company_code, 'holder_uid', q.requester_uid, 'holder_name', q.requester_name, 'department', q.department, 'event_id', q.event_id, 'debit', amt, 'memo', q.pr_no || ' · ' || q.purpose),
        jsonb_build_object('account_kind', 'bank', 'company_code', q.company_code, 'bank_account_id', bk.id, 'department', q.department, 'event_id', q.event_id, 'credit', amt, 'memo', coalesce(p->>'ref', ''))));
    end if;
    st := case when q.pay_type = 'supplier' then 'purchasing' else 'released' end;
    update public.pr_requests set status = st, release_entry_id = ent, released_amount = amt, release_bank_id = bk.id, release_date = d, release_ref = nullif(btrim(coalesce(p->>'ref', '')), ''),
      release_to = nullif(btrim(coalesce(p->>'to', '')), ''), release_slip = nullif(p->>'slip', ''), released_by = me, released_by_name = nm, released_at = now(),
      settle_due = case when st = 'purchasing' then greatest(d, coalesce((select date_to from public.pr_events where id = q.event_id), d)) + coalesce((private.pr_cfg()->>'settle_days')::int, 7) end
    where id = q.id;
    perform private.pr_log(q.id, 'Funds released by ' || nm, 'RM ' || to_char(amt, 'FM999,999,990.00') || ' from ' || coalesce(bk.bank_name || ' ', '') || bk.account_name || coalesce(' ••' || bk.last4, '') || coalesce(' · ref ' || nullif(btrim(coalesce(p->>'ref', '')), ''), ''));
    perform private.cms_log('purchasing.released', 'pr_requests', q.id::text, q.company_code, q.pr_no || ': RM ' || to_char(amt, 'FM999,999,990.00') || ' released', jsonb_build_object('entry', ent));
    mail := 'released';
  when 'acknowledge' then
    if q.status <> 'released' or q.requester_uid <> me then raise exception 'Only the purchaser can confirm receiving the money.'; end if;
    update public.pr_requests set status = 'purchasing', acknowledged_at = now(),
      settle_due = greatest((now() at time zone 'Asia/Kuala_Lumpur')::date, coalesce((select date_to from public.pr_events where id = q.event_id), '1900-01-01')) + coalesce((private.pr_cfg()->>'settle_days')::int, 7) where id = q.id;
    perform private.pr_log(q.id, 'Money received, confirmed by ' || nm, 'RM ' || to_char(q.released_amount, 'FM999,999,990.00'));
    st := 'purchasing';
  when 'cancel' then
    if not ((q.requester_uid = me and q.status in ('draft', 'finance', 'directors', 'returned', 'approved')) or ((r->>'finance')::boolean and q.status = 'approved')) then raise exception 'This request can no longer be cancelled.'; end if;
    update public.pr_requests set status = 'cancelled' where id = q.id;
    perform private.pr_log(q.id, 'Cancelled by ' || nm, nullif(btrim(coalesce(p->>'reason', '')), ''));
    st := 'cancelled';
  when 'discard' then
    if q.requester_uid <> me or q.status <> 'draft' then raise exception 'Only your own draft can be discarded.'; end if;
    update public.pr_requests set deleted_at = now() where id = q.id;
    st := 'discarded';
  else raise exception 'Unknown action.';
  end case;
  return jsonb_build_object('id', q.id, 'status', st, 'mail', mail);
end $f$;

-- ---------------------------------------------------------------- books
create or replace function public.cms_pr_books(p_company text default null, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare f date := coalesce(p_from, date_trunc('month', now() at time zone 'Asia/Kuala_Lumpur')::date); t date := coalesce(p_to, (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  if not (public.cms_can('purchasing.finance', 'V') or private.pr_is_director()) then raise exception 'Only Finance and the Directors can see the books.'; end if;
  return jsonb_build_object('from', f, 'to', t,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'no', j.entry_no, 'date', j.entry_date, 'kind', j.kind, 'memo', j.memo, 'by', j.posted_by_name, 'at', j.posted_at,
        'pr_no', (select pr_no from public.pr_requests where id = j.request_id), 'request_id', j.request_id,
        'lines', (select jsonb_agg(jsonb_build_object('kind', l.account_kind, 'company', l.company_code, 'account', case l.account_kind
              when 'bank' then (select coalesce(b.bank_name || ' ', '') || b.account_name || coalesce(' ••' || b.last4, '') from public.pr_bank_accounts b where b.id = l.bank_account_id)
              when 'float' then 'Petty cash – ' || l.holder_name else (select c.name from public.pr_categories c where c.id = l.category_id) end,
            'department', l.department, 'event', (select name from public.pr_events where id = l.event_id), 'debit', l.debit, 'credit', l.credit, 'memo', l.memo) order by l.line_no)
          from public.pr_journal_lines l where l.entry_id = j.id)) order by j.entry_date desc, j.entry_no desc)
      from public.pr_journal j where j.entry_date between f and t
        and (p_company is null or exists (select 1 from public.pr_journal_lines l where l.entry_id = j.id and l.company_code = p_company))), '[]'::jsonb),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'company', b.company_code, 'account', coalesce(b.bank_name || ' ', '') || b.account_name || coalesce(' ••' || b.last4, ''), 'active', b.is_active,
        'paid_out', (select coalesce(sum(l.credit - l.debit), 0) from public.pr_journal_lines l where l.bank_account_id = b.id)) order by b.company_code, b.account_name)
      from public.pr_bank_accounts b where p_company is null or b.company_code = p_company), '[]'::jsonb),
    'floats', coalesce((select jsonb_agg(jsonb_build_object('holder', z.holder_name, 'uid', z.holder_uid, 'company', z.company_code, 'balance', z.bal) order by z.holder_name, z.company_code)
      from (select holder_uid, max(holder_name) holder_name, company_code, sum(debit - credit) bal from public.pr_journal_lines where account_kind = 'float' and (p_company is null or company_code = p_company) group by 1, 3) z), '[]'::jsonb));
end $f$;

-- ---------------------------------------------------------------- emails (service role only) and files
create or replace function public.cms_pr_notify_info(p_id uuid, p_event text)
returns jsonb language sql stable security definer set search_path = public, auth, pg_temp as $$
  select jsonb_build_object('pr_no', q.pr_no, 'status', q.status, 'requester', q.requester_name, 'purpose', q.purpose, 'company', q.company_code,
    'est_total', q.est_total, 'approved_amount', q.approved_amount, 'released_amount', q.released_amount, 'release_amount', q.release_amount,
    'reason', coalesce(case when p_event = 'returned' then q.return_reason else q.disapprove_reason end, ''), 'level', q.level,
    'requester_email', (select email from auth.users where id = q.requester_uid),
    'finance', coalesce((select jsonb_agg(distinct au.email) from auth.users au where au.id <> q.requester_uid and private.pr_user_can(au.id, 'purchasing.finance', 'E')
        and not exists (select 1 from public.cms_user_roles x where x.user_id = au.id and x.role_code = 'super_admin' and x.is_active and not exists (select 1 from public.cms_user_roles y where y.user_id = au.id and y.role_code = 'finance' and y.is_active))), '[]'::jsonb),
    'directors', coalesce((select jsonb_agg(distinct au.email) from public.cms_user_roles ur join auth.users au on au.id = ur.user_id where ur.role_code = 'director' and ur.is_active and ur.user_id <> q.requester_uid
        and not exists (select 1 from jsonb_array_elements(q.approvals) a where (a->>'uid')::uuid = ur.user_id and a->>'role' = 'director')), '[]'::jsonb))
  from public.pr_requests q where q.id = p_id;
$$;
revoke all on function public.cms_pr_notify_info(uuid, text) from public, anon, authenticated;
grant execute on function public.cms_pr_notify_info(uuid, text) to service_role;

insert into storage.buckets (id, name, public) values ('pr-files', 'pr-files', false) on conflict (id) do nothing;
create or replace function public.cms_pr_file_ok(p_name text, p_write boolean)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.pr_requests q where q.id::text = split_part(p_name, '/', 1) and q.deleted_at is null and (
    (q.requester_uid = auth.uid() and (not p_write or q.status in ('draft', 'returned', 'purchasing', 'settlement')))
    or (public.cms_can('purchasing.finance', 'E') and (not p_write or q.status in ('approved', 'purchasing', 'settlement')))
    or (not p_write and (public.cms_can('purchasing.finance', 'V') or private.pr_is_director()))));
$$;
revoke all on function public.cms_pr_file_ok(text, boolean) from public, anon;
grant execute on function public.cms_pr_file_ok(text, boolean) to authenticated;
do $m$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'pr files read') then
    create policy "pr files read" on storage.objects for select to authenticated using (bucket_id = 'pr-files' and public.cms_pr_file_ok(name, false)); end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'pr files upload') then
    create policy "pr files upload" on storage.objects for insert to authenticated with check (bucket_id = 'pr-files' and public.cms_pr_file_ok(name, true)); end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'pr files remove') then
    create policy "pr files remove" on storage.objects for delete to authenticated using (bucket_id = 'pr-files' and public.cms_pr_file_ok(name, true)); end if;
end $m$;

do $m$ declare f text; begin
  foreach f in array array['public.cms_pr_context()', 'public.cms_pr_settings_set(jsonb)', 'public.cms_pr_members()', 'public.cms_pr_member_set(uuid,text)',
    'public.cms_pr_bank_save(uuid,jsonb)', 'public.cms_pr_category_save(uuid,jsonb)', 'public.cms_pr_event_save(uuid,jsonb)', 'public.cms_pr_list(text)',
    'public.cms_pr_get(uuid)', 'public.cms_pr_save(uuid,jsonb,boolean)', 'public.cms_pr_act(uuid,text,jsonb)', 'public.cms_pr_books(text,date,date)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $m$;
