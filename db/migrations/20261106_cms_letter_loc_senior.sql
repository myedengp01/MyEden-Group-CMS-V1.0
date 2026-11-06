-- MyEden Group CMS V1.0 · v2026.11.06 · Letter of Confirmation — Senior Position (CLC 6 Nov 2026)
-- Confirmation in a senior post after the promotion probation, with an optional salary increment.
-- 1. Placeholders: {{promotion_letter_date}}, {{increment_effective_date}} and {{salary_arrangement}} (written by the letter page from the
--    "Salary: No change / Increment" choice: one sentence, or the Current | Increment | % | Revised table).
-- 2. Template LOC_SNR saved as a DRAFT (not active) for review in Letter Templates before it is published.
--    Position name and JD code come from the JD Manual ({{jd_title}}, {{jd_reference}}). NRIC left blank for the employee. Acknowledge receipt only.
-- 3. "Update records from this letter": the salary month follows {{increment_effective_date}} when the letter has one
--    (the confirmation still uses the confirmation date); the salary review stays every 12 months by default.
-- Additive only.

insert into public.hr_letter_placeholders (key, label, description, kind, source, source_key, required, editable, protected, active) values
  ('promotion_letter_date', 'Promotion letter date', 'Date of the letter that promoted the employee to the senior position', 'date', 'manual', '', true, true, false, true),
  ('increment_effective_date', 'Increment effective date', 'When the salary increment takes effect: the confirmation date, the 1st of the following month, or another date', 'date', 'manual', '', false, true, false, true),
  ('salary_arrangement', 'Salary arrangement', 'Written from the Salary choice on the letter page: no change, or the increment table', 'paragraph', 'calculation', '', true, false, false, true)
on conflict (key) do nothing;

do $m$
declare v text := gen_random_uuid()::text; b text;
begin
  b := $t$Date: {{letter_date}}
Ref: {{letter_reference}}
PRIVATE & CONFIDENTIAL

To:
{{employee_name}}
{{address_line1}}
{{address_line2}}
{{postcode_town}}
{{state}}

Dear {{employee_name}},

[b]CONFIRMATION AS {{jd_title}}[/b]

We refer to our letter dated {{promotion_letter_date}} promoting you to the position of {{jd_title}} (JD Ref: {{jd_reference}}) in the {{department}} department, effective {{promotion_probation_start}}, subject to a probation of {{promotion_probation_period}}.

Following the review of your performance during the probation which ended on {{promotion_probation_end}}, including your skill, competence, temperament, aptitude, attitude and suitability for the position, we are pleased to inform you that you are confirmed as {{jd_title}} with effect from {{confirmation_date}}.

[b]Salary[/b]
{{salary_arrangement}}

[b]Performance Review[/b]
As a senior position, your performance will continue to be evaluated every 6 months to maintain the quality of service and good working relationships with colleagues. Your next performance review is due on {{next_review_date}}.

[b]Other Terms[/b]
The instruction sheet setting out your duties and responsibilities as {{jd_title}} continues to apply. All other terms and conditions of your employment remain unchanged unless otherwise stated in this letter. Future increments, bonuses and other benefits remain at the Company's discretion, based on performance, appraisal results and business performance.

We congratulate you on your confirmation and thank you for your continued commitment.

Kindly acknowledge receipt of this letter by signing the acknowledgement below.

Yours sincerely,
For and on behalf of
{{company_name}}



__________________________
{{authorized_signatory}}
{{authorized_designation}}

[b]ACKNOWLEDGEMENT OF RECEIPT[/b]
I, {{employee_name}}, acknowledge receipt of this letter of confirmation as {{jd_title}}.



Employee Signature: __________________________
Name: {{employee_name}}
NRIC: __________________________
Date: __________________________$t$;
  if not exists (select 1 from public.hr_letter_templates where code = 'LOC_SNR') then
    insert into public.hr_letter_templates (code, title, version, body, active, status, letter_type, format, created_by, created_by_name)
    values ('LOC_SNR', 'Letter of Confirmation — Senior Position', v, b, false, 'draft', 'LOC', 'text', auth.uid(), 'CMS build');
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason)
    values ('LOC_SNR', v, 'Letter of Confirmation — Senior Position', b, auth.uid(), 'New draft: confirmation in a senior position after the promotion probation, optional increment (CLC 6 Nov 2026)');
  end if;
end $m$;

-- the salary month of an applied letter follows {{increment_effective_date}} when present
do $m$
declare src text; old text := $o$else date_trunc('month', coalesce(v_date, current_date))::date end;$o$;
begin
  select pg_get_functiondef('public.cms_letter_apply_preview(uuid)'::regprocedure) into src;
  if position('increment_effective_date' in src) = 0 then
    if position(old in src) = 0 then raise exception 'cms_letter_apply_preview has changed; salary month line not found'; end if;
    execute replace(src, old, $n$else date_trunc('month', coalesce(private.cms_parse_date(f->>'increment_effective_date'), v_date, current_date))::date end;$n$);
  end if;
end $m$;
