-- MyEden Group CMS V1.0 · PRI-009 · Facts for this letter
-- When HR chooses a person and a letter, the letter workspace shows the facts that matter for that letter type, from the
-- CMS records, so the drafter and the approver can assess before issuing. Facts that match a placeholder in the template
-- can be inserted with one click. Salary facts need "See salaries"; loan balances need Payroll "view".
-- Leave balances are worked out in the page with the payroll leave engine (same numbers as Leave Balances).

create or replace function private.cms_ldate(d date) returns text language sql stable as $f$
  select to_char(d, 'FMDD FMMonth YYYY') $f$;

-- one fact: label, shown value, placeholder key it can fill, the value inserted, a flag (ok / warn / bad) and a note
create or replace function private.cms_fact(p_label text, p_value text, p_key text default null, p_flag text default null, p_note text default null, p_insert text default null)
returns jsonb language sql immutable as $f$
  select case when p_value is null and p_flag is null then null
    else jsonb_strip_nulls(jsonb_build_object('label', p_label, 'value', coalesce(p_value, '—'), 'key', p_key, 'insert', coalesce(p_insert, p_value),
      'flag', p_flag, 'note', p_note)) end $f$;

create or replace function private.cms_fact_group(p_title text, p_items jsonb[])
returns jsonb language sql immutable as $f$
  select case when exists (select 1 from unnest(p_items) x where x is not null)
    then jsonb_build_object('title', p_title, 'items', (select jsonb_agg(x) from unnest(p_items) x where x is not null)) end $f$;

