// MyEden Group CMS V1.0 · form printouts in the original apps' own layouts (PRI-030, v2026.11.27).
// SCF, OTCF, MTCF, TEC and Purchase requests print exactly as MEG-SCF / MEG-OTCF / MEG-MTCF / MEG-TEC-V2 / MEG-PRFAF printed them:
// the same markup and CSS (css/form-print.css), drawn in a separate frame so nothing of the CMS styling leaks in, captured with
// html2canvas and laid on A4 pages the way each app placed them. Print and Download PDF use the same page pictures.
// File name for every form:  FORM - CLAIMANT NAME - Mon YYYY - serial - decision.pdf
(function () {
  'use strict';
  const ROOT = new URL('../', document.currentScript.src).href;
  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const MON = MONTHS.map((m) => m.slice(0, 3));
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmt2 = (v) => { const n = Number(v); return Number.isFinite(n) ? n.toFixed(2) : '0.00'; };
  const dmy = (v) => { const s = String(v || ''); const m = s.match(/^(\d{4})-(\d{2})-(\d{2})/); return m ? `${m[3]}/${m[2]}/${m[1]}` : s; };
  const ver = () => window.CMS_VERSION || '';
  const pad2 = (n) => String(n).padStart(2, '0');
  // the companies as the form apps named them, with their logos
  const CO = {
    MEG: { name: 'MYEDEN GROUP SDN BHD', short: 'MyEden Group', tec: 'MyEden Group Sdn Bhd', logo: 'assets/logos/myeden-group.png' },
    MEH: { name: 'MYEDEN EDU HUB SDN BHD', short: 'MyEden Edu Hub Sdn Bhd', tec: 'MyEden Edu Hub', logo: 'assets/logos/forms/MEH.png' },
    HDS: { name: 'HAPPY DINO SDN BHD', short: 'Happy Dino', tec: 'Happy Dino Sdn Bhd', logo: 'assets/logos/forms/HDS.png' },
    ABN: { name: 'ABORNE PROJECT', short: 'Aborne Project', tec: 'Aborne Project', logo: 'assets/logos/forms/ABN.png' },
  };
  const coOf = (code) => { const k = String(code || '').toUpperCase(); const c = CO[({ HD: 'HDS', ABP: 'ABN', MEDU: 'MEH' })[k] || k];
    return c ? { ...c, code: k, logo: ROOT + c.logo } : { name: k, short: k, tec: k, code: k, logo: '' }; };
  const FORM = { scf: 'SCF', otcf: 'OTCF', mtcf: 'MTCF', tec: 'TEC', 'tec-v2': 'TEC', pr: 'PR' };
  const key = (form) => (String(form || '').toLowerCase() === 'tec-v2' ? 'tec' : String(form || '').toLowerCase());

  // ---- files (receipts, journey proof, item photos): downloaded, so the capture is never blocked by another site's rules
  const sb = () => window.CMS_API?.sb?.();
  async function fileUrl(bucket, path) {
    if (!path) return '';
    try { const { data, error } = await sb().storage.from(bucket).download(path); if (error || !data) return ''; return URL.createObjectURL(data); } catch (e) { return ''; }
  }

  // ---- the name of the printout
  function period(form, s) {
    const f = key(form);
    const span = (list) => { const u = [...new Set(list.filter(Boolean))].sort(); if (!u.length) return '';
      const [a, b] = [u[0], u[u.length - 1]]; const [ya, ma] = a.split('-').map(Number); const [yb, mb] = b.split('-').map(Number);
      if (a === b) return `${MON[ma - 1]} ${ya}`; if (ya === yb) return `${MON[ma - 1]}-${MON[mb - 1]} ${ya}`; return `${MON[ma - 1]} ${ya}-${MON[mb - 1]} ${yb}`; };
    const ym = (y, m) => (y && m ? `${y}-${pad2(m)}` : '');
    const iso = (d) => { const t = String(d || ''); let m = t.match(/^(\d{4})-(\d{2})/); if (m) return `${m[1]}-${m[2]}`; m = t.match(/^(\d{1,2})[-/](\d{1,2})[-/](\d{4})/); return m ? `${m[3]}-${pad2(m[2])}` : ''; };
    if (f === 'otcf') return span([ym(s.year, s.month)]);
    if (f === 'tec') return span((s.pages || []).map((p) => ym(p.year, p.month)));
    if (f === 'mtcf') return span((s.trips || []).map((t) => iso(t.date))) || span([iso(s.start_date), iso(s.end_date)]);
    if (f === 'scf') { const y = s.period_year || String(s.claim_date || '').slice(-4); const mi = (n) => MONTHS.findIndex((x) => x.toLowerCase() === String(n || '').toLowerCase()) + 1;
      return span([ym(y, mi(s.period_from)), ym(y, mi(s.period_to))]); }
    if (f === 'pr') return span([iso(s.submitted_at || s.created_at)]);
    return '';
  }
  const DECISION = { approved: 'Approved', disapproved: 'Disapproved', paid: 'Paid', submitted: 'Pending', draft: 'Draft', done: 'Checked', finance: 'Pending', directors: 'Pending',
    released: 'Released', purchasing: 'Released', settlement: 'Settling', closed: 'Closed', returned: 'Returned', cancelled: 'Cancelled', checked: 'Checked', rejected: 'Disapproved' };
  const claimant = (f, s) => ({ otcf: s.emp_name, mtcf: s.claimant_name, scf: s.claimed_by, tec: s.teacher_name, pr: s.requester_name })[f] || s.claimant_name || '';
  const serialOf = (f, s) => (f === 'pr' ? s.pr_no : f === 'tec' ? [...new Set((s.pages || []).map((p) => p.serial_no).filter(Boolean))].join(', ') || s.serial_no : s.serial_no) || '';
  function fileName(form, s, opts = {}) {
    const f = key(form); const dec = opts.decision === 'approve' ? 'Approved' : opts.decision === 'disapprove' ? 'Disapproved' : (DECISION[String(s.status || '').toLowerCase()] || s.status || '');
    const clean = (x) => String(x || '').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, '-').replace(/\s+/g, ' ').trim();
    return [FORM[f] || f.toUpperCase(), String(claimant(f, s) || '').toUpperCase(), period(f, s), serialOf(f, s), dec].map(clean).filter(Boolean).join(' - ') + '.pdf';
  }

  // ================= OTCF · MEG-OTCF makeReadOnlySheetHtml (the "original-form approved output") =================
  function otcfDisplayItems(items) { return (items || []).map((it) => (Number(it.slot) > 1 ? { ...it, date: '↳', day: '', ph: false, claimType: '', _slot: Number(it.slot), _ph: it.ph, _day: it.day } : it)); }
  // a day with no claim (no claim type, time, remark or PH tick) shows an empty Total Hrs cell instead of 0.00 (v2026.11.27)
  const used = (it) => !!(String(it.claimType || '').trim() || String(it.from || '').trim() || String(it.to || '').trim() || String(it.remarks || '').trim() || it.ph || it._ph || it._slot);
  function otcf(sub) {
    const c = coOf(sub.company_code); const items = Array.isArray(sub.line_items) ? sub.line_items : [];
    const monthName = MONTHS[(sub.month || 1) - 1] || ''; const numDays = sub.no_of_days || items.length || '';
    const approvedDate = sub.approved_at ? dmy(String(sub.approved_at).slice(0, 10)) : '';
    const rowsHtml = otcfDisplayItems(items).map((it) => {
      const trClass = (it._slot ? 'slot-row ' : '') + (it.ph || it._ph ? 'ph-row' : (['Saturday', 'Sunday'].includes(it.day || it._day) ? 'weekend' : ''));
      return `<tr class="${trClass}"><td class="date-cell">${esc(it.date)}</td><td class="day-cell">${esc(it.day)}</td><td class="ph-cell">${it.ph ? '☑' : ''}</td><td class="claim-cell">${esc(it.claimType)}</td>
        <td class="time-cell">${esc(it.from)}</td><td class="time-cell">${esc(it.to)}</td><td class="total-cell">${used(it) ? fmt2(it.totalHrs) : ''}</td><td class="remarks-cell">${esc(it.remarks)}</td></tr>`;
    }).join('');
    const html = `<div class="sheet approved-otcf-original" style="max-width:980px;">
      <div class="version">${esc(`MEG-OTCF · CMS ${ver()}`)}</div>
      <div class="form-header">
        <div class="logo-box"><img src="${esc(c.logo)}" alt="logo"></div>
        <div class="title-box"><div class="company-name">${esc(c.name)}</div><div class="form-title">Overtime Claim Form (OTCF)</div>
          <div class="company-select-wrap">Company: <span class="approved-company-value">${esc(c.short)}</span></div></div>
        <div class="serial-box"><div class="label">Serial No.</div><div class="serial-display">${esc(sub.serial_no)}</div></div>
      </div>
      <div class="header-grid">
        <div class="field"><label>Name</label><div class="field-value">${esc(sub.emp_name)}</div></div>
        <div class="field"><label>Department</label><div class="field-value">${esc(sub.department)}</div></div>
        <div class="field"><label>Designation</label><div class="field-value">${esc(sub.designation)}</div></div>
        <div class="field"><label>Month</label><div class="field-value">${esc(monthName)}</div></div>
        <div class="field"><label>Submission Date</label><div class="field-value">${esc(dmy(sub.submission_date))}</div></div>
        <div class="field"><label>No. of days in mth</label><div class="field-value">${esc(numDays)}</div></div>
        <div class="field"></div>
        <div class="field"><label>Year</label><div class="field-value">${esc(sub.year)}</div></div>
      </div>
      <div class="note">** OT Claim forms should be submitted on the last day of each month to the HR</div>
      <div class="note">** For late submission of OT claim form, payment will be made the following month</div>
      <div class="working-hours">
        <div><label>Working Hour From:</label><span class="approved-time-value">${esc(sub.working_hour_from)}</span></div>
        <div><label>To:</label><span class="approved-time-value">${esc(sub.working_hour_to)}</span></div>
        <div class="note" style="margin:0;">OT hours overlapping this range will be flagged as an error.</div>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th rowspan="2">Date</th><th rowspan="2">Day</th><th rowspan="2">PH</th><th rowspan="2">Claim Type</th><th colspan="2">OT Hrs</th><th rowspan="2">Total Hrs</th><th rowspan="2">Remarks</th></tr><tr><th>From</th><th>To</th></tr></thead>
        <tbody>${rowsHtml}</tbody>
        <tfoot><tr><td colspan="6">Total Hours :</td><td>${fmt2(sub.total_hours)}</td><td></td></tr></tfoot>
      </table></div>
      <div class="legend"><span><span class="swatch" style="background:var(--blue);"></span>Weekend</span><span><span class="swatch" style="background:var(--red);"></span>Public Holiday (ticked)</span><span><span class="swatch" style="background:var(--red-strong);"></span>OT overlaps working hours (error)</span></div>
      <div class="sig-grid">
        <div class="sig-line">Claimant's Signature</div>
        <div class="approved"><h3>Approved By</h3>
          <div class="field"><label>Name</label><div class="field-value">${esc(sub.approved_by_name)}</div></div>
          <div class="field"><label>Signature</label><div class="field-value">${esc(sub.approval_token)}</div></div>
          <div class="field"><label>Date</label><div class="field-value">${esc(approvedDate)}</div></div>
        </div>
      </div>
    </div>`;
    // MEG-OTCF fits the whole claim on one A4 page, 5 mm margin
    return [{ html, width: 980, pick: '.sheet', place: { fit: 5 } }];
  }

  // ================= MTCF · MEG-MTCF makeReadOnlySheetHtml + generateCompletePdf (journey proof 6 to a page) =================
  async function mtcf(sub) {
    const c = coOf(sub.company_code); const trips = Array.isArray(sub.trips) ? sub.trips : [];
    const approvedDate = sub.approved_at ? String(sub.approved_at).slice(0, 10).split('-').reverse().join('/') : '';
    const rowsHtml = trips.map((t) => `<tr><td class="date-cell">${esc(t.date)}</td><td>${esc(t.purpose)}</td><td>${esc(t.start_location)}</td><td>${esc(t.end_location)}</td>
      <td>${esc(fmt2(t.distance_km))}</td><td class="remarks-cell">${esc(t.remarks)}</td></tr>`).join('');
    const html = `<div class="sheet" style="max-width:980px;">
      <div class="version">${esc(`MEG-MTCF · CMS ${ver()}`)}</div>
      <div class="form-header">
        <div class="logo-box"><img src="${esc(c.logo)}" alt="logo"></div>
        <div class="title-box"><div class="company-name">${esc(c.name)}</div><div class="form-title">Mileage Tracking &amp; Claim Form (MTCF)</div></div>
        <div class="serial-box"><div class="label">Serial No.</div><div class="serial-display">${esc(sub.serial_no)}</div></div>
      </div>
      <div class="header-grid">
        <div class="field"><label>Claimant's Name</label><div class="field-value">${esc(sub.claimant_name)}</div></div>
        <div class="field"><label>Rate (RM/KM)</label><div class="field-value">${esc(fmt2(sub.rate_rm_per_km))}</div></div>
        <div class="field"><label>Start Date</label><div class="field-value">${esc(sub.start_date)}</div></div>
        <div class="field"><label>End Date</label><div class="field-value">${esc(sub.end_date)}</div></div>
        <div class="field"><label>Date of Claim</label><div class="field-value">${esc(sub.date_of_claim)}</div></div>
        <div class="field"><label>Year</label><div class="field-value">${esc(sub.year)}</div></div>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th>Date</th><th>Business / Trip Purpose</th><th>Start Location</th><th>End Location</th><th>Distance (KM)</th><th>Remarks</th></tr></thead>
        <tbody>${rowsHtml}</tbody>
        <tfoot><tr><td colspan="4">Total Mileage (KM) :</td><td>${fmt2(sub.total_mileage_km)}</td><td></td></tr><tr><td colspan="4">Total Amount (MYR) :</td><td>${fmt2(sub.total_amount)}</td><td></td></tr></tfoot>
      </table></div>
      <div class="sig-grid">
        <div class="sig-line">Claimant's Signature</div>
        <div class="approved"><h3>Approved By</h3>
          <div class="field"><label>Check by</label><div class="field-value">${esc(sub.approved_by_name)}</div></div>
          <div class="field"><label>Approval Token</label><div class="field-value">${esc(sub.approval_token)}</div></div>
          <div class="field"><label>Date of Approval</label><div class="field-value">${esc(approvedDate)}</div></div>
        </div>
      </div>
    </div>`;
    const blocks = [{ html, width: 980, pick: '.sheet', place: { slice: true } }];
    const proofs = [];
    for (const t of trips) for (const r of (Array.isArray(t.receipts) ? t.receipts : [])) {
      if (!r?.path) continue; const url = await fileUrl('mtcf-receipts', r.path); if (!url) continue;
      proofs.push({ url, seq: proofs.length + 1, date: t.date || '', purpose: t.purpose || '', start: t.start_location || '', end: t.end_location || '', distance: fmt2(t.distance_km), remarks: t.remarks || '' });
    }
    const cellW = (210 - 24 - 8) / 3;
    for (let i = 0; i < proofs.length; i += 6) {
      const cells = proofs.slice(i, i + 6).map((it, j) => `<div class="c" style="left:${12 + (j % 3) * (cellW + 4)}mm;top:${20 + Math.floor(j / 3) * 126}mm">
        <div class="b"><img src="${esc(it.url)}" alt=""></div><img class="cap" src="${journeyCaption(it)}" alt=""></div>`).join('');
      blocks.push({ html: `<div class="fp-proof"><div class="t">${i ? 'Journey Proof (continued)' : 'Journey Proof'}</div><div class="l"></div>${cells}</div>`, width: '210mm', pick: '.fp-proof', place: { a4: true } });
    }
    return blocks;
  }
  // MEG-MTCF journeyCaptionDataUrl, unchanged
  function journeyCaption(it) {
    const cv = document.createElement('canvas'); cv.width = 900; cv.height = 210; const ctx = cv.getContext('2d');
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, cv.width, cv.height); ctx.textBaseline = 'top';
    const fit = (text, maxWidth) => { let out = String(text || ''); if (ctx.measureText(out).width <= maxWidth) return out; while (out.length > 1 && ctx.measureText(`${out}…`).width > maxWidth) out = out.slice(0, -1); return `${out}…`; };
    const max = 850;
    ctx.fillStyle = '#1c3d6e'; ctx.font = '700 28px "Segoe UI", Arial, sans-serif'; ctx.fillText(fit(`#${it.seq || ''}  ${it.date || ''}  ${it.distance || '0.00'} KM`, max), 24, 16);
    ctx.fillStyle = '#333333'; ctx.font = '500 24px "Segoe UI", Arial, sans-serif'; ctx.fillText(fit(it.purpose || '', max), 24, 62);
    ctx.font = '400 22px "Segoe UI", Arial, sans-serif'; ctx.fillText(fit(`${it.start || ''} → ${it.end || ''}`, max), 24, 105);
    if (it.remarks) { ctx.fillStyle = '#555555'; ctx.font = '600 21px "Segoe UI", Arial, sans-serif'; ctx.fillText(fit(`Remarks: ${it.remarks}`, max), 24, 148); }
    return cv.toDataURL('image/png');
  }

  // ================= SCF · MEG-SCF buildPrintPages + appendLoadedReceiptPages =================
  async function scf(sub) {
    const c = coOf(sub.company_code);
    const rows = (Array.isArray(sub.line_items) ? sub.line_items : []).map((l) => ({ ...l, amount: Number(l.amount || 0) }));
    const FIRST = 20, NEXT = 28; const pages = []; let i = 0, n = 0;
    while (i < rows.length || n === 0) { const lim = n === 0 ? FIRST : NEXT; pages.push(rows.slice(i, i + lim)); i += lim; n++; if (i >= rows.length) break; }
    const ref = `${c.code === 'HD' ? 'HDS' : c.code}-FORMS-SCF ${ver()}`;
    let running = 0; const out = [];
    pages.forEach((pageRows, idx) => {
      const bf = running; running += pageRows.reduce((a, r) => a + r.amount, 0); const last = idx === pages.length - 1;
      const head = idx === 0 ? `<div class="header"><div class="logo-box"><img src="${esc(c.logo)}"></div>
          <div class="title-box"><div class="company-name">${esc(c.name)}</div><div class="form-title">Claim Form for Misc. Expenses (SCF)</div></div>
          <div class="serial-box"><div class="label">Serial No.</div><div class="serial-display">${esc(sub.serial_no)}</div></div></div>
        <div class="meta-row"><div class="period-line">Claim for the period of <b>${esc(sub.period_from)}</b> to <b>${esc(sub.period_to)}</b>, <b>${esc(sub.period_year)}</b></div>
          <div class="pay-method"><b>Payment:</b> ${esc(sub.payment_method)}</div></div>
        <div class="claimant-row"><div><b>Claimed by:</b> ${esc(sub.claimed_by)}</div><div><b>Date:</b> ${esc(sub.claim_date)}</div></div>
        <div class="claimant-row" style="margin-top:4px;"><div><b>Bank:</b> ${esc(sub.bank_name)}</div><div><b>Account No:</b> ${esc(sub.bank_account_no || sub.bank_masked)}</div><div><b>Account Holder:</b> ${esc(sub.claimed_by)}</div></div>`
        : `<div class="header" style="border-bottom:1px solid var(--line);padding-bottom:8px;"><div class="logo-box" style="width:50px;height:50px;"><img src="${esc(c.logo)}"></div>
          <div class="title-box"><div class="company-name" style="font-size:15px;">${esc(c.name)} — (continued)</div></div></div>`;
      const before = pages.slice(0, idx).reduce((a, p) => a + p.length, 0);
      const body = pageRows.map((r, k) => `<tr><td class="no">${before + k + 1}</td><td>${esc(r.date)}</td><td>${esc(r.supplier)}</td>
        <td>${esc(r.item)}${r.remarks ? `<div style="font-size:9px;color:#555;margin-top:2px;">Remarks: ${esc(r.remarks)}</div>` : ''}</td><td class="amt">${r.amount.toFixed(2)}</td></tr>`).join('');
      const empty = Array.from({ length: Math.max(0, (idx === 0 ? FIRST : NEXT) - pageRows.length) }, () => '<tr class="empty-row"><td class="no"></td><td></td><td></td><td></td><td class="amt"></td></tr>').join('');
      const bfRow = idx > 0 ? `<tr><td colspan="4" style="text-align:right;font-weight:700;">Total Brought Forward:</td><td class="amt" style="font-weight:700;">${bf.toFixed(2)}</td></tr>` : '';
      const foot = last ? `<tr><td colspan="4" style="text-align:right;font-weight:700;border-top:2px solid var(--navy);">TOTAL:</td><td class="amt" style="font-weight:700;border-top:2px solid var(--navy);">RM ${running.toFixed(2)}</td></tr>`
        : `<tr><td colspan="4" style="text-align:right;font-weight:700;">Total Carried Forward:</td><td class="amt" style="font-weight:700;">${running.toFixed(2)}</td></tr>`;
      const office = last ? `<div class="office-section"><div class="note">* For office use only</div><div class="office-grid">
          <div><label>Prepared By</label><div>${esc(sub.prepared_by)}</div></div><div><label>Checked By</label><div>${esc(sub.checked_by)}</div></div><div><label>Date of Checking</label><div>${esc(sub.checked_date)}</div></div></div></div>` : '';
      out.push(`<div class="print-page" style="background:#fff;">${head}<div class="print-table-wrap"><table class="claim-table">
        <thead><tr><th style="width:26px">No.</th><th style="width:78px">Date</th><th style="width:190px">Supplier</th><th style="width:110px">Item(s) / Bill / Inv No</th><th style="width:90px">Amount (RM)</th></tr></thead>
        <tbody>${bfRow}${body}${empty}${foot}</tbody></table></div>${office}
        <div class="footer-stamp" style="position:static;margin-top:14px;"><span>Ref: ${esc(ref)}</span><span>Page ${idx + 1} of ${pages.length}</span></div>
        ${idx === 0 && String(sub.status || 'draft') === 'draft' ? '<div class="pdf-draft-watermark">DRAFT</div>' : ''}</div>`);
    });
    // supporting receipts: 3 × 2 per page; full-page (A4) receipts turned and two to a page, the first one using the space under a single row
    const items = []; rows.forEach((li) => (Array.isArray(li.receipts) ? li.receipts : []).forEach((r) => { if (r?.path) items.push({ path: r.path, isA4: !!r.isA4,
      caption: `${li.date || ''} · ${li.supplier || ''}${li.item ? ` — ${li.item}` : ''} · RM ${Number(li.amount || 0).toFixed(2)}` }); }));
    const loaded = []; for (const it of items) { const url = await fileUrl('scf-receipts', it.path); if (url) loaded.push({ ...it, url }); }
    const W = 182, GAP = 4, COLS = 3, PER = 6, CW = (W - GAP * (COLS - 1)) / COLS, IH = 100, CH = 9;
    const rp = []; let cur = null; const newPage = () => { cur = { title: rp.length ? 'Supporting Receipts (continued)' : 'Supporting Receipts', cells: [], n: 0 }; rp.push(cur); };
    const grid = loaded.filter((x) => !x.isA4), a4 = loaded.filter((x) => x.isA4);
    if (grid.length) { newPage(); grid.forEach((it) => { if (cur.n >= PER) newPage(); cur.cells.push(`<div class="receipt-print-cell" style="width:${CW}mm;min-height:${IH + CH}mm;break-inside:avoid;page-break-inside:avoid;">
      <div style="width:${CW}mm;height:${IH}mm;border:1px solid #ccc;border-radius:2px;display:flex;align-items:center;justify-content:center;overflow:hidden;background:#fafafa;"><img src="${esc(it.url)}" style="max-width:100%;max-height:100%;object-fit:contain;display:block;"></div>
      <div style="font-size:7pt;color:#555;margin-top:1mm;line-height:1.2;min-height:${CH - 1}mm;">${esc(it.caption)}</div></div>`); cur.n++; }); }
    if (a4.length) {
      const AW = W, AH = W * (148 / 210);
      const block = (it) => `<div class="receipt-print-cell" style="width:${AW}mm;grid-column:1 / -1;break-inside:avoid;page-break-inside:avoid;">
        <div style="width:${AW}mm;height:${AH}mm;border:1px solid #ccc;border-radius:2px;overflow:hidden;background:#fafafa;position:relative;"><img src="${esc(it.url)}" style="position:absolute;top:50%;left:50%;width:${AH}mm;height:${AW}mm;object-fit:contain;transform:translate(-50%,-50%) rotate(90deg);"></div>
        <div style="font-size:7pt;color:#555;margin-top:1mm;line-height:1.2;">${esc(it.caption)} (full page)</div></div>`;
      let k = 0; if (grid.length && cur.n >= 1 && cur.n <= COLS) cur.cells.push(block(a4[k++]));
      if (k < a4.length) { newPage(); let on = 0; for (; k < a4.length; k++) { if (on >= 2) { newPage(); on = 0; } cur.cells.push(block(a4[k])); on++; } }
    }
    rp.forEach((p) => out.push(`<div class="print-page"><div class="receipt-page-title">${esc(p.title)}</div>
      <div style="display:grid;grid-template-columns:repeat(${COLS}, ${CW}mm);column-gap:${GAP}mm;row-gap:${GAP}mm;align-items:start;">${p.cells.join('')}</div></div>`));
    return out.map((h) => ({ html: `<div class="pdf-export-stage">${h}</div>`, width: '210mm', pick: '.print-page', place: { a4: true } }));
  }

  // ================= TEC · MEG-TEC-V2 pages/page-template.html, as printed (A4 portrait, 6 mm margin) =================
  let tecStd = null;
  async function tecStandards() {
    if (tecStd) return tecStd;
    try { const { data } = await sb().from('tec_v2_standards').select('name').order('sort_order'); tecStd = (data || []).map((x) => x.name); } catch (e) { tecStd = []; }
    return tecStd;
  }
  async function tec(sub) {
    const c = coOf(sub.company_code); const all = await tecStandards(); const pages = Array.isArray(sub.pages) ? sub.pages : [];
    const now = new Date(); const stamp = `${pad2(now.getDate())}-${pad2(now.getMonth() + 1)}-${now.getFullYear()}-${pad2(now.getHours())}:${pad2(now.getMinutes())}`;
    const t12 = (v) => { const m = String(v || '').match(/^(\d{1,2}):(\d{2})/); if (!m) return ''; const h = +m[1]; return `${pad2(h % 12 || 12)}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`; };
    const per = new Map(); pages.forEach((p) => per.set(p.course_name, (per.get(p.course_name) || 0) + 1));
    return pages.map((p) => {
      const y = Number(p.year) || now.getFullYear(); const mi = Math.max(0, (Number(p.month) || 1) - 1);
      const wk = (d) => { const n = parseInt(d, 10); if (!n) return false; const w = new Date(y, mi, n).getDay(); return w === 0 || w === 6; };
      const days = (list) => Array.from({ length: 10 }, (_, j) => { const v = (list || [])[j] || ''; return `<td${wk(v) ? ' class="weekend"' : ''}><select class="day-select"><option>${esc(v)}</option></select></td>`; }).join('');
      const ss = Array.isArray(p.students) ? p.students : [];
      const std = [...new Set([...all, ...(p.standards || [])])];
      const fee = ss.reduce((a, s) => a + Number(s.monthlyFee || 0), 0), ven = ss.reduce((a, s) => a + Number(s.venueFee || 0), 0), net = ss.reduce((a, s) => a + Number(s.netPay || 0), 0);
      const rows = ss.map((s, j) => `<tr data-row="actual"><td rowspan="2" class="number-cell">${j + 1}</td><td rowspan="2"><input class="cell-input student-name" type="text" value="${esc(String(s.name || '').toUpperCase())}"></td>
          <td class="day-kind">Actual Day</td>${days(s.actualDays)}
          <td rowspan="2"><input class="cell-input money-input monthly-fee" type="text" value="${esc(fmt2(s.monthlyFee))}"></td><td rowspan="2"><input class="cell-input money-input venue-fee" type="text" value="${esc(fmt2(s.venueFee))}"></td>
          <td rowspan="2"><input class="cell-input money-input net-pay" type="text" value="${esc(fmt2(s.netPay))}"></td></tr>
        <tr data-row="replacement"><td class="day-kind">Replacement Day</td>${days(s.replacementDays)}</tr>`).join('');
      const html = `<article class="paper"><header class="document-header">
        <div class="header-top-row"><div class="header-logo-badge"><img src="${esc(c.logo)}" alt="Company logo"></div>
          <div class="header-title-block"><div class="company-name-display">${esc(c.tec.toUpperCase())}</div>
            <div class="document-title"><div>MONTHLY TUITION / ENRICHMENT CLASS PAYMENT</div><div class="year-line"><span>FOR THE YEAR</span><input class="year-input" id="year" type="text" value="${esc(p.year)}"></div></div></div></div>
        <div class="meta-grid">
          <div class="meta-column">
            <div class="field-row"><label>Teacher's Name :</label><input id="teacherName" type="text" value="${esc(sub.teacher_name)}"></div>
            <div class="field-row"><label>Course :</label><select id="course"><option>${esc(p.course_name)}</option></select></div>
            <div class="field-row"><label>Time Duration :</label><div class="time-fields"><span>From</span><input id="timeFrom" type="text" value="${esc(t12(p.time_from))}"><span>To</span><input id="timeTo" type="text" value="${esc(t12(p.time_to))}"></div></div>
          </div>
          <div class="meta-column">
            <div class="field-row"><label>Serial No :</label><input id="serialNo" type="text" value="${esc(p.serial_no)}"></div>
            <div class="field-row"><label>Payment Mode :</label><select id="paymentMode"><option>${esc(p.payment_mode || sub.payment_mode || 'Fixed Monthly')}</option></select></div>
            <div class="field-row"><label>Standard :</label><div id="standardCheckboxes" class="standard-checkbox-group">${std.map((x) => `<label><input type="checkbox"${(p.standards || []).includes(x) ? ' checked' : ''}>${esc(x)}</label>`).join('')}</div></div>
          </div>
        </div></header>
        <div class="table-wrap"><table>
          <colgroup><col class="col-no"><col class="col-name"><col class="col-kind"><col class="col-day" span="10"><col class="col-money"><col class="col-money"><col class="col-money"></colgroup>
          <thead><tr><th rowspan="2">No.</th><th rowspan="2">Student's Name</th><th rowspan="2">Month Of</th><th class="month-header" colspan="10"><select id="month"><option>${esc((MONTHS[mi] || '').toUpperCase())}</option></select></th>
            <th rowspan="2">Monthly<br>Fee</th><th rowspan="2">Venue Fee /<br>Head Count</th><th rowspan="2">Net Pay</th></tr>
            <tr id="slotHeaders">${Array.from({ length: 10 }, (_, j) => `<th class="slot-header">${j + 1}</th>`).join('')}</tr></thead>
          <tbody id="studentRows">${rows}</tbody>
          <tfoot><tr><td colspan="13" class="total-label">Total</td><td id="totalFee" class="total-number">${fmt2(fee)}</td><td id="totalVenue" class="total-number">${fmt2(ven)}</td><td id="totalNet" class="total-number">${fmt2(p.subtotal != null ? p.subtotal : net)}</td></tr></tfoot>
        </table></div>
        ${p.is_group_total_page ? `<section id="courseGroupGrandTotal" class="grand-total-panel" style="display:flex;"><span class="grand-total-label">GRAND TOTAL (${esc(p.course_name)}) — ${per.get(p.course_name)} page(s)</span><span class="grand-total-value">RM ${esc(fmt2(p.group_total))}</span></section>` : ''}
        <footer class="document-footer"><p class="note">** Please complete all required data, select “Print / PDF” and save the file, then forward the completed form to MyEden.</p>
          <div class="footer-row"><div class="footer-meta"><span>MYEDEN Digital Payment Form · <strong>${esc(`MEG-TEC-V2 · CMS ${ver()}`)}</strong></span><span class="generated-stamp">Timestamp: <strong>${esc(stamp)}</strong></span></div>
          <span>Ref: <strong>MEG-FRM-OR-001 v1.0</strong></span></div></footer></article>`;
      return { html, width: '198mm', pick: '.paper', place: { margin: 6 } };
    });
  }

  // ================= Purchase request · MEG-PRFAF buildPrfafSheetHtml =================
  const PR_ST = { draft: 'DRAFT', finance: 'WITH FINANCE', directors: 'WITH DIRECTORS', approved: 'APPROVED', released: 'RELEASED', purchasing: 'PURCHASING', settlement: 'SETTLEMENT',
    closed: 'CLOSED', returned: 'RETURNED', disapproved: 'DISAPPROVED', cancelled: 'CANCELLED' };
  const PR_PAY = { advance: 'Advance', supplier: 'Supplier', reimburse: 'Reimburse' };
  async function pr(r) {
    const c = coOf(r.company_code); const items = (r.items || []).filter((i) => !i.removed);
    const photos = await Promise.all(items.map(async (i) => [await fileUrl('pr-files', i.photo_path), await fileUrl('pr-files', i.receipt_path)]));
    const signers = (r.approvals || []).filter((a) => a && a.name); const lastAt = signers.length ? signers[signers.length - 1].at : null;
    const approvedDate = lastAt ? dmy(new Date(new Date(lastAt).getTime() + 8 * 36e5).toISOString().slice(0, 10)) : '';
    const num = (v) => (v == null || v === '' ? 0 : Number(v));
    const projTotal = items.reduce((s, i) => s + num(i.qty) * num(i.est_unit), 0); const actTotal = items.reduce((s, i) => s + num(i.act_qty) * num(i.act_unit), 0);
    const photoCell = (url) => (url ? `<img src="${esc(url)}" style="width:44px;height:44px;object-fit:cover;border-radius:4px;border:1px solid var(--line);display:block;">` : '<span style="color:var(--muted);">—</span>');
    const rowsHtml = items.map((it, k) => `<tr><td style="text-align:left;">${esc(it.description)}</td>
      <td class="num">${num(it.qty)} × RM ${fmt2(it.est_unit)}</td><td class="num">RM ${fmt2(num(it.qty) * num(it.est_unit))}</td>
      <td class="num">${it.act_qty != null ? `${num(it.act_qty)} × RM ${fmt2(it.act_unit)}` : '—'}</td><td class="num">${it.act_qty != null ? `RM ${fmt2(num(it.act_qty) * num(it.act_unit))}` : '—'}</td>
      <td style="text-align:center;">${photoCell(photos[k][0])}</td><td style="text-align:center;">${photoCell(photos[k][1])}</td></tr>`).join('');
    const html = `<div class="sheet" style="max-width:980px;">
      <div style="text-align:right;font-size:11px;color:#999;margin-bottom:6px;">${esc(`MEG-PRFAF · CMS ${ver()}`)}</div>
      <div class="form-header">
        <div class="logo-box"><img src="${esc(c.logo)}" alt="${esc(c.name)}"></div>
        <div class="title-box"><div class="company-name">${esc(c.name)}</div><div class="form-title">Purchase Request &amp; Funding Application (PRFAF)</div></div>
        <div class="serial-box"><div class="label">Serial No.</div><div class="serial-display">${esc(r.pr_no || 'Draft — not yet submitted')}</div></div>
      </div>
      <table><tbody>
        <tr><td style="text-align:left;width:25%;"><strong>Requested By</strong></td><td style="text-align:left;">${esc(r.requester_name)}</td><td style="text-align:left;width:25%;"><strong>Department</strong></td><td style="text-align:left;">${esc(r.department || '—')}</td></tr>
        <tr><td style="text-align:left;"><strong>Purpose</strong></td><td colspan="3" style="text-align:left;">${esc(r.purpose)}</td></tr>
      </tbody></table>
      <table style="margin-top:10px;"><thead><tr><th>Item</th><th>Projected</th><th>Proj. Subtotal</th><th>Actual</th><th>Actual Subtotal</th><th>Ref Photo</th><th>Receipt</th></tr></thead><tbody>${rowsHtml}</tbody></table>
      <div style="display:flex;justify-content:flex-end;margin-top:10px;"><table style="width:auto;min-width:260px;"><tbody>
        <tr><td style="text-align:right;border-bottom:none;"><strong>Projected Total :</strong></td><td class="num" style="border-bottom:none;">RM ${fmt2(projTotal)}</td></tr>
        <tr><td style="text-align:right;border-bottom:none;"><strong>Actual Total :</strong></td><td class="num" style="border-bottom:none;">RM ${fmt2(actTotal)}</td></tr>
      </tbody></table></div>
      <div style="display:flex;justify-content:space-between;margin-top:10px;font-size:13px;"><span>Requested: RM ${fmt2(r.est_total)} (${esc(PR_PAY[r.pay_type] || r.pay_type || '')})</span><span>Status: <strong>${esc(PR_ST[r.status] || String(r.status || 'draft').toUpperCase())}</strong></span></div>
      ${Number(r.released_amount) ? `<p style="font-size:13px;">Disbursed: RM ${fmt2(r.released_amount)} (${esc(PR_PAY[r.pay_type] || '')}) — ref ${esc(r.release_ref || '—')}</p>` : ''}
      ${r.disapprove_reason ? `<p style="font-size:13px;color:var(--out);">Disapproved: ${esc(r.disapprove_reason)}</p>` : ''}
      <div style="display:flex;justify-content:space-between;margin-top:40px;">
        <div style="width:45%;border-top:1px solid #333;padding-top:6px;font-size:12px;">Requester's Signature</div>
        <div style="width:45%;"><h3 style="margin:0 0 8px;font-size:14px;">Approved By</h3>
          <div style="font-size:12px;margin-bottom:4px;">Check by: ${esc(signers.map((a) => a.name).join(' & '))}</div>
          <div style="font-size:12px;margin-bottom:4px;">Approval Token: ${esc(signers.length ? 'Signed in the CMS' : '(token stamped on approval)')}</div>
          <div style="font-size:12px;">Date of Approval: ${esc(approvedDate)}</div></div>
      </div>
    </div>`;
    return [{ html, width: 980, pick: '.sheet', place: { slice: true } }];
  }

  const RENDER = { otcf, mtcf, scf, tec, pr };
  const supported = (form) => !!RENDER[key(form)];

  // ---- the print frame: the form's own CSS and html2canvas, nothing else
  let frameP = null;
  function frame() {
    if (frameP) return frameP;
    frameP = new Promise((ok, no) => {
      const f = document.createElement('iframe'); f.setAttribute('aria-hidden', 'true'); f.tabIndex = -1;
      f.style.cssText = 'position:fixed;left:-30000px;top:0;width:1300px;height:2000px;border:0;visibility:hidden;pointer-events:none;';
      f.srcdoc = `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="${ROOT}css/form-print.css?v=${encodeURIComponent(ver())}">
        <script src="${ROOT}vendor/html2canvas.min.js"><\/script><script src="${ROOT}vendor/jspdf.umd.min.js"><\/script>
        <style>html,body{margin:0;padding:0;background:#fff}</style></head><body></body></html>`;
      f.onload = () => (f.contentWindow.html2canvas && f.contentWindow.jspdf ? ok(f) : no(new Error('The print tools did not load. Check your connection and try again.')));
      document.body.appendChild(f);
    }).catch((e) => { frameP = null; throw e; });
    return frameP;
  }
  const settle = (root) => Promise.all([...root.querySelectorAll('img')].map((im) => (im.complete ? null : new Promise((ok) => { im.onload = ok; im.onerror = ok; setTimeout(ok, 12000); }))));

  // html2canvas misplaces the text of text boxes and drop-downs, so each one becomes a plain box with the same size, look and text
  const KEEP = ['box-sizing', 'width', 'height', 'min-width', 'min-height', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
    'border-top', 'border-right', 'border-bottom', 'border-left', 'border-radius', 'background-color', 'background-image', 'color', 'font-family', 'font-size', 'font-weight', 'font-style',
    'letter-spacing', 'text-transform', 'font-variant-numeric', 'box-shadow', 'vertical-align', 'flex', 'flex-basis', 'flex-grow', 'flex-shrink', 'align-self'];
  function freeze(d, w) {
    d.querySelectorAll('input:not([type=checkbox]):not([type=radio]), select').forEach((el) => {
      const cs = w.getComputedStyle(el); const r = el.getBoundingClientRect();
      const box = d.createElement('div'); box.className = el.className; if (el.id) box.id = el.id;
      const align = el.tagName === 'SELECT' && cs.textAlignLast && cs.textAlignLast !== 'auto' && cs.textAlignLast !== 'start' ? cs.textAlignLast : cs.textAlign;
      box.style.cssText = KEEP.map((k) => `${k}:${cs.getPropertyValue(k)}`).join(';') + `;box-sizing:border-box;width:${r.width}px;height:${r.height}px;min-width:0;display:${cs.display === 'block' ? 'flex' : 'inline-flex'};align-items:center;`
        + `justify-content:${/center/.test(align) ? 'center' : /right|end/.test(align) ? 'flex-end' : 'flex-start'};overflow:hidden;white-space:nowrap;line-height:1.15`;
      box.textContent = el.tagName === 'SELECT' ? (el.options[el.selectedIndex]?.text || '') : el.value;
      el.replaceWith(box);
    });
  }

  // A4 page pictures (JPEG data URLs), placed the way each app placed them
  const PW = 1654, PH = Math.round(PW * 297 / 210), PX = PW / 210;   // pixels per mm
  async function pages(form, sub) {
    const f = key(form); if (!RENDER[f]) throw new Error('This form has no original printout.');
    const blocks = await RENDER[f](sub || {}); api.lastHtml = blocks.map((b) => b.html).join('\n'); const fr = await frame(); const d = fr.contentDocument; const w = fr.contentWindow;
    const out = []; const blank = () => { const cv = document.createElement('canvas'); cv.width = PW; cv.height = PH; const g = cv.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, PW, PH); out.push(cv); return g; };
    for (const b of blocks) {
      d.body.innerHTML = `<div class="fp-${f}" style="width:${typeof b.width === 'number' ? `${b.width}px` : b.width}">${b.html}</div>`;
      await settle(d.body); if (d.fonts?.ready) await d.fonts.ready;
      freeze(d, w);
      const el = d.body.querySelector(b.pick) || d.body.firstElementChild;
      const cv = await w.html2canvas(el, { scale: 2, useCORS: true, backgroundColor: '#ffffff', logging: false, imageTimeout: 15000 });
      const p = b.place;
      if (p.a4) { blank().drawImage(cv, 0, 0, PW, PH); continue; }
      if (p.fit != null) { const mw = 210 - p.fit * 2, mh = 297 - p.fit * 2; const r = Math.min(mw / cv.width, mh / cv.height); const ww = cv.width * r, hh = cv.height * r;
        blank().drawImage(cv, (210 - ww) / 2 * PX, (297 - hh) / 2 * PX, ww * PX, hh * PX); continue; }
      const m = p.margin || 0; const ww = 210 - m * 2; const hh = cv.height * ww / cv.width; const room = 297 - m * 2;   // full width, cut into A4 lengths
      for (let y = 0; y < hh - 0.5 || y === 0; y += room) {
        const g = blank(); g.save(); g.beginPath(); g.rect(m * PX, m * PX, ww * PX, room * PX); g.clip(); g.drawImage(cv, m * PX, (m - y) * PX, ww * PX, hh * PX); g.restore();
      }
    }
    d.body.innerHTML = '';
    return out.map((cv) => cv.toDataURL('image/jpeg', 0.92));
  }

  async function pdf(form, sub, opts = {}) {
    const imgs = await pages(form, sub); const fr = await frame();
    const doc = new fr.contentWindow.jspdf.jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait', compress: true });
    imgs.forEach((im, i) => { if (i) doc.addPage('a4', 'portrait'); doc.addImage(im, 'JPEG', 0, 0, 210, 297, undefined, 'FAST'); });
    return { blob: doc.output('blob'), fileName: fileName(form, sub, opts), pages: imgs.length };
  }

  // ---- the viewer: the pages as they will print, with Print and Download PDF
  function open(form, sub, opts = {}) {
    const name = fileName(form, sub, opts);
    const ov = document.createElement('div'); ov.className = 'doc-ov fp-ov';
    ov.innerHTML = `<div class="print-bar no-print"><button type="button" class="btn" data-back>‹ Back</button><span class="muted small fp-name"></span>
      <button type="button" class="btn" data-dl disabled>Download PDF</button><button type="button" class="btn primary" data-pr disabled>Print</button></div>
      <div class="doc-scroll"><div class="fp-pages"><p class="muted fp-wait">Preparing the printout…</p></div></div>`;
    ov.querySelector('.fp-name').textContent = name;
    document.body.appendChild(ov); document.body.classList.add('doc-ov-on'); const prev = document.title; document.title = name.replace(/\.pdf$/, '');
    let imgs = null; let closed = false;
    const shut = () => { if (closed) return false; closed = true; ov.remove(); document.body.classList.remove('doc-ov-on'); document.title = prev; return true; };
    const done = () => { if (shut()) opts.onClose?.(); };
    ov.querySelector('[data-back]').addEventListener('click', done);
    window.addEventListener('hashchange', shut, { once: true });   // moving to another page just closes it
    pages(form, sub).then((list) => {
      if (closed) return; imgs = list;
      ov.querySelector('.fp-pages').innerHTML = list.map((src, i) => `<img class="fp-page" src="${src}" alt="Page ${i + 1}">`).join('');
      ov.querySelectorAll('[data-dl],[data-pr]').forEach((b) => { b.disabled = false; });
    }).catch((e) => { ov.querySelector('.fp-pages').innerHTML = `<p class="bad-txt">${esc(e.message || e)}</p>`; });
    ov.querySelector('[data-dl]').addEventListener('click', async (e) => {
      const b = e.currentTarget; b.disabled = true;
      try { const fr = await frame(); const doc = new fr.contentWindow.jspdf.jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait', compress: true });
        imgs.forEach((im, i) => { if (i) doc.addPage('a4', 'portrait'); doc.addImage(im, 'JPEG', 0, 0, 210, 297, undefined, 'FAST'); });
        const url = URL.createObjectURL(doc.output('blob')); const a = document.createElement('a'); a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 60000);
      } catch (x) { window.alert?.(x.message); } b.disabled = false;
    });
    ov.querySelector('[data-pr]').addEventListener('click', () => printImages(imgs, name));
    return ov;
  }
  function printImages(imgs, name) {
    const f = document.createElement('iframe'); f.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;';
    f.srcdoc = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(name.replace(/\.pdf$/, ''))}</title><style>@page{size:A4 portrait;margin:0}html,body{margin:0;padding:0}
      img{display:block;width:210mm;height:297mm;page-break-after:always;break-after:page}img:last-child{page-break-after:auto;break-after:auto}</style></head>
      <body>${imgs.map((s) => `<img src="${s}">`).join('')}</body></html>`;
    f.onload = () => { setTimeout(() => { try { f.contentWindow.focus(); f.contentWindow.print(); } catch (e) { window.print(); } setTimeout(() => f.remove(), 60000); }, 200); };
    document.body.appendChild(f);
  }

  const api = { supported, fileName, pages, pdf, open, period, lastHtml: '' };   // lastHtml: the markup of the last printout (checks)
  window.CMS_FORM_PRINT = api;
}());
