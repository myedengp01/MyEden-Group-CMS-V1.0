# MyEden Group CMS V1.0 · Ideas register (PRI)

"PRI" = put record idea. Each idea is recorded here when it comes up. When an idea becomes the next task, it is built
into that release and this entry is updated with the version and how it was implemented.

| No. | Recorded | Idea | Status |
|---|---|---|---|
| PRI-001 | 2026-10-19 | Salary increment reminder: last increment amount and date, next review by interval (6, 9, 12 months; editable, changeable, addable) | **Built in v2026.10.19-16:10** |
| PRI-002 | 2026-10-19 | Rehire option for former staff, with a reminder of why they left; leaving reason mandatory for every leaver; for past employees, HR/Admin can add the reason | Built in MyPayroll v2026.10.20-10:50 + CMS v2026.10.20-10:50 |
| PRI-003 | 2026-10-19 | Payroll items from the payroll line: allowances for a fixed period that expire (e.g. 1 Jan–30 Jun 2026); Add / Edit / Delete items; every item type carries its EPF / SOCSO / EIS / PCB treatment with Malaysian-law presets and remarks | Built in MyPayroll v2026.10.20-10:50 |
| PRI-004 | 2026-10-20 | KPI-based annual leave carry forward: KPI record per employee (E, S, A, I, U), KPI cut-off month (default October, editable), eligible carry-forward shown on leave balances (editable), automatic year-end carry forward of the 31 Dec balance up to the eligible days; negative balance treated as unpaid leave | Built in MyPayroll v2026.10.20-10:50 |
| PRI-005 | 2026-10-21 | Money shown with thousands separator and 2 decimals everywhere in the CMS (0,000.00) | **Built in v2026.10.21-14:00** |
| PRI-006 | 2026-10-21 | Employee items register (hand-on / hand-over): every company item issued is recorded and confirmed by the employee in their own app (time stamp, optional photo); returns, renewals, replacements and credential changes during employment; hand-over list activated at offboarding with deadline, notes and approval | **Built in v2026.10.21-14:20** (staff confirmation in My Items) |
| PRI-007 | 2026-10-21 | Staff timeline (recruitment → onboarding → changes → offboarding) and Career Paths: per role, the career path with current position and the next levels with salary caps from the JD; sub-menu "Career Paths" listing every employee | **Built in v2026.10.21-15:45** |
| PRI-008 | 2026-10-21 | MyEden Group salary cap per JD level, editable, shown beside the JD (market-based) salary range | **Built in v2026.10.21-15:45** |
| PRI-009 | 2026-10-22 | HR letters: when a letter is chosen for a person, show that person's facts for that letter type beside the draft (e.g. confirmation / increment: start date, probation end / confirmation due, extensions; resignation: notice period, last day, leave balance) | **Built in v2026.10.22-14:45** |
| PRI-010 | 2026-10-22 | Switch-over rule: forms, MyPayroll and the CMS run side by side on the same data until confirmed stable; only then are staff redirected to the CMS for all transactions; MEG-EAF V2 applicant and HR system move into the CMS in a later phase | Step B built in v2026.10.22-15:05 (banner + Sync Check); switch-over waits for CLC |
| PRI-011 | 2026-10-22 | One page per employee with everything about them: personal details, passport-size photo from the MEG-EAF application, IC (front / back) photos, passport, and all other details | **Built in v2026.10.25-23:20** |
| PRI-012 | 2026-10-29 | Attendance app in the CMS: staff clock in / out on the phone with geo location (centre geofence), attendance records feed payroll (overtime, part-time hours, unpaid absence, allowances) | Recorded — waiting for CLC's 7 decisions |

## PRI-001 · Salary increment reminder — built in v2026.10.19-16:10
- **Payroll › Increments & Reviews** lists active staff: current salary, last increment (+/− amount and month), review
  interval and next review date, with views Needs attention / Overdue / Due this month / Next 3 months / All.
- **Last increment** = the last salary change in payroll's salary history on the person's main company (a transfer's
  copied history is counted once).
- **Next review** = the later of last increment, confirmation date and join date + the person's interval, or a date HR
  set by hand (cleared when the next increment is recorded).
