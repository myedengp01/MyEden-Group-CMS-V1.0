# MyPayroll V2.0 pages inside the CMS (Phase 6)

`js/` is MyPayroll-System-V2.0's page and calculation code, copied so the CMS runs the same tested code on the same database.
Changes from MyPayroll: `config.js` and `supabase.js` use the CMS connection and sign-in; `ui.js` shows messages as CMS toasts and
dialogs with the CMS look (`myp-modal` / `myp-dialog`); `megforms.js` takes its client from `supabase.js`. `app.js` is not used —
the CMS (`js/app.js`, "PHASE 6 · MYPAYROLL PAGES INSIDE THE CMS") opens each page and gives it the CMS permission for that page.
`payroll.css` is generated from MyPayroll's `css/app.css`, scoped to `.myp` / `.myp-modal`, with MyPayroll's colours mapped to the CMS ones.
