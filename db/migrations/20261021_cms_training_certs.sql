-- MyEden Group CMS V1.0 · Phase 5c · Training & Certificates
-- Certificates per person (first aid, SKM, ECCE, PERMATA / KAAK, food handler + typhoid, driving licence …) with expiry dates,
-- a copy of the certificate, verification by HR and reminders before they lapse. Certificate types say how long a certificate
-- is valid and whether every active staff member must hold one. Training sessions record who attended and can issue the
-- certificate to attendees. Staff see their own in "My Certificates" (new self-service part "certs", off by default) and can
-- send a new certificate for HR to verify.

alter table public.cms_self_access drop constraint cms_self_access_part_check;
alter table public.cms_self_access add constraint cms_self_access_part_check
  check (part in ('profile','payslips','ea','salary','leave','claims','items','handbook','certs'));
do $m$ declare d text := pg_get_functiondef('public.cms_self_set(uuid[], text, boolean)'::regprocedure); n text;
begin
  n := replace(d, $x$'items','handbook') then raise exception$x$, $x$'items','handbook','certs') then raise exception$x$);
  if n <> d then execute n; end if;
end $m$;

create table if not exists public.cms_cert_types (
  code text primary key, label text not null,
  category text not null default 'other' check (category in ('first_aid','childcare','food','safety','licence','skills','other')),
  validity_months int,                 -- null = does not expire
  required_all boolean not null default false,
  remind_days int not null default 60, -- remind this many days before expiry
  is_active boolean not null default true, sort_order int not null default 100);
alter table public.cms_cert_types enable row level security;
insert into public.cms_cert_types (code, label, category, validity_months, required_all, sort_order) values
  ('FIRST_AID', 'First Aid & CPR', 'first_aid', 36, true, 10),
  ('PERMATA', 'Kursus Asuhan PERMATA / KAAK (Kursus Asas Asuhan Kanak-Kanak)', 'childcare', null, false, 20),
  ('ECCE', 'ECCE certificate / diploma', 'childcare', null, false, 30),
  ('SKM', 'Sijil Kemahiran Malaysia (SKM)', 'skills', null, false, 40),
  ('FOOD_HANDLER', 'Food handler course', 'food', null, false, 50),
  ('TYPHOID', 'Typhoid vaccination', 'food', 36, false, 60),
  ('FIRE', 'Fire safety / evacuation drill', 'safety', 12, false, 70),
  ('DRIVING', 'Driving licence', 'licence', null, false, 80),
  ('OTHER', 'Other certificate', 'other', null, false, 200)
on conflict (code) do nothing;

create table if not exists public.cms_certificates (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.employee_master(id) on delete cascade,
  type_code text not null references public.cms_cert_types(code),
  title text, issuer text, cert_no text,
  issued_on date, expires_on date,
  file text,                                   -- copy of the certificate (picture or PDF, data URL)
  note text,
  status text not null default 'verified' check (status in ('pending','verified','rejected','replaced')),
  source text not null default 'hr' check (source in ('hr','self','training')),
  training_id uuid,
  created_by uuid, created_at timestamptz not null default now(),
  verified_by uuid, verified_by_name text, verified_at timestamptz, reject_reason text,
  updated_at timestamptz not null default now());
alter table public.cms_certificates enable row level security;
create index if not exists cms_certificates_person_idx on public.cms_certificates (person_id, type_code, status);

