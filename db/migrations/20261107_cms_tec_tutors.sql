-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 F1 — Tuition claims (TEC V2) in the CMS, and tutors (CLC 7 Nov 2026)
-- 1. Tutors: outside tutors who are not staff get a simple record (name, email, phone, company, courses, notes). Only an Admin (or Super Admin)
--    creates the record and sends the sign-in invite. A tutor's login has the "Tutor" role: it opens only My Tuition Claims.
--    Tutors are not staff: they do not appear in People, headcount or payroll, and their claims are not "unmatched claimants" in Sync Check.
-- 2. TEC V2 claims made in the CMS by tutors and by staff (with the Claims part): month, company (MyEden Group or MyEden Edu Hub), one page
--    per course with standards and students (class dates, replacement dates, monthly fee). Venue fee = the Admin-set % of the fee (5% to start,
--    changed in Action Center › Claim settings); net pay = fee − venue fee. Pages of the same course share one serial (<course code>-DDMMYYYYHHMM)
--    and the last page of a course carries the course total, exactly as the TEC-V2 app saves them, in the same tec_v2_submissions table.
--    Templates: the same saved student lists (tec_v2_templates) as the app. Submit → the PIC is emailed and marks it done (Action Center).
-- Additive: new tables, role, two permission modules, settings and functions; two functions patched to leave tutors out of "unmatched".

-- 1 · tutors -----------------------------------------------------------------------------------------------------------------------
create table if not exists public.cms_tutors (
  id uuid primary key default gen_random_uuid(),
  name text not null, email text, phone text,
  company_code text not null default 'MEG' check (company_code in ('MEG', 'MEH')),
  courses text[] not null default '{}', notes text, is_active boolean not null default true,
  created_by uuid, created_by_name text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists uq_cms_tutors_email on public.cms_tutors (lower(email)) where email is not null;
alter table public.cms_tutors enable row level security;
revoke all on public.cms_tutors from anon, authenticated;

create table if not exists public.cms_tutor_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tutor_id uuid not null unique references public.cms_tutors(id) on delete cascade,
  invited_at timestamptz not null default now(), invited_by uuid, sent_count int not null default 1
);
alter table public.cms_tutor_links enable row level security;
revoke all on public.cms_tutor_links from anon, authenticated;

insert into public.cms_modules (code, label, grp, phase, sort_order, kind, acts, description) values
  ('tutors', 'Tutors', 'People & Employment', 4, 14, 'section', 'VCE', 'Outside tutors who claim tuition (TEC): their records and sign-in invites'),
  ('tutor_self', 'My Tuition Claims (tutors)', 'Self-service', 4, 15, 'section', 'V', 'For tutor logins: make and follow their own tuition claims')
on conflict (code) do nothing;
insert into public.cms_roles (code, name, description, rank, phase, is_system)
values ('tutor', 'Tutor', 'Outside tutor: makes and follows their own tuition claims (TEC) only', 5, 4, true)
on conflict (code) do nothing;
insert into public.cms_role_permissions (role_code, module_code, actions) values
  ('tutor', 'tutor_self', 'V'), ('admin', 'tutors', 'VCE')
on conflict (role_code, module_code) do nothing;
update public.cms_modules set label = 'Action Center' where code = 'approvals' and label = 'Approvals & Workflows';

create or replace function private.cms_me_tutor() returns uuid language sql stable security definer set search_path = public, pg_temp as $$
  select l.tutor_id from public.cms_tutor_links l join public.cms_tutors t on t.id = l.tutor_id where l.user_id = auth.uid() and t.is_active limit 1;
$$;
revoke all on function private.cms_me_tutor() from public, anon, authenticated;
create or replace function private.cms_can_tutors() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.cms_is_super_admin() or public.cms_can('tutors', 'E');
$$;
revoke all on function private.cms_can_tutors() from public, anon, authenticated;

