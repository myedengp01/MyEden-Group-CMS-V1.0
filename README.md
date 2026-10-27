# MyEden Group CMS V1.0

MyEden Group's Central Management System: one login and one database for every person, from application to offboarding.
Static site (GitHub Pages) + Supabase. No build step.

**Current version:** v2026.10.22-10:40 · **Phase 6 · Payroll in the CMS** (Phases 0–4 live)

## What this version is
Phase 0 connects the CMS to the Supabase project `vzngfswtofegimfcoigx` ("MyEden Group CMS V1.0"):
- **Sign-in** with the same email and password as MEG-EAF V2 and MEG-FORMS; forgot / reset password.
  A login with no CMS role sees "No access yet".
- **Roles & access**: Super Admin, Admin, HR (live now) and Payroll, Finance, Approver, Staff (for later phases).
  Each role has View / Create / Edit / Approve / Delete / Export per module, optionally limited to companies.
  The menu only shows what a person may open. Only a Super Admin grants roles or changes permissions.
- **Suggested roles** from MEG-EAF V2 and MEG-FORMS permissions and from the person's JD position; a Super Admin accepts each one.
- **One person record**: `employee_master`. Each login can be linked to its person. Employer (contract) and paying company are separate.
- **Dashboard** with live figures, my tasks, recent activity. **Approvals** shows what is waiting in MEG-FORMS and MEG-EAF V2.
- **View People** (no IC, bank or salary), **Organisation** (companies, other spellings, centres, JD departments).
- **Audit log** (append-only) and **Export all data** (Excel or JSON, Super Admin, logged).

Other menu pages show the phase they arrive in and link to the app that does the job today.