- **Intervals** (6, 9, 12 months to start) are a list Admin can edit and add to; each interval can be the default for
  confirmation statuses (6 months: under probation; 12 months: confirmed, contract, part time, internship). HR can set
  a different interval or a review date per person.
- **Record increment** (HR/Admin): new salary from a payroll month, on the main company; finalised months are refused;
  logged in the Audit Log.
- **Reminders:** the bell / My tasks show "N salary reviews due" for Admin and HR; View People has a Next review column.
- Permissions (`payroll.increments`): Admin all; HR view, record, change review; Payroll, Finance, Account / Payroll
  Viewer, CEO / Director view.

## PRI-002 · Rehire and leaving reasons — built in v2026.10.20-10:50
- **How it was built:** MyPayroll: reason, details, rehire eligibility and note on every employment period (required
  whenever a last working day is set — in Record resignation and Edit employment, and enforced by the database);
  15-reason pick-list (editable in Settings › Pick-lists); Former staff shows Leaving reason and Rehire, with "Add reason"
  (HR / Admin) and a "no leaving reason" count (151 to fill in); the rehire window lists every earlier period with the
  last salary and a "left before notice ended" flag, keeps the Employee ID, and needs an admin override reason when
  marked not eligible (kept in the period notes and the audit log). CMS: View People shows the reason, rehire
  eligibility and a "rehired" tag under the last working day (`20261020_cms_people_leaving.sql`).
- **CMS (v2026.10.20-11:50):** Former Staff › click a person: periods, reason for leaving and rehire eligibility (HR /
  Admin), **Rehire…** (same Employee ID, back to Active; Admin override for not eligible), "Reason missing" filter;
  the 3 dismissed leavers pre-filled with "Dismissed".
- Not built yet (ideas above): returning-applicant flag in EAF, exit checklist, turnover report, service carry-over.

### Original plan
- **Leaving reason** (mandatory when a leaver is recorded): pick from a list Admin can edit — Resigned: further studies;
  Resigned: better offer / career change; Resigned: relocation; Resigned: personal / family; Health; Contract ended;
  Not confirmed after probation; Terminated: performance; Terminated: misconduct; Dismissed; Retirement; Mutual
  agreement; Absconded / did not return; Passed away; Other (details required). Plus a short note.
- **Past employees:** the 150 former staff get the reason added by HR/Admin only, with a "reason missing" filter and
  count until every one is filled in.
- **Rehire eligibility** set at exit: Eligible / Eligible with conditions / Not eligible, with a note (who decided, why).
- **Rehire** (HR/Admin, on a former person): starts a new employment on the same person record with a new join date and
  **keeps the existing Employee ID** (decided 2026-10-19);
  the window first shows the reminder — previous stints, positions and centres, last salary, leaving reason, eligibility,
  notice served or short, settlement / loans / assets outstanding. Not eligible needs an Admin and a reason to override.
- **More ideas:** flag returning applicants in MEG-EAF V2 when the email / phone / IC matches former staff; exit
  checklist (assets returned, clearance, final settlement, exit interview notes); turnover report by leaving reason and
  centre; option to carry service years for leave when rehired within a set period.

## PRI-003 · Fixed-period items and item types from the payroll line — built in v2026.10.20-10:50
- **How it was built:** the line window's "Add item" has This month only / Recurring (every month) with an "Ends on"
  date; recurring items are saved on the person's paying company from that month and the line recalculates at once;
  a "Recurring items on this company" list gives Edit, End from… (last month paid) and Delete. Admins get "New item
  type" there and in Settings › Payment types: a Statutory treatment preset sets the four ticks and shows the remark;
  a tick that differs needs a reason (kept in the notes); system items show "system" (rename only); a type used in a
  finalised payslip or a recurring item is offered "Switch off" instead of delete. Existing item types were given the
  preset matching their current ticks; nothing was changed.

### Original plan
- **Already in MyPayroll:** recurring allowances per person with From / Until dates (employee page › Pay), and
  Settings › Payment types with EPF / SOCSO / EIS / PCB ticks and notes per item type.
