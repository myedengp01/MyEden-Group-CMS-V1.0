# Transfer and Promotion letter: admin testing

TRL_LOP combines transfer, promotion, basic salary changes, new-position assessment, post-assessment salary arrangements, employee acceptance and revised terms. It is deliberately draft/inactive and cannot be issued operationally. Existing letter issuance is unchanged.

## Use
Open Letters, choose TRL_LOP and an employee. Choose a destination department and approved JD position. The selector is limited to the employee’s legal company, active entities/departments, non-future effective dates and JDs with a reference/version. Destination position, department, location, reporting manager and JD reference/version are filled from the JD. Salary remains separate. Choose maintained salary, an agreed post-assessment increment, or a review without a promised increment. Complete assessment dates, terms and signatory details.

Appendix A is read-only JD content; Appendix B contains revised terms. Preview and print show tables and draft markings. Saving does not update Employee Master. Cross-legal-employer transfers need a separate agreement and are excluded from this trial selector.

## Server safeguards
Both the existing gateway administrator role and CMS company-scoped draft permission are required. Anonymous execution is denied. Save re-fetches the JD, rejects stale selections, computes salary values and stores authoritative rendered content and JD snapshot. It does not trust client-supplied JD text or destination fields. Submitted/approved records retain the existing edit and distinct-person approval restrictions. TRL_LOP and testing-only snapshots are blocked by cms_letter_issue. Existing CMS audit logging remains active.

## Validation
Run `cd tests`, `npm install`, then `npm test` (Node.js). The isolated PGlite fixture uses dummy data and permission stubs, not production credentials. Coverage: approved same-company JD, server-owned destination/salary values, saved snapshot, stale JD detection, missing/inactive/cross-company/non-admin rejection, issuance blocked and unchanged employee record. App syntax and a dummy browser preview were checked. Live RPC read tests verified authorized lookup and non-admin rejection in a rolled-back transaction. Full signed-in user acceptance remains required before any operational release.
