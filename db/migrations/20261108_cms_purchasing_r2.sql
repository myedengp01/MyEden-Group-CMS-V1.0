-- MyEden Group CMS V1.0 · v2026.11.08 · Purchasing & Petty Cash (new PRFAF), release 2 (CLC 8 Nov 2026)
-- Settlement: the purchaser records what was bought (actual qty / price / supplier / receipt no. and photo per line, extra lines allowed; a line with no
-- receipt needs a reason) and sends it to Finance. Overspend beyond the tolerance (Admin %) needs approval at the level of the actual total.
-- Finance verifies each line (accept / query); queries send it back. Closing posts the purchase: expense by category (department, event) against the
-- purchaser's petty cash (advance / claim back). Petty cash below zero = the company owes the purchaser: Finance reimburses (or the next release adds it);
-- money can also be returned (year-end settle). Reversal entries correct mistakes; months can be locked; year-end closing records bring-forward or settle.
-- Reports (spend by company / category / department / event / month / day, bank movements, events budget vs actual, petty cash, late settlements,
-- receipt issues) and statements (bank account, purchaser's petty cash, event). Additive: new columns, one table, functions.

alter table public.pr_requests add column if not exists actual_total numeric(12,2);
alter table public.pr_requests add column if not exists settle_note text;
alter table public.pr_requests add column if not exists excess_needed boolean not null default false;
alter table public.pr_requests add column if not exists excess_by uuid;
alter table public.pr_requests add column if not exists excess_by_name text;
alter table public.pr_requests add column if not exists excess_at timestamptz;
alter table public.pr_requests add column if not exists query_note text;
alter table public.pr_requests add column if not exists verified_by uuid;
alter table public.pr_requests add column if not exists verified_by_name text;
alter table public.pr_requests add column if not exists verified_at timestamptz;
alter table public.pr_requests add column if not exists purchase_entry_id uuid;
alter table public.pr_items add column if not exists is_extra boolean not null default false;
alter table public.pr_items add column if not exists removed boolean not null default false;   -- extra lines taken out at settlement are kept, marked removed

create table if not exists public.pr_year_closings (
  id uuid primary key default gen_random_uuid(), year int not null, holder_uid uuid not null, holder_name text, company_code text not null,
  balance numeric(12,2) not null, decision text not null check (decision in ('carry', 'settle')), entry_id uuid references public.pr_journal(id),
  decided_by uuid, decided_by_name text, decided_at timestamptz not null default now(), unique (year, holder_uid, company_code));
alter table public.pr_year_closings enable row level security;
revoke all on public.pr_year_closings from anon, authenticated;

-- no postings into a locked period
do $m$ declare src text;
begin
  select pg_get_functiondef('private.pr_post(text,date,uuid,text,jsonb,uuid)'::regprocedure) into src;
  if position('lock_date' in src) = 0 then
    execute replace(src, $o$  if dr <> cr or dr <= 0 then raise exception 'The entry does not balance (debit % · credit %).', dr, cr; end if;$o$,
      $n$  if dr <> cr or dr <= 0 then raise exception 'The entry does not balance (debit % · credit %).', dr, cr; end if;
  if p_date <= coalesce(nullif(private.pr_cfg()->>'lock_date', '')::date, '1900-01-01'::date) then
    raise exception 'The books are closed up to %. Use a later date or ask Admin to reopen the month.', to_char((private.pr_cfg()->>'lock_date')::date, 'DD Mon YYYY'); end if;$n$);
  end if;
end $m$;

-- the purchaser records the purchase. p: {note, lines: [{id?, description, supplier, act_qty, act_unit, receipt_no, receipt_path, no_receipt_reason, category_id}]}
create or replace function public.cms_pr_settle_save(p_id uuid, p jsonb, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; ln jsonb; n int := 0; v_qty numeric; v_unit numeric; v_tot numeric := 0; keep uuid[] := '{}'; iid uuid; tol numeric; mx int;
begin
  select * into q from public.pr_requests where id = p_id and deleted_at is null for update;
  if q.id is null or q.requester_uid <> auth.uid() then raise exception 'Request not found.'; end if;
  if q.status <> 'purchasing' then raise exception 'Record the purchase after approval (and after confirming you received the money).'; end if;
  select coalesce(max(sort_order), 0) into mx from public.pr_items where request_id = q.id;
  for ln in select x from jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) x loop
    n := n + 1;
    if n > 80 then raise exception 'Too many lines.'; end if;
    v_qty := round(coalesce(public.meg_forms_try_numeric(ln->>'act_qty'), 0), 2); v_unit := round(coalesce(public.meg_forms_try_numeric(ln->>'act_unit'), 0), 2);
    if v_qty < 0 or v_unit < 0 or v_qty * v_unit > 1000000 then raise exception 'Line %: quantity or price is not valid.', n; end if;
    if coalesce(ln->>'receipt_path', '') <> '' and ln->>'receipt_path' !~ ('^' || q.id::text || '/') then raise exception 'Line %: the receipt is not stored with this request.', n; end if;
    if nullif(ln->>'category_id', '') is not null and not exists (select 1 from public.pr_categories where id = (ln->>'category_id')::uuid) then raise exception 'Line %: unknown category.', n; end if;
    iid := nullif(ln->>'id', '')::uuid;
    if iid is not null and exists (select 1 from public.pr_items where id = iid and request_id = q.id) then
      update public.pr_items set act_qty = v_qty, act_unit = v_unit, act_total = round(v_qty * v_unit, 2),
        supplier = coalesce(nullif(left(btrim(coalesce(ln->>'supplier', '')), 120), ''), supplier), receipt_no = nullif(left(btrim(coalesce(ln->>'receipt_no', '')), 60), ''),
        receipt_path = nullif(ln->>'receipt_path', ''), no_receipt_reason = nullif(left(btrim(coalesce(ln->>'no_receipt_reason', '')), 300), ''),
        category_id = nullif(ln->>'category_id', '')::uuid, description = case when is_extra then left(btrim(coalesce(ln->>'description', '')), 300) else description end,
        verify_status = null, verify_note = case when p_submit then null else verify_note end, removed = false where id = iid;
    else
      mx := mx + 1;
      insert into public.pr_items (request_id, sort_order, description, supplier, qty, est_unit, est_total, is_extra, act_qty, act_unit, act_total, receipt_no, receipt_path, no_receipt_reason, category_id)
      values (q.id, mx, left(btrim(coalesce(ln->>'description', '')), 300), nullif(left(btrim(coalesce(ln->>'supplier', '')), 120), ''), 0, 0, 0, true, v_qty, v_unit, round(v_qty * v_unit, 2),
              nullif(left(btrim(coalesce(ln->>'receipt_no', '')), 60), ''), nullif(ln->>'receipt_path', ''), nullif(left(btrim(coalesce(ln->>'no_receipt_reason', '')), 300), ''), nullif(ln->>'category_id', '')::uuid)
      returning id into iid;
    end if;
    keep := keep || iid; v_tot := v_tot + round(v_qty * v_unit, 2);
  end loop;
  update public.pr_items set removed = true, act_qty = 0, act_unit = 0, act_total = 0, verify_status = null where request_id = q.id and is_extra and not removed and not (id = any(keep));
  tol := coalesce((private.pr_cfg()->>'tolerance_pct')::numeric, 10);
  update public.pr_requests set actual_total = v_tot, settle_note = nullif(left(btrim(coalesce(p->>'note', '')), 1000), ''),
    excess_needed = v_tot > round(coalesce(approved_amount, est_total) * (1 + tol / 100), 2), updated_at = now() where id = q.id returning * into q;
  if p_submit then
    if exists (select 1 from public.pr_items where request_id = q.id and is_extra and not removed and (description = '' or coalesce(act_total, 0) <= 0)) then raise exception 'Every extra line needs a description, quantity and price.'; end if;
    if exists (select 1 from public.pr_items where request_id = q.id and coalesce(act_total, 0) > 0 and receipt_path is null and no_receipt_reason is null) then
      raise exception 'Attach a receipt to every line you bought, or say why there is no receipt.'; end if;
    if exists (select 1 from public.pr_items i join public.pr_categories c on c.id = coalesce(i.category_id, q.category_id) where i.request_id = q.id and coalesce(i.act_total, 0) > 0 and c.remark_required)
       and q.settle_note is null and q.justification is null then raise exception 'A Miscellaneous line needs a remark: say what was bought.'; end if;
    update public.pr_requests set status = 'settlement', settled_at = now(), query_note = null, excess_by = null, excess_by_name = null, excess_at = null where id = q.id;
    perform private.pr_log(q.id, 'Purchase recorded, sent to Finance', 'RM ' || to_char(v_tot, 'FM999,999,990.00') || case when q.excess_needed then ' (over the approved amount + ' || tol || ' %: needs approval)' else '' end);
  end if;
  return jsonb_build_object('id', q.id, 'status', case when p_submit then 'settlement' else q.status end, 'actual_total', v_tot, 'excess_needed', q.excess_needed, 'mail', case when p_submit then 'settled' end);
end $f$;

-- Finance verifies. actions: line {item_id, status accepted|queried, note} · excess {note} · query {note} · close
create or replace function public.cms_pr_verify(p_id uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare q public.pr_requests; r jsonb := private.pr_roles(); me uuid := auth.uid(); nm text := private.cms_user_name(auth.uid()); ent uuid; lines jsonb; tot numeric; lv text; mail text;
begin
  select * into q from public.pr_requests where id = p_id and deleted_at is null for update;
  if q.id is null or not private.pr_can_see(q) then raise exception 'Request not found.'; end if;
  if q.requester_uid = me then raise exception 'You cannot verify your own purchase.'; end if;
  if q.status <> 'settlement' then raise exception 'This purchase is not waiting for verification.'; end if;
  if p_action = 'excess' then
    if not q.excess_needed or q.excess_by is not null then raise exception 'No overspend approval is needed.'; end if;
    lv := private.pr_level(q.actual_total);
    if not ((lv = 'finance' and (r->>'finance')::boolean) or (lv <> 'finance' and (r->>'director')::boolean)) then
      raise exception 'The overspend (total RM %) must be approved by %.', to_char(q.actual_total, 'FM999,999,990.00'), case lv when 'finance' then 'Finance' else 'a Director' end; end if;
    update public.pr_requests set excess_by = me, excess_by_name = nm, excess_at = now() where id = q.id;
    perform private.pr_log(q.id, 'Overspend approved by ' || nm, 'RM ' || to_char(q.actual_total, 'FM999,999,990.00') || ' against RM ' || to_char(coalesce(q.approved_amount, q.est_total), 'FM999,999,990.00') || coalesce(' · ' || nullif(btrim(coalesce(p->>'note', '')), ''), ''));
    return jsonb_build_object('id', q.id, 'status', q.status);
  end if;
  if not (r->>'finance')::boolean then raise exception 'Only Finance can verify purchases.'; end if;
  case p_action
  when 'line' then
    if coalesce(p->>'status', '') not in ('accepted', 'queried') then raise exception 'Accept or query the line.'; end if;
    if p->>'status' = 'queried' and btrim(coalesce(p->>'note', '')) = '' then raise exception 'Say what is wrong with the line.'; end if;
    update public.pr_items set verify_status = p->>'status', verify_note = nullif(btrim(coalesce(p->>'note', '')), '') where id = (p->>'item_id')::uuid and request_id = q.id;
    if not found then raise exception 'Line not found.'; end if;
    return jsonb_build_object('id', q.id, 'status', q.status);
  when 'query' then
    if btrim(coalesce(p->>'note', '')) = '' and not exists (select 1 from public.pr_items where request_id = q.id and verify_status = 'queried') then raise exception 'Say what the purchaser must fix.'; end if;
    update public.pr_requests set status = 'purchasing', query_note = coalesce(nullif(btrim(coalesce(p->>'note', '')), ''), 'See the queried lines.') where id = q.id;
    perform private.pr_log(q.id, 'Sent back with questions by ' || nm, coalesce(nullif(btrim(coalesce(p->>'note', '')), ''), (select string_agg(description || ': ' || coalesce(verify_note, ''), '; ') from public.pr_items where request_id = q.id and verify_status = 'queried')));
    mail := 'queried';
  when 'close' then
    if exists (select 1 from public.pr_items where request_id = q.id and coalesce(act_total, 0) > 0 and coalesce(verify_status, '') <> 'accepted') then raise exception 'Accept every line first (or send it back with questions).'; end if;
    if q.excess_needed and q.excess_by is null then raise exception 'The overspend must be approved first.'; end if;
    tot := coalesce(q.actual_total, 0);
    if q.pay_type <> 'supplier' and tot > 0 then
      select jsonb_agg(jsonb_build_object('account_kind', 'expense', 'company_code', q.company_code, 'category_id', z.cat, 'department', q.department, 'event_id', q.event_id, 'debit', z.amt, 'memo', q.pr_no || ' · ' || z.what))
        into lines from (select coalesce(i.category_id, q.category_id) cat, sum(i.act_total) amt, string_agg(i.description, ', ' order by i.sort_order) what
                           from public.pr_items i where i.request_id = q.id and coalesce(i.act_total, 0) > 0 group by 1) z;
      lines := lines || jsonb_build_array(jsonb_build_object('account_kind', 'float', 'company_code', q.company_code, 'holder_uid', q.requester_uid, 'holder_name', q.requester_name,
        'department', q.department, 'event_id', q.event_id, 'credit', tot, 'memo', q.pr_no || ' · purchase'));
      ent := private.pr_post('purchase', (now() at time zone 'Asia/Kuala_Lumpur')::date, q.id, 'Purchase by ' || q.requester_name || ' for ' || q.pr_no, lines);
    end if;
    update public.pr_requests set status = 'closed', closed_at = now(), verified_by = me, verified_by_name = nm, verified_at = now(), purchase_entry_id = ent where id = q.id;
    perform private.pr_log(q.id, 'Verified and closed by ' || nm, 'RM ' || to_char(tot, 'FM999,999,990.00') || case when q.pay_type = 'supplier' then ' (paid to supplier at release)' else ' posted' end);
    perform private.cms_log('purchasing.closed', 'pr_requests', q.id::text, q.company_code, q.pr_no || ' closed (RM ' || to_char(tot, 'FM999,999,990.00') || ')', jsonb_build_object('entry', ent));
    mail := 'closed';
  else raise exception 'Unknown action.';
  end case;
  return jsonb_build_object('id', q.id, 'status', case p_action when 'close' then 'closed' else 'purchasing' end, 'mail', mail, 'balance', private.pr_float(q.requester_uid, q.company_code));
end $f$;

-- Finance moves petty cash: reimburse (company pays what it owes the purchaser) or return (purchaser pays money back)
create or replace function public.cms_pr_float_move(p_uid uuid, p_company text, p_kind text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare bal numeric := private.pr_float(p_uid, p_company); amt numeric := round(coalesce(public.meg_forms_try_numeric(p->>'amount'), 0), 2); bk public.pr_bank_accounts;
  d date := coalesce(nullif(p->>'date', '')::date, (now() at time zone 'Asia/Kuala_Lumpur')::date); nm text := private.cms_user_name(p_uid); ent uuid;
begin
  if not public.cms_can('purchasing.finance', 'E') then raise exception 'Only Finance can do this.'; end if;
  if p_uid = auth.uid() then raise exception 'Another Finance member must record your own petty cash.'; end if;
  if p_kind not in ('reimburse', 'return') then raise exception 'Unknown action.'; end if;
  select * into bk from public.pr_bank_accounts where id = nullif(p->>'bank_id', '')::uuid and is_active;
  if bk.id is null or bk.company_code <> p_company then raise exception 'Choose an account of %.', p_company; end if;
  if d > (now() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'The date is in the future.'; end if;
  if amt <= 0 then raise exception 'Enter the amount.'; end if;
  if p_kind = 'reimburse' and amt > -bal then raise exception 'The company owes % only RM %.', nm, to_char(greatest(-bal, 0), 'FM999,999,990.00'); end if;
  if p_kind = 'return' and amt > bal then raise exception '% holds only RM % petty cash.', nm, to_char(greatest(bal, 0), 'FM999,999,990.00'); end if;
  if btrim(coalesce(p->>'ref', '')) = '' and bk.kind = 'bank' then raise exception 'Enter the transfer reference.'; end if;
  ent := private.pr_post(p_kind, d, null, case p_kind when 'reimburse' then 'Reimbursed to ' else 'Returned by ' end || nm || coalesce(' · ' || nullif(btrim(coalesce(p->>'note', '')), ''), ''),
    case p_kind when 'reimburse' then jsonb_build_array(
        jsonb_build_object('account_kind', 'float', 'company_code', p_company, 'holder_uid', p_uid, 'holder_name', nm, 'debit', amt, 'memo', 'Reimbursement'),
        jsonb_build_object('account_kind', 'bank', 'company_code', p_company, 'bank_account_id', bk.id, 'credit', amt, 'memo', btrim(coalesce(p->>'ref', ''))))
      else jsonb_build_array(
        jsonb_build_object('account_kind', 'bank', 'company_code', p_company, 'bank_account_id', bk.id, 'debit', amt, 'memo', btrim(coalesce(p->>'ref', ''))),
        jsonb_build_object('account_kind', 'float', 'company_code', p_company, 'holder_uid', p_uid, 'holder_name', nm, 'credit', amt, 'memo', 'Returned')) end);
  perform private.cms_log('purchasing.' || p_kind, 'pr_journal', ent::text, p_company, nm || ': RM ' || to_char(amt, 'FM999,999,990.00') || case p_kind when 'reimburse' then ' reimbursed' else ' returned' end, p);
  return jsonb_build_object('entry', ent, 'balance', private.pr_float(p_uid, p_company));
end $f$;

-- reversal of a posted entry (Finance). A reversed release puts the request back to Approved; a reversed purchase back to Settlement sent.
create or replace function public.cms_pr_reverse(p_entry uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare j public.pr_journal; ent uuid; q public.pr_requests;
begin
  if not public.cms_can('purchasing.finance', 'E') then raise exception 'Only Finance can reverse entries.'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Give the reason for the reversal.'; end if;
  select * into j from public.pr_journal where id = p_entry;
  if j.id is null then raise exception 'Entry not found.'; end if;
  if j.kind = 'reversal' then raise exception 'A reversal cannot be reversed. Post the entry again instead.'; end if;
  if exists (select 1 from public.pr_journal where reverses = j.id) then raise exception 'This entry has already been reversed.'; end if;
  if j.request_id is not null then
    select * into q from public.pr_requests where id = j.request_id for update;
    if j.kind = 'release' and q.status not in ('released', 'purchasing') then raise exception 'The purchase has been recorded: reverse the purchase first.'; end if;
    if j.kind = 'release' and q.status = 'purchasing' and q.pay_type <> 'supplier' and q.acknowledged_at is not null and q.actual_total is not null then raise exception 'The purchaser has started recording the purchase.'; end if;
  end if;
  ent := private.pr_post('reversal', (now() at time zone 'Asia/Kuala_Lumpur')::date, j.request_id, 'Reversal of ' || j.entry_no || ': ' || btrim(p_reason),
    (select jsonb_agg(jsonb_build_object('account_kind', l.account_kind, 'company_code', l.company_code, 'bank_account_id', l.bank_account_id, 'holder_uid', l.holder_uid, 'holder_name', l.holder_name,
       'category_id', l.category_id, 'department', l.department, 'event_id', l.event_id, 'debit', l.credit, 'credit', l.debit, 'memo', 'Reversal · ' || coalesce(l.memo, '')) order by l.line_no)
     from public.pr_journal_lines l where l.entry_id = j.id), j.id);
  if j.request_id is not null and j.kind = 'release' then
    update public.pr_requests set status = 'approved', release_entry_id = null, released_amount = null, release_bank_id = null, release_date = null, release_ref = null, release_to = null,
      release_slip = null, released_by = null, released_by_name = null, released_at = null, acknowledged_at = null, settle_due = null where id = j.request_id;
    perform private.pr_log(j.request_id, 'Release reversed by ' || private.cms_user_name(auth.uid()), btrim(p_reason));
  elsif j.request_id is not null and j.kind = 'purchase' then
    update public.pr_requests set status = 'settlement', closed_at = null, verified_by = null, verified_by_name = null, verified_at = null, purchase_entry_id = null where id = j.request_id;
    perform private.pr_log(j.request_id, 'Purchase posting reversed by ' || private.cms_user_name(auth.uid()), btrim(p_reason));
  end if;
  perform private.cms_log('purchasing.reversal', 'pr_journal', j.id::text, null, 'Entry ' || j.entry_no || ' reversed', jsonb_build_object('reason', p_reason, 'reversal', ent));
  return jsonb_build_object('entry', ent);
end $f$;

-- lock the books up to a date: Finance may move it forward; only Admin (settings) may reopen
create or replace function public.cms_pr_lock(p_until date)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare cur date := nullif(private.pr_cfg()->>'lock_date', '')::date; v jsonb;
begin
  if not (public.cms_can('purchasing.finance', 'E') or public.cms_can('purchasing.settings', 'E')) then raise exception 'Only Finance can close the books.'; end if;
  if p_until is not null and p_until > (now() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'You cannot close a period that has not ended.'; end if;
  if (p_until is null or p_until < coalesce(cur, '1900-01-01'::date)) and not public.cms_can('purchasing.settings', 'E') then raise exception 'Only Admin can reopen closed months.'; end if;
  v := private.pr_cfg() || jsonb_build_object('lock_date', p_until);
  insert into public.cms_settings (key, value, updated_at, updated_by) values ('pr_settings', v, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform private.cms_log('purchasing.lock', 'cms_settings', 'pr_settings', null, coalesce('Purchasing books closed up to ' || to_char(p_until, 'DD Mon YYYY'), 'Purchasing books reopened'), jsonb_build_object('from', cur, 'to', p_until));
  return v;
end $f$;

create or replace function public.cms_pr_year_end(p_year int)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare ye date := make_date(p_year, 12, 31);
begin
  if not (public.cms_can('purchasing.finance', 'V') or private.pr_is_director()) then raise exception 'Only Finance and the Directors can see the year-end closing.'; end if;
  return jsonb_build_object('year', p_year, 'lock_date', private.pr_cfg()->>'lock_date',
    'rows', coalesce((select jsonb_agg(jsonb_build_object('uid', z.holder_uid, 'holder', z.holder_name, 'company', z.company_code, 'year_end', z.bal, 'now', private.pr_float(z.holder_uid, z.company_code),
        'decision', c.decision, 'decided_by', c.decided_by_name, 'decided_at', c.decided_at) order by z.holder_name, z.company_code)
      from (select l.holder_uid, max(l.holder_name) holder_name, l.company_code, sum(l.debit - l.credit) bal from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
             where l.account_kind = 'float' and j.entry_date <= ye group by 1, 3) z
      left join public.pr_year_closings c on c.year = p_year and c.holder_uid = z.holder_uid and c.company_code = z.company_code), '[]'::jsonb));
end $f$;

create or replace function public.cms_pr_year_decide(p_year int, p_uid uuid, p_company text, p_decision text, p_entry uuid default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
declare bal numeric;
begin
  if not public.cms_can('purchasing.finance', 'E') then raise exception 'Only Finance can do the year-end closing.'; end if;
  if p_decision not in ('carry', 'settle') then raise exception 'Choose bring forward or settle.'; end if;
  if p_year > extract(year from now() at time zone 'Asia/Kuala_Lumpur')::int then raise exception 'That year has not started.'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into bal from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
   where l.account_kind = 'float' and l.holder_uid = p_uid and l.company_code = p_company and j.entry_date <= make_date(p_year, 12, 31);
  insert into public.pr_year_closings (year, holder_uid, holder_name, company_code, balance, decision, entry_id, decided_by, decided_by_name)
  values (p_year, p_uid, private.cms_user_name(p_uid), p_company, bal, p_decision, p_entry, auth.uid(), private.cms_user_name(auth.uid()))
  on conflict (year, holder_uid, company_code) do update set balance = excluded.balance, decision = excluded.decision, entry_id = coalesce(excluded.entry_id, public.pr_year_closings.entry_id),
    decided_by = excluded.decided_by, decided_by_name = excluded.decided_by_name, decided_at = now();
  perform private.cms_log('purchasing.year_end', 'pr_year_closings', p_year::text, p_company, private.cms_user_name(p_uid) || ' petty cash ' || p_year || ': ' || case p_decision when 'carry' then 'brought forward' else 'settled' end || ' (RM ' || to_char(bal, 'FM999,999,990.00') || ')', '{}'::jsonb);
end $f$;

create or replace function public.cms_pr_report(p_from date, p_to date, p_company text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if not (public.cms_can('purchasing.finance', 'V') or private.pr_is_director()) then raise exception 'Only Finance and the Directors can see the reports.'; end if;
  return (with x as (select l.*, j.entry_date, j.kind from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
                     where j.entry_date between p_from and p_to and (p_company is null or l.company_code = p_company)),
               e as (select * from x where account_kind = 'expense')
  select jsonb_build_object('from', p_from, 'to', p_to, 'company', p_company,
    'totals', jsonb_build_object('spent', (select coalesce(sum(debit - credit), 0) from e),
       'released', (select coalesce(sum(credit - debit), 0) from x where account_kind = 'bank' and kind in ('release')),
       'reimbursed', (select coalesce(sum(credit - debit), 0) from x where account_kind = 'bank' and kind = 'reimburse'),
       'returned', (select coalesce(sum(debit - credit), 0) from x where account_kind = 'bank' and kind = 'return'),
       'bank_net', (select coalesce(sum(credit - debit), 0) from x where account_kind = 'bank')),
    'by_company', coalesce((select jsonb_agg(jsonb_build_object('k', company_code, 'amt', a) order by a desc) from (select company_code, sum(debit - credit) a from e group by 1) z), '[]'::jsonb),
    'by_category', coalesce((select jsonb_agg(jsonb_build_object('k', (select name from public.pr_categories where id = category_id), 'asset', (select is_asset from public.pr_categories where id = category_id), 'amt', a) order by a desc) from (select category_id, sum(debit - credit) a from e group by 1) z), '[]'::jsonb),
    'by_department', coalesce((select jsonb_agg(jsonb_build_object('k', coalesce(department, '—'), 'amt', a) order by a desc) from (select department, sum(debit - credit) a from e group by 1) z), '[]'::jsonb),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('k', m, 'amt', a) order by m) from (select to_char(entry_date, 'YYYY-MM') m, sum(debit - credit) a from e group by 1) z), '[]'::jsonb),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('k', entry_date, 'out', o, 'in', i, 'spent', s) order by entry_date) from (
        select entry_date, sum(case when account_kind = 'bank' then credit else 0 end) o, sum(case when account_kind = 'bank' then debit else 0 end) i,
               sum(case when account_kind = 'expense' then debit - credit else 0 end) s from x group by 1) z), '[]'::jsonb),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('k', coalesce(b.bank_name || ' ', '') || b.account_name || coalesce(' ••' || b.last4, ''), 'company', b.company_code, 'id', b.id,
        'out', (select coalesce(sum(credit), 0) from x where bank_account_id = b.id), 'in', (select coalesce(sum(debit), 0) from x where bank_account_id = b.id)) order by b.company_code, b.account_name)
      from public.pr_bank_accounts b where p_company is null or b.company_code = p_company), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', ev.id, 'k', ev.name, 'company', ev.company_code, 'status', ev.status, 'budget', ev.budget,
        'committed', (select coalesce(sum(coalesce(r.approved_amount, r.est_total)), 0) from public.pr_requests r where r.event_id = ev.id and r.deleted_at is null and r.status not in ('draft', 'returned', 'disapproved', 'cancelled', 'closed')),
        'spent', (select coalesce(sum(l.debit - l.credit), 0) from public.pr_journal_lines l where l.event_id = ev.id and l.account_kind = 'expense')) order by ev.date_from desc nulls last, ev.name)
      from public.pr_events ev where ev.status in ('active', 'closed') and (p_company is null or ev.company_code = p_company)), '[]'::jsonb),
    'floats', coalesce((select jsonb_agg(jsonb_build_object('uid', z.holder_uid, 'holder', z.holder_name, 'company', z.company_code, 'balance', z.bal, 'free', private.pr_available(z.holder_uid, z.company_code)) order by z.holder_name, z.company_code)
      from (select holder_uid, max(holder_name) holder_name, company_code, sum(debit - credit) bal from public.pr_journal_lines where account_kind = 'float' and (p_company is null or company_code = p_company) group by 1, 3) z), '[]'::jsonb),
    'late', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'pr_no', r.pr_no, 'requester', r.requester_name, 'company', r.company_code, 'purpose', r.purpose, 'due', r.settle_due,
        'days', today - r.settle_due, 'amount', coalesce(r.released_amount, r.approved_amount), 'status', r.status) order by r.settle_due)
      from public.pr_requests r where r.deleted_at is null and r.status in ('released', 'purchasing') and r.settle_due < today and (p_company is null or r.company_code = p_company)), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'pr_no', r.pr_no, 'requester', r.requester_name, 'item', i.description, 'amount', i.act_total,
        'issue', case when i.verify_status = 'queried' then 'Queried: ' || coalesce(i.verify_note, '') else 'No receipt: ' || coalesce(i.no_receipt_reason, '') end) order by r.pr_no)
      from public.pr_requests r join public.pr_items i on i.request_id = r.id
     where r.deleted_at is null and coalesce(i.act_total, 0) > 0 and (i.no_receipt_reason is not null or i.verify_status = 'queried')
       and coalesce(r.settled_at, r.updated_at)::date between p_from and p_to and (p_company is null or r.company_code = p_company)), '[]'::jsonb),
    'status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.pr_requests where deleted_at is null and status <> 'draft' and (p_company is null or company_code = p_company) group by 1) z), '{}'::jsonb)));
