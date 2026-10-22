# MyEden Group CMS V1.0

MyEden Group's Central Management System: one login and one database for every person, from application to offboarding.
Static site (GitHub Pages) + Supabase. No build step.

**Current version:** v2026.10.22-10:10 · **Phase 6 · Payroll in the CMS** (Phases 0–4 live)

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