create table if not exists public.cms_trainings (
  id uuid primary key default gen_random_uuid(),
  title text not null, provider text, date_from date not null, date_to date, hours numeric(6,1), cost numeric(12,2), location text,
  cert_type_code text references public.cms_cert_types(code), note text,
  created_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table public.cms_trainings enable row level security;
create table if not exists public.cms_training_attendees (
  training_id uuid not null references public.cms_trainings(id) on delete cascade,
  person_id uuid not null references public.employee_master(id) on delete cascade,
  status text not null default 'registered' check (status in ('registered','attended','absent')),
  certificate_id uuid references public.cms_certificates(id) on delete set null,
  note text, primary key (training_id, person_id));
alter table public.cms_training_attendees enable row level security;

-- file check: picture or PDF, at most ~2 MB
create or replace function private.cms_doc_ok(p text)
returns text language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
begin
  if p is null or p = '' then return null; end if;
  if length(p) > 2900000 then raise exception 'The file is too large (2 MB at most).'; end if;
  if p !~ '^data:(image/|application/pdf)' then raise exception 'Attach a picture or a PDF.'; end if;
  return p;
end $$;

create or replace function private.cms_cert_json(c public.cms_certificates)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', c.id, 'person_id', c.person_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
    'type', c.type_code, 'type_label', t.label, 'title', c.title, 'issuer', c.issuer, 'cert_no', c.cert_no, 'issued_on', c.issued_on, 'expires_on', c.expires_on,
    'has_file', c.file is not null, 'note', c.note, 'status', c.status, 'source', c.source, 'verified_by', c.verified_by_name, 'verified_at', c.verified_at,
    'reject_reason', c.reject_reason, 'created_at', c.created_at,
    'state', case when c.status <> 'verified' then c.status when c.expires_on is null then 'valid' when c.expires_on < current_date then 'expired'
                  when c.expires_on <= current_date + t.remind_days then 'expiring' else 'valid' end)
  from public.employee_master em, public.cms_cert_types t where em.id = c.person_id and t.code = c.type_code;
$$;

create or replace function public.cms_training()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.cms_require('training', 'V');
  return jsonb_build_object('can_edit', public.cms_can('training', 'E'), 'can_types', public.cms_can('training', 'A'),
    'types', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.label) from public.cms_cert_types t), '[]'::jsonb),
    'certificates', coalesce((select jsonb_agg(private.cms_cert_json(c) order by c.expires_on nulls last) from public.cms_certificates c join public.employee_master em on em.id = c.person_id
        where c.status <> 'replaced' and private.cms_can_company('training', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code),
          'title', em.approved_job_title, 'certs_on', private.cms_self_on(em.id, 'certs')) order by em.employee_name)
      from public.employee_master em where em.employment_status in ('active','onboarding') and private.cms_can_company('training', 'V', private.cms_canon(em.company_code))), '[]'::jsonb),
    'trainings', coalesce((select jsonb_agg(jsonb_build_object('id', tr.id, 'title', tr.title, 'provider', tr.provider, 'from', tr.date_from, 'to', tr.date_to, 'hours', tr.hours,
          'cost', tr.cost, 'location', tr.location, 'cert_type', tr.cert_type_code, 'note', tr.note,
          'attendees', coalesce((select jsonb_agg(jsonb_build_object('person_id', a.person_id, 'name', em.employee_name, 'status', a.status, 'certificate_id', a.certificate_id) order by em.employee_name)
                                 from public.cms_training_attendees a join public.employee_master em on em.id = a.person_id where a.training_id = tr.id), '[]'::jsonb))
        order by tr.date_from desc) from public.cms_trainings tr), '[]'::jsonb));
end $$;

create or replace function public.cms_cert_file(p_id uuid)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.cms_certificates; em public.employee_master;
begin
  select * into c from public.cms_certificates where id = p_id;
  if c.id is null then raise exception 'Certificate not found.'; end if;
  select * into em from public.employee_master where id = c.person_id;
  if c.person_id is distinct from private.cms_me() and not private.cms_can_company('training', 'V', private.cms_canon(em.company_code)) then raise exception 'Not allowed.'; end if;
  return c.file;
end $$;