create or replace function public.cms_tutors_list()
returns jsonb language sql stable security definer set search_path = public, auth, pg_temp as $$
  select case when public.cms_is_super_admin() or public.cms_can('tutors', 'V') or public.cms_can('tec', 'C') then jsonb_build_object(
    'can_edit', private.cms_can_tutors(),
    'courses', coalesce((select jsonb_agg(name order by name) from public.tec_v2_courses), '[]'::jsonb),
    'tutors', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'email', t.email, 'phone', t.phone, 'company', t.company_code, 'courses', to_jsonb(t.courses),
        'notes', t.notes, 'active', t.is_active, 'login', u.email, 'signed_in', u.last_sign_in_at is not null, 'invited_at', l.invited_at, 'sent', l.sent_count,
        'claims', (select count(*) from public.tec_v2_submissions s where s.deleted_at is null and (s.submitted_by = l.user_id or private.cms_norm_name(s.teacher_name) = private.cms_norm_name(t.name))))
        order by t.is_active desc, t.name)
      from public.cms_tutors t left join public.cms_tutor_links l on l.tutor_id = t.id left join auth.users u on u.id = l.user_id), '[]'::jsonb)) end;
$$;
revoke all on function public.cms_tutors_list() from public, anon;
grant execute on function public.cms_tutors_list() to authenticated;

create or replace function public.cms_tutor_save(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid := p_id; nm text := upper(btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'))); em text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
begin
  if not private.cms_can_tutors() then raise exception 'Only an Admin can add or change tutors.'; end if;
  if nm = '' then raise exception 'Enter the tutor''s name.'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The email is not valid.'; end if;
  if coalesce(p->>'company', 'MEG') not in ('MEG', 'MEH') then raise exception 'Tutors claim under MyEden Group or MyEden Edu Hub.'; end if;
  if exists (select 1 from public.employee_master where private.cms_norm_name(employee_name) = private.cms_norm_name(nm) and employment_status <> 'former') then
    raise exception '% is on the staff list: staff claim tuition from My Claims, not as a tutor.', nm; end if;
  if v is null then
    insert into public.cms_tutors (name, email, phone, company_code, courses, notes, created_by, created_by_name)
    values (nm, em, nullif(btrim(p->>'phone'), ''), coalesce(p->>'company', 'MEG'), coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'courses', '[]'::jsonb)) x), '{}'),
            nullif(btrim(p->>'notes'), ''), auth.uid(), private.cms_user_name(auth.uid())) returning id into v;
  else
    update public.cms_tutors set name = nm, email = em, phone = nullif(btrim(p->>'phone'), ''), company_code = coalesce(p->>'company', company_code),
      courses = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'courses', '[]'::jsonb)) x), '{}'), notes = nullif(btrim(p->>'notes'), ''),
      is_active = coalesce((p->>'active')::boolean, is_active), updated_at = now() where id = v;
    if not found then raise exception 'Tutor not found.'; end if;
    -- a tutor switched off loses the Tutor role (the login and the claims stay)
    if coalesce((p->>'active')::boolean, true) = false then
      update public.cms_user_roles set is_active = false, revoked_by = auth.uid(), revoked_at = now()
       where role_code = 'tutor' and is_active and user_id in (select user_id from public.cms_tutor_links where tutor_id = v);
    end if;
  end if;
  perform private.cms_log('tutor.save', 'cms_tutors', v::text, coalesce(p->>'company', 'MEG'), 'Tutor ' || nm || case when p_id is null then ' added' else ' updated' end, p - 'notes');
  return v;
end $f$;
revoke all on function public.cms_tutor_save(uuid, jsonb) from public, anon;
grant execute on function public.cms_tutor_save(uuid, jsonb) to authenticated;

-- for the cms-invite function: the tutor's email and any login already using it
create or replace function public.cms_tutor_invite_prepare(p_tutor uuid)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $f$
declare t public.cms_tutors; uid uuid; used boolean; linked uuid;
begin
  if not private.cms_can_tutors() then raise exception 'Only an Admin can invite tutors.'; end if;
  select * into t from public.cms_tutors where id = p_tutor;
  if t.id is null or not t.is_active then raise exception 'Tutor not found or switched off.'; end if;
  if t.email is null then raise exception 'Add the tutor''s email first.'; end if;
  select u.id, u.last_sign_in_at is not null into uid, used from auth.users u where lower(u.email) = t.email limit 1;
  if uid is not null and exists (select 1 from public.cms_user_links where user_id = uid) then raise exception 'This email belongs to a staff login.'; end if;
  select user_id into linked from public.cms_tutor_links where tutor_id = t.id;
  if linked is not null and linked is distinct from uid then raise exception 'This tutor is already linked to another login.'; end if;
  return jsonb_build_object('tutor_id', t.id, 'name', t.name, 'email', t.email, 'user_id', uid, 'used', coalesce(used, false));