- **In the payroll line window:** "Add item" gets a choice: *this month only* (as now) or *recurring*, with a
  **"Ends on" checkbox** and date (e.g. 1 Jan–30 Jun 2026); a recurring item is saved as the person's allowance, so
  it appears every month until it expires and stops by itself. The line lists the person's recurring items with
  **Edit** (amount, dates, from a month) and **Delete / End from a month**; finalised months are never changed.
- **Item types:** "New item type" and "Edit item type" open from the same window (Admin): name, earning or
  deduction, category, and ticks for EPF / SOCSO / EIS / PCB. Choosing a category pre-ticks the usual treatment
  with a remark (e.g. overtime: no EPF; travel allowance: no EPF/SOCSO/EIS, still taxable; gift: not wages; bonus:
  EPF only; reimbursements: not wages, not taxed). The ticks stay editable, and a changed preset asks for a note.
  System items (basic salary, overtime, unpaid leave, claims) can be renamed but not deleted; an item type already
  used in a finalised month can be switched off but not deleted.

## PRI-004 · KPI-based annual leave carry forward — built in v2026.10.20-10:50
- **How it was built (MyPayroll, Time & leave):** new **KPI grades & carry forward** page (grade per person per year,
  note, who / when, override days + reason, filters for no grade / overrides); HR policies gets the KPI cut-off month
  (October), the confirmed-only switch and the buy-back approval switch; Leave balances adds KPI, Eligible and Will
  carry columns; until last year is closed its carry forward is shown as provisional (*), only for people with leave
  history last year and no carried / opening days already posted (so imported opening balances are never doubled);
  Year-end close applies the rules, asks for approver and date for each buy-back, forfeits the rest, and turns a negative
  balance into unpaid leave dated 31 Dec (1 Jan if December is already finalised) with an AL correction back to 0;
  December's payroll warns until the leave year is closed. The CMS KPI & Appraisal slot points to MyPayroll for now.

### Original plan
- **Already in MyPayroll:** KPI grade per person per year (table `eppd_kpi_ratings`, empty so far) and Time & leave ›
  Year-end close, which uses Settings › HR policies › carry forward: E 6, S 3, A 1, I 0, U 0 days, confirmed staff only;
  the excess above the cap is bought back (E, S, A at 50 / 25 / 10 %) or forfeited. The close is run by hand.
- **New:** a KPI record page (CMS People › KPI & Appraisal, phase 5 slot) holding the grade per person per year, with
  who graded and when; a **KPI cut-off month** setting (default October, editable) — the grade in force at the cut-off
  decides the carry-forward eligibility for that year.
- **Leave balances** gets columns KPI grade (at cut-off), Eligible carry forward (from the grade) and an Override
  (editable, reason required).
- **Automatic year-end:** on 1 January the 31 Dec AL balance carries forward automatically: none → 0; less than the
  eligible days → the whole balance; more → the eligible days (excess bought back or forfeited as today);
  **negative balance → unpaid leave** in the payroll (month to be decided).
- **Decided 2026-10-20:**
  1. Excess above the eligible days: buy-back only with management approval — for eligible employees only, an option
     per person: buy back or not, and at what rate (50 / 25 / 10 % or another rate); approver and date recorded.
     Not bought back → forfeited.
  2. Negative 31 Dec balance → unpaid leave in **December's payroll** (December is finalised in January).
  3. Caps stay E 6, S 3, A 1, I 0, U 0; "confirmed staff only" stays on as a management setting that can be switched.
  4. No KPI grade at the cut-off → 0 days carried forward.

## PRI-005 · Money format 0,000.00 — built in v2026.10.21-14:00
- **How it was built:** amounts already shown with `money()` (RM 0,000.00) everywhere; the salary boxes (Hire, Add paying company, Record increment) now show 2,300.00 when you leave the box and the plain number while typing; JD salary bands show RM 1,800.00 – RM 2,200.00; audit-log amounts and all self-service pages (payslips, EA, salary history) use 2 decimals.
- Every salary and amount in the CMS shows a thousands separator and exactly 2 decimals (e.g. 2,300.00), in tables,
  windows and exports; inputs accept 2300 / 2300.5 and are shown back as 2,300.50 when the field is left.
- Plan: one `money2()` helper used everywhere (no "RM" duplication where the column header already says RM);
  amount inputs get the same formatting on blur. Exports keep plain numbers so Excel can calculate.

