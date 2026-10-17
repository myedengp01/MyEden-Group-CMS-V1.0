// MyEden Group CMS V1.0 · menu and module map.
// Every page in the sidebar is listed here once: route, label, icon, the system it replaces or connects,
// the build phase it arrives in, and what it will do. The router, sidebar and Ctrl+K search all read this list.
window.CMS_PHASES = {
  0: 'Phase 0 · Foundation',
  1: 'Phase 1 · MEG-FORMS',
  2: 'Phase 2 · Payroll',
  3: 'Phase 3 · Recruitment & onboarding',
  4: 'Phase 4 · Staff self-service',
  5: 'Phase 5 · HR operations',
  9: 'Later',
};

window.CMS_MENU = [
  { section: 'Workspace', items: [
    { route: 'dashboard', label: 'Dashboard', icon: 'home', phase: 0, desc: 'Today across MyEden Group: people, positions, applications, approvals and your tasks.' },
    { group: 'People & Employment', icon: 'users', items: [
      { route: 'people', label: 'View People', phase: 0, desc: 'Every person in the Employee Master, from applicant to former staff: employer on the contract, paying company and centre.', plan: ['Full record, salary history and documents arrive with Payroll (Phase 2)'] },
      { route: 'people/add', label: 'Add Person', phase: 2, source: 'MyPayroll V2.0', desc: 'Create an employee record with the next Employee ID.', plan: ['Department fills in the paying company', 'Employee ID generated on save', 'Or created automatically from an accepted applicant (Phase 3)'] },
      { route: 'people/former', label: 'Former Staff', phase: 0, desc: 'Everyone who has left: last day and the company they worked for.' },
      { route: 'people/ids', label: 'Employee IDs', phase: 2, source: 'MyPayroll V2.0', myp: 'employees/ids', desc: 'The Employee ID register: format, next number and who holds which ID.' },
      { route: 'people/import', label: 'Import from Workbook', phase: 2, source: 'MyPayroll V2.0', myp: 'employees/import', desc: 'Bring staff in from the MEG-EPPD payroll workbook.' },
      { route: 'people/directory', label: 'Employee Directory', phase: 4, desc: 'Who is who, by centre and department, with contact details staff are allowed to see.' },
      { route: 'org', label: 'Organisation Structure', phase: 0, desc: 'Companies, centres and departments, and the positions in each.', plan: ['Myeden Group · Myeden Edu Hub · Happy Dino · Aborne Project', 'Centres: Taska Genius Eden, PJK Eden, Tadika Genius Eden, Tadika Happy Dino, HQ', 'Department codes E1–E11, E3+, HQ'] },
      { route: 'documents', label: 'Employee Documents', phase: 5, desc: 'Contracts, IC copies, certificates and letters, filed per employee.' },
    ] },
    { group: 'Recruitment', icon: 'search-user', items: [
      { route: 'jd', label: 'Job Description Manual', phase: 3, source: 'MEG-EAF V2', desc: 'The controlled multi-entity JD master. Positions here also become CMS roles.' },
      { route: 'positions', label: 'Positions & Vacancies', phase: 3, desc: 'Open a role from a JD, get it approved, and track headcount.' },
      { route: 'applications', label: 'Applications', phase: 3, source: 'MEG-EAF V2', desc: 'Invitation-only applications, screening and Office Use.' },
      { route: 'interviews', label: 'Shortlist & Interviews', phase: 3, source: 'MEG-EAF V2', desc: 'Shortlists, interview schedules and scores.' },
      { route: 'onboarding', label: 'Offers & Onboarding', phase: 3, source: 'MEG-EAF V2', desc: 'LOEC, acceptance, then the applicant becomes an employee without retyping.', plan: ['LOEC workflow', 'Accepted applicant → employee record + Employee ID', 'Onboarding checklist and handbook acknowledgement'] },
      { route: 'handbook', label: 'Employee Handbook', phase: 3, source: 'MEG-EAF V2', desc: 'Handbook issued per legal employer, with digital acknowledgement tracked per version.' },
    ] },
    { group: 'Time & Leave', icon: 'calendar', items: [
      { route: 'leave', label: 'Leave Records', phase: 2, source: 'MyPayroll V2.0', myp: 'leave', desc: 'Leave taken and approved, by person and type.' },
      { route: 'leave/balances', label: 'Leave Balances', phase: 2, source: 'MyPayroll V2.0', myp: 'leave/balances', desc: 'Entitlements, carry-forward and adjustments.' },
      { route: 'leave/al-calculator', label: 'AL Calculator', phase: 2, source: 'MyPayroll V2.0', myp: 'leave/al-calculator', desc: 'Annual leave entitlement and pro-rata calculator.' },
      { route: 'leave/year-end', label: 'Year-end Close', phase: 2, source: 'MyPayroll V2.0', myp: 'leave/year-end', desc: 'Close the leave year: carry-forward, buy-back and new entitlements.' },
      { route: 'time', label: 'Overtime & Hours', phase: 2, source: 'MyPayroll V2.0', myp: 'time', desc: 'Hours worked and overtime priced into the monthly payroll.' },
      { route: 'leave/import', label: 'Import Leave', phase: 2, source: 'MyPayroll V2.0', myp: 'leave/import', desc: 'Bring past leave records in from the workbook.' },
    ] },
    { group: 'Forms & Claims', icon: 'file-check', items: [
      { route: 'overtime', label: 'Overtime Claims (OTCF)', phase: 1, source: 'MEG-OTCF', desc: 'Overtime claims with approval, priced into payroll.' },
      { route: 'forms/scf', label: 'Staff Claims (SCF)', phase: 1, source: 'MEG-SCF', desc: 'Miscellaneous staff claims, approved and reimbursed with the salary.' },
      { route: 'forms/mtcf', label: 'Mileage Claims (MTCF)', phase: 1, source: 'MEG-MTCF', desc: 'Mileage tracking and claims.' },
      { route: 'forms/tec', label: 'Teacher Tuition Claims (TEC)', phase: 1, source: 'MEG-TEC-V2', desc: "Teachers' monthly tuition and enrichment class payment claims." },
      { route: 'forms/prfaf', label: 'Purchase & Funding (PRFAF)', phase: 1, source: 'MEG-PRFAF', desc: 'Purchase requests and funding applications with company and event ledgers.' },
    ] },
    { group: 'Payroll', icon: 'wallet', badge: 'V2.0', items: [
      { route: 'payroll', label: 'Monthly Payroll', phase: 2, source: 'MyPayroll V2.0', myp: 'payroll', desc: 'Pay runs, EPF / SOCSO / EIS, PCB, finalise and reopen.' },
      { route: 'payroll/reports', label: 'Payslips & Reports', phase: 2, source: 'MyPayroll V2.0', myp: 'reports', desc: 'Payslips, statutory lists, year to date and EA forms.' },
      { route: 'payroll/companies', label: 'Paying Companies', phase: 2, source: 'MyPayroll V2.0', myp: 'payroll/companies', desc: 'Which company pays each person, and moves from a given month.' },
      { route: 'payroll/loans', label: 'Company Loans', phase: 2, source: 'MyPayroll V2.0', myp: 'loans', desc: 'Company loans to staff and their monthly deductions.' },
      { route: 'payroll/settlement', label: 'Final Settlement', phase: 2, source: 'MyPayroll V2.0', myp: 'settlements', desc: 'Final pay for leavers: notice, leave and loan balances.' },
      { route: 'payroll/import', label: 'Import Past Months', phase: 2, source: 'MyPayroll V2.0', myp: 'payroll/import', desc: 'Bring past pay runs in from the workbook.' },
    ] },
    { group: 'Performance & Growth', icon: 'trend', items: [
      { route: 'performance', label: 'KPI & Appraisal', phase: 5, desc: 'KPI grades, appraisals and probation confirmation.' },
      { route: 'training', label: 'Training & Certificates', phase: 5, desc: 'First aid, SKM, ECCE and other certificates, with expiry reminders.' },
    ] },
    { route: 'assets', label: 'Assets & Equipment', icon: 'box', phase: 5, desc: 'Laptops, keys, uniforms and devices issued to staff, returned at offboarding.' },
    { route: 'letters', label: 'HR Letters', icon: 'mail', phase: 5, source: 'MEG-EAF V2', desc: 'Appointment, confirmation, service and other letters on company letterheads.' },
    { route: 'hrlaw', label: 'Employment Act & Calculators', icon: 'scale', phase: 3, source: 'MEG-EAF V2', desc: 'Statutory reference and OT, leave, notice, maternity and final-pay calculators.' },
    { route: 'approvals', label: 'Approvals & Workflows', icon: 'check-circle', phase: 0, desc: 'Everything waiting for a decision across MEG-FORMS, MEG-EAF V2 and the handbook.' },
    { route: 'reports', label: 'Reports & Analytics', icon: 'chart', phase: 5, desc: 'Headcount, turnover, cost and claims across companies and centres.' },
  ] },
  { section: 'Administration', items: [
    { group: 'Payroll Settings', icon: 'wallet', items: [
      { route: 'settings/org', label: 'Departments & Job Titles', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/org', desc: 'Payroll departments (centre codes) and job titles.' },
      { route: 'settings/lists', label: 'Pick-lists', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/lists', desc: 'The choices offered in payroll forms.' },
      { route: 'settings/payment-types', label: 'Payment Types', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/payment-types', desc: 'Allowances, deductions and other pay items, and how each is taxed and contributed.' },
      { route: 'settings/statutory', label: 'Statutory Tables', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/statutory', desc: 'EPF, SOCSO, EIS and PCB tables.' },
      { route: 'settings/holidays', label: 'Public Holidays', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/holidays', desc: 'Public holidays by state and year.' },
      { route: 'settings/policies', label: 'HR Policies', phase: 2, source: 'MyPayroll V2.0', myp: 'settings/policies', desc: 'Leave, overtime and other policy rules used by payroll.' },
    ] },
    { route: 'admin/roles', label: 'Users, Roles & Access', icon: 'shield', phase: 0, desc: 'Who can see and do what, per module and action.' },
    { route: 'admin/companies', label: 'Companies & Settings', icon: 'building', phase: 0, desc: 'Companies, their codes and other spellings, centres and units. Letterheads, statutory numbers and holidays come later.' },
    { route: 'admin/audit', label: 'Audit Log', icon: 'list', phase: 0, desc: 'Every change, who made it and when.' },
    { route: 'admin/export', label: 'Export All Data', icon: 'download', phase: 0, desc: 'Your own backup copy of every table (the free plan has no automatic backups).' },
  ] },
];

// Group companies shown on the dashboard (the full list, with inactive codes, comes from the database).
window.CMS_COMPANIES = [
  { code: 'MEG', name: 'MyEden Group Sdn. Bhd.', short: 'MyEden Group', logo: 'assets/logos/myeden-group.png', centres: 'Taska Genius Eden · PJK Eden · HQ' },
  { code: 'MEH', name: 'MyEden Edu Hub Sdn. Bhd.', short: 'MyEden Edu Hub', logo: 'assets/logos/edu-hub.jpg', centres: 'Tadika Genius Eden · Tadika Happy Dino' },
  { code: 'HD', name: 'Happy Dino Sdn. Bhd.', short: 'Happy Dino', logo: 'assets/logos/happy-dino.jpg', centres: '' },
  { code: 'ABP', name: 'Aborne Project Sdn. Bhd.', short: 'Aborne Project', logo: 'assets/logos/aborne-project.png', centres: '' },
];

// Where each module lives today, until it moves into the CMS.
window.CMS_SOURCES = {
  'MyPayroll V2.0': 'https://myedengp01.github.io/MyPayroll-System-V2.0/',
  'MEG-EAF V2': 'https://myedengp01.github.io/MEG-EAF-V2/dashboard.html',
  'MEG-FORMS': 'https://myedengp01.github.io/DB-MEG-FORMS/',
  'MEG-SCF': 'https://myedengp01.github.io/MEG-SCF/',
  'MEG-OTCF': 'https://myedengp01.github.io/MEG-OTCF/',
  'MEG-MTCF': 'https://myedengp01.github.io/MEG-MTCF/',
  'MEG-PRFAF': 'https://myedengp01.github.io/MEG-PRFAF/',
  'MEG-TEC-V2': 'https://myedengp01.github.io/MEG-TEC-V2/',
};

// Menu route → permission module (cms_modules.code). Routes not listed use their own name.
window.CMS_MODULE_OF = {
  'people/add': 'people', 'people/directory': 'people', positions: 'recruitment', applications: 'recruitment', interviews: 'recruitment',
  'leave/balances': 'leave', 'forms/scf': 'scf', 'forms/mtcf': 'mtcf', 'forms/tec': 'tec', 'forms/prfaf': 'prfaf',
  'payroll/reports': 'payroll', 'payroll/companies': 'payroll', 'payroll/loans': 'payroll', 'payroll/settlement': 'payroll', 'payroll/import': 'payroll',
  'people/former': 'people', 'people/ids': 'people', 'people/import': 'people',
  'leave/al-calculator': 'leave', 'leave/year-end': 'leave', 'leave/import': 'leave', time: 'leave',
  'settings/org': 'payroll.settings', 'settings/lists': 'payroll.settings', 'settings/payment-types': 'payroll.settings',
  'settings/statutory': 'payroll.settings', 'settings/holidays': 'payroll.settings', 'settings/policies': 'payroll.settings',
  'admin/roles': 'admin.roles', 'admin/companies': 'admin.companies', 'admin/audit': 'admin.audit', 'admin/export': 'admin.export',
};
