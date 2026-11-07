-- MyEden Group CMS V1.0 · v2026.11.07 · PRI-010 F0 — claimant matching and PRFAF company (CLC 7 Nov 2026)
-- 1. Claimant names on forms that do not match a name in the Employee Master (short names, nicknames) can be matched once to the right person
--    (Admin › Sync Check › Match claimants); the match is kept and used everywhere the CMS links a claim to a person.
-- 2. PRFAF has no company field: its company now comes from the ledger account (MEDU → MyEden Edu Hub, ABORNE → Aborne Project),
--    kept in a new company_code column filled automatically, so the CMS lists, filters and checks PRFAF by company like the other forms.
-- Additive: new table, new column (filled from the ledger account), two company spellings added, functions replaced.

-- 1 · claimant matches ------------------------------------------------------------------------------------------------------------
create table if not exists public.cms_claimant_aliases (
  name_norm text primary key,
  name_seen text not null,
  person_id uuid not null references public.employee_master(id) on delete cascade,
  created_by uuid, created_by_name text, created_at timestamptz not null default now()
);
alter table public.cms_claimant_aliases enable row level security;
revoke all on public.cms_claimant_aliases from anon, authenticated;

create or replace function private.cms_claim_person(p_name text)
returns table(id uuid, employee_id text) language sql stable security definer set search_path = public, auth, pg_temp as $$
  select x.id, x.employee_id from (
    select em.id, em.employee_id::text employee_id, 0 o, 0 a, null::date s
      from public.cms_claimant_aliases ca join public.employee_master em on em.id = ca.person_id
     where ca.name_norm = private.cms_norm_name(p_name)
    union all
    select em.id, em.employee_id::text, 1, case when em.employment_status = 'active' then 0 else 1 end, em.start_date
      from public.employee_master em where private.cms_norm_name(em.employee_name) = private.cms_norm_name(p_name)
    union all   -- older claims carry the sign-in email instead of a name: the login linked to the person, or the payroll email
    select em.id, em.employee_id::text, 2, 0, em.start_date
      from auth.users u join public.cms_user_links ul on ul.user_id = u.id join public.employee_master em on em.id = ul.employee_master_id
     where position('@' in coalesce(p_name, '')) > 0 and lower(u.email) = lower(btrim(p_name))
    union all
    select em.id, em.employee_id::text, 3, 0, em.start_date
      from public.eppd_employees ee join public.employee_master em on em.id = ee.employee_master_id
     where position('@' in coalesce(p_name, '')) > 0 and lower(ee.email) = lower(btrim(p_name))) x
  order by x.o, x.a, x.s desc nulls last limit 1;
$$;
revoke all on function private.cms_claim_person(text) from public, anon, authenticated;

-- names on forms not matched to a person, with suggestions (people sharing a word of the name)
create or replace function public.cms_claimant_unmatched()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $f$
declare src record; acc jsonb := '[]'::jsonb; v jsonb;
begin
  if not (public.cms_is_super_admin() or public.cms_can('people.link', 'V')) then raise exception 'You do not have access to this.'; end if;
  for src in select * from (values ('scf', 'scf_submissions', 'SCF'), ('otcf', 'otcf_submissions', 'OTCF'), ('mtcf', 'mtcf_submissions', 'MTCF'),
      ('tec', 'tec_submissions', 'TEC V1'), ('tec-v2', 'tec_v2_submissions', 'TEC'), ('prfaf', 'prfaf_submissions', 'PRFAF')) s(code, tbl, label) loop
    if to_regclass('public.' || src.tbl) is null then continue; end if;
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('name', n, 'form', %L, 'count', c, 'latest', l)), '[]'::jsonb) from (
        select coalesce(nullif(j->>'claimed_by', ''), nullif(j->>'claimant_name', ''), nullif(j->>'emp_name', ''), nullif(j->>'teacher_name', ''), nullif(j->>'submitted_by_name', '')) n,
               count(*) c, max(coalesce(public.meg_forms_try_timestamptz(j->>'submitted_at'), public.meg_forms_try_timestamptz(j->>'created_at'))) l
          from (select to_jsonb(t) j from public.%I t) x
         where nullif(j->>'deleted_at', '') is null and lower(coalesce(j->>'status', '')) <> 'draft'
         group by 1) z
       where n is not null and not exists (select 1 from private.cms_claim_person(n) p where p.id is not null)$q$, src.label, src.tbl) into v;
    acc := acc || v;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('name', g.name, 'forms', g.forms, 'count', g.cnt, 'latest', g.latest,
      'suggest', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.employee_name, 'employee_id', s.employee_id, 'company', private.cms_canon(s.company_code),
                    'status', s.employment_status) order by s.score desc, s.active desc, s.employee_name), '[]'::jsonb)
                  from (select * from (select em.id, em.employee_name, em.employee_id, em.company_code, em.employment_status, (em.employment_status = 'active') active,
                               (select count(*) from regexp_split_to_table(upper(g.name), '[^A-Z]+') t where length(t) >= 2
                                  and t = any (regexp_split_to_array(upper(em.employee_name), '[^A-Z]+'))) score
                          from public.employee_master em) q where q.score > 0 order by q.score desc, q.active desc limit 5) s))
      order by g.cnt desc, g.name)
    from (select x->>'name' name, jsonb_agg(jsonb_build_object('form', x->>'form', 'count', (x->>'count')::int)) forms, sum((x->>'count')::int) cnt, max(x->>'latest') latest
            from jsonb_array_elements(acc) x group by private.cms_norm_name(x->>'name'), x->>'name') g), '[]'::jsonb);