## Database (all additive; nothing existing was changed)
`db/migrations/` holds every SQL file applied to the project, in order:
1. `20261017_cms_phase0_foundation.sql` — structure snapshot, `cms_` tables, functions, lock-down, first Super Admin
2. `20261017_cms_phase0_patch1.sql` — centre falls back to department code; ignore placeholder form rows
3. `20261017_cms_phase0_patch2.sql` — fixed search path on the audit-log guard
4. `20261017_cms_payroll_settings_module.sql` — Payroll Settings permission row
5. `20261017_cms_phase1_claims.sql` — claims list, claim detail, processing / payment / note actions (through the MEG-FORMS steps)
6. `20261017_cms_phase1_dashboard.sql` — dashboard claim figures by stage
7. `20261017_cms_phase1_decisions.sql` — approve / disapprove (OTCF, MTCF) and mark as done (TEC) in the CMS, signed PDF link
8. `20261017_cms_payroll_viewer_role.sql` — Account / Payroll Viewer role (view only)
9. `20261017_cms_director_approval.sql` — CEO / Director role; claims by Super Admins, Admins and Directors need a Director
10. `20261019_cms_paying_companies.sql` — Paying Companies: transfer, joint payment, end a company, main company, corrections (over MyPayroll's `eppd_assignments`); People list with previous IDs

11. `20261019_cms_main_by_period_notice_names.sql` — main paying company by period, notice period until, names in upper case, People columns (needs `db/payroll/011_main_company_by_period.sql` run by hand first)

12. `20261019_cms_increments.sql` — Increments & Reviews (PRI-001): review intervals, per-person review, record increment
13. `20261020_cms_people_leaving.sql` — View People: leaving reason, rehire eligibility and rehired tag from payroll (PRI-002)
14. `20261020_cms_leaving_rehire.sql` — Former Staff: record the reason for leaving and rehire from the CMS; fills "Dismissed" as the reason for the 3 dismissed leavers

15. `20261021_cms_recruitment.sql` — Phase 3: recruitment read functions (applications, JD, positions, offers & onboarding, handbook), one group-wide next Employee ID number for EAF / CMS / MyPayroll, and `cms_hire` (accepted applicant → person + payroll record)

16. `20261021_cms_hire_from_approved.sql` — Offers & Onboarding lists applications with decision Approved (MEG-EAF V2 has no screen for the offer-accepted stage); Hire works straight from the application
17. `20261021_cms_auto_employee_id.sql` — Employee ID number reserved automatically when a person reaches onboarding (first come, first served), ID completed once gender and start date are known, rebuilt with the same number until the first payslip, never reused; "Did not join"; Employee ID incomplete list. One-off: `db/payroll/012_remove_test_employee.sql` (run in the SQL editor) removes the TEST EMPLOYEE record
18. `20261021_cms_existing_employee_match.sql` — approved applications matched to existing employees (email or name): shown with "Link" instead of "Hire", Hire refuses duplicates, workflow-test applications hidden; one-off link of applications that already had an employee record
19. `20261021_cms_self_service.sql` — Phase 4a staff self-service: per-person switches (all off by default), payslip / EA releases (finalised months only), Reports to (pre-filled from the offer's "reporting to" where the name matched), My Profile change requests approved by HR, salary history
20. `20261021_cms_items_handover.sql` — Phase 4b items register and hand-over (PRI-006): item types, items with confirmation by the person, every change as an event (passwords never stored), hand-over opened automatically when a leaving date is confirmed, approval by the reports-to line or HR / Admin, clearance status
21. `20261021_cms_self_claims_handbook.sql` — Phase 4c My Claims (own SCF / OTCF / MTCF with stage) and My Handbook (assignment status)
22. `20261021_cms_self_leave.sql` — Phase 4d My Leave (built, switched off): leave requests, approval along Reports to (directors approve anyone below; a director by the other director or HR; none set → HR), HR tick for "entered in payroll"
23. `20261021_cms_careers.sql` — Phase 5a MyEden salary caps beside each JD band (with history), JD position per person (matched by title or set by HR), Career Paths and the staff timeline
24. `20261021_cms_appraisals.sql` — Phase 5b probation reviews and annual appraisals (JD KPI scores, KPI grade, recommendation), approval applies confirmation / probation extension / KPI grade to payroll / promotion; My Appraisal for self-assessment and reviewers
25. `20261021_cms_probation_rules.sql` — probation end date = confirmation date; probation length from the record, else the offer's probation months, else assumed 3 months; extension letter tracking and an automatic follow-up review
26. `20261021_cms_training_certs.sql` — Phase 5c certificate types (validity, required for all, reminder days), certificates per person with copy and verification, training sessions with attendance that issues the certificate, My Certificates (self-service part "certs")
27. `20261021_cms_documents_letters.sql` — Phase 5d employee documents (storage bucket `employee-documents` policies, register, remove with reason), HR letters from templates (context filled from records, drafts, issue, void; probation extension letter marks the appraisal letter issued), off-boarding hand-over checklist (approval needs every step done or a note)
28. `20261021_cms_permissions_hr.sql` — "Who can do what" editable by Admin and Super Admin with a reason; locked sections (Companies & Settings, Users & Roles, Export All Data, Purchase & Funding) only a Super Admin can change; new "Set MyEden salary caps" permission (Admin by default, HR view only); HR access widened (Payroll and Payroll Settings, overtime, organisation structure, claims view, documents and training export, audit log view); Directors approve HR letters; MyPayroll access follows the CMS Payroll "edit" permission
29. `20261021_cms_letters_v2.sql` — HR Letters centre: letter steps draft → approval (never the drafter) → issue; template lifecycle (draft, pending, published, sent back, retired; on/off; changes to a published template wait for approval; retirement approval); Word templates in the private `hr-letter-sources` bucket; placeholder register editing; issued letters can be voided; MEG-EAF V2 letter write functions retired (they now point to the CMS)
30. `20261022_cms_reports.sql` — Phase 5e Reports & Analytics: one read-only call with people (start / last day, company, department, gender, leaving reason; names only for People viewers), payroll cost per month and company (Payroll viewers only) and claims (only forms the user may see)
31. `20261022_cms_permission_catalogue.sql` — the complete permission list (descriptions, only the actions that apply, special permissions incl. Phase 6 ones), today's settings saved as each role's default with reset, per-person extra permissions, roles created / renamed / removed by Admin, Admin and Super Admin grant roles (Super Admin only for Super Admin, locked items and the Admin role; nobody changes their own access), Account Viewer and Payroll Viewer as separate roles; letters, claim payment, payslip release, self-service, hand-over and login linking checked against their own special permissions
32. `20261022_cms_phase6a_settings.sql` — Phase 6a: extra row-level rules so CMS users reach the MyPayroll settings tables by their CMS permissions (read: Payroll or Payroll settings view; change: Payroll settings edit), Employee IDs by "Change Employee ID", the workbook import by Super Admin
33. `20261022_cms_phase6b_leave_time.sql` — Phase 6b: row-level rules for leave records, adjustments, year closes and KPI grades (Leave view / edit), hours and OTCF links (Payroll view / edit), payroll months (Payroll view) and approved OTCF claims (Overtime claims view); year close, OTCF pull and leave import accept the CMS permissions
34. `20261022_cms_phase6c_payroll.sql` — Phase 6c: Payroll "view" may read pay lines, claims, date of birth, salary history, tax profiles, loans and settlements; "Prepare payroll" may change allowances and delete a draft month; save / finalise / reopen accept Prepare / Finalise / Reopen payroll
35. `20261022_cms_phase6d_payslips_reports.sql` — Phase 6d: `cms_eppd_private` view (via `cms_payroll_private()`): date of birth with Payroll view, IC / passport / EPF / SOCSO / tax numbers only with "See IC", bank only with "See bank"; the Phase 6c read rule on the private table is switched off (`using (false)`)
36. `20261022_cms_phase6e_directory.sql` — Phase 6e: loans and settlements change with "Prepare payroll"; workbook history import accepts CMS Super Admin; Employee Directory permissions (`directory`, `directory.contacts`, `directory.all`, `directory.chart`, defaults Admin / HR / Director), `cms_directory()` and `cms_directory_exported()`
37. `20261022_cms_letter_facts.sql` — PRI-009: `cms_letter_facts(person, letter type)` with helpers `private.cms_ldate`, `private.cms_fact`, `private.cms_fact_group`
38. `20261022_cms_sync_check.sql` — PRI-010: `cms_sync_runs`, `private.cms_sync_compute()`, `private.cms_sync_record()`, `cms_sync_check(p_run)` (Super Admin), nightly pg_cron job `cms-sync-check-nightly` (15:30 UTC)
39. `20261022_cms_add_person.sql` — People › Add Person: `cms_hire` takes `manual: true` (no application; People "add"), an existing Employee ID, Chinese name and nationality, refuses a duplicate NRIC, records `source_type = manual_entry`; `cms_hire_prefill()` with no arguments gives the lists
40. `20261022_cms_person_profile.sql` — PRI-011: specials `people.personal`, `people.personal_edit`, `people.photos`; tables `cms_person_profile`, `cms_person_images`; private bucket `cms-profile-images` with its read / upload rules; `cms_person_profile`, `cms_person_eaf_image`, `cms_person_profile_save`, `cms_person_image_set`
41. `20261026_cms_payroll_reimport_months.sql` — Import Past Months: the reason and the imported months are written to the payroll log and the CMS Audit Log
42. `20261026_cms_letter_jd_placeholders.sql` — placeholders `jd_title`, `jd_responsibilities` (+ `jd_reference`, `jd_version` from records); `cms_letter_jd_lookup(person, title, position)`
43. `20261026_cms_letter_reference_jd_appendix.sql` — `hr_letter_records.reference` + `{{letter_reference}}` (given on first save, e.g. MEG/HR/LOC_LOI/2026/0001); placeholders `jd_department`, `jd_level`, `jd_reports_to`, `jd_purpose`, `jd_effective_date`, `jd_qualifications`, `jd_experience`; `cms_letter_jd_titles(person)`
44. `20261026_cms_person_master_edit.sql` — Super Admin only: `cms_person_master(person)`, `cms_person_master_save(person, changes, reason)` (identity, Employee ID, master company, centre, job title, employment status, confirmation / probation dates; join date locked; Employee Master + payroll record together; logged)
45. `20261027_cms_employment_history.sql` — permission `people.history` (Admin, HR); `cms_employer_periods`; `cms_person_history`, `cms_person_transfer`, `cms_person_period_add`, `cms_person_period_end`, `cms_person_paylines_move` (Super Admin); master company follows the employer history
46. `20261027_cms_history_correct_company.sql` — `cms_person_assignment_correct` (Super Admin: fix the company of a paying-company part, dates kept); seeded employer periods end on the last day for former staff
47. `20261027_cms_letter_jd_duties_format.sql` — `{{jd_responsibilities}}` as numbered titles with the description on the next line

Payroll data copied from MyPayroll V2.0 (Phase 2) is described in `db/payroll/README.md`.

The browser never touches tables directly. Every read and write goes through a `cms_` function that checks the role first
and writes an audit entry. A snapshot of the database structure before Phase 0 is stored in `cms_schema_snapshots`
(download it from Export All Data › Structure snapshot only).

## Try it
- Upload the folder to `myedengp01/Myeden-Group-CMS-V1.0` and turn on **Settings › Pages › Deploy from branch `main` / root**.
  It will be at https://myedengp01.github.io/Myeden-Group-CMS-V1.0/
- In Supabase › Authentication › URL Configuration, add that address to **Redirect URLs** so password-reset emails return to the CMS.
- Opening `index.html` straight from the folder also works for a quick look.

## Plan
| Phase | What |
|---|---|
| 0 Foundation | Read existing apps and database; sign-in, roles & access (positions from the JD Manual), organisation data, audit log, export all data. Supabase project `vzngfswtofegimfcoigx` renamed "MyEden Group CMS V1.0". |
| 1 MEG-FORMS | SCF, OTCF, MTCF, PRFAF, TEC (teacher tuition claims) as CMS modules |
| 2 Payroll | MyPayroll V2.0 tables and data move into the CMS project (between pay runs) |
| 3 Recruitment & onboarding | MEG-EAF V2: JD Manual, applications, LOEC, handbook, Employment Act tools; accepted applicant → employee |
| 4 Self-service | Staff logins: payslips, leave, claims, profile |
| 5 HR operations | HR Letters, assets & equipment, training & certificates, KPI & appraisal, documents, reports |
| Later | Attendance, announcements |

Not included: HD Manager, MEG-PCMON.

## Layout
```
index.html          app shell
css/cms.css         theme (light + dark, responsive)
js/version.js       UVN — the only place the version is set
js/config.js        Supabase address and publishable key (public by design)
js/api.js           sign-in and calls to the cms_ functions
js/menu.js          every page: route, label, phase, the system it replaces, permission module
js/icons.js         line icons
js/claim-pdf.js     signed claim PDFs, made by the form app's own code in a hidden frame
js/app.js           sign-in screens, sidebar, top bar, Ctrl+K search, router, pages
db/migrations/      SQL applied to the database, in order
assets/logos/       MyEden mark (3D logo) and company logos
```

## Known issues
- **Claim emails only reach myeden.group@gmail.com (found 17 Oct 2026).** The MEG-FORMS email functions (otcf-notify,
  mtcf-notify, tec-notify, …) send through Resend from `onboarding@resend.dev`, which is Resend's test mode: it refuses every
  other recipient (`403 · You can only send testing emails to your own email address`). Affects the form apps and the CMS
  alike; the decision itself is always saved. **Fix:** verify a company domain at resend.com/domains (add its DNS records),
  then change `FROM_EMAIL` in each notify function to `MEG-FORMS <noreply@that-domain>`. Alternative: Gmail with an app password.

## Change log
- **v2026.10.27-12:55** — HR letters: the JD duties (`{{jd_responsibilities}}`) now follow the JD Manual's layout — "1. Title" in bold, the
  description on its own indented line under it. Database: `20261027_cms_letter_jd_duties_format.sql`.
- **v2026.10.27-12:25** — **Printing Word letters.** Printed / saved PDF letters now come out as clean A4 pages: no browser web address,
  date or page counter on the paper, no blank half-pages. Text that runs past the bottom margin continues on a new page with the same
  letterhead and footer, and "Page x of y" in the footer counts the pages. The PDF and the Word download are named
  "<employee> - <letter> - <date time>".
- **v2026.10.27-11:15** — Word letter preview: the "DRAFT — NOT ISSUED" / "DRAFT — INCOMPLETE" / "APPROVED — NOT YET ISSUED" mark is now a
  faint diagonal watermark across the page instead of red text at the top, which overlapped the letterhead. The issued Word file has no mark.
- **v2026.10.27-10:50** — History tab: **Correct…** on each paying-company part (Super Admin) for a company that was wrong from the
  start — the dates stay, only the company changes; then move the pay lines. Database: `20261027_cms_history_correct_company.sql`.
- **v2026.10.27-09:40** — **Employment history on the profile (History tab).** For people whose path is not a straight line: the
  employer of record over time, each employment period with how it ended, and its paying-company parts. **Transfer…** from a date changes
  the employer of record, the paying company or both (service continuous; salary and running allowances carry over). **Add past
  period…** records an employment that has already ended (e.g. a temporary contract after leaving). **Change end…** corrects how / when a
  past period ended. **Pay lines vs history** lists months paid under the wrong company; a Super Admin moves them (amounts unchanged,
  months stay finalised, company totals move, audit entry per month). New permission "Employment history" (Admin and HR by default).
  Join dates stay locked. Database: `20261027_cms_employment_history.sql`.
- **v2026.10.26-22:30** — Fix: Edit master record failed for former staff ("confirmation_status … not-null"). Their Resigned /
  Terminated / Dismissed status is now shown and locked (changed only through Leaving / Rehire), and the status can no longer be cleared.
- **v2026.10.26-20:45** — **Super Admin: edit master record.** On the employee profile, a Super Admin can correct the full name, Chinese
  name, gender, date of birth, NRIC, nationality, Employee ID, master company (employer of record), centre / department, job title,
  employment status, confirmation date and probation end date. Changing the company suggests the matching Employee ID (same running
  number); the old ID is kept as the previous ID. The join date is locked. A reason is required; the before / after list is shown before
  saving and kept in the audit log and the Timeline. The Employee Master and the payroll record change together. Database:
  `20261026_cms_person_master_edit.sql`.
- **v2026.10.26-18:35** — **Company letterhead on Word letters.** A Word template with no picture in its page header (e.g. "All Companies"
  templates) now gets the company letterhead (MEG / HD / ABP / MEH) added to the header automatically: the employee's company in the letter
  workspace and in the issued Word file, the template's company in the template editor and review (MyEden Group when "Any company").
  Templates that carry their own letterhead are left as they are. No database change.
- **v2026.10.26-17:10** — **One letter template for every JD level.** Every letter now gets its own reference number when the draft is first
  saved (`{{letter_reference}}`, e.g. MEG/HR/LOC_LOI/2026/0001 — company / HR / letter type / year / running number), fixed for good and
  usable in the footer. More JD placeholders from the same approved JD as `{{jd_title}}`: department, level, reports to, purpose, effective
  date, minimum qualifications and required experience — so a single template can carry the full JD of any position in an appendix. The
  New position field offers the approved JD titles of the person's company, all levels. Database: `20261026_cms_letter_reference_jd_appendix.sql`.
- **v2026.10.26-13:40** — **HR letters: duties, JD reference and version from the JD Manual.** New placeholders `{{jd_title}}` and
  `{{jd_responsibilities}}` (one lettered line per responsibility: "a. Title — Description"); `{{jd_reference}}` and `{{jd_version}}` are now
  filled too. The JD is the approved one of the employee's own company for the position in the letter (`{{new_position}}` /
  `{{revised_position}}`, or the position chosen in the transfer & promotion letter), else the employee's current position (Career Paths
  JD first, then the job title on record). A note above the fields says which JD was used, or that none was found. In Word letters a
  paragraph holding only `{{jd_responsibilities}}` becomes one paragraph per duty in the same style. Database: `20261026_cms_letter_jd_placeholders.sql`.
