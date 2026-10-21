-- MyEden Group CMS V1.0 · run once in the Supabase SQL editor (project vzngfswtofegimfcoigx), then "Run".
-- Removes the "TEST EMPLOYEE" record (a handbook test bridge record, never a real person). Its handbook assignment
-- was already removed. Nothing else refers to it.
delete from public.employee_master
 where id = '22fbbeec-ead4-4ff8-84cd-9031226e0112' and employee_name = 'TEST EMPLOYEE';

-- check: should return 0
select count(*) as test_employee_left from public.employee_master where employee_name = 'TEST EMPLOYEE';
