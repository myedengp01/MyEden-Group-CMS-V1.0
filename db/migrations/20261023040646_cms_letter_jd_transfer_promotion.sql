begin;
set local lock_timeout='3s';
create function private.cms_jd_plain(p jsonb) returns text language plpgsql immutable set search_path='' as $$
declare result text;
begin
 if p is null or p='null'::jsonb then return ''; end if;
 if jsonb_typeof(p)='object' then select string_agg(initcap(replace(key,'_',' '))||': '||private.cms_jd_plain(value),E'\n' order by key) into result from jsonb_each(p);return coalesce(result,''); end if;
 if jsonb_typeof(p)='array' then select string_agg(private.cms_jd_plain(value),E'\n' order by ord) into result from jsonb_array_elements(p) with ordinality x(value,ord);return coalesce(result,''); end if;
 return p#>>'{}';
end $$;
revoke all on function private.cms_jd_plain(jsonb) from public,anon,authenticated;
-- Trial access uses both the existing gateway admin role and CMS company permissions.
create function private.cms_letter_jd_require(p_person uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare c text;
begin
 if auth.uid() is null or not public.eaf_v2_is_admin(auth.uid()) then raise exception 'Administrator testing access required.' using errcode='42501'; end if;
 select private.cms_canon(company_code) into c from public.employee_master where id=p_person;
 if c is null then raise exception 'Choose an employee.'; end if;
 perform private.cms_require('letters.draft','V',c);
 return c;
end $$;
revoke all on function private.cms_letter_jd_require(uuid) from public,anon,authenticated;

create function public.cms_letter_jd_options(p_person uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c text;
begin
 c:=private.cms_letter_jd_require(p_person);
 return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'title',p.job_title,'department',d.name,'reference',p.reference,'version',p.version,'company',e.code) order by d.name,p.job_title,p.reference)
 from public.jd_positions p join public.jd_entities e on e.id=p.entity_id join public.jd_departments d on d.id=p.department_id and d.entity_id=e.id
 where private.cms_canon(e.code)=c and e.is_active and d.is_active and p.status='approved'
 and nullif(btrim(p.version),'') is not null and nullif(btrim(p.reference),'') is not null
 and (p.effective_date is null or p.effective_date <= (now() at time zone 'Asia/Kuala_Lumpur')::date)), '[]'::jsonb);
end $$;
revoke all on function public.cms_letter_jd_options(uuid) from public,anon;
grant execute on function public.cms_letter_jd_options(uuid) to authenticated;

