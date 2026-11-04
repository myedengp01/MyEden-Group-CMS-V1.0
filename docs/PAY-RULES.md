# MyEden Group CMS V1.0 · How pay is worked out (as built, 3 Nov 2026)

Taken from the payroll engine (`payroll/js/engines/payroll.js`, `ot.js`, `leave.js`, `resign.js`, `statutory.js`, `pcb.js`) and the
settings in force. Recorded as PRI-013; the open points at the end are waiting for CLC's decision.

## The three rates everything is built on

| Rate | How it is worked out | Example (basic RM 2,600) |
|---|---|---|
| Daily rate (ORP) | Basic ÷ 26 (Employment Act s.60I) | RM 100.00 |
| Calendar-day rate | Basic ÷ days in that month (28–31) | RM 83.87 in a 31-day month |
| Hourly rate (HRP) | Daily rate ÷ the person's normal hours (working hours to − from − meal break; 8 if not recorded), **at most 8 from the October 2026 payroll** (EA s.60A; CLC 3 Nov 2026). Shorter days keep their own hours. | 9 h a day → ÷ 8 → RM 12.50 |

Hourly-paid staff: the hourly rate is their pay rate; their daily rate = hourly rate × their own normal hours (the 8-hour cap does not apply to them).

Working week: 5 days, 45 hours (Monday–Friday). Saturday is the off day (overtime 1.5×), Sunday the rest day (EA rest-day rule). The same hours (capped at 8) set "half a day" (4 h) and "beyond normal hours" for rest days and public holidays. Before October 2026 the workbook used ÷ 9 (Jan–May) and ÷ 8 (Jun–Sep); those months are not recalculated.

## What uses which rate

| Item | Method |
|---|---|
| Basic pay, part month (joined / left / transferred mid-month) | Basic ÷ calendar days × days employed |
| Hourly-paid basic | Hours recorded in Part-time Hours × hourly rate |
| Unpaid leave | Days of unpaid leave × calendar-day rate |
| Overtime, normal day | Hours × HRP × 1.5 (or the person's own multiplier, if set) |
| Overtime, off day (Saturday) | Hours × HRP × 1.5 |
| Rest day, up to half a normal day | ½ × daily rate |
| Rest day, more than half up to a normal day | 1 × daily rate |
| Rest day, beyond normal hours | Extra hours × HRP × 2 |
| Public holiday, normal hours | 2 × daily rate (on top of the holiday pay already in the salary) |
| Public holiday, beyond normal hours | Extra hours × HRP × 3 |
| Annual leave paid out on leaving | Unused days × daily rate (more taken than earned is deducted at the same rate) |
| Annual leave buy-back (year-end, approved) | Days × daily rate × buy-back % (50 / 25 / 10 %) |
| Notice not served | Calendar days × calendar-day rate of each month; employee pays, company pays, or waived |
| Negative leave balance at year end | Becomes unpaid leave in December (calendar-day rate) |
| Company loans | Monthly instalment, or the whole balance in the final month |
| Staff claims (SCF / MTCF) | Added on top of net pay; not wages |
| OTCF with up to 3 times a day | Rest day / public holiday: the day's times are added up before the rate is chosen; normal / off days line by line |

## Leave entitlements

- Annual leave, full time: 8 / 12 / 16 days by service (under 2 years / 2–5 / 5 and over). Pro-rated by month: a month counts if service
  starts by the 15th or ends on or after the 15th; each period rounded half up.
- Annual leave, part time: from 2027, 6 / 8 / 11 days; casual (30 % or less of a 45-hour week) none. Before 2027: full-time days × weekly hours ÷ 45.
- Sick leave: 14 / 18 / 22 days (part time 10 / 13 / 15 from 2027), by completed years at 31 December of the leave year — or at the last day of
  service if earlier (PRI-014, 3 Nov 2026): reaching the 2- or 5-year mark in the year gives the higher days for the whole year from 1 January.
  Full days in the year of joining; never pro-rated, and never deducted when someone leaves (EA s.24 / s.60F). Hospitalisation: a 60-day
  pool that includes sick leave.
- Carry forward: by KPI grade E 6 / S 3 / A 1 / I 0 / U 0 days, confirmed staff only; the excess bought back if approved, otherwise forfeited.
- Notice period: letter date + 4 / 6 / 12 weeks by completed years (4 on probation). Leave offset against the notice uses Monday–Friday, public holidays skipped.

## Approval and the payroll report

- HR prepares and saves the month, then submits it; a Director approves (or returns it with a reason); only then can it be finalised. Saving the draft again, or reopening a finalised month, clears the approval (4 Nov 2026).
- The monthly payroll report (by company) shows every pay item, statutory and net pay, leave taken and balances, company totals and the names of who prepared, approved and finalised it. Drafts are watermarked.

## Statutory deductions

- EPF, SOCSO, EIS: from the official tables in Settings, on the wages of the items each payment type is ticked for. Age is taken on the last
  day of the previous month (the 60+ rates start the month after the birthday).
- PCB: not calculated automatically — "Automatic PCB" is off, so last month's PCB is copied forward and HR checks or types it. The full monthly
  formula is built, ready to switch on.
- Rounding: each amount to 2 decimals; PCB (when automatic) rounds up to the next 5 sen.

## Open points (waiting for CLC)

1. Two different day rates: leave pay-outs and overtime use basic ÷ 26; unpaid leave, part months and notice not served use basic ÷ calendar
   days (both follow the workbook). Mismatch: a negative leave balance is deducted at ÷ 26 on leaving but at ÷ calendar days at year end.
2. Basic only: every rate uses basic salary. Under the Employment Act the daily rate for overtime and leave pay can arguably include fixed
   allowances (e.g. a position allowance). Confirm with the advisor.
3. Overtime above RM 4,000: the CMS pays Employment Act overtime to everyone; the Act does not require it above RM 4,000. Company policy?
4. Pay rises within a month: the salary in force on the month's last day is used, so a rise dated 15 Nov applies to all of November.
5. Unpaid leave across a month end (e.g. 30 Nov – 2 Dec) is all deducted in the month it starts.
6. Optional modules switched off: Automatic PCB, Claims in payroll, Company loans, Final settlement — while off, those amounts do not reach the
   payslip automatically.
7. ~~Rest-day "half a day" uses the person's own normal hours~~ — decided 3 Nov 2026: hours capped at 8 from October 2026 (half a day = 4 h); 5-day 45-hour week.
8. No public holidays entered for 2026 or 2027: leave day counts and the resignation calculator skip none until they are added.

## Idea

A "How pay is worked out" page in the CMS (from this document) for HR to refer to, kept in step with the settings.
