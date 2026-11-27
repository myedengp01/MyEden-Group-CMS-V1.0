// MyEden Group CMS V1.0 · signed PDFs for claims decided in the CMS (v2026.11.20).
// The PDF is the original app's printout (js/form-print.js, PRI-030 v2026.11.27): the same pages as Print in the claim window,
// named FORM - CLAIMANT - Mon YYYY - serial - decision.
// It no longer loads the MEG-OTCF / MEG-MTCF page, so those apps can be retired.
(function () {
  'use strict';
  const BUCKET = { otcf: 'otcf-pdfs', mtcf: 'mtcf-pdfs' };

  async function makePdf(form, sub, dec) {
    const f = String(form || '').toLowerCase(); if (!BUCKET[f]) return null;
    if (f === 'mtcf' && dec !== 'approve') return null;   // as in MEG-MTCF: no PDF for a disapproval
    // v2026.11.27 (PRI-030): the original app's own printout and the standard file name, from js/form-print.js
    if (!window.CMS_FORM_PRINT) throw new Error('The CMS is still loading.');
    const out = await window.CMS_FORM_PRINT.pdf(f, sub, { decision: dec === 'approve' ? 'approve' : 'disapprove' });
    return { blob: out.blob, fileName: out.fileName };
  }

  // same place and link lifetime as the apps: <bucket>/<claim id>/<file>, signed link for 30 days
  async function savePdf(form, id, blob, fileName) {
    const bucket = BUCKET[String(form).toLowerCase()]; const sb = window.CMS_API.sb();
    const path = `${id}/${fileName}`;
    const up = await sb.storage.from(bucket).upload(path, blob, { upsert: true, contentType: 'application/pdf' });
    if (up.error) throw new Error(up.error.message);
    const signed = await sb.storage.from(bucket).createSignedUrl(path, 60 * 60 * 24 * 30);
    if (signed.error) throw new Error(signed.error.message);
    await window.CMS_API.rpc('cms_claim_set_pdf', { p_form: form, p_id: id, p_url: signed.data.signedUrl });
    return signed.data.signedUrl;
  }

  window.CMS_CLAIM_PDF = { supported: (form) => !!BUCKET[String(form || '').toLowerCase()], makePdf, savePdf };
}());
