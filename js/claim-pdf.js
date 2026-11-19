// MyEden Group CMS V1.0 · signed PDFs for claims decided in the CMS (v2026.11.20).
// The PDF is the claim in its paper form's layout (the same pages as Print / PDF in the claim window), with the receipts / journey
// photos after it, made here in the CMS with html2canvas + jsPDF (the same libraries and versions the MEG-FORMS apps used).
// It no longer loads the MEG-OTCF / MEG-MTCF page, so those apps can be retired.
(function () {
  'use strict';
  const BUCKET = { otcf: 'otcf-pdfs', mtcf: 'mtcf-pdfs' };
  const NAME = { otcf: 'OTCF', mtcf: 'MTCF' };
  let libs = null;
  const loadScript = (src) => new Promise((ok, no) => { const s = document.createElement('script'); s.src = src; s.onload = ok; s.onerror = () => no(new Error(`Could not load ${src}`)); document.head.appendChild(s); });
  const loadLibs = () => (libs = libs || Promise.all([window.html2canvas ? null : loadScript('../vendor/html2canvas.min.js'), window.jspdf ? null : loadScript('../vendor/jspdf.umd.min.js')])
    .catch((e) => { libs = null; throw e; }));
  // wait for the pictures (logo, receipts) before capturing; one that never loads is left out
  const pictures = (root) => Promise.all([...root.querySelectorAll('img')].map((im) => (im.complete && im.naturalWidth ? null : new Promise((ok) => { im.onload = ok; im.onerror = ok; setTimeout(ok, 10000); }))));

  async function makePdf(form, sub, dec) {
    const f = String(form || '').toLowerCase(); if (!BUCKET[f]) return null;
    if (f === 'mtcf' && dec !== 'approve') return null;   // as in MEG-MTCF: no PDF for a disapproval
    if (typeof window.CMS_CLAIM_SHEETS !== 'function') throw new Error('The CMS is still loading.');
    const sheets = await window.CMS_CLAIM_SHEETS(f, sub, sub.company_code, sub.serial_no);
    await loadLibs();
    const host = document.createElement('div');
    host.setAttribute('aria-hidden', 'true');
    host.style.cssText = 'position:fixed;left:-30000px;top:0;width:210mm;background:#fff;pointer-events:none;';
    host.innerHTML = `<div class="print-doc">${sheets.join('')}</div>`;
    document.body.appendChild(host);
    try {
      await pictures(host);
      const pdf = new window.jspdf.jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait', compress: true });
      let first = true;
      for (const el of host.querySelectorAll('.sheet')) {
        const canvas = await window.html2canvas(el, { scale: 2, useCORS: true, backgroundColor: '#ffffff', logging: false });
        const pagePx = Math.round(canvas.width * 297 / 210);   // one A4 page, in canvas pixels
        for (let y = 0; y < canvas.height; y += pagePx) {
          const h = Math.min(pagePx, canvas.height - y); if (h < 20 && y > 0) break;
          const part = document.createElement('canvas'); part.width = canvas.width; part.height = h;
          part.getContext('2d').drawImage(canvas, 0, y, canvas.width, h, 0, 0, canvas.width, h);
          if (!first) pdf.addPage(); first = false;
          pdf.addImage(part.toDataURL('image/jpeg', 0.9), 'JPEG', 0, 0, 210, h * 210 / canvas.width);
        }
      }
      const label = dec === 'approve' ? 'Approved' : 'Disapproved';
      const fileName = `${NAME[f]}_${String(sub.serial_no || sub.id).replace(/[^a-z0-9]+/gi, '_')}_${label}.pdf`;
      return { blob: pdf.output('blob'), fileName };
    } finally { host.remove(); }
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