## PRI-006 · Employee items register (hand-on / hand-over) — built in v2026.10.21-14:20
- **How it was built:** Items & Hand-over page (HR / Admin) and My Items (staff, switched on per person). Item types table (Admin);
  each item has its own history of events (issued, confirmed, returned, replaced, renewed, moved, lost, damaged, written off,
  password changed, notes, reports by the person), photos compressed on the phone. Hand-over opens from a trigger on the payroll
  leaving date or the Employee Master last working day; approver defaults to Reports-to; approval stores name + time and sets
  clearance "cleared". Passwords are refused in text fields. SOP in docs/SOP-items-handover.md.
**Items covered:** company email / system accounts, keys and access cards, thumb drives and laptops / phones, uniforms,
handbook and printed manuals, name tags, anything else HR/Admin adds (item types are a list Admin can extend).

**Proposed design**
1. *Item catalogue* (Admin): item type, asset tag / serial (optional), whether it must be returned, replacement cost,
   who is the custodian (HR, Admin, IT, centre head).
2. *Issue* (HR/Admin in the CMS, Assets & Equipment): choose person + item(s), quantity, condition, issue photo, note.
   The employee gets a notification in the employee app (Phase 4 Self-service) → "Confirm received": tick, optional photo
   from the phone camera / gallery (same logic as the claim forms), and the confirmation is locked with a time stamp.
   Not confirmed in N days → reminder, then flagged to HR.
3. *During employment* every change is an event on the same item, never an overwrite: returned, replaced (old returned +
   new issued), renewed, lost / damaged (with note, optional deduction reference), transferred to another person.
   Each event is confirmed by both sides the same way.
4. *Accounts and passwords:* the CMS records that a credential exists, who holds it, and when it was last changed or
   reset (and by whom). **The password itself is never stored in the CMS**: it is kept in a password manager / the
   email admin console, and on handover IT resets it. This keeps the register safe even if a report is printed or shared.
5. *Offboarding:* when the notice period is confirmed (leaving date set), a hand-over list is created automatically from
   all items still held, with a deadline (default = last working day, editable), a responsible receiver per item, notes,
   and photos at return. The receiver confirms each return; HR/Admin approves the completed list (approver + time stamp).
   Open items appear on the bell and block the "cleared" status of the final payroll (with an override + reason).
6. *Records:* full history per person and per item, printable acknowledgement (issue and hand-over) as PDF, audit log.
- Depends on Phase 4 (employee app) for the employee's own confirmation; until then HR can record a signed paper
  acknowledgement with a photo.

## PRI-007 · Staff timeline and Career Paths — built in v2026.10.21-15:45
- **How it was built:** Performance & Growth › Career Paths. Each person is placed on a JD position (auto-matched by title +
  employer; HR places the rest from the "Not placed" tab with suggestions, with a "since" date). Ladders = positions of the same
  company and department by level (L1–L5). Place in band uses the MyEden cap where set, otherwise the JD range. The timeline
  merges MEG-EAF V2 application / offer, payroll joining / confirmation / leaving, salary changes, CMS events and items.
- **Timeline** on each person: application and interview (MEG-EAF V2), offer / LOEC, hire and Employee ID, payroll start,
  confirmation, increments, transfers / promotions, items issued, notice, hand-over, last day, rehire — one dated list.
- **Career Paths** (sub-menu): per JD role family, the ladder of levels (e.g. Associate → Executive → Senior → Lead → Manager);
  each employee shown on their current level with time in level, current salary vs the level cap, and the next level(s)
  with their salary cap. List of all employees with filters (company, department, due for review, at / above cap).

## PRI-008 · MyEden Group salary cap beside the JD range — built in v2026.10.21-15:45
- **How it was built:** a MyEden min / max beside every JD band (tier), edited in Career Paths › Ladders & salary caps with an
  effective date and reason; every change is kept (who, when). The JD Manual window shows it beside the market range, and
  Increments & Reviews flags salaries near (≥ 95 %) or above the level cap. The JD Manual itself (MEG-EAF V2) is not changed.