-- Snapshot excludes salary bands, recruitment settings and other internal planning data.
create function public.cms_letter_jd_get(p_person uuid,p_position uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c text; p public.jd_positions; d text; doc text; details jsonb; part record;
begin
 c:=private.cms_letter_jd_require(p_person);
 select x.* into p from public.jd_positions x join public.jd_entities e on e.id=x.entity_id join public.jd_departments z on z.id=x.department_id and z.entity_id=e.id
 where x.id=p_position and private.cms_canon(e.code)=c and e.is_active and z.is_active and x.status='approved'
 and nullif(btrim(x.version),'') is not null and nullif(btrim(x.reference),'') is not null
 and (x.effective_date is null or x.effective_date <= (now() at time zone 'Asia/Kuala_Lumpur')::date);
 if p.id is null then raise exception 'Choose a current approved JD for this employee''s legal company.'; end if;
 select name into d from public.jd_departments where id=p.department_id;
 doc:=concat_ws(E'\n','Appendix A — Approved Job Description','Position: '||p.job_title,'Department: '||d,'Reference: '||p.reference,'Version: '||p.version,'Effective date: '||coalesce(p.effective_date::text,''),'Level: '||coalesce(p.level,''),'Reporting to: '||coalesce(p.reports_to,''),'Direct reports: '||coalesce(p.direct_reports,''),'Works closely with: '||coalesce(p.works_closely_with,''),'Employment type: '||coalesce(p.employment_type,''),'Work location: '||coalesce(p.location,''),'Purpose',p.purpose);
 for part in select title,description from public.jd_responsibilities where position_id=p.id order by sequence,id loop
  doc:=doc||E'\n\n'||coalesce(part.title,'Responsibility')||E'\n'||coalesce(part.description,'');
 end loop;
 doc:=doc||E'\n\n'||concat_ws(E'\n','Minimum qualifications',p.minimum_qualifications,'Required experience',p.required_experience,'Skills and knowledge',p.skills_knowledge,'Authority boundaries',p.authority_boundaries,'Role interfaces',p.role_interface,'Appointment note',p.appointment_note);
 for part in select * from (values ('Working conditions',p.working_conditions),('Safety and child protection',p.safety_child_protection),('Performance expectations',p.performance_expectations),('Accountability',p.accountability_model)) x(label,value) where value is not null and value not in ('null'::jsonb,'[]'::jsonb,'{}'::jsonb) loop
  doc:=doc||E'\n\n'||part.label||E'\n'||private.cms_jd_plain(part.value);
 end loop;
 for part in select area,measure,review_frequency from public.jd_kpis where position_id=p.id order by sequence,id loop doc:=doc||E'\n\nPerformance measure: '||concat_ws(' — ',part.area,part.measure,part.review_frequency); end loop;
 for part in select name from public.jd_competencies where position_id=p.id order by sequence,id loop doc:=doc||E'\nCompetency: '||part.name; end loop;
 for part in select value_name,expectation from public.jd_core_values where position_id=p.id order by sequence,id loop doc:=doc||E'\nCore value: '||concat_ws(' — ',part.value_name,part.expectation); end loop;
 return jsonb_build_object('position_id',p.id,'reference',p.reference,'version',p.version,'company',c,'text',doc,'fingerprint',md5(doc),
 'fields',jsonb_build_object('new_position',p.job_title,'new_department',d,'new_location',coalesce(p.location,''),'new_reporting_manager',coalesce(p.reports_to,''),'jd_reference',p.reference,'jd_version',p.version));
end $$;
revoke all on function public.cms_letter_jd_get(uuid,uuid) from public,anon;
grant execute on function public.cms_letter_jd_get(uuid,uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.cms_letter_save(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare em public.employee_master; t public.hr_letter_templates; l public.hr_letter_records; v uuid := nullif(p->>'id', '')::uuid;
        sub boolean := coalesce((p->>'submit')::boolean, false); ap uuid := nullif(p->>'appraisal_id', '')::uuid; snap jsonb; jd jsonb; f jsonb; txt text; k text; amount numeric; current_amount numeric;
begin
  if coalesce((p->>'issue')::boolean, false) then raise exception 'Letters are now approved before they are issued: save the draft and submit it.'; end if;
  select * into em from public.employee_master where id = (p->>'person_id')::uuid;
  if em.id is null then raise exception 'Choose the person.'; end if;
  perform private.cms_require('letters.draft', 'V', private.cms_canon(em.company_code));
  select * into t from public.hr_letter_templates where code = p->>'template';
  if t.code is null then raise exception 'Choose the letter.'; end if;
  if t.code='TRL_LOP' then perform private.cms_letter_jd_require(em.id); end if;
  if t.code<>'TRL_LOP' and (t.status <> 'published' or not t.active) then raise exception 'This template is not switched on for use.'; end if;
  if t.code='TRL_LOP' then
    if t.status='retired' then raise exception 'This template is retired.'; end if;
    f:=coalesce(p->'fields','{}'::jsonb); if jsonb_typeof(f)<>'object' or pg_column_size(f)>65536 then raise exception 'Invalid letter fields.'; end if;
    f:=f || (private.cms_letter_context(em.id)-'_company'-'_home_address');
    if nullif(f->>'_jd_position_id','') is not null then
      jd:=public.cms_letter_jd_get(em.id,(f->>'_jd_position_id')::uuid);
      if f->>'_jd_fingerprint' is distinct from jd->>'fingerprint' then raise exception 'The JD changed. Select it again and review the updated Appendix A.'; end if;
      f:=f||(jd->'fields');
    else
      if sub then raise exception 'Select an approved JD before submitting.'; end if;
      f:=f||jsonb_build_object('new_position','','new_department','','new_location','','new_reporting_manager','','jd_reference','','jd_version','');
    end if;
    if nullif(f->>'basic_increment','') is not null and nullif(f->>'current_basic','') is not null then
      if replace(f->>'basic_increment',',','') !~ '^[0-9]+([.][0-9]+)?$' or replace(f->>'current_basic',',','') !~ '^[0-9]+([.][0-9]+)?$' then raise exception 'Enter valid basic salary amounts.'; end if;
      amount:=replace(f->>'basic_increment',',','')::numeric; current_amount:=replace(f->>'current_basic',',','')::numeric;
      if amount<0 or current_amount<=0 then raise exception 'Enter a non-negative increment and a positive current basic salary.'; end if;
      f:=f||jsonb_build_object('current_basic',to_char(current_amount,'FM999999990.00'),'basic_increment',to_char(amount,'FM999999990.00'),'basic_increment_pct',to_char(round(100*amount/current_amount,2),'FM999999990.00'),'revised_basic',to_char(current_amount+amount,'FM999999990.00'));
    else f:=f||jsonb_build_object('basic_increment_pct','','revised_basic',''); end if;
    case f->>'_post_probation_mode'
    when 'maintained' then f:=f||jsonb_build_object('post_probation_salary_arrangement','Following successful assessment, the monthly basic salary remains RM '||coalesce(f->>'revised_basic','{{revised_basic}}')||'. No further increment is agreed in this letter.');
    when 'review' then f:=f||jsonb_build_object('post_probation_salary_arrangement','Salary will be reviewed after successful assessment. No additional increment or amount is guaranteed by this letter. Any approved change will be confirmed separately in writing.');
    when 'agreed' then
      if nullif(f->>'post_probation_increment','') is null or nullif(f->>'revised_basic','') is null or nullif(f->>'post_probation_effective_date','') is null then
        f:=f||jsonb_build_object('post_probation_salary_arrangement','{{post_probation_details}}');
      else
        if replace(f->>'post_probation_increment',',','') !~ '^[0-9]+([.][0-9]+)?$' then raise exception 'Enter a valid post-assessment increment.'; end if;
        amount:=replace(f->>'post_probation_increment',',','')::numeric;current_amount:=replace(f->>'revised_basic',',','')::numeric;
        if amount<0 or current_amount<=0 then raise exception 'Invalid post-assessment salary increment.'; end if;
        f:=f||jsonb_build_object('post_probation_salary_arrangement','Upon successful completion confirmed in writing, the following agreed increment takes effect from '||(f->>'post_probation_effective_date')||E'.
Description | Current | Increment | Increment (%) | Revised
Monthly basic salary | RM '||to_char(current_amount,'FM999999990.00')||' | RM '||to_char(amount,'FM999999990.00')||' | '||to_char(round(100*amount/current_amount,2),'FM999999990.00')||' % | RM '||to_char(current_amount+amount,'FM999999990.00'));
      end if;
    else f:=f||jsonb_build_object('post_probation_salary_arrangement','{{post_probation_arrangement}}');
    end case;
    txt:=t.body;
    for k in select distinct m[1] from regexp_matches(t.body,'\{\{([a-z0-9_]+)\}\}','g') m loop
      if nullif(btrim(f->>k),'') is not null then txt:=replace(txt,'{{'||k||'}}',f->>k);
      elsif exists(select 1 from public.hr_letter_placeholders where key=k and not required) then txt:=replace(txt,'{{'||k||'}}',''); end if;
    end loop;
    txt:=replace(txt,'Appendix B — Revised Terms and Conditions',coalesce(jd->>'text','Appendix A — {{approved_job_description}}')||E'\n\nAppendix B — Revised Terms and Conditions');
    p:=p||jsonb_build_object('fields',f,'text',txt);
  end if;
  if sub then
    if nullif(p->>'text', '') is null then raise exception 'Nothing to submit.'; end if;
    if (p->>'text') ~ '\{\{[a-z0-9_]+\}\}' then raise exception 'Fill in every field before submitting (some {{…}} are still empty).'; end if;
  end if;
  if v is not null then
    select * into l from public.hr_letter_records where id = v for update;
    if l.id is null or l.status <> 'draft' then raise exception 'Only a draft can be changed.'; end if;
    if l.created_by is distinct from auth.uid() and not public.cms_can('letters', 'E') then raise exception 'Only the person who drafted it can change this letter.'; end if;
    ap := coalesce(ap, nullif(l.source_snapshot->>'appraisal_id', '')::uuid);
  end if;
  snap := jsonb_build_object('source', 'cms', 'appraisal_id', ap, 'text', p->>'text', 'company', p->'company',
            'created_by_name', coalesce(l.source_snapshot->>'created_by_name', private.cms_my_name()))
          || case when sub then jsonb_build_object('submitted_at', now(), 'submitted_by_name', private.cms_my_name()) else '{}'::jsonb end;
  if t.code='TRL_LOP' then snap:=snap||jsonb_build_object('jd',jd,'testing_only',true); end if;
  if v is null then
    insert into public.hr_letter_records (employee_id, company_code, template_code, template_version, status, fields, source_snapshot, created_by)
    values (em.id, private.cms_canon(em.company_code), t.code, t.version, case when sub then 'pending_approval' else 'draft' end, coalesce(p->'fields', '{}'::jsonb), snap, auth.uid())
    returning id into v;
  else
    update public.hr_letter_records set employee_id = em.id, company_code = private.cms_canon(em.company_code), template_code = t.code, template_version = t.version,
           status = case when sub then 'pending_approval' else 'draft' end, fields = coalesce(p->'fields', fields), source_snapshot = snap, updated_at = now()
     where id = v;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (v, auth.uid(), case when sub then 'submitted_for_approval' else 'draft_saved' end, jsonb_build_object('source', 'cms'));
  if sub then
    perform private.cms_log('letter.submitted', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || t.title || ' sent for approval', jsonb_build_object('letter_id', v));
  end if;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.cms_letter_issue(p_id uuid, p_docx_path text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l public.hr_letter_records; em public.employee_master; t public.hr_letter_templates; ap uuid;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  if not (public.cms_can('letters.issue', 'V', private.cms_canon(em.company_code)) or public.cms_can('letters.issue', 'V', private.cms_canon(em.company_code))) then
    raise exception 'Not allowed: issuing HR letters' using errcode = '42501';
  end if;
  if l.template_code='TRL_LOP' or coalesce((l.source_snapshot->>'testing_only')::boolean,false) then raise exception 'TRL_LOP is under admin testing. Operational issuance is disabled.' using errcode='42501'; end if;
  if l.status <> 'approved' then raise exception 'Only an approved letter can be issued.'; end if;
  select * into t from public.hr_letter_templates where code = l.template_code;
  if t.format = 'docx' and (p_docx_path is null or p_docx_path !~ ('^cms/issued/' || l.id::text || '\.docx$')) then raise exception 'The filled Word letter was not saved — try again.'; end if;
  update public.hr_letter_records set status = 'issued', issued_by = auth.uid(), issued_at = now(), updated_at = now(),
         issued_snapshot = jsonb_build_object('text', coalesce(l.source_snapshot->>'approved_text', l.source_snapshot->>'text'), 'issued_by_name', private.cms_my_name(),
                                              'company', l.source_snapshot->'company', 'template_version', l.template_version, 'format', t.format, 'docx_path', p_docx_path,
                                              'approved_by_name', l.source_snapshot->>'approved_by_name')
   where id = l.id;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), 'issued', jsonb_build_object('source', 'cms'));
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (em.id, 'hr_letter_issued', t.title, jsonb_build_object('letter_id', l.id, 'template', t.code), auth.uid());
  perform private.cms_log('letter.issued', 'employee_master', em.id::text, private.cms_canon(em.company_code), em.employee_name || ': ' || t.title || ' issued', jsonb_build_object('letter_id', l.id));
  ap := nullif(l.source_snapshot->>'appraisal_id', '')::uuid;
  if ap is not null and coalesce(t.letter_type, t.code) = 'PEL' then
    update public.cms_appraisals set letter_issued_at = now(), letter_ref = l.id::text, letter_by = auth.uid(), updated_at = now()
     where id = ap and person_id = em.id and recommendation = 'extend' and letter_issued_at is null;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.cms_letter_decide(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l public.hr_letter_records; em public.employee_master; t public.hr_letter_templates;
begin
  select * into l from public.hr_letter_records where id = p_id for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  select * into em from public.employee_master where id = l.employee_id;
  perform private.cms_require('letters.approve', 'V', private.cms_canon(em.company_code));
  if l.template_code='TRL_LOP' then perform private.cms_letter_jd_require(em.id); end if;
  if l.status <> 'pending_approval' then raise exception 'This letter is not waiting for approval.'; end if;
  if l.created_by = auth.uid() then raise exception 'You drafted this letter — someone else must approve it.'; end if;
  select * into t from public.hr_letter_templates where code = l.template_code;
  if p_approve then
    if t.version is distinct from l.template_version then raise exception 'The template changed after this letter was drafted — send it back so the drafter can refresh it.'; end if;
    update public.hr_letter_records set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now(),
           source_snapshot = source_snapshot || jsonb_build_object('approved_by_name', private.cms_my_name(), 'approved_text', source_snapshot->>'text') - 'rejected'
     where id = l.id;
  else
    if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for sending it back.'; end if;
    update public.hr_letter_records set status = 'draft', updated_at = now(),
           source_snapshot = source_snapshot || jsonb_build_object('rejected', jsonb_build_object('reason', btrim(p_reason), 'by', private.cms_my_name(), 'at', now()))
     where id = l.id;
  end if;
  insert into public.hr_letter_audit (letter_id, actor_id, action, event_snapshot) values (l.id, auth.uid(), case when p_approve then 'approved' else 'rejected' end, jsonb_build_object('reason', p_reason, 'source', 'cms'));
  perform private.cms_log('letter.' || case when p_approve then 'approved' else 'sent_back' end, 'employee_master', em.id::text, private.cms_canon(em.company_code),
    em.employee_name || ': ' || t.title || case when p_approve then ' approved' else ' sent back: ' || btrim(p_reason) end, jsonb_build_object('letter_id', l.id));
  return case when p_approve then 'approved' else 'draft' end;
end $function$
;
CREATE OR REPLACE FUNCTION public.cms_letters()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform private.cms_require('letters', 'V');
  return jsonb_build_object('can_edit', public.cms_can('letters.draft', 'V'), 'can_change', public.cms_can('letters.templates', 'V'), 'can_publish', public.cms_can('letters.publish', 'V'), 'can_switch', public.cms_can('letters.switch', 'V'), 'can_placeholders', public.cms_can('letters.placeholders', 'V'), 'can_void', public.cms_can('letters', 'E'),
    'can_approve', public.cms_can('letters.approve', 'V'), 'can_issue', public.cms_can('letters.issue', 'V'),
    'me', auth.uid(), 'can_jd_test',coalesce(public.eaf_v2_is_admin(auth.uid()),false),
    'templates', coalesce((select jsonb_agg(private.cms_letter_tpl_json(t) order by coalesce(t.letter_type, t.code), t.code) from public.hr_letter_templates t where t.code<>'TRL_LOP' or public.eaf_v2_is_admin(auth.uid())), '[]'::jsonb),
    'placeholders', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'description', description, 'kind', kind, 'source', source, 'source_key', source_key,
        'required', required, 'editable', editable, 'protected', protected, 'active', active, 'default', default_value, 'revision', revision) order by key) from public.hr_letter_placeholders), '[]'::jsonb),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'person_id', l.employee_id, 'name', em.employee_name, 'employee_id', em.employee_id, 'company', private.cms_canon(em.company_code),
          'template', l.template_code, 'title', t.title, 'format', t.format, 'status', l.status, 'fields', l.fields,
          'jd',l.source_snapshot->'jd', 'testing_only',l.source_snapshot->'testing_only',
          'text', coalesce(l.issued_snapshot->>'text', l.source_snapshot->>'text'), 'docx_path', l.issued_snapshot->>'docx_path',
          'created_at', l.created_at, 'created_by', l.created_by, 'created_by_name', l.source_snapshot->>'created_by_name',
          'submitted_at', l.source_snapshot->>'submitted_at', 'approved_at', l.approved_at, 'approved_by_name', l.source_snapshot->>'approved_by_name',
          'rejected', l.source_snapshot->'rejected', 'issued_at', l.issued_at, 'issued_by', l.issued_snapshot->>'issued_by_name',
          'void_reason', l.source_snapshot->>'void_reason', 'appraisal_id', l.source_snapshot->>'appraisal_id') order by coalesce(l.issued_at, l.updated_at, l.created_at) desc)
      from public.hr_letter_records l join public.employee_master em on em.id = l.employee_id left join public.hr_letter_templates t on t.code = l.template_code
      where private.cms_can_company('letters', 'V', private.cms_canon(em.company_code)) and (l.template_code<>'TRL_LOP' or public.eaf_v2_is_admin(auth.uid()))), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('person_id', em.id, 'employee_id', em.employee_id, 'name', em.employee_name, 'company', private.cms_canon(em.company_code), 'status', em.employment_status) order by em.employee_name)
      from public.employee_master em where em.employment_status in ('active','onboarding','former') and private.cms_can_company('letters', 'V', private.cms_canon(em.company_code))), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.cms_letter_facts(p_person uuid, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  g := g || private.cms_fact_group('Employment', array[
    private.cms_fact('Start date', private.cms_ldate(v_join), null, case when v_join is null then 'warn' end, case when v_join is null then 'No start date recorded.' end),
    private.cms_fact('Length of service', v_svc, 'months_worked', null, null, v_mo::text),
    private.cms_fact('Position', coalesce(em.approved_job_title, v_title), 'current_position'),
    private.cms_fact('Centre / department', coalesce(v_unit, em.department), 'current_department'),
    private.cms_fact('Employment status', case v_conf when 'UP' then 'Under probation' when 'C' then 'Confirmed' when 'CT' then 'Contract'
      when 'PT' then 'Part time' when 'INT' then 'Internship' when 'R' then 'Resigned' when 'TR' then 'Terminated' when 'DM' then 'Dismissed' else v_conf end),
    private.cms_fact('Reports to', v_boss, 'current_manager', case when v_boss is null then 'warn' end, case when v_boss is null then 'Not set (People › Self-service Access).' end)]);

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

  if t in ('LOC', 'LOC_LOI', 'PEL', 'LOI', 'LOP', 'TRL_LOP', 'PIP') then
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

  if t in ('LOC_LOI', 'LOI', 'LOP', 'TRL_LOP') and v_sal then
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

  if t in ('WL', 'SCL', 'EL', 'DI', 'SAL', 'TL', 'PIP') then
    select jsonb_agg(private.cms_fact(coalesce(tp.title, r.template_code), private.cms_ldate(r.issued_at::date)
             || coalesce(' · ' || nullif(r.fields->>'warning_level', ''), '') || coalesce(' · ' || left(nullif(coalesce(r.fields->>'matter_subject', r.fields->>'allegation_subject'), ''), 80), '')) order by r.issued_at)
      into v_disc from public.hr_letter_records r join public.hr_letter_templates tp on tp.code = r.template_code
     where r.employee_id = p_person and r.status = 'issued' and coalesce(tp.letter_type, split_part(tp.code, '_TP', 1)) in ('WL', 'SCL', 'EL', 'DI', 'SAL', 'TL', 'PIP');
    g := g || jsonb_build_object('title', 'Earlier letters', 'items',
      coalesce(v_disc, jsonb_build_array(private.cms_fact('Warnings, show cause, inquiries', 'None issued in the CMS', null, 'ok'))));
  end if;

  if t in ('TRL','TRL_LOP') then
    g := g || private.cms_fact_group('Now', array[
      private.cms_fact('Employer', (select coalesce(c.name, em.company_code) from public.cms_companies c where c.code = private.cms_canon(em.company_code))),
      private.cms_fact('Paid by', (select coalesce(c.name, v_paying) from public.cms_companies c where c.code = v_paying)),
      private.cms_fact('Centre', coalesce(v_unit, em.department), 'current_location'),
      private.cms_fact('Reporting manager', v_boss, 'current_reporting_manager')]);
  end if;

  if t = 'UAL' then
    select sum(l.days) into v_upl from public.eppd_leave_records l where l.employee_id = v_eppd and l.leave_type = 'UPL'
       and l.status <> 'cancelled' and l.date_from >= date_trunc('year', v_today)::date;
    g := g || private.cms_fact_group('Unpaid leave', array[private.cms_fact('Unpaid leave this year', coalesce(v_upl, 0)::text || ' days')]);
  end if;

  return jsonb_build_object('type', t, 'eppd_employee_id', v_eppd, 'last_day', coalesce(v_last, v_req),
    'leave', t in ('RL', 'TL', 'UAL'), 'groups', coalesce((select jsonb_agg(x) from unnest(g) x where x is not null), '[]'::jsonb));
end $function$
;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('letter_date','letter date','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('employee_name','employee name','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('address_line1','address line1','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('address_line2','address line2','text','manual',false) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('postcode_town','postcode town','text','manual',false) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('state','state','text','manual',false) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('discussion_date','discussion date','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('effective_date','effective date','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('current_position','current position','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_position','new position','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('current_department','current department','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_department','new department','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('current_location','current location','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_location','new location','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('current_reporting_manager','current reporting manager','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_reporting_manager','new reporting manager','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('transfer_reason','transfer reason','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('transfer_type','transfer type','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('handover_date','handover date','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('jd_reference','jd reference','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('jd_version','jd version','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('current_basic','current basic','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('basic_increment','basic increment','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('basic_increment_pct','basic increment pct','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('revised_basic','revised basic','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('approved_remuneration_or_allowance_changes','approved remuneration or allowance changes','paragraph','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('promotion_probation_period','promotion probation period','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('promotion_probation_start','promotion probation start','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('promotion_probation_end','promotion probation end','date','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('promotion_assessment_criteria','promotion assessment criteria','paragraph','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('post_probation_salary_arrangement','post probation salary arrangement','paragraph','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('company_name','company name','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('authorized_signatory','authorized signatory','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('authorized_designation','authorized designation','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_agreement_reference','new agreement reference','text','manual',true) on conflict(key) do nothing;
insert into public.hr_letter_placeholders(key,label,kind,source,required) values('new_terms_and_conditions','new terms and conditions','paragraph','manual',true) on conflict(key) do nothing;
do $$ declare v text:=gen_random_uuid()::text; begin
 if exists(select 1 from public.hr_letter_templates where code='TRL_LOP') then raise exception 'TRL_LOP already exists; review instead of overwriting.'; end if;
 insert into public.hr_letter_templates(code,title,version,body,active,status,letter_type,format) values('TRL_LOP','Letter of Transfer and Promotion',v,'Date: {{letter_date}}
PRIVATE & CONFIDENTIAL

To:
{{employee_name}}
{{address_line1}}
{{address_line2}}
{{postcode_town}}
{{state}}

Subject: Letter of Transfer and Promotion
Dear {{employee_name}},
We refer to our discussion on {{discussion_date}}. Management proposes your transfer and promotion on the terms below, effective {{effective_date}}, subject to your acceptance of this letter and the revised terms in Appendix B.

Item | Current | Revised
Position | {{current_position}} | {{new_position}}
Department | {{current_department}} | {{new_department}}
Work location | {{current_location}} | {{new_location}}
Reporting to | {{current_reporting_manager}} | {{new_reporting_manager}}

Reason for transfer: {{transfer_reason}}
Transfer arrangement: {{transfer_type}}
Please complete the agreed handover by {{handover_date}}. Your responsibilities and requirements for the new position are set out in Appendix A, JD reference {{jd_reference}}, version {{jd_version}}.

[b]Monthly basic salary on transfer and promotion[/b]
Description | Current | Increment | Increment (%) | Revised
Monthly basic salary | RM {{current_basic}} | RM {{basic_increment}} | {{basic_increment_pct}} % | RM {{revised_basic}}
Where salary is maintained, the increment is RM 0.00 (0.00%) and the revised basic salary equals the current basic salary. Allowances and other remuneration changes, if any: {{approved_remuneration_or_allowance_changes}}

[b]Probationary assessment for the new position[/b]
Assessment period: {{promotion_probation_period}}, from {{promotion_probation_start}} to {{promotion_probation_end}}.
Assessment criteria: {{promotion_assessment_criteria}}
Management will communicate the assessment outcome in writing. This assessment concerns the new position; it does not restart your original employment commencement date or service period. Any further change to your appointment or terms will be documented separately.

[b]Salary arrangement after assessment[/b]
{{post_probation_salary_arrangement}}

[b]Revised terms and agreement[/b]
The specific revised terms are recorded in Appendix B below. All other existing employment terms continue unless expressly replaced by this agreement. A change of legal employer requires a separate documented agreement and does not take effect solely through this letter.
Please review this letter, Appendix A and Appendix B before signing your acceptance.

Yours faithfully,
For and on behalf of {{company_name}}

__________________________________
Authorised Signatory
Name: {{authorized_signatory}}
Designation: {{authorized_designation}}


[b]Employee Agreement and Acceptance[/b]
I have read and agree to the transfer, new position and department, salary arrangements, assessment period, Job Description in Appendix A and revised terms in Appendix B. I understand the effective date and acknowledge receipt of a copy of this agreement and both appendices.


Signature: __________________________________
Name: __________________________________
NRIC: __________________________________
Date: __________________________________

Appendix B — Revised Terms and Conditions
Agreement reference: {{new_agreement_reference}}
{{new_terms_and_conditions}}',false,'draft','TRL_LOP','text');
 insert into public.hr_letter_template_versions(code,version,title,body,reason) values('TRL_LOP',v,'Letter of Transfer and Promotion','Date: {{letter_date}}
PRIVATE & CONFIDENTIAL

To:
{{employee_name}}
{{address_line1}}
{{address_line2}}
{{postcode_town}}
{{state}}

Subject: Letter of Transfer and Promotion
Dear {{employee_name}},
We refer to our discussion on {{discussion_date}}. Management proposes your transfer and promotion on the terms below, effective {{effective_date}}, subject to your acceptance of this letter and the revised terms in Appendix B.

Item | Current | Revised
Position | {{current_position}} | {{new_position}}
Department | {{current_department}} | {{new_department}}
Work location | {{current_location}} | {{new_location}}
Reporting to | {{current_reporting_manager}} | {{new_reporting_manager}}

Reason for transfer: {{transfer_reason}}
Transfer arrangement: {{transfer_type}}
Please complete the agreed handover by {{handover_date}}. Your responsibilities and requirements for the new position are set out in Appendix A, JD reference {{jd_reference}}, version {{jd_version}}.

[b]Monthly basic salary on transfer and promotion[/b]
Description | Current | Increment | Increment (%) | Revised
Monthly basic salary | RM {{current_basic}} | RM {{basic_increment}} | {{basic_increment_pct}} % | RM {{revised_basic}}
Where salary is maintained, the increment is RM 0.00 (0.00%) and the revised basic salary equals the current basic salary. Allowances and other remuneration changes, if any: {{approved_remuneration_or_allowance_changes}}

[b]Probationary assessment for the new position[/b]
Assessment period: {{promotion_probation_period}}, from {{promotion_probation_start}} to {{promotion_probation_end}}.
Assessment criteria: {{promotion_assessment_criteria}}
Management will communicate the assessment outcome in writing. This assessment concerns the new position; it does not restart your original employment commencement date or service period. Any further change to your appointment or terms will be documented separately.

[b]Salary arrangement after assessment[/b]
{{post_probation_salary_arrangement}}

[b]Revised terms and agreement[/b]
The specific revised terms are recorded in Appendix B below. All other existing employment terms continue unless expressly replaced by this agreement. A change of legal employer requires a separate documented agreement and does not take effect solely through this letter.
Please review this letter, Appendix A and Appendix B before signing your acceptance.

Yours faithfully,
For and on behalf of {{company_name}}

__________________________________
Authorised Signatory
Name: {{authorized_signatory}}
Designation: {{authorized_designation}}


[b]Employee Agreement and Acceptance[/b]
I have read and agree to the transfer, new position and department, salary arrangements, assessment period, Job Description in Appendix A and revised terms in Appendix B. I understand the effective date and acknowledge receipt of a copy of this agreement and both appendices.


Signature: __________________________________
Name: __________________________________
NRIC: __________________________________
Date: __________________________________

Appendix B — Revised Terms and Conditions
Agreement reference: {{new_agreement_reference}}
{{new_terms_and_conditions}}','Requested combined letter with selected approved JD; admin testing only');
 insert into public.hr_letter_admin_audit(action,object_key,after_value,reason) values('template_created','TRL_LOP',jsonb_build_object('version',v,'status','draft'),'Combined transfer and promotion template with JD snapshot; issuance disabled');
end $$;
commit;