- **v2026.10.26-11:45** — **Import Past Months: choose the months.** After reading the workbook, every month has a tick box (none
  ticked to start); only the ticked months are imported, and the button names them ("Import 2 months (Mar, Jul)"). Each month shows
  whether it is new, imported before (replaced — with the lines that change and the gross / net difference per person) or made /
  reopened in the payroll (cannot be ticked). A reason is required; it goes into the payroll log and the Audit Log. Replaced months keep
  no old copy. No SQL reset is needed to re-import. Database: `20261026_cms_payroll_reimport_months.sql`.
- **v2026.10.25-23:20** — PRI-011 · **employee profile**: a person's name in View People or the Employee Directory opens one page with
  everything about them — header with the passport-size photo, name / Chinese name, Employee ID, position, status, centre, company,
  service and reports-to; tabs Overview, Personal, Family (and emergency contact), Background (education, work history, languages,
  skills, application declarations), Employment (periods, paying companies, probation, notice, leaving), Pay (salary history,
  allowances, bank, EPF / SOCSO / tax), Leave (balances, same numbers as Leave Balances, and this year's records), Photo & documents
  (photo, IC front / back, passport page, uploaded documents), Letters & reviews, Timeline. Photo and IC images and personal details come
  from the MEG-EAF V2 application where there is one; HR can upload images and edit personal details (kept in the CMS and logged; the
  application is not changed). New special permissions, HR and above by default and assignable: "See personal details", "Edit personal
  details", "Upload photo and ID images"; IC images follow "See IC and passport numbers". Database: `20261022_cms_person_profile.sql`.
- **v2026.10.22-15:50** — **People › Add Person** inside the CMS (it still pointed to MyPayroll V2.0, whose Add employee creates only the
  payroll record): one form creates the person in the Employee Master and their payroll record together — identity (NRIC fills the date
  of birth), employer and paying company, centre, job title, statuses, working hours, starting salary — with the next Employee ID, or an
  existing ID for someone who already has one. Duplicates are refused (same name / email: use Rehire; same NRIC). Needs People "add" and
  "edit" and Paying Companies "edit". Database: `20261022_cms_add_person.sql` (extends `cms_hire` and `cms_hire_prefill`).
- **v2026.10.22-15:05** — PRI-010 step B · **payroll moves to the CMS, Sync check**: MyPayroll V2.0 (v2026.10.22-14:55) shows a banner on
  every page — "Payroll now runs in the MyEden Group CMS" — with a link to the same page here; it keeps working as a fallback until you
  confirm and it is made read-only. New **Admin › Sync Check** (Super Admin): for each form (SCF, OTCF, MTCF, TEC, PRFAF) and MEG-EAF V2,
  the records, statuses and anything that would make a record look different or go missing in the CMS (claimant not matched to a person,
  company not recognised, unknown status, processing / payment marks with no claim, paid while still waiting for approval, completed
  applications with no person, applications stuck in onboarding), with how long each has been clean. Runs every night at 11.30 pm and on
  "Run check now"; every run is kept. Letter facts: notice now also shows the HR-policy notice (probation 4 weeks, then by years of service).
  Database: `20261022_cms_sync_check.sql`.
- **v2026.10.22-14:45** — PRI-009 · **facts for this letter**: in the HR letter workspace, as soon as the person and the letter are chosen,
  a "Facts for this letter" panel shows what matters for that letter type from the CMS records — employment (start, service, position,
  centre, status, reports to); probation (period, end / confirmation due with overdue / due-soon flags, extensions already given);
  latest approved appraisal; pay (current basic, last increment, next review, JD range and MyEden cap) for increment / promotion letters;
  notice (resignation date, contract notice, HR-policy notice (probation 4 weeks, then by years of service), Employment Act s.12 minimum, last day by the notice vs agreed, items to hand over, loan
  balance) for resignation / termination; earlier disciplinary letters; current employer / centre for transfers; leave balances (same
  numbers as Leave Balances) for resignation and unpaid-leave letters. Each fact that matches an editable field of the template has
  **Insert**, plus **Fill all matching**. Drafter and approver both see it; salary, leave and loan facts follow their permissions.
  Database: `20261022_cms_letter_facts.sql`.
- **v2026.10.22-14:20** — Phase 6e · **loans, final settlement and past months inside the CMS**, plus the **Employee Directory**.
  Company Loans and Final Settlement open inside the CMS (read with Payroll "view"; add / change with "Prepare payroll"); Import Past Months opens
  inside the CMS for Super Admin. Every MyPayroll V2.0 page now has its CMS version. Employee Directory (the Phase 4 page): who is who by centre
  and department, position, company, who each person reports to, probation / new-joiner tags, search and filters. New permission section
  "Employee Directory" (view, export to Excel) with three special permissions — "See phone and email in the directory", "See all companies in the
  directory" (without it: your own company only) and "Org chart in the directory". Admin, HR and Director get all of it by default; anyone else only
  when you grant it in Users, Roles & Access. Database: `20261022_cms_phase6e_directory.sql`.
- **v2026.10.22-13:00** — Phase 6d · **payslips & reports inside the CMS**: Payslips & Reports (payslips, monthly summary, payment list, EPF,
  SOCSO & EIS and PCB lists, year to date, EA forms) now open inside the CMS, from finalised months only; print / save as PDF hides the CMS frame,
  lists print landscape, Excel downloads as before. Needs Payroll "view"; saving the default EA signatory needs Payroll settings "edit".
  Privacy fix: payroll pages in the CMS now read identity & bank details through a view that follows "See IC and passport numbers" (IC, passport,
  EPF / SOCSO / tax numbers) and "See bank account details" column by column; home address, spouse and emergency contacts are never read by payroll
  pages. Releasing payslips and EA forms to staff stays in People › Self-service Access. Database: `20261022_cms_phase6d_payslips_reports.sql`.
- **v2026.10.22-10:55** — Phase 6c · **monthly payroll inside the CMS**: Monthly Payroll (the list of months and each month's pay lines — hours,
  overtime, allowances, deductions, EPF / SOCSO / EIS and PCB) now runs inside the CMS on the same tables and the same calculation as MyPayroll.
  Save draft / recalculate / delete draft follow "Prepare payroll", Finalise follows "Finalise payroll", Reopen follows "Reopen a finalised month";
  anyone with Payroll "view" sees the months read-only. Recalculating January–October with the CMS copy matched MyPayroll's saved lines.
  Database: `20261022_cms_phase6c_payroll.sql`.
- **v2026.10.22-10:40** — Phase 6b · **leave & time inside the CMS**: Leave Records, Leave Balances, Leave by Month (audit), AL Calculator, KPI Grades &
  Carry Forward, Year-end Close, Import Leave, Overtime & Hours and Part-time Hours now open inside the CMS (the last three pages were only in MyPayroll
  before). Leave pages follow the Leave permission, hours follow Payroll; imports are Super Admin. Database: `20261022_cms_phase6b_leave_time.sql`.
- **v2026.10.22-10:10** — Phase 6a · **payroll settings inside the CMS**: Departments & Job Titles, Pick-lists, Payment Types, Statutory Tables, Public
  Holidays, HR Policies, Employee IDs and Import from Workbook now open inside the CMS. They run MyPayroll V2.0's own page code (copied into `payroll/js`,
  unchanged except the connection, messages and dialogs) on the same tables, with the CMS sign-in, look (`payroll/payroll.css`, generated from MyPayroll's
  styles) and permissions. Database: `20261022_cms_phase6a_settings.sql`.