- The JD Manual salary bands stay as the market reference. Beside each level, a **MyEden cap** (min / max) that
  HR/Admin can edit, with effective date and change history (who, when, why). Career Paths and increment reviews
  use the MyEden cap; the market range stays visible for comparison.

## PRI-009 · Person facts beside the letter draft — built in v2026.10.22-14:45
- **How it was built:** `cms_letter_facts(person, letter type)` gathers the facts on the server (employment, probation from the probation
  rules and issued Probation Extension letters, the latest approved appraisal, pay from Increments & Reviews and the JD / MyEden cap
  of the person's Career Paths position, notice from the leaving record with the Employment Act s.12 minimum, open hand-over items,
  company loan balance, earlier disciplinary letters, unpaid leave). Leave balances are worked out in the page with the payroll leave
  engine, so they match Leave Balances. The panel sits above the letter fields; facts are flagged (overdue, due soon, already confirmed,
  extension no. 2, salary near / above the cap, last day earlier than the notice). **Insert** / **Fill all matching** only for fields of
  the chosen template that are editable (fields locked to the records are already filled). Salary facts need "See salaries",
  leave needs Leave or Payroll view, loans need Payroll view.
- When HR picks a person and a letter type, the letter workspace shows a "Facts for this letter" panel from the CMS records,
  so HR can assess before issuing. Only the facts that matter for that letter type:
  - *Confirmation (LOC), Confirmation & Increment (LOC_LOI), Probation Extension (PEL):* start date, probation period,
    confirmation due date, extensions already given (with dates), appraisal result, current salary, last increment.
  - *Increment (LOI), Promotion (LOP):* current salary and position, last increment (amount, date), next review due,
    MyEden cap / JD range for the level, appraisal result.
  - *Resignation acceptance (RL):* resignation letter date, notice period (contract and Employment Act), last working day,
    annual leave balance for the offset version, items still to hand over, company loan balance.
  - *Warning, Show Cause, Explanation, Domestic Inquiry, Suspension, Termination, PIP:* earlier letters of these types
    with dates, open hand-over items, notice / termination terms.
  - *Transfer (TRL):* current company / centre / paying company and position. *Unpaid leave (UAL):* leave balances and unpaid days this year.
- Facts that match a placeholder can be filled in with one click; HR can still change them before submitting.
- Facts the user may not see (salary, IC) follow the existing permissions.

## PRI-010 · Run side by side until stable, then redirect — step B built in v2026.10.22-15:05
- **Agreed (2026-10-22):** CLC runs payroll in the CMS from November 2026; "stable" applies to the forms and MEG-EAF V2; order: payroll,
  then the forms, then EAF; MyPayroll stays open with a banner (not read-only) until CLC confirms.
- **How step B was built:** MyPayroll V2.0 shows "Payroll now runs in the MyEden Group CMS" on every page with a link to the same CMS page.
  Admin › Sync Check (Super Admin) checks every form and MEG-EAF V2 nightly at 11.30 pm and on demand, keeps every run, and shows how
  long each source has been clean.
- No one-way copy: the forms (SCF, OTCF, MTCF, TEC, PRFAF), MyPayroll V2.0, MEG-EAF V2 and the CMS already read and write the
  same database, so a change in one shows in the others straight away.
- Side-by-side period: both stay open; parity checks (payroll recalculation vs saved months, claim counts, leave balances)
  are run and reported each release; nothing is switched off until CLC confirms it is stable.
- Then (Phase 6f for payroll, later for forms): old apps become read-only with a link to the CMS page, and staff are
  redirected to the CMS for all transactions.
- MEG-EAF V2 applicant and HR system pages move into the CMS in a later phase.

## PRI-011 · Employee profile — everything about a person on one page — built in v2026.10.25-23:20
- **How it was built:** route `#/person?id=…`, opened from a name in View People or the Employee Directory. One server call
  (`cms_person_profile`) merges the Employee Master, the payroll record and the linked MEG-EAF V2 application, section by section
  according to the viewer's permissions; edits are stored in `cms_person_profile` (CMS value first, then payroll, then application);
  images uploaded in the CMS go to the private bucket `cms-profile-images`, application images are fetched only when shown.
  Agreed 2026-10-22: seeing / editing personal details and uploading images are HR and above by default, assignable to others.