end $f$;
revoke all on function public.cms_tutor_invite_prepare(uuid) from public, anon;
grant execute on function public.cms_tutor_invite_prepare(uuid) to authenticated;

create or replace function public.cms_tutor_invite_finish(p_tutor uuid, p_user uuid, p_mode text)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $f$
declare t public.cms_tutors;
begin
  if not private.cms_can_tutors() then raise exception 'Only an Admin can invite tutors.'; end if;
  select * into t from public.cms_tutors where id = p_tutor;
  if t.id is null or not exists (select 1 from auth.users where id = p_user) then raise exception 'Tutor or login not found.'; end if;
  if exists (select 1 from public.cms_user_links where user_id = p_user) then raise exception 'This login belongs to a staff member.'; end if;
  insert into public.cms_tutor_links (user_id, tutor_id, invited_by) values (p_user, p_tutor, auth.uid())
  on conflict (user_id) do update set invited_at = now(), invited_by = auth.uid(), sent_count = public.cms_tutor_links.sent_count + case when p_mode = 'linked' then 0 else 1 end;
  insert into public.cms_user_roles (user_id, role_code, companies, is_active, note, granted_by, granted_at)
  values (p_user, 'tutor', array[t.company_code], true, 'Tutor invited to the CMS', auth.uid(), now())
  on conflict (user_id, role_code) do update set is_active = true, companies = excluded.companies, granted_by = excluded.granted_by, granted_at = now(), revoked_by = null, revoked_at = null;
  perform private.cms_log('tutor.invite', 'cms_tutors', t.id::text, t.company_code, 'Tutor ' || t.name || ' invited to the CMS (' || t.email || ')', jsonb_build_object('mode', p_mode));
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.cms_tutor_invite_finish(uuid, uuid, text) from public, anon;
grant execute on function public.cms_tutor_invite_finish(uuid, uuid, text) to authenticated;

-- tutors are not "unmatched claimants" (Sync Check › Match claimants and the nightly check)
do $m$ declare src text;
  o1 text := $o$where n is not null and not exists (select 1 from private.cms_claim_person(n) p where p.id is not null)$o$;
  n1 text := $n$where n is not null and not exists (select 1 from private.cms_claim_person(n) p where p.id is not null) and not exists (select 1 from public.cms_tutors tt where private.cms_norm_name(tt.name) = private.cms_norm_name(n))$n$;
  o2 text := $o$where not exists (select 1 from private.cms_claim_person(coalesce(r.claimant, '')) p where p.id is not null)) z;$o$;
  n2 text := $n$where not exists (select 1 from private.cms_claim_person(coalesce(r.claimant, '')) p where p.id is not null) and not exists (select 1 from public.cms_tutors tt where private.cms_norm_name(tt.name) = private.cms_norm_name(r.claimant))) z;$n$;
begin
  select pg_get_functiondef('public.cms_claimant_unmatched()'::regprocedure) into src;
  if position('cms_tutors' in src) = 0 then
    if position(o1 in src) = 0 then raise exception 'cms_claimant_unmatched has changed'; end if;
    execute replace(src, o1, n1);
  end if;
  select pg_get_functiondef('private.cms_sync_compute()'::regprocedure) into src;
  if position('cms_tutors' in src) = 0 then
    if position(o2 in src) = 0 then raise exception 'cms_sync_compute has changed'; end if;
    execute replace(src, o2, n2);
  end if;
end $m$;

-- 2 · TEC V2 claims ---------------------------------------------------------------------------------------------------------------
insert into public.cms_settings (key, value) values ('tec_settings', '{"venue_pct": 5}'::jsonb) on conflict (key) do nothing;

