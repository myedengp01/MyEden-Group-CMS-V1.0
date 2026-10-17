# MyEden Group CMS V1.0

MyEden Group's Central Management System: one login and one database for every person, from application to offboarding.
Static site (GitHub Pages) + Supabase. No build step.

**Current version:** v2026.10.17-13:30 · **Phase 0 · Foundation** (live: sign-in, roles & access, people, organisation, audit log, export)

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
js/app.js           sign-in screens, sidebar, top bar, Ctrl+K search, router, pages
db/migrations/      SQL applied to the database, in order
assets/logos/       MyEden mark (3D logo) and company logos
```

## Change log
- **v2026.10.17-13:30** — Phase 0 foundation: sign-in, roles & access with suggestions, login ↔ person links,
  paying company per person, live dashboard, people, organisation, approvals overview, audit log, export all data.
- **v2026.10.17-13:00** — Theme preview: navy theme, spinning 3D logo, interactive sidebar, Ctrl+K page search,
  dashboard layout, module map with phases, access model, organisation page. No live data.
