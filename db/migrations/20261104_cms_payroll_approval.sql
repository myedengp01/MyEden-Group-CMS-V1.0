-- MyEden Group CMS V1.0 · v2026.11.04 · Payroll approval by a Director, and the monthly payroll report (CLC 4 Nov 2026)
-- A month is prepared and saved by HR, submitted for approval, approved (or returned) by a Director, then finalised.
-- Saving the draft again after submitting clears the submission and approval, so what is finalised is what was approved.
-- Reopening a finalised month clears them too. Each step is in the payroll log. Additive only.

alter table public.eppd_pay_runs add column if not exists submitted_at timestamptz;
alter table public.eppd_pay_runs add column if not exists submitted_by uuid;
alter table public.eppd_pay_runs add column if not exists approved_at timestamptz;
alter table public.eppd_pay_runs add column if not exists approved_by uuid;
alter table public.eppd_pay_runs add column if not exists approval_note text;

-- person's name for a login (CMS person, else the email)
create or replace function private.cms_user_name(p_uid uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select em.employee_name from public.cms_user_links ul join public.employee_master em on em.id = ul.employee_master_id where ul.user_id = p_uid limit 1),
                  (select email from auth.users where id = p_uid));
$$;
revoke all on function private.cms_user_name(uuid) from public, anon, authenticated;

create or replace function public.cms_pay_run_approval(p_run bigint)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare r public.eppd_pay_runs;
begin
  if not (public.cms_can('payroll', 'V') or public.eppd_has_role(array['admin','hr'])) then raise exception 'You do not have access to payroll.'; end if;
  select * into r from public.eppd_pay_runs where id = p_run;
  if r.id is null then raise exception 'Pay run not found.'; end if;
  return jsonb_build_object('run_id', r.id, 'period', r.period, 'status', r.status, 'updated_at', r.updated_at,
    'submitted_at', r.submitted_at, 'submitted_by', private.cms_user_name(r.submitted_by),
    'approved_at', r.approved_at, 'approved_by', private.cms_user_name(r.approved_by), 'approval_note', r.approval_note,
    'finalised_at', r.finalised_at, 'finalised_by', private.cms_user_name(r.finalised_by),
    'can_approve', private.cms_is_director(auth.uid()), 'me', private.cms_user_name(auth.uid()));
end $f$;
revoke all on function public.cms_pay_run_approval(bigint) from public, anon;
grant execute on function public.cms_pay_run_approval(bigint) to authenticated;