end $f$;

-- statement: kind bank (p_ref = account id) · float (p_ref = purchaser uid, needs p_company) · event (p_ref = event id: spending)
create or replace function public.cms_pr_statement(p_kind text, p_ref uuid, p_company text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare opening numeric; title text;
begin
  if not (public.cms_can('purchasing.finance', 'V') or private.pr_is_director() or (p_kind = 'float' and p_ref = auth.uid())) then raise exception 'Only Finance and the Directors can see statements.'; end if;
  if p_kind not in ('bank', 'float', 'event') then raise exception 'Unknown statement.'; end if;
  title := case p_kind when 'bank' then (select coalesce(bank_name || ' ', '') || account_name || coalesce(' ••' || last4, '') || ' (' || company_code || ')' from public.pr_bank_accounts where id = p_ref)
                       when 'float' then 'Petty cash – ' || private.cms_user_name(p_ref) || ' (' || p_company || ')'
                       else (select name || ' (' || company_code || ') · budget RM ' || to_char(budget, 'FM999,999,990.00') from public.pr_events where id = p_ref) end;
  if title is null then raise exception 'Not found.'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into opening from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
   where j.entry_date < p_from and case p_kind when 'bank' then l.bank_account_id = p_ref when 'float' then l.account_kind = 'float' and l.holder_uid = p_ref and l.company_code = p_company
                                               else l.event_id = p_ref and l.account_kind = 'expense' end;
  return jsonb_build_object('title', title, 'kind', p_kind, 'from', p_from, 'to', p_to, 'opening', opening,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('date', z.entry_date, 'no', z.entry_no, 'memo', coalesce(z.lmemo, z.memo), 'pr_no', z.pr_no, 'debit', z.debit, 'credit', z.credit,
          'balance', opening + z.run) order by z.entry_date, z.entry_no, z.line_no)
      from (select j.entry_date, j.entry_no, j.memo, l.memo lmemo, l.line_no, l.debit, l.credit, (select pr_no from public.pr_requests where id = j.request_id) pr_no,
                   sum(l.debit - l.credit) over (order by j.entry_date, j.entry_no, l.line_no) run
              from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
             where j.entry_date between p_from and p_to and case p_kind when 'bank' then l.bank_account_id = p_ref when 'float' then l.account_kind = 'float' and l.holder_uid = p_ref and l.company_code = p_company
                                                                          else l.event_id = p_ref and l.account_kind = 'expense' end) z), '[]'::jsonb),
    'closing', opening + (select coalesce(sum(l.debit - l.credit), 0) from public.pr_journal_lines l join public.pr_journal j on j.id = l.entry_id
      where j.entry_date between p_from and p_to and case p_kind when 'bank' then l.bank_account_id = p_ref when 'float' then l.account_kind = 'float' and l.holder_uid = p_ref and l.company_code = p_company
                                                                   else l.event_id = p_ref and l.account_kind = 'expense' end));