-- who claims: a tutor (their own login), a staff member (Claims part), or on behalf (TEC create; for a tutor or a staff member)
create or replace function private.cms_tec_who(p_person uuid, p_tutor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare me_t uuid := private.cms_me_tutor(); t public.cms_tutors; w jsonb;
begin
  if me_t is not null then
    if (p_person is not null) or (p_tutor is not null and p_tutor <> me_t) then raise exception 'Tutors make their own claims only.'; end if;
    select * into t from public.cms_tutors where id = me_t;
    return jsonb_build_object('kind', 'tutor', 'tutor_id', t.id, 'name', t.name, 'company', t.company_code, 'behalf', false, 'preparer', t.name);
  end if;
  if p_tutor is not null then
    if not public.cms_can('tec', 'C') then raise exception 'You cannot make tuition claims for tutors.'; end if;
    select * into t from public.cms_tutors where id = p_tutor and is_active;
    if t.id is null then raise exception 'Tutor not found.'; end if;
    return jsonb_build_object('kind', 'tutor', 'tutor_id', t.id, 'name', t.name, 'company', t.company_code, 'behalf', true,
      'preparer', coalesce((select employee_name from public.employee_master where id = private.cms_me_person()), private.cms_user_name(auth.uid())));
  end if;
  w := private.cms_claim_who(p_person, 'tec');
  return w || jsonb_build_object('kind', 'staff', 'company', case when w->>'company' in ('MEG', 'MEH') then w->>'company' else 'MEG' end);
end $f$;
revoke all on function private.cms_tec_who(uuid, uuid) from public, anon, authenticated;

create or replace function public.cms_tec_context(p_person uuid default null, p_tutor uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare w jsonb := private.cms_tec_who(p_person, p_tutor);
begin
  return w || jsonb_build_object(
    'companies', (select jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name) order by c.sort_order) from public.cms_companies c where c.code in ('MEG', 'MEH') and c.is_active),
    'courses', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'code', code) order by name) from public.tec_v2_courses), '[]'::jsonb),
    'standards', coalesce((select jsonb_agg(name order by sort_order, name) from public.tec_v2_standards), '[]'::jsonb),
    'venue_pct', coalesce((select (value->>'venue_pct')::numeric from public.cms_settings where key = 'tec_settings'), 5),
    'templates', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'pages', pages) order by updated_at desc nulls last) from public.tec_v2_templates where created_by = auth.uid()), '[]'::jsonb));
end $f$;
revoke all on function public.cms_tec_context(uuid, uuid) from public, anon;
grant execute on function public.cms_tec_context(uuid, uuid) to authenticated;

create or replace function public.cms_tec_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare s public.tec_v2_submissions;
begin
  select * into s from public.tec_v2_submissions where id = p_id and deleted_at is null;
  if s.id is null then raise exception 'Claim not found.'; end if;
  if s.submitted_by is distinct from auth.uid() and not public.cms_can('tec', 'V', private.cms_canon(s.company_code))
     and not (private.cms_me_tutor() is not null and private.cms_norm_name(s.teacher_name) = (select private.cms_norm_name(name) from public.cms_tutors where id = private.cms_me_tutor()))
     and not (private.cms_me_person() is not null and (select id from private.cms_claim_person(s.teacher_name)) = private.cms_me_person()) then raise exception 'Claim not found.'; end if;
  return to_jsonb(s) || jsonb_build_object('editable', s.status = 'draft' and s.submitted_by = auth.uid(),
    'total', (select coalesce(sum((x->>'subtotal')::numeric), 0) from jsonb_array_elements(s.pages) x),
    'tutor', (select id from public.cms_tutors t where private.cms_norm_name(t.name) = private.cms_norm_name(s.teacher_name) limit 1),
    'person', (select id from private.cms_claim_person(s.teacher_name)));
end $f$;
revoke all on function public.cms_tec_get(uuid) from public, anon;
grant execute on function public.cms_tec_get(uuid) to authenticated;

-- my TEC V2 claims (made by me, or under my name)
create or replace function public.cms_tec_mine()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('form', 'tec-v2', 'form_name', 'Tuition (TEC)', 'id', s.id, 'serial_no', coalesce((select string_agg(distinct x->>'serial_no', ', ') from jsonb_array_elements(s.pages) x), s.id::text),
      'unit', 'RM', 'amount', (select coalesce(sum((x->>'subtotal')::numeric), 0) from jsonb_array_elements(s.pages) x), 'submitted_at', case when s.status = 'draft' then null else s.submitted_at end,
      'stage', case s.status when 'draft' then 'draft' when 'submitted' then 'approval' else
               case when exists (select 1 from public.meg_forms_finance_status f where f.form_code = 'tec-v2' and f.submission_id = s.id::text and f.payment_done) then 'paid' else 'processing' end end,
      'status', case s.status when 'draft' then 'Draft (not sent)' when 'submitted' then 'With the PIC' when 'done' then
               case when exists (select 1 from public.meg_forms_finance_status f where f.form_code = 'tec-v2' and f.submission_id = s.id::text and f.payment_done) then 'Paid' else 'Checked · being processed' end
               else initcap(s.status) end,
      'paid_at', (select f.payment_done_at from public.meg_forms_finance_status f where f.form_code = 'tec-v2' and f.submission_id = s.id::text and f.payment_done),
      'approved_at', s.done_at, 'approved_by', s.done_by_name) order by s.created_at desc), '[]'::jsonb)
  from public.tec_v2_submissions s
  where s.deleted_at is null and (s.submitted_by = auth.uid()
     or (private.cms_me_tutor() is not null and private.cms_norm_name(s.teacher_name) = (select private.cms_norm_name(name) from public.cms_tutors where id = private.cms_me_tutor()))
     or (private.cms_me_person() is not null and (select id from private.cms_claim_person(s.teacher_name)) = private.cms_me_person()));
