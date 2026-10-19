# MyEden Group CMS V1.0 · Ideas register (PRI)

"PRI" = put record idea. Each idea is recorded here when it comes up. When an idea becomes the next task, it is built
into that release and this entry is updated with the version and how it was implemented.

| No. | Recorded | Idea | Status |
|---|---|---|---|
| PRI-001 | 2026-10-19 | **Salary increment reminder.** Show each employee's last increment (amount and date) and remind HR when the next review is due. Review interval settings of 6, 9 or 12 months; the intervals can be edited, changed and added to. | Recorded · plan elaborated, waiting for go |

## PRI-001 · Salary increment reminder (draft plan)
- **Source of increments:** payroll salary history (`eppd_salary_history`): every salary change after the starting salary
  is an increment; amount = new salary − previous salary, date = effective date. The workbook import gave 185 starting
  salaries and 111 later changes.
- **Review intervals:** a settings list (Payroll Settings) starting with 6, 9 and 12 months; Admin can add, rename or
  change an interval. Each person gets one interval (default by confirmation status, e.g. 6 months on probation,
  12 months when confirmed), changeable per person.
- **Next review due** = last increment date (or join / confirmation date if none) + the person's interval.
- **Where it shows:** a "Last increment" and "Next review" column on View People (salary amounts only for roles that may
  see salary), a Payroll › Increments page listing who is due this month, overdue and coming up, and a dashboard /
  bell reminder for Admin and HR.
- **Recording a new increment** adds a salary-history row from a month (logged), so payroll picks it up automatically.
