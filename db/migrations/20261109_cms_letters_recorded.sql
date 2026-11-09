-- MyEden Group CMS V1.0 · v2026.11.09 · HR letters: letters issued before the CMS, signed copies, "based on letter" (CLC 9 Nov 2026)
-- 1. Record a past letter: the signed PDF is the letter. Admin / Director: recorded at once. HR: an Admin / Director approves it.
--    It takes a reference in the normal sequence (year of the letter date) and shows as "Recorded (pre-CMS)".
-- 2. Signed copy (PDF) on any issued CMS letter; once uploaded it cannot be replaced.
-- 3. cms_letter_basis(person): the person's issued / recorded promotion and transfer letters, to fill a confirmation letter.
-- 4. Update records: salary already in payroll is shown and not posted again; promotion letters can set "on probation until".
-- No DROP / DELETE.

alter table public.hr_letter_records add column if not exists origin text not null default 'cms';
alter table public.hr_letter_records add column if not exists letter_date date;
alter table public.hr_letter_records add column if not exists signed_path text;
alter table public.hr_letter_records add column if not exists signed_on date;
alter table public.hr_letter_records add column if not exists signed_at timestamptz;
alter table public.hr_letter_records add column if not exists signed_by uuid;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'hr_letter_records_origin_check') then
    alter table public.hr_letter_records add constraint hr_letter_records_origin_check check (origin in ('cms', 'recorded'));
  end if;
end $c$;

-- storage: the signed / recorded PDFs (no update policy: a file cannot be replaced)
do $p$ begin
  if not exists (select 1 from pg_policy where polname = 'CMS letter PDFs upload' and polrelid = 'storage.objects'::regclass) then
    create policy "CMS letter PDFs upload" on storage.objects for insert to authenticated
      with check (bucket_id = 'hr-letter-sources' and name ~ '^cms/(signed|recorded)/[0-9a-f-]{36}\.pdf$'
                  and (public.cms_can('letters.draft', 'V') or public.cms_can('letters.approve', 'V') or public.cms_can('letters.issue', 'V')));
  end if;
end $p$;

-- reference: a recorded letter gets one too, in the year of its letter date
do $m$ declare src text; o1 text; o2 text;
begin
  select pg_get_functiondef('private.cms_letter_reference_set()'::regprocedure) into src;
  if position('new.letter_date' in src) > 0 then return; end if;
  o1 := $o$declare y int := extract(year from (now() at time zone 'Asia/Kuala_Lumpur'))::int;$o$;
  o2 := $o$if new.reference is null and new.status in ('draft', 'pending_approval', 'approved') then$o$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 then raise exception 'cms_letter_reference_set has changed'; end if;
  execute replace(replace(src, o1, $n$declare y int := extract(year from coalesce(new.letter_date, (now() at time zone 'Asia/Kuala_Lumpur')::date))::int;$n$),
                  o2, $n$if new.reference is null and (new.status in ('draft', 'pending_approval', 'approved') or new.origin = 'recorded') then$n$);
end $m$;