end $f$;
revoke all on function public.cms_claimant_unmatched() from public, anon;
grant execute on function public.cms_claimant_unmatched() to authenticated;

create or replace function public.cms_claimant_match(p_name text, p_person uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if not (public.cms_is_super_admin() or public.cms_can('people.link', 'V')) then raise exception 'You do not have access to this.'; end if;
  if private.cms_norm_name(p_name) is null then raise exception 'No name to match.'; end if;
  if p_person is null then
    delete from public.cms_claimant_aliases where name_norm = private.cms_norm_name(p_name);
    return;
  end if;
  if not exists (select 1 from public.employee_master where id = p_person) then raise exception 'Person not found.'; end if;
  insert into public.cms_claimant_aliases (name_norm, name_seen, person_id, created_by, created_by_name)
  values (private.cms_norm_name(p_name), btrim(p_name), p_person, auth.uid(), private.cms_user_name(auth.uid()))
  on conflict (name_norm) do update set person_id = excluded.person_id, name_seen = excluded.name_seen, created_by = excluded.created_by,
    created_by_name = excluded.created_by_name, created_at = now();
  insert into public.employee_events (employee_id_ref, event_type, note, payload, changed_by)
  values (p_person, 'claimant_name_matched', 'Claims under the name "' || btrim(p_name) || '" linked to this person', jsonb_build_object('name', btrim(p_name)), auth.uid());
end $f$;
revoke all on function public.cms_claimant_match(text, uuid) from public, anon;
grant execute on function public.cms_claimant_match(text, uuid) to authenticated;

create or replace function public.cms_claimant_matches()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when public.cms_is_super_admin() or public.cms_can('people.link', 'V') then
    coalesce((select jsonb_agg(jsonb_build_object('name', a.name_seen, 'person_id', a.person_id, 'person', em.employee_name, 'employee_id', em.employee_id,
      'by', a.created_by_name, 'at', a.created_at) order by a.created_at desc)
      from public.cms_claimant_aliases a join public.employee_master em on em.id = a.person_id), '[]'::jsonb) end;
$$;
revoke all on function public.cms_claimant_matches() from public, anon;
grant execute on function public.cms_claimant_matches() to authenticated;

-- 2 · PRFAF company from the ledger account -------------------------------------------------------------------------------------
update public.cms_companies set aliases = array_append(coalesce(aliases, '{}'), 'MEDU') where code = 'MEH' and not ('MEDU' = any (coalesce(aliases, '{}')));
update public.cms_companies set aliases = array_append(coalesce(aliases, '{}'), 'ABORNE') where code = 'ABP' and not ('ABORNE' = any (coalesce(aliases, '{}')));

alter table public.prfaf_submissions add column if not exists company_code text;
create or replace function private.cms_prfaf_company() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  if new.ledger_account_id is not null then
    new.company_code := coalesce(private.cms_canon((select l.code from public.ledger_accounts l where l.id = new.ledger_account_id)), new.company_code);
  end if;
  return new;
end $f$;
drop trigger if exists trg_cms_prfaf_company on public.prfaf_submissions;
create trigger trg_cms_prfaf_company before insert or update of ledger_account_id on public.prfaf_submissions
  for each row execute function private.cms_prfaf_company();
update public.prfaf_submissions p set company_code = private.cms_canon(l.code)
  from public.ledger_accounts l where l.id = p.ledger_account_id and p.company_code is distinct from private.cms_canon(l.code);