-- HR: add / edit a certificate (a new one of the same type replaces the older one)
create or replace function public.cms_cert_save(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare em public.employee_master; t public.cms_cert_types; v uuid := nullif(p->>'id', '')::uuid; iss date := nullif(p->>'issued_on', '')::date; ex date := nullif(p->>'expires_on', '')::date;
begin
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('training', 'E', private.cms_canon(em.company_code));
  select * into t from public.cms_cert_types where code = p->>'type';
  if t.code is null then raise exception 'Choose the certificate type.'; end if;
  if t.code = 'OTHER' and nullif(btrim(p->>'title'), '') is null then raise exception 'Name the certificate.'; end if;
  if ex is null and t.validity_months is not null and iss is not null then ex := (iss + make_interval(months => t.validity_months) - interval '1 day')::date; end if;
  if ex is not null and iss is not null and ex < iss then raise exception 'The expiry date is before the issue date.'; end if;
  if v is null then
    insert into public.cms_certificates (person_id, type_code, title, issuer, cert_no, issued_on, expires_on, file, note, status, source, created_by, verified_by, verified_by_name, verified_at)
    values (em.id, t.code, nullif(btrim(p->>'title'), ''), nullif(btrim(p->>'issuer'), ''), nullif(btrim(p->>'cert_no'), ''), iss, ex, private.cms_doc_ok(p->>'file'),
            nullif(btrim(p->>'note'), ''), 'verified', 'hr', auth.uid(), auth.uid(), private.cms_my_name(), now())
    returning id into v;
    if t.code <> 'OTHER' then
      update public.cms_certificates set status = 'replaced', updated_at = now()
       where person_id = em.id and type_code = t.code and id <> v and status = 'verified' and coalesce(expires_on, 'infinity') <= coalesce(ex, 'infinity');
    end if;
  else
    update public.cms_certificates set type_code = t.code, title = nullif(btrim(p->>'title'), ''), issuer = nullif(btrim(p->>'issuer'), ''), cert_no = nullif(btrim(p->>'cert_no'), ''),
           issued_on = iss, expires_on = ex, file = coalesce(private.cms_doc_ok(p->>'file'), file), note = nullif(btrim(p->>'note'), ''), updated_at = now()
     where id = v and person_id = em.id;
    if not found then raise exception 'Certificate not found.'; end if;
  end if;
  perform private.cms_log('cert.saved', 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || t.label || coalesce(' (expires ' || to_char(ex, 'DD Mon YYYY') || ')', ''), jsonb_build_object('certificate_id', v));
  return v;
end $$;

-- HR: verify / reject a certificate sent by staff, or remove one entered by mistake (kept as replaced)
create or replace function public.cms_cert_decide(p_id uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.cms_certificates; em public.employee_master;
begin
  select * into c from public.cms_certificates where id = p_id for update;
  if c.id is null then raise exception 'Certificate not found.'; end if;
  select * into em from public.employee_master where id = c.person_id;
  perform private.cms_require('training', 'E', private.cms_canon(em.company_code));
  if p_action = 'verify' then
    if c.status <> 'pending' then raise exception 'Only a certificate waiting for HR can be verified.'; end if;
    update public.cms_certificates set status = 'verified', verified_by = auth.uid(), verified_by_name = private.cms_my_name(), verified_at = now(), updated_at = now() where id = c.id;
    if c.type_code <> 'OTHER' then
      update public.cms_certificates set status = 'replaced', updated_at = now()
       where person_id = c.person_id and type_code = c.type_code and id <> c.id and status = 'verified' and coalesce(expires_on, 'infinity') <= coalesce(c.expires_on, 'infinity');
    end if;
  elsif p_action = 'reject' then
    if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give the reason.'; end if;
    update public.cms_certificates set status = 'rejected', reject_reason = btrim(p_note), verified_by = auth.uid(), verified_by_name = private.cms_my_name(), verified_at = now(), updated_at = now() where id = c.id;
  elsif p_action = 'remove' then
    update public.cms_certificates set status = 'replaced', note = concat_ws(' · ', note, 'Removed: ' || coalesce(nullif(btrim(p_note), ''), 'entered by mistake')), updated_at = now() where id = c.id;
  else raise exception 'Unknown action.';
  end if;
  perform private.cms_log('cert.' || p_action, 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': certificate ' || p_action, jsonb_build_object('certificate_id', c.id, 'note', p_note));
end $$;

create or replace function public.cms_cert_type_save(p jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c text := upper(regexp_replace(coalesce(nullif(p->>'code', ''), p->>'label'), '[^A-Za-z0-9]+', '_', 'g'));
begin
  perform private.cms_require('training', 'A');
  if nullif(btrim(p->>'label'), '') is null then raise exception 'Name the certificate type.'; end if;
  insert into public.cms_cert_types (code, label, category, validity_months, required_all, remind_days, is_active, sort_order)
  values (left(c, 30), btrim(p->>'label'), coalesce(nullif(p->>'category', ''), 'other'), nullif(p->>'validity_months', '')::int, coalesce((p->>'required_all')::boolean, false),
          coalesce(nullif(p->>'remind_days', '')::int, 60), coalesce((p->>'is_active')::boolean, true), 150)
  on conflict (code) do update set label = excluded.label, category = excluded.category, validity_months = excluded.validity_months,
     required_all = excluded.required_all, remind_days = excluded.remind_days, is_active = excluded.is_active;
  perform private.cms_log('cert_type.saved', 'cms_cert_types', left(c, 30), null, 'Certificate type ' || btrim(p->>'label') || ' saved', p);
end $$;

-- training sessions
create or replace function public.cms_training_save(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := nullif(p->>'id', '')::uuid; pid uuid;
begin
  perform private.cms_require('training', 'E');
  if nullif(btrim(p->>'title'), '') is null or nullif(p->>'from', '') is null then raise exception 'Give the training name and date.'; end if;
  if v is null then
    insert into public.cms_trainings (title, provider, date_from, date_to, hours, cost, location, cert_type_code, note, created_by)
    values (btrim(p->>'title'), nullif(btrim(p->>'provider'), ''), (p->>'from')::date, nullif(p->>'to', '')::date, nullif(p->>'hours', '')::numeric, nullif(p->>'cost', '')::numeric,
            nullif(btrim(p->>'location'), ''), nullif(p->>'cert_type', ''), nullif(btrim(p->>'note'), ''), auth.uid()) returning id into v;
  else
    update public.cms_trainings set title = btrim(p->>'title'), provider = nullif(btrim(p->>'provider'), ''), date_from = (p->>'from')::date, date_to = nullif(p->>'to', '')::date,
           hours = nullif(p->>'hours', '')::numeric, cost = nullif(p->>'cost', '')::numeric, location = nullif(btrim(p->>'location'), ''), cert_type_code = nullif(p->>'cert_type', ''),
           note = nullif(btrim(p->>'note'), ''), updated_at = now() where id = v;
  end if;
  if p ? 'people' then
    for pid in select (x)::uuid from jsonb_array_elements_text(p->'people') x loop
      insert into public.cms_training_attendees (training_id, person_id) values (v, pid) on conflict do nothing;
    end loop;
  end if;
  perform private.cms_log('training.saved', 'cms_trainings', v::text, null, 'Training ' || btrim(p->>'title') || ' saved', p - 'people');
  return v;
end $$;

-- mark attendance; attended + a certificate type → certificate issued to the person (expiry by the type's validity)
create or replace function public.cms_training_attend(p_training uuid, p_person uuid, p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare tr public.cms_trainings; a public.cms_training_attendees; t public.cms_cert_types; cid uuid; d date;
begin
  perform private.cms_require('training', 'E');
  select * into tr from public.cms_trainings where id = p_training;
  select * into a from public.cms_training_attendees where training_id = p_training and person_id = p_person for update;
  if tr.id is null or a.training_id is null then raise exception 'Attendee not found.'; end if;
  if p_status not in ('registered','attended','absent') then raise exception 'Unknown status.'; end if;
  update public.cms_training_attendees set status = p_status where training_id = p_training and person_id = p_person;
  if p_status = 'attended' and tr.cert_type_code is not null and a.certificate_id is null then
    select * into t from public.cms_cert_types where code = tr.cert_type_code;
    d := coalesce(tr.date_to, tr.date_from);
    insert into public.cms_certificates (person_id, type_code, title, issuer, issued_on, expires_on, status, source, training_id, created_by, verified_by, verified_by_name, verified_at)
    values (p_person, t.code, tr.title, tr.provider, d, case when t.validity_months is not null then (d + make_interval(months => t.validity_months) - interval '1 day')::date end,
            'verified', 'training', tr.id, auth.uid(), auth.uid(), private.cms_my_name(), now()) returning id into cid;
    update public.cms_certificates set status = 'replaced', updated_at = now()
     where person_id = p_person and type_code = t.code and id <> cid and status = 'verified' and t.code <> 'OTHER';
    update public.cms_training_attendees set certificate_id = cid where training_id = p_training and person_id = p_person;
  end if;
end $$;

-- staff: My Certificates
create or replace function public.cms_my_certs()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs');
begin
  return jsonb_build_object(
    'certificates', coalesce((select jsonb_agg(private.cms_cert_json(c) order by c.created_at desc) from public.cms_certificates c where c.person_id = v and c.status <> 'replaced'), '[]'::jsonb),
    'types', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'validity_months', validity_months, 'required', required_all) order by sort_order, label) from public.cms_cert_types where is_active), '[]'::jsonb),
    'trainings', coalesce((select jsonb_agg(jsonb_build_object('title', tr.title, 'from', tr.date_from, 'to', tr.date_to, 'provider', tr.provider, 'hours', tr.hours, 'status', a.status) order by tr.date_from desc)
                           from public.cms_training_attendees a join public.cms_trainings tr on tr.id = a.training_id where a.person_id = v), '[]'::jsonb));
end $$;

create or replace function public.cms_my_cert_send(p jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('certs'); t public.cms_cert_types; id_ uuid; iss date := nullif(p->>'issued_on', '')::date; ex date := nullif(p->>'expires_on', '')::date;
begin
  select * into t from public.cms_cert_types where code = p->>'type' and is_active;
  if t.code is null then raise exception 'Choose the certificate type.'; end if;
  if nullif(p->>'file', '') is null then raise exception 'Attach a photo or PDF of the certificate.'; end if;
  if ex is null and t.validity_months is not null and iss is not null then ex := (iss + make_interval(months => t.validity_months) - interval '1 day')::date; end if;
  insert into public.cms_certificates (person_id, type_code, title, issuer, cert_no, issued_on, expires_on, file, note, status, source, created_by)
  values (v, t.code, nullif(btrim(p->>'title'), ''), nullif(btrim(p->>'issuer'), ''), nullif(btrim(p->>'cert_no'), ''), iss, ex, private.cms_doc_ok(p->>'file'),
          nullif(btrim(p->>'note'), ''), 'pending', 'self', auth.uid()) returning id into id_;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (v, 'certificate_sent', t.label || ' sent for HR to verify', jsonb_build_object('certificate_id', id_), auth.uid());
  return id_;
end $$;

-- reminders
create or replace function public.cms_certs_pending()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.cms_me(); hr boolean := public.cms_can('training', 'E');
begin
  return jsonb_build_object(
    'mine_expiring', case when me is not null and private.cms_self_on(me, 'certs') then (select count(*) from public.cms_certificates c join public.cms_cert_types t on t.code = c.type_code
        where c.person_id = me and c.status = 'verified' and c.expires_on is not null and c.expires_on <= current_date + t.remind_days) else 0 end,
    'hr_expiring', case when hr then (select count(*) from public.cms_certificates c join public.cms_cert_types t on t.code = c.type_code join public.employee_master em on em.id = c.person_id
        where c.status = 'verified' and c.expires_on is not null and c.expires_on <= current_date + 30 and em.employment_status in ('active','onboarding')) else 0 end,
    'hr_to_verify', case when hr then (select count(*) from public.cms_certificates where status = 'pending') else 0 end,
    'hr_missing', case when hr then (select count(*) from public.employee_master em cross join public.cms_cert_types t
        where t.required_all and t.is_active and em.employment_status = 'active'
          and not exists (select 1 from public.cms_certificates c where c.person_id = em.id and c.type_code = t.code and c.status = 'verified' and (c.expires_on is null or c.expires_on >= current_date))) else 0 end);
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_training()','cms_cert_file(uuid)','cms_cert_save(jsonb)','cms_cert_decide(uuid, text, text)','cms_cert_type_save(jsonb)',
    'cms_training_save(jsonb)','cms_training_attend(uuid, uuid, text)','cms_my_certs()','cms_my_cert_send(jsonb)','cms_certs_pending()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
