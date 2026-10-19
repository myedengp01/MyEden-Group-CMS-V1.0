# MyEden Group CMS V1.0 · Ideas register (PRI)

"PRI" = put record idea. Each idea is recorded here when it comes up. When an idea becomes the next task, it is built
into that release and this entry is updated with the version and how it was implemented.

| No. | Recorded | Idea | Status |
|---|---|---|---|
| PRI-001 | 2026-10-19 | Salary increment reminder: last increment amount and date, next review by interval (6, 9, 12 months; editable, changeable, addable) | **Built in v2026.10.19-16:10** |
| PRI-002 | 2026-10-19 | Rehire option for former staff, with a reminder of why they left; leaving reason mandatory for every leaver; for past employees, HR/Admin can add the reason | Recorded · plan elaborated, waiting for go |
| PRI-003 | 2026-10-19 | Payroll items from the payroll line: allowances for a fixed period that expire (e.g. 1 Jan–30 Jun 2026); Add / Edit / Delete items; every item type carries its EPF / SOCSO / EIS / PCB treatment with Malaysian-law presets and remarks | Recorded · plan elaborated |

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

## PRI-002 · Rehire and leaving reasons (draft plan)
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

## PRI-003 · Fixed-period items and item types from the payroll line (draft plan)
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
