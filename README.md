# MyEden Group CMS V1.0

MyEden Group's Central Management System: one login and one database for every person, from application to offboarding.
Static site (GitHub Pages) + Supabase. No build step.

**Current version:** v2026.10.17-17:50 · **Phase 1 · MEG-FORMS** · **Phase 0 · Foundation** (live: sign-in, roles & access, people, organisation, audit log, export)

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
- **v2026.10.20-21:30** — App install fix: the manifest `id` was `"./"`, which browsers read from the site root
  (`https://myedengp01.github.io/`), not the CMS folder, so phones treated the CMS as an app that was already installed.
  It is now `/MyEden-Group-CMS-V1.0/`, and the start page is `./index.html`.
- **v2026.10.20-12:15** — Installable app: new MyEden CMS icon (orbit in frosted glass, option K) for the browser tab,
  phone home screen and desktop; `manifest.webmanifest` and a small service worker (`sw.js`, caches nothing, shows an
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