create or replace function public.cms_pay_run_submit(p_run bigint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare r public.eppd_pay_runs; n int;
begin
  if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll.prepare', 'V')) then raise exception 'Only HR and admins can submit payroll.'; end if;
  select * into r from public.eppd_pay_runs where id = p_run for update;
  if r.id is null then raise exception 'Pay run not found.'; end if;
  if r.status = 'finalised' then raise exception 'This month is already finalised.'; end if;
  select count(*) into n from public.eppd_pay_lines where run_id = p_run and not excluded;
  if n = 0 then raise exception 'There are no lines to submit.'; end if;
  update public.eppd_pay_runs set submitted_at = now(), submitted_by = auth.uid(), approved_at = null, approved_by = null, approval_note = null where id = p_run;
  perform public.eppd_pay_log('PAY_SUBMIT', jsonb_build_object('run_id', p_run, 'period', r.period, 'lines', n) || coalesce(r.totals->'all', '{}'::jsonb));
  return jsonb_build_object('run_id', p_run);
end $f$;
revoke all on function public.cms_pay_run_submit(bigint) from public, anon;
grant execute on function public.cms_pay_run_submit(bigint) to authenticated;

-- p_decision 'approve' | 'return' (return needs a reason)
create or replace function public.cms_pay_run_decide(p_run bigint, p_decision text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare r public.eppd_pay_runs;
begin
  if not private.cms_is_director(auth.uid()) then raise exception 'Only a Director can approve payroll.'; end if;
  if p_decision not in ('approve', 'return') then raise exception 'Unknown decision.'; end if;
  select * into r from public.eppd_pay_runs where id = p_run for update;
  if r.id is null then raise exception 'Pay run not found.'; end if;
  if r.status = 'finalised' then raise exception 'This month is already finalised.'; end if;
  if r.submitted_at is null then raise exception 'This month has not been submitted for approval (or it was changed after submitting).'; end if;
  if p_decision = 'return' then
    if coalesce(btrim(p_note), '') = '' then raise exception 'Give a reason for returning it.'; end if;
    update public.eppd_pay_runs set submitted_at = null, submitted_by = null, approved_at = null, approved_by = null, approval_note = btrim(p_note) where id = p_run;
  else
    update public.eppd_pay_runs set approved_at = now(), approved_by = auth.uid(), approval_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_run;
  end if;
  perform public.eppd_pay_log(case when p_decision = 'approve' then 'PAY_APPROVE' else 'PAY_RETURN' end,
    jsonb_build_object('run_id', p_run, 'period', r.period, 'note', nullif(btrim(coalesce(p_note, '')), '')) || coalesce(r.totals->'all', '{}'::jsonb));
  return jsonb_build_object('run_id', p_run, 'decision', p_decision);
end $f$;
revoke all on function public.cms_pay_run_decide(bigint, text, text) from public, anon;
grant execute on function public.cms_pay_run_decide(bigint, text, text) to authenticated;

-- saving the draft clears a submission / approval (the figures changed)
CREATE OR REPLACE FUNCTION public.eppd_save_pay_run(p jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_period date := (p->>'period')::date; v_run public.eppd_pay_runs; v_exists boolean; n int;
begin
  if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll.prepare', 'V')) then raise exception 'Only HR and admins can prepare payroll.'; end if;
  if v_period is null or extract(day from v_period) <> 1 then raise exception 'Period must be the first day of a month.'; end if;
  select * into v_run from public.eppd_pay_runs where period = v_period for update;
  v_exists := found;   -- PERFORM resets FOUND, so keep the answer
  if v_exists and v_run.status = 'finalised' then raise exception 'This month is finalised. Ask an admin to reopen it.'; end if;
  if v_exists and coalesce(p->>'expected_updated_at', '') = '' then
    raise exception 'Someone else started this month after you opened it. Reload the page to see their figures; nothing was saved.';
  end if;
  if v_exists and (p->>'expected_updated_at')::timestamptz is distinct from v_run.updated_at then
    raise exception 'Someone else saved this month after you opened it. Reload the page to see their changes; nothing was saved.';
  end if;
  perform set_config('eppd.skip_audit', 'on', true);
  if not v_exists then
    insert into public.eppd_pay_runs (period, notes, totals) values (v_period, p->>'notes', coalesce(p->'totals', '{}'::jsonb))
    returning * into v_run;
  else
    update public.eppd_pay_runs set notes = p->>'notes', totals = coalesce(p->'totals', '{}'::jsonb),
      submitted_at = null, submitted_by = null, approved_at = null, approved_by = null
     where id = v_run.id
    returning * into v_run;
    delete from public.eppd_pay_lines where run_id = v_run.id;
  end if;
  n := public.eppd_insert_pay_lines(v_run.id, p->'lines');
  perform set_config('eppd.skip_audit', 'off', true);
  perform public.eppd_pay_log('PAY_SAVE', jsonb_build_object('run_id', v_run.id, 'period', v_period, 'lines', n) || coalesce(p->'totals'->'all', '{}'::jsonb));
  return jsonb_build_object('run_id', v_run.id, 'lines', n, 'updated_at', v_run.updated_at);
end $function$;

-- finalising needs a Director's approval of the saved figures
CREATE OR REPLACE FUNCTION public.eppd_finalise_pay_run(p_run bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_run public.eppd_pay_runs; n int;
begin
  if not (public.eppd_has_role(array['admin','hr']) or public.cms_can('payroll.finalise', 'V')) then raise exception 'Only HR and admins can finalise payroll.'; end if;
  select * into v_run from public.eppd_pay_runs where id = p_run for update;
  if v_run.id is null then raise exception 'Pay run not found.'; end if;
  if v_run.status = 'finalised' then raise exception 'This month is already finalised.'; end if;
  if v_run.approved_at is null then raise exception 'A Director must approve this month before it is finalised. Submit it for approval first.'; end if;
  select count(*) into n from public.eppd_pay_lines where run_id = p_run and not excluded;
  if n = 0 then raise exception 'There are no lines to finalise.'; end if;
  perform set_config('eppd.pay_unlock', 'on', true);
  update public.eppd_pay_runs set status = 'finalised', finalised_at = now(), finalised_by = auth.uid() where id = p_run;
  perform set_config('eppd.pay_unlock', 'off', true);
  perform public.eppd_pay_log('PAY_FINALISE', jsonb_build_object('run_id', p_run, 'period', v_run.period, 'lines', n, 'approved_by', v_run.approved_by) || coalesce(v_run.totals->'all', '{}'::jsonb));
  return jsonb_build_object('run_id', p_run, 'lines', n);
end $function$;

-- reopening needs a fresh approval
CREATE OR REPLACE FUNCTION public.eppd_reopen_pay_run(p_run bigint, p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_run public.eppd_pay_runs;
begin
  if not (public.eppd_is_admin() or public.cms_can('payroll.reopen', 'V')) then raise exception 'Only an admin can reopen a finalised month.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for reopening.'; end if;
  select * into v_run from public.eppd_pay_runs where id = p_run for update;
  if v_run.id is null then raise exception 'Pay run not found.'; end if;
  if v_run.status <> 'finalised' then raise exception 'This month is not finalised.'; end if;
  perform set_config('eppd.pay_unlock', 'on', true);
  update public.eppd_pay_runs set status = 'draft', reopened_at = now(), reopened_by = auth.uid(), reopen_reason = trim(p_reason),
    submitted_at = null, submitted_by = null, approved_at = null, approved_by = null, approval_note = null
   where id = p_run;
  perform set_config('eppd.pay_unlock', 'off', true);
  perform public.eppd_pay_log('PAY_REOPEN', jsonb_build_object('run_id', p_run, 'period', v_run.period, 'reason', trim(p_reason)));
  return jsonb_build_object('run_id', p_run);
end $function$;