end $f$;

-- queue, request flags and emails for the new steps
do $m$ declare src text;
begin
  select pg_get_functiondef('public.cms_pr_list(text)'::regprocedure) into src;
  if position('''settlement''' in src) = 0 then
    execute replace(src, $o$        or (q.status = 'approved' and (r->>'finance')::boolean)) end), '[]'::jsonb);$o$,
      $n$        or (q.status in ('approved', 'settlement') and (r->>'finance')::boolean)
        or (q.status = 'settlement' and q.excess_needed and q.excess_by is null and (r->>'director')::boolean and private.pr_level(q.actual_total) <> 'finance')) end), '[]'::jsonb);$n$);
  end if;
  select pg_get_functiondef('public.cms_pr_get(uuid)'::regprocedure) into src;
  if position('''settle''' in src) = 0 then
    execute replace(replace(src, $o$from public.pr_items i where i.request_id = q.id), '[]'::jsonb),$o$, $n$from public.pr_items i where i.request_id = q.id and not i.removed), '[]'::jsonb),$n$), $o$      'acknowledge', mine and q.status = 'released'));$o$,
      $n$      'acknowledge', mine and q.status = 'released',
      'settle', mine and q.status = 'purchasing',
      'verify', not mine and q.status = 'settlement' and (r->>'finance')::boolean,
      'excess', not mine and q.status = 'settlement' and q.excess_needed and q.excess_by is null
                and ((private.pr_level(q.actual_total) = 'finance' and (r->>'finance')::boolean) or (private.pr_level(q.actual_total) <> 'finance' and (r->>'director')::boolean)),
      'reverse', (r->>'finance')::boolean),
    'tolerance_pct', coalesce((private.pr_cfg()->>'tolerance_pct')::numeric, 10),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'no', j.entry_no, 'kind', j.kind, 'date', j.entry_date, 'memo', j.memo,
        'reversed', exists (select 1 from public.pr_journal x where x.reverses = j.id)) order by j.posted_at) from public.pr_journal j where j.request_id = q.id), '[]'::jsonb));$n$);
  end if;
  select pg_get_functiondef('public.cms_pr_notify_info(uuid,text)'::regprocedure) into src;
  if position('query_note' in src) = 0 then
    execute replace(src, $o$'reason', coalesce(case when p_event = 'returned' then q.return_reason else q.disapprove_reason end, ''),$o$,
      $n$'reason', coalesce(case when p_event = 'returned' then q.return_reason when p_event = 'queried' then q.query_note else q.disapprove_reason end, ''),
    'actual_total', q.actual_total, 'settle_due', q.settle_due, 'query_note', q.query_note, 'excess', q.excess_needed and q.excess_by is null,$n$);
  end if;
end $m$;

do $m$ declare f text; begin
  foreach f in array array['public.cms_pr_settle_save(uuid,jsonb,boolean)', 'public.cms_pr_verify(uuid,text,jsonb)', 'public.cms_pr_float_move(uuid,text,text,jsonb)',
    'public.cms_pr_reverse(uuid,text)', 'public.cms_pr_lock(date)', 'public.cms_pr_year_end(int)', 'public.cms_pr_year_decide(int,uuid,text,text,uuid)',
    'public.cms_pr_report(date,date,text)', 'public.cms_pr_statement(text,uuid,text,date,date)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $m$;
