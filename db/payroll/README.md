# Payroll (MyPayroll V2.0) inside the CMS project — Phase 2, step 1

17 Oct 2026. The MyPayroll V2.0 tables (`eppd_*`) were created in the CMS project and their data copied from the
MyPayroll-System project. MyPayroll-System itself was only read and is unchanged; MyPRSys tables stay there.

How it was done
- Structure: MyPayroll's own setup files, fresh-install form (no-op "drop … if exists" lines removed), applied through the
  connector as migrations `pay_001_foundation`, `pay_004_employees`, `pay_005_leave_time_a`, `pay_006_payroll_a`,
  `pay_008_phase6`, `pay_009_010_schema`. Seed rows and one-off data fixes (002, 003, 007 and the data parts of 009/010)
  were not run: the copied data already contains their result. The files here are those sources.
- The 4 functions that contain DELETE statements and the data copy: `copy_mypayroll_into_cms.sql`, run by CLC in the
  CMS SQL editor (the session refuses DELETE statements). It reads MyPayroll over dblink, swaps login ids by email,
  checks every table row for row, and keeps nothing unless all 29 tables are identical. Password left as a placeholder.

Checked afterwards: 29 tables identical (counts + row checksums), Jan–Sep 2026 totals identical (lines, gross, EPF,
SOCSO, EIS, PCB, net paid), 27 eppd functions identical, structure (373 columns, constraints, indexes, 59 policies,
56 triggers, view, grants) identical, id counters continue after the copied ids.

## Step 2 — new Employee IDs and one person record (19 Oct 2026)

Run by CLC in the CMS SQL editor (script kept out of this public repo: it lists staff record ids).
- New Employee ID format `<M|E|H|A><MMYY joined><M|F><0001…>`, directors `M0000M1000` / `M0000F1000`;
  `format_group_employee_id` (MEG-EAF V2) and `eppd_companies.eid_prefix` switched; next group number 0183.
- `employee_master.previous_employee_id`, `eppd_employees.previous_emp_id` and `eppd_employees.employee_master_id` added.
- All 184 payroll people linked one-to-one to Employee Master (57 existing records updated, 127 added, one duplicate merged).
- Two paying-company corrections agreed by CLC (Jun, Aug, Sep 2026 company totals rebuilt; overall totals unchanged).
- Checked: 183 IDs, all new format, payroll = Employee Master for every person, Jan–Sep net paid unchanged (966,235.06).
