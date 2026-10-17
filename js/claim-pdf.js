// MyEden Group CMS V1.0 · signed PDFs for claims decided in the CMS.
// The PDF is made by the form app's own code (MEG-OTCF / MEG-MTCF), loaded out of sight in a hidden frame,
// so the CMS produces exactly the same document as the app, including any later change to the app's layout.
// This works because the CMS and the form apps are served from the same site (myedengp01.github.io).
(function () {
  'use strict';
  const APPS = {
    otcf: {
      app: 'MEG-OTCF', bucket: 'otcf-pdfs',
      ready: (w) => typeof w.generateApprovalPdf === 'function' && typeof w.generateDisapprovalSummaryPdf === 'function',
      make: (w, sub, dec) => dec === 'approve' ? w.generateApprovalPdf(sub) : w.generateDisapprovalSummaryPdf(sub, sub.disapproval_reason || ''),
    },
    mtcf: {
      app: 'MEG-MTCF', bucket: 'mtcf-pdfs',
      ready: (w) => typeof w.MEG_MTCF_generateCompletePdf === 'function',
      make: (w, sub, dec) => dec === 'approve' ? w.MEG_MTCF_generateCompletePdf(sub) : null, // the MTCF app makes no PDF for a disapproval
    },
  };
  const frames = {};
  const APP_SESSION_KEY = `sb-${window.CMS_CONFIG.projectRef}-auth-token`;

  // The form app reads receipts with its own sign-in. If this browser is not signed in to the form apps yet,
  // hand it the CMS sign-in (same person, same account) so journey photos can go into the PDF.
  async function shareSession() {
    try {
      if (localStorage.getItem(APP_SESSION_KEY)) return;
      const { data } = await window.CMS_API.sb().auth.getSession();
      if (data && data.session) localStorage.setItem(APP_SESSION_KEY, JSON.stringify(data.session));
    } catch (e) { /* PDF still works; photos may be left out */ }
  }

  function appWindow(form) {
    const def = APPS[form];
    if (frames[form]) return frames[form];
    frames[form] = new Promise((resolve, reject) => {
      const url = window.CMS_SOURCES[def.app];
      const f = document.createElement('iframe');
      f.setAttribute('aria-hidden', 'true'); f.tabIndex = -1; f.title = `${def.app} PDF maker`;
      f.style.cssText = 'position:fixed;left:-20000px;top:0;width:1200px;height:900px;border:0;opacity:0;pointer-events:none;';
      const started = Date.now();
      const fail = (msg) => { frames[form] = null; f.remove(); reject(new Error(msg)); };
      f.addEventListener('load', () => {
        const poll = () => {
          let w;
          try { w = f.contentWindow; void w.document; } catch (e) { return fail(`The ${def.app} page could not be opened from the CMS.`); }
          if (w.html2canvas && w.jspdf && def.ready(w)) return resolve(w);
          if (Date.now() - started > 30000) return fail(`${def.app} took too long to load.`);
          setTimeout(poll, 250);
        };
        poll();
      });
      f.src = url + (url.includes('?') ? '&' : '?') + 'cms_pdf=1';
      document.body.appendChild(f);
    });
    return frames[form];
  }

  async function makePdf(form, sub, dec) {
    const def = APPS[form]; if (!def) return null;
    await shareSession();
    const w = await appWindow(form);
    const blob = await def.make(w, sub, dec);
    if (!blob) return null;
    const label = dec === 'approve' ? 'Approved' : 'Disapproved';
    let fileName = '';
    try { fileName = typeof w.buildSubmissionFileName === 'function' ? w.buildSubmissionFileName(sub, label) : ''; } catch (e) { /* use the fallback */ }
    if (!fileName) fileName = `${form.toUpperCase()}_${String(sub.serial_no || sub.id).replace(/[^a-z0-9]+/gi, '_')}_${label}.pdf`;
    return { blob, fileName };
  }

  // same place and link lifetime as the apps: <bucket>/<claim id>/<file>, signed link for 30 days
  async function savePdf(form, id, blob, fileName) {
    const def = APPS[form]; const sb = window.CMS_API.sb();
    const path = `${id}/${fileName}`;
    const up = await sb.storage.from(def.bucket).upload(path, blob, { upsert: true, contentType: 'application/pdf' });
    if (up.error) throw new Error(up.error.message);
    const signed = await sb.storage.from(def.bucket).createSignedUrl(path, 60 * 60 * 24 * 30);
    if (signed.error) throw new Error(signed.error.message);
    await window.CMS_API.rpc('cms_claim_set_pdf', { p_form: form, p_id: id, p_url: signed.data.signedUrl });
    return signed.data.signedUrl;
  }

  window.CMS_CLAIM_PDF = { supported: (form) => !!APPS[form], makePdf, savePdf };
})();
