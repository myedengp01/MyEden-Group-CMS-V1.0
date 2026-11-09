-- MyEden Group CMS V1.0 · v2026.11.09 · Departments in letters and records (CLC 9 Nov 2026)
-- Departments: HQ (E8, E9 merged) · Taska Genius Eden E1 E6 E7 · Eden Childcare Center / Pusat Jagaan Kanak-Kanak Eden E10 (E11 merged; No 22A & 24A)
--              · Myeden Edu Hub: Tadika Genius Eden E3, Tadika Happy Dino E3+.
-- 1. Letters print the profile department code as recorded (e.g. E10); the payroll unit only when the profile is empty (reverts the unit-name change).
--    The context also gives _dept_profile / _dept_payroll so the letter can warn when they differ.
-- 2. Transfer letters: "Update records" offers Department (new_department, an active department code) from the effective date;
--    a future date rides on the scheduled "position" change (payload.department). Sets the profile department and the payroll unit.
-- 3. New switches for transfer letters: has_handover (handover sentence), effective_passed (wording when the effective date has passed).
-- 4. One-off data (applied separately, on CLC's approval 9 Nov 2026): E9 and E11 marked merged; 18 staff's profile department set to their
--    payroll unit (Woo Pey Yee stays E10 until her transfer letter updates it); each logged on the profile.
create or replace function private.cms_apply_department(p_person uuid, p_code text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare v_old text; v_code text := (select u.code from public.cms_units u where upper(u.code) = upper(btrim(coalesce(p_code, ''))) and u.is_active limit 1);
begin
  if v_code is null then raise exception 'Department % is not an active department code.', coalesce(p_code, '?'); end if;
  select department into v_old from public.employee_master where id = p_person;
  update public.employee_master set department = v_code, updated_at = now() where id = p_person;
  update public.cms_employee_payroll set unit_code = v_code, updated_at = now() where employee_master_id = p_person and unit_code is distinct from v_code;
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (p_person, 'department_changed', 'Department ' || coalesce(v_old, '—') || ' → ' || v_code || coalesce(' (' || nullif(p_note, '') || ')', ''),
          jsonb_build_object('from', v_old, 'to', v_code, 'note', p_note), auth.uid());
end $f$;
revoke all on function private.cms_apply_department(uuid, text, text) from public;

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('private.cms_apply_position(uuid,jsonb,date)'::regprocedure) into src;
  if position('cms_apply_department' in src) > 0 then return; end if;
  o1 := $o$  if nullif(p->>'position_id', '') is not null then$o$;
  if position(o1 in src) = 0 then raise exception 'cms_apply_position has changed'; end if;
  execute replace(src, o1, $n$  if nullif(p->>'department', '') is not null then perform private.cms_apply_department(p_person, p->>'department', p->>'note'); end if;
$n$ || o1);
end $m$;

do $m$ declare src text; o1 text; n1 text;
begin
  select pg_get_functiondef('private.cms_letter_context(uuid)'::regprocedure) into src;
  if position('_dept_payroll' in src) > 0 then return; end if;
  o1 := $o$'department', coalesce((select u.name from public.cms_employee_payroll pp join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person limit 1),
                       (select u.name from public.cms_units u where u.code = em.department limit 1), em.department, (select dept from job)),
    'current_department', coalesce((select u.name from public.cms_employee_payroll pp join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person limit 1),
                       (select u.name from public.cms_units u where u.code = em.department limit 1), em.department, (select dept from job)),$o$;
  n1 := $n$'department', coalesce(nullif(btrim(em.department), ''), (select pp.unit_code from public.cms_employee_payroll pp where pp.employee_master_id = p_person limit 1), (select dept from job)),
    'current_department', coalesce(nullif(btrim(em.department), ''), (select pp.unit_code from public.cms_employee_payroll pp where pp.employee_master_id = p_person limit 1), (select dept from job)),
    '_dept_profile', nullif(btrim(em.department), ''), '_dept_payroll', (select pp.unit_code from public.cms_employee_payroll pp where pp.employee_master_id = p_person limit 1),$n$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_context has changed'; end if;
  execute replace(src, o1, n1);
end $m$;

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position('''department''' in src) > 0 then return; end if;
  o1 := $o$  v_title := nullif(btrim(coalesce(f->>'new_position', f->>'revised_position', '')), '');$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_apply_preview has changed'; end if;
  execute replace(src, o1, $n$  if v_type like 'TRL%' and nullif(btrim(coalesce(f->>'new_department', '')), '') is not null
     and upper(btrim(f->>'new_department')) is distinct from upper(coalesce(em.department, '')) then
    items := items || jsonb_build_array(jsonb_build_object('kind', 'department', 'label', 'Department', 'date', v_date, 'department', upper(btrim(f->>'new_department')),
      'allowed', v_can_people and exists (select 1 from public.cms_units u where upper(u.code) = upper(btrim(f->>'new_department')) and u.is_active),
      'now', coalesce(em.department, '—') || coalesce(' · payroll unit ' || (select pp.unit_code from public.cms_employee_payroll pp where pp.employee_master_id = em.id and pp.unit_code is distinct from em.department), ''),
      'after', upper(btrim(f->>'new_department')) || ' from ' || coalesce(to_char(v_date, 'DD Mon YYYY'), '?')
               || case when not exists (select 1 from public.cms_units u where upper(u.code) = upper(btrim(f->>'new_department')) and u.is_active) then ' — not an active department code' else '' end));
  end if;
$n$ || o1);
end $m$;

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_apply(uuid,jsonb)'::regprocedure) into src;
  if position('when ''department'' then' in src) > 0 then return; end if;
  o1 := $o$    when 'arrears' then
$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_apply has changed'; end if;
  execute replace(src, o1, $n$    when 'department' then
      perform private.cms_require('people', 'E', co);
      if d is null then raise exception 'Give the date of the new department.'; end if;
      if d <= today then perform private.cms_apply_department(em.id, it->>'department', 'Letter ' || ref);
      else insert into public.cms_scheduled_changes (person_id, kind, apply_on, payload, source_letter)
           values (em.id, 'position', d, jsonb_build_object('department', it->>'department', 'note', 'Letter ' || ref, 'reference', ref), l.id); end if;
      done := done || jsonb_build_array(jsonb_build_object('kind', 'department', 'date', d, 'department', it->>'department', 'scheduled', d > today));
$n$ || o1);
end $m$;

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('private.cms_apply_scheduled()'::regprocedure) into src;
  if position('Department from' in src) > 0 then return; end if;
  o1 := $o$else 'Position from ' || to_char(s.apply_on, 'DD Mon YYYY') || ': ' || coalesce(s.payload->>'title', '') end$o$;
  if position(o1 in src) = 0 then raise exception 'cms_apply_scheduled has changed'; end if;
  execute replace(src, o1, $n$when 'position' then case when nullif(s.payload->>'title', '') is null and nullif(s.payload->>'department', '') is not null
              then 'Department from ' || to_char(s.apply_on, 'DD Mon YYYY') || ': ' || (s.payload->>'department')
              else 'Position from ' || to_char(s.apply_on, 'DD Mon YYYY') || ': ' || coalesce(s.payload->>'title', '') end else '' end$n$);
end $m$;

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('has_handover', 'Handover of current duties', 'Yes: the letter asks for the handover of the current duties by the handover date.', 'text', 'manual', '', 'yes', true, true, true, false, gen_random_uuid(), now()),
  ('effective_passed', 'Effective date already passed', 'Set automatically: yes when the effective date is before the letter date — the letter then asks for it to be signed and returned instead of "takes effect upon your signed acceptance".', 'text', 'manual', '', 'no', true, true, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
insert into public.hr_letter_options (key, type, options) values
  ('has_handover', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]'),
  ('effective_passed', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]')
on conflict (key) do nothing;
-- (applied) do $d$ declare r record; n int := 0;
-- (applied) begin
-- (applied)   perform set_config('request.jwt.claims', '{"sub":"bc6c4da5-b8c2-48c6-8e35-1211e273950c","role":"authenticated"}', true);
-- (applied)   update public.cms_units set is_active = false, note = 'Merged into HQ.' where code = 'E9' and coalesce(note, '') <> 'Merged into HQ.';
-- (applied)   update public.cms_units set is_active = false, note = 'Merged into E10 (No 22A & 24A).' where code = 'E11' and coalesce(note, '') <> 'Merged into E10 (No 22A & 24A).';
-- (applied)   for r in select em.id, em.employee_name, em.department, pp.unit_code from public.cms_employee_payroll pp join public.employee_master em on em.id = pp.employee_master_id
-- (applied)             where em.employment_status = 'active' and pp.unit_code is distinct from em.department and em.employee_id <> 'M0419F0008' loop
-- (applied)     perform private.cms_apply_department(r.id, r.unit_code, 'profile department set to the payroll unit, approved by CLC 9 Nov 2026');
-- (applied)     perform private.cms_log('person.department', 'employee_master', r.id::text, null, r.employee_name || ': department ' || coalesce(r.department, '—') || ' → ' || r.unit_code || ' (payroll unit)', jsonb_build_object('from', r.department, 'to', r.unit_code));
-- (applied)     n := n + 1;
-- (applied)   end loop;
-- (applied)   raise notice 'updated %', n;
-- (applied) end $d$;