- **v2026.10.22-10:00** — **Permissions for the whole CMS.** Users, Roles & Access › Roles & permissions: pick a role and see every section with
  what it covers and only the actions that apply (in the section's own words, e.g. "Add people", "Approve or disapprove"), plus special permissions
  (approve / issue / publish letters, mark each claim form as paid, release payslips, switch on self-service parts, approve profile changes and
  hand-overs, link logins, grant roles, change permissions, and — taking effect in Phase 6 — see IC / bank / salary, change Employee ID, prepare /
  finalise / reopen payroll). Changes are saved together with a reason; "changed from default" is marked and "Reset to default" puts a role back.
  New roles (copied from another), rename, remove. Logins: Admin can now add and remove roles and give a person extra permissions. Compare roles
  grid kept. Account Viewer (new) and Payroll Viewer (renamed) are separate. The 19 pages still in MyPayroll now say "Runs in MyPayroll V2.0 until
  Phase 6". Database: `20261022_cms_permission_catalogue.sql`.
- **v2026.10.22-07:55** — Phase 5e · **Reports & Analytics**: by company and period (last 12 months or a year). Headcount: staff now, joined, left,
  turnover, average service, headcount at each month end by company, staff by department, length of service and gender, staff list. Turnover: leavers by
  month, how long leavers stayed, why they left (with "not recorded"), turnover by year since 2020 with "left within 3 months", leavers list. Payroll cost:
  employer cost (gross + employer EPF / SOCSO / EIS) by month and company, finalised months only in the totals, cost per person paid. Claims: RM claimed by
  form and month, paid, still open, overtime hours, by company and by stage. Every chart has hover values and a table view; CSV export for those with
  Reports export. Database: `20261022_cms_reports.sql`.
- **v2026.10.21-22:35** — **HR Letters centre** (moved in from MEG-EAF V2) and **permissions for HR**. HR drafts a letter on a full-page workspace (fields left,
  large A4 preview right with zoom and full screen, missing fields in red, DRAFT stamp) and sends it for approval; Admin, Super Admin or a Director approves
  (never the drafter) or sends it back with a reason; HR, Admin, Super Admin or a Director issues it, and it is kept in the person's records. Templates: text
  (placeholder picker inserts {{name}} at the cursor; B / I / U) or Word (the .docx keeps its layout and is filled inside). Import a filled Word letter: the
  CMS finds who it was written for and their details (name, ID, salary, company, dates, address) and turns the ticked ones into placeholders; anything else by
  "Make placeholder". New and changed templates need approval unless made by someone who can approve; old templates stay until a retirement is approved;
  on/off per template. Placeholder register (create, edit, protected ones locked). Company letterheads from the four company images. Bell reminders.
  Permissions: "Who can do what" editable by Admin and Super Admin with a reason, locked sections, HR payroll access (MyPayroll follows), MyEden caps set only
  with the new caps permission. MEG-EAF V2 letter pages now point to the CMS. Database: `20261021_cms_permissions_hr.sql`, `20261021_cms_letters_v2.sql`.
- **v2026.10.21-18:30** — Phase 5d · **Documents, HR Letters, off-boarding checklist**: Employee Documents (upload to each person's folder, type, date,
  expiry, open, remove with reason). HR Letters: pick a person and template, the letter is filled from records (name, address, position, dates, salary)
  with a live preview on the company letterhead, missing fields must be filled before issue; drafts, issued register, void, print. Appraisal window can
  issue the extension / confirmation / promotion letter directly. Hand-over now has a checklist (resignation letter, access, documents, exit interview,
  final pay); approval needs all steps done or a note. Database: `20261021_cms_documents_letters.sql`.
- **v2026.10.21-18:05** — Phase 5c · **Training & Certificates** (Performance & Growth): Expiring & expired, Missing required (types marked "required for
  all staff"), To verify (sent by staff), All certificates, Training sessions (attendees; "attended" adds the training's certificate with
  its expiry) and Certificate types (validity months, reminder days, required). Copies (photo or PDF) kept with each certificate; a renewed
  certificate replaces the older one of the same type. **My Certificates** (new self-service part "certs", off by default): own certificates
  and training, required-but-missing warning, send a certificate for HR to verify. Bell reminders. Database: `20261021_cms_training_certs.sql`.
- **v2026.10.21-16:45** — Forms: full-width fields and tick boxes in windows lay out properly (e.g. "Ask for a self-assessment" in Start probation review).
- **v2026.10.21-16:25** — Probation rules: the probation end date is the confirmation date (confirming sets the confirmation date to the probation end,
  not the approval day). Probation length varies (3–6 months or longer): taken from the record, else the offer's probation months in
  MEG-EAF V2, else assumed 3 months and marked "assumed"; HR sets the exact end date when starting the review. An approved extension
  saves the new end date, opens a follow-up probation review due on it, and asks for the **probation extension letter** (bell reminder
  until HR marks it issued, with a link to HR Letters in MEG-EAF V2).
- **v2026.10.21-16:10** — Phase 5b · **KPI & Appraisal** (Performance & Growth). Tabs: In progress, Probation due (on probation in payroll, ending within
  30 days or overdue), Annual {year} (start one or all), Approved. HR starts an appraisal; the reviewer (the person they report to, or HR)
  scores each JD KPI + conduct, attendance and child safety (1–5), gives the KPI grade E/S/A/I/U, strengths, improvements, goals and a
  recommendation. HR / Admin or a director approves (or returns it): probation → confirmed in payroll + Employee Master (probation review
  recorded) or extended; annual → KPI grade written to payroll (annual-leave carry forward), promotion to the next JD level, recommended
  salary shown for Increments & Reviews. **My Appraisal** (staff): self-assessment when asked, results once approved, and appraisals to
  review for managers. Bell reminders. Database: `20261021_cms_appraisals.sql`.
- **v2026.10.21-15:45** — Phase 5a · **Performance & Growth › Career Paths** (PRI-007, PRI-008). *People*: every active employee on their JD level
  (matched by job title + employer, or placed by HR), time in level, salary, place in the band, level cap and next level with its cap.
  *Ladders & salary caps*: each company / department ladder with the JD (market) range and an editable **MyEden cap** per tier
  (effective date, reason, change history). *Not placed*: people whose job title does not match a JD position, with suggestions.
  Each person opens a **timeline** from application, offer, joining, confirmation, salary changes, Employee ID, items and hand-over to
  leaving. The JD Manual window and Increments & Reviews show the MyEden cap / "near cap" / "above cap". Database: `20261021_cms_careers.sql`.
- **v2026.10.21-15:00** — Self-service Access: after a change (Reports to, a switch, a release) the list and the page stay where you were instead of jumping to the top.
- **v2026.10.21-14:35** — Phase 4c · **My Claims** (own SCF / OTCF / MTCF claims and where each is: waiting, approved, paid, not approved; buttons to the
  forms for a new claim) and **My Handbook** (assignment, opened / read / acknowledged, opens the handbook in MEG-EAF V2).
  Phase 4d · **My Leave** built but switched off per person: apply (MC photo for sick / hospitalisation leave), cancel, approvers shown;
  approvals follow Reports to (directors can approve anyone below; directors by the other director or HR; no Reports-to → HR; never
  your own). New **Time & Leave › Leave Requests** for HR with "entered in payroll" tick (payroll leave stays manual for now).
  Phase 4 complete. Database: `20261021_cms_self_claims_handbook.sql`, `20261021_cms_self_leave.sql`.
- **v2026.10.21-14:20** — Phase 4b · Items & Hand-over (PRI-006). **Items & Hand-over** (menu, was "Assets & Equipment") for HR / Admin: issue items
  per person with photo; staff confirm receipt in **My Items** (time stamp, optional phone photo); returned, replaced, renewed, moved to
  another person, lost / damaged, written off and password changed / reset (the password itself is never stored) are each recorded in the
  item's history. A hand-over opens by itself when the leaving date is confirmed (deadline = last day, approver = reports-to), staff see
  what to return, the manager or HR / Admin approves (no self-approval) and clearance becomes "cleared". Item types editable by Admin.
  Bell reminders for staff, managers and HR. SOP: `docs/SOP-items-handover.md`. Database: `20261021_cms_items_handover.sql`.
- **v2026.10.21-14:00** — Phase 4a · Staff self-service. New **My Self-service** menu (My Home, My Profile, My Payslips & EA, My Salary History)
  that shows only the parts HR / Admin switched on for that person; staff with no CMS role can now sign in to it.
  New **People & Employment › Self-service Access**: switch parts on/off per person or in bulk; release payslips per month and EA
  forms per year (finalised months only; same layout and figures as MyPayroll, print / save as PDF); set who each person reports to
  (leave approvers follow this line, directors by the other director or HR); approve or reject profile changes (bank changes need a photo).
  Bell: new payslip for staff, profile changes waiting for HR. Money boxes show 0,000.00 (PRI-005). Database: `20261021_cms_self_service.sql`.
- **v2026.10.21-11:50** — Offers & Onboarding no longer offers Hire for someone who is already an employee: an approved application that
  matches an existing employee (same email or name) shows "Already an employee?" with a **Link** button, and Hire itself refuses
  to create a duplicate. Applications named "DO NOT PROCESS" are hidden. Database: `20261021_cms_existing_employee_match.sql`.
- **v2026.10.21-11:15** — Always the latest release: the app asks the server for the current version on every open and loads its files
  tagged with that version, so a browser or installed app can no longer keep running an older copy. If a new release is
  published while the CMS is open, a "Reload now" bar appears (checked when the app comes back to the front and every 15 minutes).
- **v2026.10.21-10:50** — Automatic Employee ID: a group number is reserved the moment someone reaches onboarding, whichever app created the record,
  and the full ID is built once gender and start date are entered (rebuilt with the same number if those change before the first payslip).
  Offers & Onboarding shows an "Employee ID incomplete" list and a "Did not join…" button (number kept, never reused); the bell
  reminds about incomplete IDs. Short-term co-partners can be excluded. Database: `20261021_cms_auto_employee_id.sql`.
- **v2026.10.21-10:20** — Offers & Onboarding fix: MEG-EAF V2 records only the decision (Approved) and the Office Use details;
  it has no screen for the "offer accepted" stage or the onboarding handoff, so approved applicants never reached this page.
  It now lists every application with decision Approved and no employee record: **Hire…** when the Office Use start date
  and salary are filled (the CMS writes the onboarding handoff itself), otherwise "Office Use incomplete". People already
  created from an application in MEG-EAF V2 (Application Summary) appear under "Not yet in payroll" with **Add to payroll…**.
  The "Prepare handoff" button was removed. Database: `20261021_cms_hire_from_approved.sql`.
- **v2026.10.21-08:45** — **Phase 3 · Recruitment & onboarding** (MEG-EAF V2 data in the CMS):
  **Applications** (stage counts, company / stage tabs, summary and stage history per applicant), **Shortlist & Interviews**
  (the same list, opened on shortlisted and offers), **JD Manual** (119 positions by company and department with purpose,
  responsibilities, KPIs, competencies; salary bands for HR / Admin), **Positions & Vacancies** (staff and open applications
  per position, open-for-applications filter), **Offers & Onboarding** (accepted applicants, people not yet in payroll,
  offer-letter tracker with stamp-duty due dates), **Hire**: one step creates the person record and the payroll record
  (company, centre, title, hours, starting salary, Employee ID), **one Employee ID numbering** for MEG-EAF V2, the CMS and
  MyPayroll, **Employee Handbook** progress (assigned / opened / read / acknowledged, % read, past due) plus a Handbook column
  on View People, **Employment Act & Calculators** opening MEG-EAF V2. Bell reminders: applicants to hire, staff not in payroll,
  stamp duty due. Editing applications, offer letters, JDs and handbook assignments stays in MEG-EAF V2.
  Database: `20261021_cms_recruitment.sql`.
- **v2026.10.20-22:45** — Sign-in page shows **Install MyEden CMS app** whenever the browser can install the CMS (the
  CMS keeps the browser's own install pop-up hidden, so this button is the visible offer); the same button stays in the
  name menu after sign-in.
- **v2026.10.20-22:35** — App install, final fix: two test pages proved Chrome would install a new app from this site,
  and one with the CMS's exact install settings, so Chrome was holding a stale "installed" record for the CMS's own
  folder. The CMS page now lives in `app/` with its own settings file (`app/manifest.webmanifest`) and service worker
  (`app/sw.js`); the root `index.html` forwards there (keeping `#…` links such as password resets). Files (js, css,
  assets) stay at the root; `window.CMS_ROOT = '../'` on the app page tells the code where they are. Test pages removed.
- **v2026.10.20-22:00** — App install, second fix: Chrome on Android still said "already installed" although no MyEden
  CMS app exists on the devices (chrome://webapks lists only MEG-FORMS, MEG-EAF, MEG-EAF V2). The app now has a fresh
  identity Chrome has never seen: settings file `cms-app.webmanifest` (was `manifest.webmanifest`), id
  `/MyEden-Group-CMS-V1.0/?app=cms`, start page `./?source=pwa`.
- **v2026.10.20-21:30** — App install fix: the manifest `id` was `"./"`, which browsers read from the site root
  (`https://myedengp01.github.io/`), not the CMS folder, so phones treated the CMS as an app that was already installed.
  It is now `/MyEden-Group-CMS-V1.0/`, and the start page is `./index.html`.
- **v2026.10.20-12:15** — Installable app: new MyEden CMS icon (orbit in frosted glass, option K) for the browser tab,
  phone home screen and desktop; `manifest.webmanifest` (now `cms-app.webmanifest`) and a small service worker (`sw.js`, caches nothing, shows an
  "offline" page without a connection). Chrome / Edge / Android show "Install"; the user menu has **Install app** when
  the browser offers it; on iPhone / iPad use Share › Add to Home Screen.
- **v2026.10.20-11:50** — Former Staff: click a person to see every employment period (dates, position, centre, company,
  last salary for those allowed to see pay, reason, rehire eligibility, short notice) and, for HR / Admin, record the
  reason for leaving and rehire eligibility. **Rehire…** starts a new employment period in payroll with the same Employee
  ID (new join date, paying company, centre, title, status); the person moves back to Active. "Not eligible" needs an
  Admin and an override reason. New "Reason missing" filter with a count. The 3 dismissed leavers got the reason
  "Dismissed". Database: `20261020_cms_leaving_rehire.sql`.
- **v2026.10.20-10:50** — View People: under the last working day, the leaving reason, rehire eligibility and a "rehired"
  tag from MyPayroll (PRI-002). KPI & Appraisal note points to MyPayroll's KPI grades & carry forward (PRI-004).
  MyPayroll v2026.10.20-10:50 adds leaving reasons and rehire, recurring items and item types from the payroll line, and
  KPI carry forward (PRI-002 / 003 / 004). Database: `20261020_cms_people_leaving.sql`.
- **v2026.10.19-16:10** — **Increments & Reviews** (PRI-001, Payroll menu): last increment and next salary review per
  person, review intervals 6 / 9 / 12 months (Admin can edit and add; each can be the default for confirmation statuses),
  per-person interval or review date, Record increment from a payroll month, bell reminder of reviews due, and a Next
  review column on View People. Database: `20261019_cms_increments.sql`. Ideas register: PRI-002 (rehire) recorded.
- **v2026.10.19-15:50** — Frozen headers: long lists (View People, Former Staff, Paying Companies, every claims list and
  Approvals, Users, Roles & Access, Audit Log) fill the screen and scroll inside their own box; the search, filters, tabs and
  column headings stay in view, the page title scrolls away first. Employee ID and Name (claims: select box and serial no.;
  permissions: module) stay put when scrolling sideways; on phones only the first column. Tables in windows keep their
  headings too. Ideas register started in `docs/IDEAS.md` (PRI-001 salary increment reminder).
- **v2026.10.19-15:25** — The main paying company now changes **from a month**: after a transfer, the old company keeps its record and its
  "Main" mark for the months it paid; Set main asks for the first month; ending the main company of a joint payment makes the
  other company main from the next month. View People adds **Confirmation** (with confirmed date), **Notice until** (with the
  letter date and weeks), **Last working day**, and a **Serving notice** tab. Notice until is stored in payroll: the 22 dates
  from the EPPD workbook were brought in (one is an agreed 8-week notice), new letters are counted from the notice-period policy,
  and HR can change the date in MyPayroll's Record resignation. **Employee names are in upper case** everywhere in the CMS and are
  saved that way (11 Employee Master names were changed). Database: `db/payroll/011_main_company_by_period.sql` (run by hand) and
  `20261019_cms_main_by_period_notice_names.sql`.
- **v2026.10.19-13:05** — **Paying Companies** is live (Payroll › Paying Companies, and from each person in View People).
  Admin and HR can transfer a person to another company from a payroll month, add a second company (joint payment, with its own
  salary and statutory switches), end one of two companies, set the main company, and correct a mistake (reason required;
  Admin only when a finalised month used the record). Finalised months are never rewritten. Every change is in the Audit Log.
  View People shows the previous Employee ID under the new one, searchable by either, and "Paid by" now comes from payroll
  (★ = main company in a joint payment). New permission module `payroll.paying`: Admin full, HR view/add/edit,
  Payroll, Finance, Account / Payroll Viewer and CEO / Director view only. Database: `20261019_cms_paying_companies.sql`.
- **v2026.10.17-19:25** — Bulk buttons name the count ("Disapprove 1 claim", "Approve 3 claims"); a failed claimant email now says why, and that the decision stands. Resend test-mode issue recorded under Known issues.
- **v2026.10.17-19:00** — **Disapprove selected** on the Approvals and form pages (OTCF and MTCF): one required reason for
  every ticked claim, each claimant notified, OTCF disapproval PDF as in the app. Your own claims can't be ticked and are
  marked "Yours". New role **CEO / Director** (given to the two Director logins): claims submitted by a Super Admin, Admin
  or Director show "Waiting for CEO / Director" and only a Director (never the claimant) can decide them in the CMS. The
  form apps are unchanged. Database: `20261017_cms_director_approval.sql`.
- **v2026.10.17-18:20** — Approve and disapprove OTCF and MTCF claims, and mark TEC claims as done, in the CMS (one at a
  time or several at once). The signed PDF is made by the form app's own PDF code, saved where the app saves it, and the
  claimant gets the same email the app sends. Needs a CMS role with Approve and the matching MEG-FORMS approver permission;
  nobody can decide their own claim. PRFAF is still approved in its app (it also sets up the fund release).
  New role **Account / Payroll Viewer**: sees claims, people, payroll and reports, changes nothing; suggested for
  MEG-EAF V2 view-only users. Database: `20261017_cms_phase1_decisions.sql`, `20261017_cms_payroll_viewer_role.sql`.
- **v2026.10.17-17:50** — Phase 1: claims from SCF, OTCF, MTCF, TEC (V1 and V2) and PRFAF in the CMS. Approvals is one queue
  (waiting for approval, ready to process, waiting for payment); each form has its own page; every claim opens with its
  details, the Payroll / Account checklist, mark as paid / undo, and notes. Claimants are matched to the Employee Master.
  Staff still submit, and approvers still approve, in the form apps (they create the signed PDF and send notifications).
  Database: `20261017_cms_phase1_claims.sql`, `20261017_cms_phase1_dashboard.sql`.
- **v2026.10.17-17:30** — Menu now lists every MyPayroll V2.0 page (Phase 2 placeholders with an "Open in MyPayroll V2.0" button
  to the matching page), Former Staff page, Company Loans and Final Settlement split, OTCF moved to Forms & Claims,
  new Payroll Settings group with its own permission row (`db/migrations/20261017_cms_payroll_settings_module.sql`).
- **v2026.10.17-16:45** — New sign-in screens (design D): navy brand panel with the spinning logo, form with a logo-colour
  ring on hover and focus, show/hide password button; same look for forgot-password, new-password and no-access.
  Logo keeps spinning when Windows animation effects are off.
- **v2026.10.17-13:30** — Phase 0 foundation: sign-in, roles & access with suggestions, login ↔ person links,
  paying company per person, live dashboard, people, organisation, approvals overview, audit log, export all data.
- **v2026.10.17-13:00** — Theme preview: navy theme, spinning 3D logo, interactive sidebar, Ctrl+K page search,
  dashboard layout, module map with phases, access model, organisation page. No live data.