create or replace function public.cms_letter_facts(p_person uuid, p_type text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare
  em public.employee_master; t text := upper(coalesce(p_type, ''));
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_sal boolean := public.cms_can('people.salary', 'V'); v_pay boolean := public.cms_can('payroll', 'V');
  v_eppd bigint; v_join date; v_conf text; v_resigned date; v_rletter date; v_until date; v_last date; v_title text; v_policy text;
  v_mo int; v_svc text; pe record; ap public.cms_appraisals; inc record; v_boss text; v_unit text; v_paying text;
  v_ext jsonb; v_next int; v_items int; v_loan numeric; v_upl numeric; v_disc jsonb;
  v_ea text; v_notice text; v_req date; v_flag text; v_note text; v_days int; v_cap record;
  g jsonb[] := '{}';
begin
  select * into em from public.employee_master where id = p_person;
  if em.id is null then raise exception 'Person not found.'; end if;
  perform private.cms_require('letters', 'V', private.cms_canon(em.company_code));

  select e.id, m.join_date, m.confirmation_status, m.resigned_date, m.resignation_letter_date, m.notice_until, jt.name into v_eppd, v_join, v_conf, v_resigned, v_rletter, v_until, v_title
    from public.eppd_employees e join public.eppd_employments m on m.employee_id = e.id left join public.eppd_job_titles jt on jt.id = m.job_title_id
   where e.employee_master_id = p_person order by (m.resigned_date is null) desc, m.join_date desc nulls last, m.id desc limit 1;
  v_join := coalesce(v_join, em.start_date);
  v_conf := coalesce(v_conf, case lower(em.confirmation_status) when 'confirmed' then 'C' when 'probation' then 'UP' end);
  v_rletter := coalesce(em.resignation_letter_date, v_rletter); v_last := coalesce(em.actual_last_working_date, v_resigned);
  v_mo := case when v_join is null then null else (extract(year from age(coalesce(v_resigned, v_today), v_join)) * 12 + extract(month from age(coalesce(v_resigned, v_today), v_join)))::int end;
  v_svc := case when v_mo is null then null when v_mo < 12 then v_mo || ' month' || case when v_mo = 1 then '' else 's' end
    else (v_mo / 12) || ' year' || case when v_mo / 12 = 1 then '' else 's' end || case when v_mo % 12 > 0 then ' ' || (v_mo % 12) || ' month' || case when v_mo % 12 = 1 then '' else 's' end else '' end end;
  select b.employee_name into v_boss from public.employee_master b where b.id = em.reports_to_id;
  select coalesce(u.name, pp.unit_code), pp.paying_company_code into v_unit, v_paying
    from public.cms_employee_payroll pp left join public.cms_units u on u.code = pp.unit_code where pp.employee_master_id = p_person;

  -- employment, for every letter
  g := g || private.cms_fact_group('Employment', array[
    private.cms_fact('Start date', private.cms_ldate(v_join), null, case when v_join is null then 'warn' end, case when v_join is null then 'No start date recorded.' end),
    private.cms_fact('Length of service', v_svc, 'months_worked', null, null, v_mo::text),
    private.cms_fact('Position', coalesce(em.approved_job_title, v_title), 'current_position'),
    private.cms_fact('Centre / department', coalesce(v_unit, em.department), 'current_department'),
    private.cms_fact('Employment status', case v_conf when 'UP' then 'Under probation' when 'C' then 'Confirmed' when 'CT' then 'Contract'
      when 'PT' then 'Part time' when 'INT' then 'Internship' when 'R' then 'Resigned' when 'TR' then 'Terminated' when 'DM' then 'Dismissed' else v_conf end),
    private.cms_fact('Reports to', v_boss, 'current_manager', case when v_boss is null then 'warn' end, case when v_boss is null then 'Not set (People › Self-service Access).' end)]);

  -- probation: confirmation, confirmation & increment, probation extension
  if t in ('LOC', 'LOC_LOI', 'PEL') then
    select * into pe from private.cms_probation_end(p_person);
    select coalesce(jsonb_agg(jsonb_build_object('to', r.fields->>'revised_probation_end_date', 'on', r.issued_at::date) order by r.issued_at), '[]'::jsonb), count(*)
      into v_ext, v_next
      from public.hr_letter_records r join public.hr_letter_templates tp on tp.code = r.template_code
     where r.employee_id = p_person and coalesce(tp.letter_type, split_part(tp.code, '_TP', 1)) = 'PEL' and r.status = 'issued';
    v_days := pe.end_date - v_today;
    if em.confirmation_date is not null or v_conf = 'C' then
      v_flag := case when t = 'PEL' then 'bad' else 'warn' end; v_note := 'Already confirmed' || coalesce(' on ' || private.cms_ldate(em.confirmation_date), '') || '.';
    elsif v_days < 0 then v_flag := 'bad'; v_note := 'Overdue by ' || -v_days || ' day' || case when v_days = -1 then '' else 's' end || '.';
    elsif v_days <= 14 then v_flag := 'warn'; v_note := 'Due in ' || v_days || ' day' || case when v_days = 1 then '' else 's' end || '.';
    else v_flag := 'ok'; v_note := 'Due in ' || v_days || ' days.'; end if;
    g := g || private.cms_fact_group('Probation', array[
      private.cms_fact('Probation period', case when pe.source = 'offer' then pe.months || ' months (from the offer)'
        when pe.source = 'recorded' then 'Recorded end date' else '3 months (assumed — not recorded)' end, null, case when pe.source = 'assumed' then 'warn' end,
        case when pe.source = 'assumed' then 'Check the offer letter; record the probation end date on the person.' end),
      private.cms_fact('Probation ends · confirmation due', private.cms_ldate(pe.end_date), 'current_probation_end_date', v_flag, v_note),
      private.cms_fact('Confirmation date (if confirmed on the due date)', private.cms_ldate(coalesce(em.confirmation_date, pe.end_date)), 'confirmation_date'),
      private.cms_fact('Extensions already given', case when v_next = 0 then 'None' else v_next || ': ' || (select string_agg('to ' || coalesce(x->>'to', '?') || ' (letter ' ||
        private.cms_ldate((x->>'on')::date) || ')', '; ') from jsonb_array_elements(v_ext) x) end, null, case when v_next > 0 and t = 'PEL' then 'warn' end,
        case when v_next > 0 and t = 'PEL' then 'This would be extension no. ' || (v_next + 1) || '.' end),
      private.cms_fact('Time on probation so far', case when v_conf = 'UP' then v_svc end)]);
  end if;

  -- latest approved appraisal
  if t in ('LOC', 'LOC_LOI', 'PEL', 'LOI', 'LOP', 'PIP') then
    select * into ap from public.cms_appraisals a where a.person_id = p_person and a.status = 'approved' order by a.approved_at desc nulls last limit 1;
    if ap.id is null then
      g := g || private.cms_fact_group('Appraisal', array[private.cms_fact('Latest approved appraisal', 'None on record', null, 'warn',
        'Start one under Performance & Growth › Appraisals before deciding.')]);
    else
      g := g || private.cms_fact_group('Appraisal', array[
        private.cms_fact('Latest approved appraisal', initcap(replace(coalesce(ap.kind, 'review'), '_', ' ')) || ' · approved ' || private.cms_ldate(ap.approved_at::date), 'review_date', null, null, private.cms_ldate(coalesce(ap.reviewed_at, ap.approved_at)::date)),
        private.cms_fact('Rating', ap.rating::text),
        private.cms_fact('Recommendation', ap.recommendation),
        private.cms_fact('Recommended increment', case when v_sal and ap.rec_increment is not null then to_char(ap.rec_increment, 'FM999,999,990.00') end, 'basic_increment'),
        private.cms_fact('Recommended new probation end', private.cms_ldate(ap.rec_extend_to), 'revised_probation_end_date'),
        private.cms_fact('Improvement areas', ap.improvements::text, 'improvement_areas')]);
    end if;
  end if;

  -- pay: confirmation & increment, increment, promotion
  if t in ('LOC_LOI', 'LOI', 'LOP') and v_sal then
    begin
      select * into inc from public.cms_increments(p_person) limit 1;
    exception when others then
      select null::numeric current_salary, null::date last_change_date, null::numeric last_change, null::date next_review into inc;
    end;
    select coalesce(p.job_title, '') || coalesce(' · ' || p.level, '') pos,
           (select min(b.salary_min) from public.jd_salary_bands b where b.position_id = p.id) jmin, (select max(b.salary_max) from public.jd_salary_bands b where b.position_id = p.id) jmax,
           (select min(c.cap_min) from public.jd_salary_bands b join public.cms_salary_caps c on c.band_id = b.id where b.position_id = p.id) cmin,
           (select max(c.cap_max) from public.jd_salary_bands b join public.cms_salary_caps c on c.band_id = b.id where b.position_id = p.id) cmax
      into v_cap from public.cms_person_position pp join public.jd_positions p on p.id = pp.position_id where pp.person_id = p_person;
    g := g || private.cms_fact_group('Pay', array[
      private.cms_fact('Current basic salary', case when inc.current_salary is not null then 'RM ' || to_char(inc.current_salary, 'FM999,999,990.00') end, 'current_basic', null, null, to_char(inc.current_salary, 'FM999,999,990.00')),
      private.cms_fact('Last increment', case when inc.last_change_date is not null then 'RM ' || to_char(inc.last_change, 'FM999,999,990.00') || ' on ' || private.cms_ldate(inc.last_change_date) else 'None recorded' end),
      private.cms_fact('Next salary review', private.cms_ldate(inc.next_review), null, case when inc.next_review < v_today then 'warn' end, case when inc.next_review < v_today then 'Review date has passed.' end),
      private.cms_fact('JD position (Career Paths)', nullif(v_cap.pos, ''), 'jd_reference', case when v_cap.pos is null then 'warn' end, case when v_cap.pos is null then 'Not placed on a JD position yet.' end),
      private.cms_fact('JD salary range', case when v_cap.jmin is not null then 'RM ' || to_char(v_cap.jmin, 'FM999,999,990') || ' – ' || to_char(v_cap.jmax, 'FM999,999,990') end),
      private.cms_fact('MyEden cap', case when v_cap.cmax is not null then 'RM ' || to_char(v_cap.cmin, 'FM999,999,990') || ' – ' || to_char(v_cap.cmax, 'FM999,999,990') end, null,
        case when v_cap.cmax is not null and inc.current_salary >= v_cap.cmax then 'bad' when v_cap.cmax is not null and inc.current_salary >= v_cap.cmax * 0.95 then 'warn' end,
        case when v_cap.cmax is not null and inc.current_salary >= v_cap.cmax then 'Salary is at or above the cap.' when v_cap.cmax is not null and inc.current_salary >= v_cap.cmax * 0.95 then 'Salary is within 5% of the cap.' end)]);
  end if;

  -- leaving: resignation acceptance, termination
  if t in ('RL', 'TL') then
    v_ea := case when v_mo is null then null when v_mo < 24 then '4 weeks' when v_mo < 60 then '6 weeks' else '8 weeks' end;
    select case when v_conf = 'UP' then (value->>'probation_weeks') || ' weeks' else (select (b->>'weeks') || ' weeks' from jsonb_array_elements(value->'bands') b
      where extract(year from age(coalesce(v_rletter, v_today), v_join)) >= (b->>'from_years')::numeric
        and (b->>'to_years' is null or extract(year from age(coalesce(v_rletter, v_today), v_join)) < (b->>'to_years')::numeric) limit 1) end
      into v_policy from public.eppd_policies where key = 'notice_period';
    v_notice := case when em.notice_period_value is not null then em.notice_period_value || ' ' || coalesce(em.notice_period_unit, '') end;
    v_req := coalesce(em.required_last_working_date, v_until, case when v_rletter is not null and coalesce(v_notice, v_policy, v_ea) ~ '^\d+ weeks?$'
      then v_rletter + (split_part(coalesce(v_notice, v_policy, v_ea), ' ', 1)::int * 7) - 1 end);
    select count(*) into v_items from public.cms_items i where i.person_id = p_person and i.status in ('issued', 'held');
    if v_pay then
      select sum(greatest(0, l.principal - coalesce((select sum(coalesce((it->>'override')::numeric, (it->>'amount')::numeric, 0))
          from public.eppd_pay_lines pl join public.eppd_pay_runs r on r.id = pl.run_id, jsonb_array_elements(coalesce(pl.items, '[]'::jsonb)) it
         where r.status = 'finalised' and not coalesce(pl.excluded, false) and it->>'key' = 'LOAN:' || l.id), 0)))
        into v_loan from public.eppd_loans l where l.employee_id = v_eppd and l.status = 'active';
    end if;
    g := g || private.cms_fact_group('Notice & last day', array[
      private.cms_fact('Resignation letter date', private.cms_ldate(v_rletter), 'resignation_date', case when t = 'RL' and v_rletter is null then 'warn' end,
        case when t = 'RL' and v_rletter is null then 'Not recorded — record the resignation on the person first.' end),
      private.cms_fact('Notice period in the contract', coalesce(v_notice, 'Not recorded'), case when v_notice is not null then 'notice_period' end),
      private.cms_fact('Notice by HR policy', v_policy, case when v_notice is null then 'notice_period' end, null, case when v_conf = 'UP' then 'On probation.' else 'Based on completed years of service.' end),
      private.cms_fact('Employment Act minimum (s.12)', v_ea, null, null, 'Based on ' || coalesce(v_svc, '?') || ' of service.'),
      private.cms_fact('Last working day by the notice', private.cms_ldate(v_req), 'last_notice_date'),
      private.cms_fact('Last working day agreed', private.cms_ldate(v_last), 'last_working_day',
        case when v_last < v_req then 'warn' end, case when v_last < v_req then
          'Earlier than the notice allows by ' || (v_req - v_last) || ' days — notice in lieu or leave offset.' end),
      private.cms_fact('Company items still to hand over', case when v_items = 0 then 'None' else v_items::text end, null, case when v_items > 0 then 'warn' end),
      private.cms_fact('Company loan balance', case when v_loan > 0 then 'RM ' || to_char(v_loan, 'FM999,999,990.00') when v_pay then 'None' end, null, case when v_loan > 0 then 'warn' end,
        case when v_loan > 0 then 'Recovered in the final settlement.' end)]);
  end if;

  -- earlier letters: disciplinary and performance letters
  if t in ('WL', 'SCL', 'EL', 'DI', 'SAL', 'TL', 'PIP') then
    select jsonb_agg(private.cms_fact(coalesce(tp.title, r.template_code), private.cms_ldate(r.issued_at::date)
             || coalesce(' · ' || nullif(r.fields->>'warning_level', ''), '') || coalesce(' · ' || left(nullif(coalesce(r.fields->>'matter_subject', r.fields->>'allegation_subject'), ''), 80), '')) order by r.issued_at)
      into v_disc from public.hr_letter_records r join public.hr_letter_templates tp on tp.code = r.template_code
     where r.employee_id = p_person and r.status = 'issued' and coalesce(tp.letter_type, split_part(tp.code, '_TP', 1)) in ('WL', 'SCL', 'EL', 'DI', 'SAL', 'TL', 'PIP');
    g := g || jsonb_build_object('title', 'Earlier letters', 'items',
      coalesce(v_disc, jsonb_build_array(private.cms_fact('Warnings, show cause, inquiries', 'None issued in the CMS', null, 'ok'))));
  end if;

  -- transfer
  if t = 'TRL' then
    g := g || private.cms_fact_group('Now', array[
      private.cms_fact('Employer', (select coalesce(c.name, em.company_code) from public.cms_companies c where c.code = private.cms_canon(em.company_code))),
      private.cms_fact('Paid by', (select coalesce(c.name, v_paying) from public.cms_companies c where c.code = v_paying)),
      private.cms_fact('Centre', coalesce(v_unit, em.department), 'current_location'),
      private.cms_fact('Reporting manager', v_boss, 'current_reporting_manager')]);
  end if;

  -- unpaid leave
  if t = 'UAL' then
    select sum(l.days) into v_upl from public.eppd_leave_records l where l.employee_id = v_eppd and l.leave_type = 'UPL'
       and l.status <> 'cancelled' and l.date_from >= date_trunc('year', v_today)::date;
    g := g || private.cms_fact_group('Unpaid leave', array[private.cms_fact('Unpaid leave this year', coalesce(v_upl, 0)::text || ' days')]);
  end if;

  return jsonb_build_object('type', t, 'eppd_employee_id', v_eppd, 'last_day', coalesce(v_last, v_req),
    'leave', t in ('RL', 'TL', 'UAL'), 'groups', coalesce((select jsonb_agg(x) from unnest(g) x where x is not null), '[]'::jsonb));
end $f$;
revoke all on function public.cms_letter_facts(uuid, text) from public, anon;
grant execute on function public.cms_letter_facts(uuid, text) to authenticated;