$$;
revoke all on function public.cms_tec_mine() from public, anon;
grant execute on function public.cms_tec_mine() to authenticated;

-- save / submit. p: person_id?, tutor_id?, company (MEG|MEH), month, year,
--    pages [{course_name, standards [..], students [{name, actualDays [10], replacementDays [10], monthlyFee}]}]
create or replace function public.cms_tec_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare w jsonb; s public.tec_v2_submissions; co text := coalesce(nullif(p->>'company', ''), 'MEG'); mon int := (p->>'month')::int; yr int := (p->>'year')::int;
  pct numeric := coalesce((select (value->>'venue_pct')::numeric from public.cms_settings where key = 'tec_settings'), 5);
  pg jsonb; st jsonb; v_pages jsonb := '[]'::jsonb; studs jsonb; fee numeric; ven numeric; sub numeric; i int; k int := 0; nstud int := 0;
  course text; v_cc text; serials jsonb := '{}'::jsonb; totals jsonb := '{}'::jsonb; lasts jsonb := '{}'::jsonb; stamp text := to_char(now() at time zone 'Asia/Kuala_Lumpur', 'DDMMYYYYHH24MI');
  days jsonb; rdays jsonb; std text;
begin
  if p_id is not null then
    select * into s from public.tec_v2_submissions where id = p_id and deleted_at is null for update;
    if s.id is null then raise exception 'Claim not found.'; end if;
    if s.submitted_by is distinct from auth.uid() then raise exception 'Only the person who made this claim can change it.'; end if;
    if s.status <> 'draft' then raise exception 'This claim has been submitted and can no longer be changed.'; end if;
  end if;
  w := private.cms_tec_who(nullif(p->>'person_id', '')::uuid, nullif(p->>'tutor_id', '')::uuid);
  if co not in ('MEG', 'MEH') then raise exception 'Tuition claims are under MyEden Group or MyEden Edu Hub.'; end if;
  if mon is null or mon not between 1 and 12 or yr is null or yr not between 2024 and 2099 then raise exception 'Choose the month and year.'; end if;
  -- course order as first seen, then build pages with venue fee, net pay and subtotals
  for pg in select x from jsonb_array_elements(coalesce(p->'pages', '[]'::jsonb)) x loop
    k := k + 1;
    if k > 40 then raise exception 'Too many pages.'; end if;
    course := btrim(coalesce(pg->>'course_name', ''));
    if course <> '' and not exists (select 1 from public.tec_v2_courses c where c.name = course) then raise exception 'Page %: unknown course.', k; end if;
    for std in select jsonb_array_elements_text(coalesce(pg->'standards', '[]'::jsonb)) loop
      if not exists (select 1 from public.tec_v2_standards x where x.name = std) then raise exception 'Page %: unknown standard %.', k, std; end if;
    end loop;
    studs := '[]'::jsonb; sub := 0;
    for st in select x from jsonb_array_elements(coalesce(pg->'students', '[]'::jsonb)) x loop
      nstud := nstud + 1;
      if nstud > 600 then raise exception 'Too many students.'; end if;
      fee := round(coalesce(public.meg_forms_try_numeric(st->>'monthlyFee'), 0), 2);
      if fee < 0 or fee > 100000 then raise exception 'Page %: a fee is not valid.', k; end if;
      ven := round(fee * pct / 100, 2);
      days := (select coalesce(jsonb_agg(coalesce(d, '')), '[]'::jsonb) from (select (select x from jsonb_array_elements_text(coalesce(st->'actualDays', '[]'::jsonb)) with ordinality a(x, o) where a.o = g) d from generate_series(1, 10) g) z);
      rdays := (select coalesce(jsonb_agg(coalesce(d, '')), '[]'::jsonb) from (select (select x from jsonb_array_elements_text(coalesce(st->'replacementDays', '[]'::jsonb)) with ordinality a(x, o) where a.o = g) d from generate_series(1, 10) g) z);
      if exists (select 1 from jsonb_array_elements_text(days || rdays) d where d <> '' and (d !~ '^[0-9]{1,2}$' or d::int not between 1 and 31)) then raise exception 'Page %: class dates are day numbers (1 to 31).', k; end if;
      studs := studs || jsonb_build_object('name', left(btrim(coalesce(st->>'name', '')), 120), 'actualDays', days, 'replacementDays', rdays,
        'monthlyFee', fee, 'venueFee', ven, 'netPay', fee - ven);
      sub := sub + fee - ven;
    end loop;
    v_pages := v_pages || (jsonb_build_object('course_name', course, 'standards', coalesce(pg->'standards', '[]'::jsonb), 'month', mon, 'year', yr,
      'students', studs, 'subtotal', sub, 'serial_no', '', 'is_group_total_page', false, 'group_total', null)
      || case when coalesce(pg->>'time_from', '') ~ '^[0-2][0-9]:[0-5][0-9]$' then jsonb_build_object('time_from', pg->>'time_from', 'time_to', coalesce(pg->>'time_to', '')) else '{}'::jsonb end);
    if course <> '' then
      if not serials ? course then
        v_cc := coalesce((select nullif(c.code, '') from public.tec_v2_courses c where c.name = course), course);
        serials := serials || jsonb_build_object(course, v_cc || '-' || stamp);
      end if;
      totals := totals || jsonb_build_object(course, coalesce((totals->>course)::numeric, 0) + sub);
      lasts := lasts || jsonb_build_object(course, k - 1);
    end if;
  end loop;
  -- group pages by course (first-seen order), with each course's serial; the last page of a multi-page course carries the course total
  v_pages := (select coalesce(jsonb_agg(x.pg order by x.first_seen, x.o), '[]'::jsonb) from (
      select (e.pg || jsonb_build_object('serial_no', coalesce(serials->>(e.pg->>'course_name'), ''),
               'is_group_total_page', (select count(*) from jsonb_array_elements(v_pages) y where y->>'course_name' = e.pg->>'course_name') > 1 and (lasts->>(e.pg->>'course_name'))::int = e.o - 1,
               'group_total', case when (select count(*) from jsonb_array_elements(v_pages) y where y->>'course_name' = e.pg->>'course_name') > 1 and (lasts->>(e.pg->>'course_name'))::int = e.o - 1
                                   then totals->(e.pg->>'course_name') end)) pg,
             e.o, (select min(o2) from jsonb_array_elements(v_pages) with ordinality y(v, o2) where y.v->>'course_name' = e.pg->>'course_name') first_seen
        from jsonb_array_elements(v_pages) with ordinality e(pg, o)) x);
  if p_submit then
    if jsonb_array_length(v_pages) = 0 then raise exception 'Add at least one course page.'; end if;
    for i in 0 .. jsonb_array_length(v_pages) - 1 loop
      if v_pages->i->>'course_name' = '' then raise exception 'Page %: choose the course.', i + 1; end if;
      if jsonb_array_length(v_pages->i->'standards') = 0 then raise exception 'Page % (%): tick at least one Standard.', i + 1, v_pages->i->>'course_name'; end if;
      if jsonb_array_length(v_pages->i->'students') = 0 then raise exception 'Page % (%): add the students.', i + 1, v_pages->i->>'course_name'; end if;
      if exists (select 1 from jsonb_array_elements(v_pages->i->'students') x where x->>'name' = '' or (x->>'monthlyFee')::numeric <= 0) then
        raise exception 'Page % (%): every student needs a name and a monthly fee.', i + 1, v_pages->i->>'course_name'; end if;
    end loop;
  end if;
  if s.id is null then
    insert into public.tec_v2_submissions (submitted_by, teacher_name, company_code, pages, status, submitted_at)
    values (auth.uid(), w->>'name', co, v_pages, case when p_submit then 'submitted' else 'draft' end, now()) returning * into s;
  else
    update public.tec_v2_submissions set teacher_name = w->>'name', company_code = co, pages = v_pages,
      status = case when p_submit then 'submitted' else 'draft' end, submitted_at = now() where id = s.id returning * into s;
  end if;
  if p_submit then
    perform private.cms_log('claim.submitted', 'tec-v2', s.id::text, co, 'TEC ' || coalesce((select string_agg(distinct x->>'serial_no', ', ') from jsonb_array_elements(v_pages) x), '') || ' submitted in the CMS for ' || (w->>'name'),
      jsonb_build_object('behalf', w->'behalf', 'kind', w->'kind', 'pages', jsonb_array_length(v_pages), 'venue_pct', pct));
  end if;
  return jsonb_build_object('id', s.id, 'status', s.status, 'serials', (select coalesce(jsonb_agg(distinct x->>'serial_no'), '[]'::jsonb) from jsonb_array_elements(v_pages) x where x->>'serial_no' <> ''),
    'total', (select coalesce(sum((x->>'subtotal')::numeric), 0) from jsonb_array_elements(v_pages) x), 'venue_pct', pct);
