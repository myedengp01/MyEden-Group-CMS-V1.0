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
