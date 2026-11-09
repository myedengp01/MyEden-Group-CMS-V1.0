-- MyEden Group CMS V1.0 · v2026.11.09 · Confirmation letters: confirmed on the probation end date, increment from the coming 1st, salary arrears (CLC 9 Nov 2026)
-- * increment_start: default "1st of the following month" (next_month).
-- * Backdated increment: arrears (months not yet paid at the new rate) paid once in the first open payroll month — switch + months / amount / payroll month.
-- * Payment type ARREARS "Salary arrears": wages (EPF, SOCSO, EIS, PCB), EA form B1(a); a one-month row in eppd_allowances is paid by the payroll engine.
-- * cms_letter_context: _open_payroll = the month after the latest finalised payroll.
-- * Update records: "Salary arrears" item → the one-off row in that payroll month (refused if that month is already finalised).
insert into public.eppd_payment_types (code, name, kind, category, subject_epf, subject_socso, subject_eis, subject_pcb, is_recurring, is_system, is_active, sort_order, notes, treatment)
select 'ARREARS', 'Salary arrears', 'earning', 'basic', true, true, true, true, false, true, true, 2,
       'Back pay of a backdated salary increment (from an HR letter): wages — EPF, SOCSO, EIS and PCB; EA form B1(a).', 'wages'
 where not exists (select 1 from public.eppd_payment_types where code = 'ARREARS');

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, default_value, required, editable, active, protected, revision, updated_at) values
  ('arrears', 'Backdated increment (salary arrears)', 'Yes when the increment starts in a month already paid: the difference is paid once as salary arrears.', 'text', 'manual', '', 'no', true, true, true, false, gen_random_uuid(), now()),
  ('arrears_months', 'Arrears for (months)', 'e.g. September to October 2026', 'text', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('arrears_amount', 'Arrears amount (RM)', 'Increment × the months already paid at the old rate.', 'money', 'manual', '', '', true, true, true, false, gen_random_uuid(), now()),
  ('arrears_payroll_month', 'Arrears paid in the payroll of', 'e.g. November 2026 (the first payroll month still open).', 'text', 'manual', '', '', true, true, true, false, gen_random_uuid(), now())
on conflict (key) do nothing;
insert into public.hr_letter_options (key, type, options) values ('arrears', 'switch', '[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]') on conflict (key) do nothing;
update public.hr_letter_options set options = '[{"value":"next_month","label":"1st of the following month"},{"value":"confirmation","label":"On the confirmation date"},{"value":"other","label":"Another date"}]'::jsonb
 where key = 'increment_start' and options->0->>'value' = 'confirmation';
update public.hr_letter_placeholders set default_value = 'next_month', description = 'The 1st of the month after the confirmation (default), the confirmation date, or another date.', revision = gen_random_uuid(), updated_at = now()
 where key = 'increment_start' and default_value = 'confirmation';

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_context(uuid)'::regprocedure) into src;
  if position('_open_payroll' in src) > 0 then return; end if;
  o1 := $o$ || jsonb_build_object('_company',$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_context has changed'; end if;
  execute replace(src, o1, $n$ || jsonb_build_object('_open_payroll', (select to_char((max(r.period) + interval '1 month')::date, 'YYYY-MM-DD') from public.eppd_pay_runs r where r.status = 'finalised'))$n$ || o1);
end $m$;

do $m$ declare src text; o1 text; o2 text; o3 text; o4 text;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position('''arrears''' in src) > 0 then return; end if;
  o1 := $o$ v_have boolean := false; v_pst date;$o$;
  o2 := $o$  v_title := nullif(btrim(coalesce(f->>'new_position', f->>'revised_position', '')), '');$o$;
  o3 := $o$  new_sal := private.cms_money(f->>'revised_basic');$o$;
  o4 := $o$' payroll' || case when v_type like 'TRL%' and v_pend is not null then$o$;
  if position(o1 in src) = 0 or position(o2 in src) = 0 or position(o3 in src) = 0 or position(o4 in src) = 0 then raise exception 'cms_letter_apply_preview has changed'; end if;
  src := replace(src, o1, o1 || ' v_arm date; v_ara numeric; v_fin boolean; v_sal0 date; v_back boolean := false;');
  -- backdated increment: the new basic goes into the first open payroll month; the months before are paid once as arrears
  src := replace(src, o3, $n$  v_ara := private.cms_money(f->>'arrears_amount');
  if lower(coalesce(f->>'arrears', '')) = 'yes' then
    v_arm := coalesce(private.cms_parse_date('1 ' || btrim(coalesce(f->>'arrears_payroll_month', ''))),
                      (select (max(r.period) + interval '1 month')::date from public.eppd_pay_runs r where r.status = 'finalised'), date_trunc('month', current_date)::date);
    if v_arm > v_sal then v_sal0 := v_sal; v_sal := v_arm; v_back := true; end if;
  end if;
$n$ || o3);
  src := replace(src, o4, $n$' payroll' || case when v_back then ' (increment from ' || to_char(v_sal0, 'DD Mon YYYY') || '; the months before are paid as arrears)' else '' end || case when v_type like 'TRL%' and v_pend is not null then$n$);
  src := replace(src, o2, $n$  if lower(coalesce(f->>'arrears', '')) = 'yes' and v_ara > 0 and m.id is not null then
    v_fin := exists (select 1 from public.eppd_pay_runs r where r.period = v_arm and r.status = 'finalised');
    items := items || jsonb_build_array(jsonb_build_object('kind', 'arrears', 'label', 'Salary arrears', 'date', v_arm, 'amount', v_ara, 'months', f->>'arrears_months',
      'allowed', v_can_pay and not v_fin, 'now', '—',
      'after', 'RM ' || to_char(v_ara, 'FM999,990.00') || ' once in the ' || to_char(v_arm, 'FMMonth YYYY') || ' payroll' || coalesce(' (' || nullif(f->>'arrears_months', '') || ')', '')
               || case when v_fin then ' — that payroll is already finalised: choose a later month' else '' end));
  end if;
$n$ || o2);
  execute src;
end $m$;

do $m$ declare src text; o1 text;
begin
  select pg_get_functiondef('public.cms_letter_apply(uuid,jsonb)'::regprocedure) into src;
  if position('when ''arrears'' then' in src) > 0 then return; end if;
  o1 := $o$    when 'probation' then
$o$;
  if position(o1 in src) = 0 then raise exception 'cms_letter_apply has changed'; end if;
  execute replace(src, o1, $n$    when 'arrears' then
      if not public.cms_can('payroll.increments', 'C', co) then raise exception 'Adding salary arrears needs permission to record increments.' using errcode = '42501'; end if;
      if m.id is null then raise exception 'No current employment in payroll for the arrears.'; end if;
      d := date_trunc('month', coalesce(d, current_date))::date;
      if exists (select 1 from public.eppd_pay_runs r where r.period = d and r.status = 'finalised') then raise exception 'The % payroll is already finalised — choose a later month for the arrears.', to_char(d, 'FMMonth YYYY'); end if;
      if not ((it->>'amount')::numeric > 0) then raise exception 'Give the arrears amount.'; end if;
      insert into public.eppd_allowances (assignment_id, payment_type_id, amount, start_date, end_date, note)
      values ((select a.id from public.eppd_assignments a where a.employment_id = m.id order by a.is_primary desc, a.id limit 1),
              (select t.id from public.eppd_payment_types t where t.code = 'ARREARS'), (it->>'amount')::numeric, d, (d + interval '1 month - 1 day')::date,
              'Salary arrears' || coalesce(' ' || nullif(it->>'months', ''), '') || ', letter ' || ref);
      done := done || jsonb_build_array(jsonb_build_object('kind', 'arrears', 'date', d, 'amount', (it->>'amount')::numeric, 'months', it->>'months'));
$n$ || o1);
end $m$;