end $f$;
revoke all on function public.cms_tec_save(uuid, jsonb, boolean) from public, anon;
grant execute on function public.cms_tec_save(uuid, jsonb, boolean) to authenticated;

create or replace function public.cms_tec_discard(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare s public.tec_v2_submissions;
begin
  select * into s from public.tec_v2_submissions where id = p_id and deleted_at is null for update;
  if s.id is null or s.submitted_by is distinct from auth.uid() then raise exception 'Claim not found.'; end if;
  if s.status <> 'draft' then raise exception 'Only a draft can be discarded.'; end if;
  update public.tec_v2_submissions set deleted_at = now(), deleted_by_name = private.cms_user_name(auth.uid()) where id = s.id;
end $f$;
revoke all on function public.cms_tec_discard(uuid) from public, anon;
grant execute on function public.cms_tec_discard(uuid) to authenticated;

-- templates (the same saved student lists as the TEC-V2 app, per login)
create or replace function public.cms_tec_template_save(p_name text, p_pages jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $f$
declare v uuid; nm text := left(btrim(coalesce(p_name, '')), 80);
begin
  if private.cms_me_tutor() is null and private.cms_me_person() is null and not public.cms_can('tec', 'C') then raise exception 'You cannot save tuition templates.'; end if;
  if nm = '' then raise exception 'Give the template a name.'; end if;
  if jsonb_typeof(p_pages) <> 'array' then raise exception 'Nothing to save.'; end if;
  select id into v from public.tec_v2_templates where created_by = auth.uid() and lower(name) = lower(nm);
  if v is null then insert into public.tec_v2_templates (created_by, name, pages) values (auth.uid(), nm, p_pages) returning id into v;
  else update public.tec_v2_templates set pages = p_pages, updated_at = now() where id = v; end if;
  return v;
end $f$;
revoke all on function public.cms_tec_template_save(text, jsonb) from public, anon;
grant execute on function public.cms_tec_template_save(text, jsonb) to authenticated;

create or replace function public.cms_tec_settings_set(p_venue_pct numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not (public.cms_is_super_admin() or public.cms_can('admin.roles', 'E')) then raise exception 'Only an Admin can change the venue fee.'; end if;
  if p_venue_pct is null or p_venue_pct < 0 or p_venue_pct > 100 then raise exception 'The venue fee must be between 0 and 100 percent.'; end if;
  insert into public.cms_settings (key, value, updated_at, updated_by) values ('tec_settings', jsonb_build_object('venue_pct', round(p_venue_pct, 2)), now(), auth.uid())
  on conflict (key) do update set value = public.cms_settings.value || excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('settings.tec', 'cms_settings', 'tec_settings', null, 'Tuition venue fee set to ' || round(p_venue_pct, 2) || ' %', '{}'::jsonb);
end $f$;
revoke all on function public.cms_tec_settings_set(numeric) from public, anon;
grant execute on function public.cms_tec_settings_set(numeric) to authenticated;

create or replace function public.cms_claim_settings()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('history_months', (select claimant_history_months from public.meg_forms_settings where singleton limit 1),
    'scf_receipts_required', coalesce((select (value->>'receipts_required')::boolean from public.cms_settings where key = 'scf_settings'), true),
    'tec_venue_pct', coalesce((select (value->>'venue_pct')::numeric from public.cms_settings where key = 'tec_settings'), 5),
    'can_edit', public.cms_is_super_admin() or public.cms_can('admin.roles', 'E'))
  where public.cms_can('approvals', 'V');
$$;