create or replace function private.cms_letter_recorded_text(p_title text, p_fields jsonb, p_snap jsonb)
returns text language sql stable security definer set search_path = public, pg_temp as $f$
  select concat_ws(E'\n', p_title, 'Recorded in the CMS: a letter issued before the CMS. The signed copy (PDF) is the letter.',
    'Letter date: ' || to_char(nullif(p_snap->>'letter_date', '')::date, 'FMDD FMMonth YYYY'),
    'Signed for the Company by: ' || nullif(concat_ws(', ', nullif(p_snap->>'signatory', ''), nullif(p_snap->>'designation', '')), ''),
    'Signed by the employee on: ' || to_char(nullif(p_snap->>'signed_on', '')::date, 'FMDD FMMonth YYYY'),
    (select string_agg(coalesce(ph.label, replace(e.key, '_', ' ')) || ': ' || (e.value #>> '{}'), E'\n'
              order by coalesce(array_position(array['current_position', 'new_position', 'department', 'effective_date', 'promotion_probation_start', 'promotion_probation_period',
                'promotion_probation_end', 'current_basic', 'basic_increment', 'revised_basic', 'increment_effective_date', 'review_cycle'], e.key), 99), e.key)
       from jsonb_each(p_fields) e left join public.hr_letter_placeholders ph on ph.key = e.key
      where e.key not like '\_%' and e.key not in ('letter_reference', 'letter_date', 'employee_name') and nullif(e.value #>> '{}', '') is not null),
    'Note: ' || nullif(p_snap->>'note', ''));
$f$;
revoke all on function private.cms_letter_recorded_text(text, jsonb, jsonb) from public;

-- 1. record a past letter. p: id (new uuid, also the PDF name), person, type, letter_date, signatory, designation, signed_on, fields, note
create or replace function public.cms_letter_record(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_id uuid := nullif(p->>'id', '')::uuid; em public.employee_master; t public.hr_letter_templates; co text; v_path text; v_date date; v_signed date;
        v_auto boolean; v_fields jsonb; v_snap jsonb; v_text text; me text := private.cms_my_name(); r public.hr_letter_records;
        today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if not (public.cms_can('letters.draft', 'V') or public.cms_can('letters.approve', 'V')) then raise exception 'Not allowed: recording HR letters' using errcode = '42501'; end if;
  if v_id is null then raise exception 'Missing letter id.'; end if;
  if exists (select 1 from public.hr_letter_records where id = v_id) then raise exception 'This letter was already recorded.'; end if;
  select * into em from public.employee_master where id = nullif(p->>'person', '')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  co := private.cms_canon(em.company_code); perform private.cms_require('letters', 'V', co);
  select * into t from public.hr_letter_templates x where coalesce(x.letter_type, x.code) = p->>'type' and x.code <> 'TRL_LOP'
   order by (x.status = 'published' and x.active) desc, (x.status = 'published') desc, x.updated_at desc nulls last limit 1;
  if t.code is null then raise exception 'Choose the letter type.'; end if;
  v_date := nullif(p->>'letter_date', '')::date; v_signed := nullif(p->>'signed_on', '')::date;
  if v_date is null then raise exception 'Give the letter date.'; end if;
  if v_date > today then raise exception 'The letter date cannot be in the future.'; end if;
  if v_signed is not null and (v_signed < v_date or v_signed > today) then raise exception 'The date the employee signed must be between the letter date and today.'; end if;
  if nullif(btrim(coalesce(p->>'signatory', '')), '') is null then raise exception 'Give who signed the letter for the Company.'; end if;
  v_path := 'cms/recorded/' || v_id::text || '.pdf';
  if not exists (select 1 from storage.objects o where o.bucket_id = 'hr-letter-sources' and o.name = v_path) then raise exception 'The signed PDF was not uploaded — try again.'; end if;
  v_fields := coalesce((select jsonb_object_agg(e.key, btrim(e.value #>> '{}')) from jsonb_each(coalesce(p->'fields', '{}'::jsonb)) e
                         where e.key ~ '^[a-z0-9_]+$' and nullif(btrim(e.value #>> '{}'), '') is not null), '{}'::jsonb)
              || jsonb_build_object('letter_date', to_char(v_date, 'FMDD FMMonth YYYY'), 'employee_name', em.employee_name);
  v_snap := jsonb_build_object('letter_date', v_date, 'signatory', btrim(p->>'signatory'), 'designation', nullif(btrim(coalesce(p->>'designation', '')), ''),
                               'signed_on', v_signed, 'note', nullif(btrim(coalesce(p->>'note', '')), ''), 'pdf_path', v_path);
  v_text := private.cms_letter_recorded_text(t.title, v_fields - 'employee_name', v_snap);
  v_auto := public.cms_can('letters.approve', 'V');
  insert into public.hr_letter_records (id, employee_id, company_code, template_code, template_version, status, origin, letter_date, fields, source_snapshot,
       created_by, created_at, updated_at, signed_path, signed_on, signed_at, signed_by, approved_by, approved_at, issued_by, issued_at, issued_snapshot)
  values (v_id, em.id, co, t.code, t.version, case when v_auto then 'issued' else 'pending_approval' end, 'recorded', v_date, v_fields,
       jsonb_build_object('text', v_text, 'recorded', v_snap, 'created_by_name', me, 'submitted_at', now()) || case when v_auto then jsonb_build_object('approved_by_name', me) else '{}'::jsonb end,
       auth.uid(), now(), now(), v_path, v_signed, now(), auth.uid(),
       case when v_auto then auth.uid() end, case when v_auto then now() end, case when v_auto then auth.uid() end, case when v_auto then now() end,
       case when v_auto then jsonb_build_object('text', v_text, 'recorded', true, 'pdf_path', v_path, 'issued_by_name', me, 'approved_by_name', me) end)
  returning * into r;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (r.id, auth.uid(), 'recorded', jsonb_build_object('source', 'cms', 'status', r.status));
  if v_auto then
    insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (r.id, auth.uid(), 'approved', jsonb_build_object('source', 'cms', 'note', 'Recorded by an approver'));
    insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
    values (em.id, 'hr_letter_issued', t.title || ' (recorded, pre-CMS, dated ' || to_char(v_date, 'DD Mon YYYY') || ')', jsonb_build_object('letter_id', r.id, 'template', t.code, 'recorded', true), auth.uid());
  end if;
  perform private.cms_log('letter.recorded', 'employee_master', em.id::text, co,
    em.employee_name || ': ' || t.title || ' dated ' || to_char(v_date, 'DD Mon YYYY') || ' recorded' || case when v_auto then '' else ' (waiting for approval)' end, jsonb_build_object('letter_id', r.id));
  return jsonb_build_object('id', r.id, 'status', r.status, 'reference', r.reference);
end $f$;
revoke all on function public.cms_letter_record(jsonb) from public, anon; grant execute on function public.cms_letter_record(jsonb) to authenticated;

-- approving / sending back a recorded letter (HR recorded it): approve = recorded at once; send back = cancelled with the reason
do $m$ declare src text; o1 text; n1 text;
begin
  select pg_get_functiondef('public.cms_letter_decide(uuid,boolean,text)'::regprocedure) into src;
  if position('l.origin = ''recorded''' in src) > 0 then return; end if;
  o1 := $o$  select * into t from public.hr_letter_templates where code = l.template_code;
  if p_approve then$o$;
  n1 := $n$  select * into t from public.hr_letter_templates where code = l.template_code;
  if l.origin = 'recorded' then
    if p_approve then
      update public.hr_letter_records set status = 'issued', approved_by = auth.uid(), approved_at = now(), issued_by = auth.uid(), issued_at = now(), updated_at = now(),
             source_snapshot = source_snapshot || jsonb_build_object('approved_by_name', private.cms_my_name()),
             issued_snapshot = jsonb_build_object('text', l.source_snapshot->>'text', 'recorded', true, 'pdf_path', l.signed_path, 'issued_by_name', private.cms_my_name(), 'approved_by_name', private.cms_my_name())
       where id = l.id;
      insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
      values (em.id, 'hr_letter_issued', t.title || ' (recorded, pre-CMS, dated ' || to_char(l.letter_date, 'DD Mon YYYY') || ')', jsonb_build_object('letter_id', l.id, 'template', t.code, 'recorded', true), auth.uid());
    else
      if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for sending it back.'; end if;
      update public.hr_letter_records set status = 'void', updated_at = now(),
             source_snapshot = source_snapshot || jsonb_build_object('void_reason', 'Not approved: ' || btrim(p_reason), 'rejected', jsonb_build_object('reason', btrim(p_reason), 'by', private.cms_my_name(), 'at', now()))
       where id = l.id;
    end if;
    insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), case when p_approve then 'approved' else 'rejected' end, jsonb_build_object('reason', p_reason, 'source', 'cms'));
    perform private.cms_log('letter.' || case when p_approve then 'approved' else 'sent_back' end, 'employee_master', em.id::text, private.cms_canon(em.company_code),
      em.employee_name || ': recorded ' || t.title || case when p_approve then ' approved' else ' not approved: ' || btrim(p_reason) end, jsonb_build_object('letter_id', l.id));
    return case when p_approve then 'issued' else 'void' end;
  end if;
  if p_approve then$n$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_decide has changed'; end if;
  execute replace(src, o1, n1);
end $m$;

-- 2. signed copy on an issued CMS letter
create or replace function public.cms_letter_signed(p_id uuid, p_signed_on date)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare l public.hr_letter_records; em public.employee_master; v_path text := 'cms/signed/' || p_id::text || '.pdf';
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  if not public.cms_can('letters.issue', 'V', private.cms_canon(em.company_code)) then raise exception 'Not allowed: uploading signed letters' using errcode = '42501'; end if;
  if l.status <> 'issued' then raise exception 'Only an issued letter takes a signed copy.'; end if;
  if l.signed_path is not null then raise exception 'The signed copy is already uploaded — it cannot be replaced.'; end if;
  if p_signed_on is null then raise exception 'Give the date the employee signed.'; end if;
  if p_signed_on < (l.issued_at at time zone 'Asia/Kuala_Lumpur')::date or p_signed_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'The date the employee signed must be between the issue date and today.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'hr-letter-sources' and o.name = v_path) then raise exception 'The signed PDF was not uploaded — try again.'; end if;
  update public.hr_letter_records set signed_path = v_path, signed_on = p_signed_on, signed_at = now(), signed_by = auth.uid() where id = l.id;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'signed_uploaded', jsonb_build_object('source', 'cms', 'note', 'Employee signed ' || to_char(p_signed_on, 'DD Mon YYYY')));
  perform private.cms_log('letter.signed', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': signed copy of ' || coalesce(l.reference, 'letter') || ' uploaded', jsonb_build_object('letter_id', l.id));
end $f$;
revoke all on function public.cms_letter_signed(uuid, date) from public, anon; grant execute on function public.cms_letter_signed(uuid, date) to authenticated;

-- 3. letters a confirmation can be based on
create or replace function public.cms_letter_basis(p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare em public.employee_master;
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then return '[]'::jsonb; end if;
  perform private.cms_require('letters', 'V', private.cms_canon(em.company_code));
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'reference', l.reference, 'title', t.title, 'type', coalesce(t.letter_type, t.code), 'origin', l.origin,
      'letter_date', coalesce(l.letter_date, (l.issued_at at time zone 'Asia/Kuala_Lumpur')::date), 'fields', l.fields) order by coalesce(l.letter_date, l.issued_at::date) desc)
    from public.hr_letter_records l join public.hr_letter_templates t on t.code = l.template_code
   where l.employee_id = em.id and l.status = 'issued' and coalesce(t.letter_type, t.code) in ('LOP', 'TRL_LOP', 'TRL')), '[]'::jsonb);
end $f$;
revoke all on function public.cms_letter_basis(uuid) from public, anon; grant execute on function public.cms_letter_basis(uuid) to authenticated;

-- the letters list: origin, letter date, signed copy
do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letters()'::regprocedure) into src;
  if position('''origin'', l.origin' in src) > 0 then return; end if;
  o1 := $o$'void_reason', l.source_snapshot->>'void_reason',$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letters has changed'; end if;
  execute replace(src, o1, $n$'void_reason', l.source_snapshot->>'void_reason', 'origin', l.origin, 'reference', l.reference, 'letter_date', l.letter_date,
          'recorded', l.source_snapshot->'recorded', 'signed_path', l.signed_path, 'signed_on', l.signed_on, 'signed_at', l.signed_at,$n$);
end $m$;

-- 4a. Update records: salary already in payroll is not posted again (and no review is set from it); promotion letters: on probation until
do $m$ declare src text; o1 text; o2 text; o3 text; o4 text; o5 text; o6 text;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position('v_have' in src) > 0 then return; end if;
  o1 := $o$rs public.cms_resignations;$o$;
  o2 := $o$     where a.employment_id = m.id and a.is_primary order by h.effective_from desc limit 1;
$o$;
  o3 := $o$'kind', 'salary', 'label', 'Basic salary', 'date', v_sal, 'amount', new_sal,
      'allowed', v_can_pay,$o$;
  o4 := $o$    items := items || jsonb_build_array(jsonb_build_object('kind', 'review', 'label', 'Next salary review', 'interval', case when f->>'review_cycle'$o$;
  o5 := $o$where is_active)));
  end if;
  if lower(coalesce(f->>'has_increment', '')) = 'no'$o$;
  o6 := $o$  new_sal := private.cms_money(f->>'revised_basic');$o$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 or position(o3 in src) = 0 or position(o4 in src) = 0 or position(o5 in src) = 0 or position(o6 in src) = 0 then
    raise exception 'cms_letter_apply_preview has changed'; end if;
  src := replace(src, o1, o1 || ' v_have boolean := false; v_pst date;');
  src := replace(src, o2, o2 || $n$    v_have := exists (select 1 from public.eppd_salary_history h join public.eppd_assignments a on a.id = h.assignment_id
                      where a.employment_id = m.id and h.effective_from = v_sal and h.amount = new_sal);
$n$);
  src := replace(src, o3, $n$'kind', 'salary', 'label', 'Basic salary', 'date', v_sal, 'amount', new_sal, 'already', v_have,
      'allowed', v_can_pay and not v_have,$n$);
  src := replace(src, o4, '    if not v_have then' || chr(10) || o4);
  src := replace(src, o5, $n$where is_active))); end if;
  end if;
  if lower(coalesce(f->>'has_increment', '')) = 'no'$n$);
  src := replace(src, o6, $n$  v_pst := coalesce(private.cms_parse_date(f->>'promotion_probation_start'), private.cms_parse_date(f->>'effective_date'));
  if v_type like 'LOP%' and v_pend is not null then
    items := items || jsonb_build_array(jsonb_build_object('kind', 'probation', 'label', 'Probation in the new position', 'date', v_pst, 'end', v_pend, 'allowed', v_can_people,
      'now', case em.confirmation_status when 'confirmed' then 'Confirmed' when 'probation' then 'On probation' when 'extended' then 'Probation extended' when 'not_applicable' then 'Not applicable' else 'Not recorded' end
             || coalesce(' · ends ' || to_char(em.probation_end_date, 'DD Mon YYYY'), ''),
      'after', 'On probation' || coalesce(' from ' || to_char(v_pst, 'DD Mon YYYY'), '') || ' until ' || to_char(v_pend, 'DD Mon YYYY')));
  end if;
$n$ || o6);
  execute src;
end $m$;

-- 4b. apply: the probation item
do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_apply(uuid,jsonb)'::regprocedure) into src;
  if position('when ''probation'' then' in src) > 0 then return; end if;
  o1 := $o$    when 'salary' then
$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_apply has changed'; end if;
  execute replace(src, o1, $n$    when 'probation' then
      perform private.cms_require('people', 'E', co);
      if nullif(it->>'end', '') is null then raise exception 'Give the end of the probation.'; end if;
      update public.employee_master set confirmation_status = 'probation', probation_end_date = (it->>'end')::date, updated_at = now() where id = em.id;
      done := done || jsonb_build_array(jsonb_build_object('kind', 'probation', 'date', d, 'end', (it->>'end')::date));
$n$ || o1);
end $m$;
