-- MyEden Group CMS V1.0 · v2026.11.05 · Signing space in text letters (CLC 5 Nov 2026)
-- Three blank lines above the company signatory (with a signature line) and above the employee's signature, in the active text letters:
-- RL, RL_TP2, RL_TP3 (resignation acceptance), LOC (confirmation), LOI (increment), LOP (promotion), LOC_LOI (confirmation and increment).
-- Each change is a new template version with its reason; letters already issued keep their own copy. Stacked blank lines render as full lines.
do $m$
declare r record; nb text; v uuid;
begin
  for r in select code, title, body from public.hr_letter_templates where code in ('RL', 'RL_TP2', 'RL_TP3', 'LOC', 'LOI', 'LOP', 'LOC_LOI') loop
    if strpos(r.body, E'\n\n\n\n') > 0 then continue; end if;   -- already has the signing space
    nb := r.body;
    if r.code like 'RL%' then
      nb := replace(nb, E'For and on behalf of {{company_name}}\nName: {{authorized_signatory}}', E'For and on behalf of {{company_name}}\n\n\n\n__________________________\nName: {{authorized_signatory}}');
      nb := replace(nb, E'\n\nEmployee Signature:', E'\n\n\n\nEmployee Signature:');
    elsif r.code = 'LOC_LOI' then
      nb := replace(nb, E'{{company_name}}\n\n_________________________\nAuthorized Signatory', E'{{company_name}}\n\n\n\n_________________________\nAuthorized Signatory');
      nb := replace(nb, E'\n\nEmployee Signature:', E'\n\n\n\nEmployee Signature:');
    else
      nb := replace(nb, E'For and on behalf of {{company_name}}\n{{authorized_signatory}}\nEmployee Acknowledgement:', E'For and on behalf of {{company_name}}\n\n\n\n__________________________\n{{authorized_signatory}}\n\nEmployee Acknowledgement:');
      nb := replace(nb, E'\nSignature: ', E'\n\n\n\nSignature: ');
    end if;
    if (length(nb) - length(r.body)) < 4 then raise exception 'Template % did not change as expected', r.code; end if;
    v := gen_random_uuid();
    update public.hr_letter_templates set body = nb, version = v, updated_at = now() where code = r.code;
    insert into public.hr_letter_template_versions (code, version, title, body, actor_id, reason)
    values (r.code, v, r.title, nb, auth.uid(), 'Signing space: three blank lines above the company signatory and the employee signature (CLC 5 Nov 2026)');
  end loop;
end $m$;