- Today the CMS shows a person in pieces (View People row, payroll record in Payroll, documents, letters, timeline).
- Wanted: one profile page per person with tabs or sections — photo and summary; personal (name, Chinese name, NRIC / passport,
  date of birth, gender, race, religion, marital status, nationality, address, phone, email); family and emergency contact;
  education, work history, languages, skills (from MEG-EAF V2); employment (company, paying company, centre, position, status,
  dates, reports to, probation / confirmation, notice); pay (salary history, allowances, bank, EPF / SOCSO / tax numbers);
  leave balances; documents (uploads, IC front / back and photo from the application, signed letters); HR letters; appraisals;
  items; timeline.
- Source of the photos: MEG-EAF V2 keeps the passport-size photo and IC front / back inside the application (photoData,
  idFrontData, idBackData); staff imported from the workbook have no application, so HR uploads them.
- Sensitive parts follow permissions (IC / passport and IC photos: "See IC"; bank: "See bank"; salary: "See salaries";
  personal / family details: a new permission).

## PRI-012 · Attendance app with geo location, feeding payroll — recorded 2026-10-29
- **Idea:** staff clock in / out from the CMS on their phone (installed to the home screen); the phone's location is checked against
  their centre's area (map point + allowed distance, e.g. 100 m) for E1, E3, E3+, E6, E7, E10, E11 and HQ. Server time is the
  official time. Attendance records are used for payroll and other calculations.
- **Staff:** Clock in / Clock out button, own history (today, month to date, late / overtime), optional reminders ("not clocked out").
- **HR / managers:** live board per centre (in, late, absent, on leave); monthly timesheet per person reviewed by the reporting line
  and locked by HR; corrections (forgotten clock-out etc.) with a reason, original never overwritten; flags (outside the area,
  poor GPS accuracy, new device, offline clock-in).
- **Payroll link (locked timesheets only):** overtime under EA 1955 (1.5× normal day, 2× rest day, 3× public holiday, 104-hour
  monthly cap; could pre-fill or replace OTCF claims); part-timers paid on hours × hourly rate; unpaid absence cross-checked with
  leave; attendance allowance. Preview before anything is posted to the pay run.
- **Limits noted:**
  - GPS can be faked on Android and a web app cannot reliably detect it. Options: rotating QR code on a tablet at each centre
    (strongest), selfie at clock-in kept for a short period, device binding (new phone needs HR approval).
  - Location is read only at clock-in / out; no background tracking or automatic clock-in. Offline clock-ins are queued and
    flagged "offline".
  - Supabase Free plan: clock records are small, but selfies would fill the 1 GB storage in about 6 months for ~60 staff;
    either no selfies, delete after 30–60 days, or the Pro plan.
  - PDPA 2010: written notice and consent for location (and photo), stated retention period; add to self-service activation
    and the handbook. Lateness pay deductions need care under EA 1955 (deductions are limited); prefer warnings or attendance
    allowance. No face recognition (biometric data).
- **Further possibilities:** rosters / shifts per centre; switching on CMS leave (attendance needs it to tell absent from on leave);
  staff-to-child ratio per centre if children's attendance is recorded; punctuality into KPI; native app wrapper later if fake
  GPS becomes a real problem.
- **Suggested phases:** A1 clock in / out, centre areas, HR live board, corrections, privacy notice (run alongside the current
  method, per PRI-010); A2 working hours / rosters, lateness, overtime, Johor public holidays, monthly approval and lock;
  A3 payroll link with preview; A4 QR / selfie checks, reminders, reports, KPI link.
- **Decisions needed from CLC before building:**
  1. Who clocks in (all staff, or exclude directors / HQ; part-timers and interns?).
  2. Outside the area: block, or allow with a reason and flag.
  3. Anti-cheating: QR at the centre, selfie, device binding, or none to start.
  4. Working hours: fixed per centre, or rosters / shifts.
  5. Payroll use: overtime, part-time hours, unpaid absence, attendance allowance, lateness.
  6. Current attendance method (punch card, thumbprint machine, WhatsApp, book), for running side by side.
  7. Switch on CMS leave as part of this.
