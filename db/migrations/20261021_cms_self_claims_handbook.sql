-- MyEden Group CMS V1.0 · Phase 4c · My Claims and My Handbook (staff self-service, switched on per person)
-- My Claims: the person's own SCF / OTCF / MTCF claims (submitted from their login, or with their name as the claimant),
-- with the same stage as the CMS approvals list; new claims are still made in the forms.
-- My Handbook: their handbook assignment status, opening the handbook in MEG-EAF V2.

create or replace function public.cms_my_claims()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v uuid := private.cms_self_require('claims'); src record; j jsonb; v_ra boolean; v_sp boolean; fin record; proc record; per record;
        v_status text; v_pay boolean; v_elig boolean; v_id text; v_claimant text; v_stage text; out jsonb := '[]'::jsonb;
begin
  for src in select * from (values ('scf', 'scf_submissions', 'Staff Claim (SCF)', 'RM'), ('otcf', 'otcf_submissions', 'Overtime (OTCF)', 'hrs'),
                                   ('mtcf', 'mtcf_submissions', 'Mileage (MTCF)', 'RM')) s(code, tbl, label, unit) loop
    if to_regclass('public.' || src.tbl) is null then continue; end if;
    select coalesce(c.requires_approval, true), coalesce(c.supports_payment, true) into v_ra, v_sp
      from (select 1) x left join public.meg_forms_workflow_config c on c.form_code = src.code;
    for j in execute format('select to_jsonb(t) from public.%I t', src.tbl) loop
      if nullif(j->>'deleted_at', '') is not null then continue; end if;
      v_status := lower(coalesce(j->>'status', ''));
      v_claimant := coalesce(nullif(j->>'claimed_by', ''), nullif(j->>'claimant_name', ''), nullif(j->>'emp_name', ''), nullif(j->>'submitted_by_name', ''), '');
      if (j->>'submitted_by') is distinct from auth.uid()::text then
        select * into per from private.cms_claim_person(v_claimant);
        if per.id is distinct from v then continue; end if;
      end if;
      v_id := j->>'id';
      select f.payment_done, f.payment_done_at into fin from public.meg_forms_finance_status f where f.form_code = src.code and f.submission_id = v_id;
      select p.fully_processed into proc from public.meg_forms_processing p where p.form_code = src.code and p.submission_id = v_id;
      v_pay := coalesce(fin.payment_done, false) or lower(coalesce(j->>'payment_confirmed', 'false')) = 'true' or v_status in ('paid', 'disbursed', 'completed');
      v_elig := case when v_status = 'disapproved' then false when v_ra then v_status in ('approved', 'paid', 'disbursed', 'completed') or v_pay
                     else v_status in ('submitted', 'approved', 'paid', 'disbursed', 'completed') or v_pay end;
      v_stage := case when v_status = 'draft' then 'draft' when v_status = 'disapproved' then 'disapproved' when v_pay then 'paid'
                      when v_ra and v_status = 'submitted' then 'approval' when v_elig and not coalesce(proc.fully_processed, false) then 'processing'
                      when v_elig and v_sp then 'payment' else 'closed' end;
      out := out || jsonb_build_object('form', src.code, 'form_name', src.label, 'id', v_id, 'serial_no', coalesce(j->>'serial_no', v_id), 'unit', src.unit,
        'amount', case src.code when 'scf' then public.meg_forms_try_numeric(j->>'total') when 'otcf' then public.meg_forms_try_numeric(j->>'total_hours')
                                when 'mtcf' then public.meg_forms_try_numeric(j->>'total_amount') end,
        'submitted_at', coalesce(public.meg_forms_try_timestamptz(j->>'submitted_at'), public.meg_forms_try_timestamptz(j->>'created_at')),
        'approved_at', public.meg_forms_try_timestamptz(j->>'approved_at'), 'approved_by', j->>'approved_by_name',
        'paid_at', coalesce(fin.payment_done_at, public.meg_forms_try_timestamptz(j->>'payment_confirmed_at'), public.meg_forms_try_timestamptz(j->>'disbursed_at')),
        'stage', v_stage,
        'status', case v_stage when 'draft' then 'Draft (not sent)' when 'disapproved' then 'Not approved' when 'paid' then 'Paid' when 'approval' then 'Waiting for approval'
                       when 'processing' then 'Approved · being processed' when 'payment' then 'Approved · waiting for payment' else initcap(replace(v_status, '_', ' ')) end,
        'note', coalesce(nullif(j->>'disapproval_reason', ''), nullif(j->>'disapproved_reason', ''), nullif(j->>'revision_reason', '')),
        'link', private.cms_claim_link(src.code, v_id, v_status));
    end loop;
  end loop;
  return (select coalesce(jsonb_agg(x order by x->>'submitted_at' desc nulls last), '[]'::jsonb) from jsonb_array_elements(out) x);
end $$;

create or replace function public.cms_my_handbook()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := private.cms_self_require('handbook');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('status', a.status, 'assigned_at', a.assigned_at, 'due_at', a.due_at, 'first_viewed_at', a.first_viewed_at,
            'read_at', coalesce(a.read_at, a.deemed_read_at), 'acknowledged_at', a.acknowledged_at, 'receipt_at', a.receipt_acknowledged_at, 'revoked_at', a.revoked_at,
            'version', (select coalesce(to_jsonb(hv)->>'version_label', to_jsonb(hv)->>'version', to_jsonb(hv)->>'title', to_jsonb(hv)->>'name')
                        from public.handbook_versions hv where hv.id = a.handbook_version_id))
          order by a.assigned_at desc)
    from public.handbook_assignments a where a.employee_id = v), '[]'::jsonb);
end $$;

do $g$ declare f text;
begin
  foreach f in array array['cms_my_claims()','cms_my_handbook()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $g$;
