-- MyEden Group CMS V1.0 · v2026.11.10 · 2027 holiday lists (MEG 2027 Holiday List, CLC 10 Nov 2026). Data only, additive.
-- Staff list → payroll holidays (eppd_holidays). Student list → E10 calendar. Genius Eden Home school → E3; Happy Dino Kindergarten → E3+
-- (term breaks: only students enrolled in childcare services attend). Christmas is observed on Fri 24 Dec 2027 as published.
-- The CNY company closure 10–14 Feb 2027 (students still on holiday) is created as a DRAFT only: 10, 11 Feb free, 12 Feb annual leave;
-- HR / Admin check the split and the people, then apply it on the Company Closure Days page.
insert into public.eppd_holidays (holiday_date, name, scope, is_active) values
  ('2027-02-05', 'Chinese New Year', 'Johor', true), ('2027-02-06', 'Chinese New Year', 'Johor', true), ('2027-02-07', 'Chinese New Year', 'Johor', true),
  ('2027-02-08', 'Chinese New Year', 'Johor', true), ('2027-02-09', 'Chinese New Year', 'Johor', true),
  ('2027-03-10', 'Hari Raya Aidilfitri', 'Johor', true),
  ('2027-03-23', 'Sultan of Johor''s Birthday', 'Johor', true),
  ('2027-04-02', 'Good Friday', 'Johor', true),
  ('2027-05-01', 'Labour Day', 'Johor', true),
  ('2027-05-17', 'Hari Raya Haji', 'Johor', true),
  ('2027-06-07', 'Agong''s Birthday', 'Johor', true),
  ('2027-08-31', 'Merdeka Day', 'Johor', true),
  ('2027-09-16', 'Malaysia Day', 'Johor', true),
  ('2027-10-28', 'Deepavali', 'Johor', true),
  ('2027-12-24', 'Christmas Day', 'Johor', true)
on conflict (holiday_date, scope) do nothing;

do $d$ declare cal text; begin
  foreach cal in array array['e10', 'e3', 'e3p'] loop
    insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title, note)
    select cal, k, f::date, t::date, n, nt from (values
      ('holiday', '2027-02-05', '2027-02-14', 'Chinese New Year', null), ('holiday', '2027-03-10', '2027-03-10', 'Hari Raya Aidilfitri', null),
      ('holiday', '2027-03-23', '2027-03-23', 'Sultan of Johor''s Birthday', null), ('holiday', '2027-04-02', '2027-04-02', 'Good Friday', null),
      ('holiday', '2027-05-01', '2027-05-01', 'Labour Day', null), ('holiday', '2027-05-17', '2027-05-17', 'Hari Raya Haji', null),
      ('holiday', '2027-06-07', '2027-06-07', 'Agong''s Birthday', null), ('holiday', '2027-08-31', '2027-08-31', 'Merdeka Day', null),
      ('holiday', '2027-09-16', '2027-09-16', 'Malaysia Day', null), ('holiday', '2027-10-28', '2027-10-28', 'Deepavali', null),
      ('holiday', '2027-12-24', '2027-12-24', 'Christmas Day', null),
      ('term_break', '2027-05-24', '2027-05-28', 'Term Break 1', 'Only students enrolled in childcare services attend'),
      ('term_break', '2027-08-30', '2027-08-30', 'Term Break 2', 'Only students enrolled in childcare services attend'),
      ('term_break', '2027-09-01', '2027-09-03', 'Term Break 2', 'Only students enrolled in childcare services attend')) v(k, f, t, n, nt)
    where (cal <> 'e10' or v.k <> 'term_break')
      and not exists (select 1 from public.cms_calendar_entries e where e.calendar = cal and e.date_from = v.f::date and e.title = v.n);
  end loop;
  if not exists (select 1 from public.cms_closures where date_from = '2027-02-10' and status <> 'cancelled') then
    with c as (insert into public.cms_closures (title, date_from, date_to, free_dates, al_dates, note)
               values ('CNY company closure 2027', '2027-02-10', '2027-02-14', '{2027-02-10,2027-02-11}', '{2027-02-12}', 'Students on CNY holiday 5–14 Feb; staff holidays end 9 Feb. Split to be confirmed.')
               returning id, title, date_from, date_to)
    insert into public.cms_calendar_entries (calendar, kind, date_from, date_to, title, note, closure_id)
    select 'staff', 'closure', date_from, date_to, title, 'Company closure (draft)', id from c;
  end if;
end $d$;
