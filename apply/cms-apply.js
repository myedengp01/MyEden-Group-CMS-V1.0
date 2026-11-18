/*
 * MyEden Group CMS · Apply Now (PRI-024, v2026.11.18)
 * The MEG-EAF V2 application form, unchanged, opened from the CMS. This file adds:
 *  - the apply-link gate (Apply Now stays "invitation only": an applicant needs a valid link from HR; CMS staff with
 *    Recruitment can always open it), checked and enforced by the server (cms_apply_gate / cms_apply_submit);
 *  - the CMS sign-in (same site, key "cms.auth") for staff, so HR fills in, views and prints without signing in again;
 *  - HR modes: ?view=<application> (the full application as submitted, read-only, print) and ?draft=<draft> (edit,
 *    save, submit a draft).
 */
(function () {
  'use strict';
  var KEY = 'cms.auth';
  var Q = new URLSearchParams(location.search);
  var TOKEN = Q.get('invite') || '';
  var VIEW = Q.get('view') || '';
  var DRAFT = Q.get('draft') || '';
  var STAFF = false; var GATE = null;
  window.CMS_APPLY = { mode: VIEW ? 'view' : DRAFT ? 'draft' : 'apply' };

  function readSession() { try { var s = JSON.parse(localStorage.getItem(KEY) || 'null'); return s && s.currentSession ? s.currentSession : s; } catch (e) { return null; } }
  var SESSION = readSession();
  function storeSession(x) { try { var o = readSession() || {}; o.access_token = x.access_token; o.refresh_token = x.refresh_token; if (x.expires_in) o.expires_at = Math.floor(Date.now() / 1000) + x.expires_in; if (x.user) o.user = x.user; localStorage.setItem(KEY, JSON.stringify(o)); } catch (e) { /* the sign-in still works this time */ } }
  function hdr(auth) { var h = { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY }; if (auth && SESSION && SESSION.access_token) h.Authorization = 'Bearer ' + SESSION.access_token; return h; }
  function refresh() {
    var fresh = readSession();
    if (fresh && fresh.access_token && SESSION && fresh.access_token !== SESSION.access_token) { SESSION = fresh; return Promise.resolve(); }   // the CMS already refreshed it
    if (!SESSION || !SESSION.refresh_token) return Promise.reject(new Error('signed out'));
    return fetch(SUPABASE_URL + '/auth/v1/token?grant_type=refresh_token', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY }, body: JSON.stringify({ refresh_token: SESSION.refresh_token }) })
      .then(function (r) { return r.json().then(function (b) { if (!r.ok || !b.access_token) throw new Error('signed out'); SESSION = b; storeSession(b); }); });
  }
  // every call goes with the CMS sign-in when there is one; an expired one is refreshed once, else the call goes as a visitor
  function rpc(fn, args, retried) {
    var auth = !!(SESSION && SESSION.access_token);
    return fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'POST', headers: hdr(auth), body: JSON.stringify(args || {}) }).then(function (r) {
      return r.text().then(function (txt) {
        var body = null; try { body = JSON.parse(txt); } catch (e) { /* plain text */ }
        if (r.status === 401 && auth && !retried) return refresh().then(function () { return rpc(fn, args, true); }, function () { SESSION = null; return rpc(fn, args, true); });
        if (!r.ok) { var msg = (body && (body.message || body.hint)) || ('HTTP ' + r.status); throw new Error(msg); }
        return body;
      });
    });
  }
  window.sbRpc = rpc;
  window.sbHeaders = function () { return hdr(true); };
  window.CMS_APPLY.rpc = rpc;

  // ---------------------------------------------------------------- screens
  function cover(html) {
    var o = document.getElementById('cmsGate');
    if (!o) { o = document.createElement('div'); o.id = 'cmsGate'; o.setAttribute('style', 'position:fixed;inset:0;background:rgba(255,255,255,.99);z-index:5000;display:flex;align-items:center;justify-content:center;padding:24px;font-family:inherit'); document.body.appendChild(o); }
    o.innerHTML = '<div style="max-width:460px;text-align:center;font-size:14px;line-height:1.6;color:#333">' + html + '</div>'; o.style.display = 'flex';
  }
  function uncover() { var o = document.getElementById('cmsGate'); if (o) o.style.display = 'none'; }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function banner(html, tone) {
    var b = document.createElement('div'); b.id = 'cmsBanner';
    b.setAttribute('style', 'margin:8px auto;max-width:900px;padding:8px 12px;border-radius:8px;font-size:12px;line-height:1.5;' + (tone === 'view' ? 'background:#e8f0fe;border:1px solid #b9cbea;color:#174ea6' : 'background:#e7f6ec;border:1px solid #b6dfc3;color:#1b5e20'));
    b.className = 'cms-banner'; b.innerHTML = html;
    var form = document.getElementById('appForm'); form.parentNode.insertBefore(b, form);
  }
  function show(id, on) { var e = document.getElementById(id); if (e) { e.hidden = !on; e.style.display = on ? '' : 'none'; } }
  function lockForm() {   // view only: nothing can be typed or changed; Print stays
    var f = document.getElementById('appForm');
    Array.prototype.forEach.call(f.querySelectorAll('input,select,textarea,button'), function (x) { x.disabled = true; });
    var c = document.getElementById('sigCanvas'); if (c) c.style.pointerEvents = 'none';
    Array.prototype.forEach.call(document.querySelectorAll('.photo-btns,.add-row-btn,.sig-btns'), function (x) { x.style.display = 'none'; });
  }
  var printCss = document.createElement('style'); printCss.textContent = '@media print{#cmsBanner,#cmsGate{display:none!important}}'; document.head.appendChild(printCss);

  // ---------------------------------------------------------------- the gate and the modes
  var origResume = window.tryAutoResume;
  window.tryAutoResume = function () {};   // replaced by start() below (runs after the form, the signature pad and the extension are ready)
  var origLoad = window.onload;
  window.onload = function () {
    if (typeof origLoad === 'function') origLoad();
    cover('<p>Opening the application form…</p>');
    setTimeout(start, 450);
  };

  function start() {
    rpc('cms_apply_gate', { p_token: TOKEN || null }).then(function (g) {
      GATE = g || {}; STAFF = !!GATE.staff;
      if ((VIEW || DRAFT) && !STAFF) { cover('<h3 style="margin-bottom:8px">Sign in to the CMS first</h3><p>This page shows an application to HR. Sign in to the MyEden Group CMS, then open it again from Recruitment › Applications.</p><p style="margin-top:12px"><a href="../app/">Open the CMS</a></p>'); return; }
      if (!GATE.ok) {
        cover(GATE.reason === 'closed'
          ? '<h3 style="margin-bottom:8px">Applications are not open</h3><p>MyEden Group is not taking applications through this form at the moment. Please contact our HR team.</p>'
          : '<h3 style="margin-bottom:8px">Please use the link from HR</h3><p>This application form opens from the link MyEden Group HR sends you.' + (GATE.reason === 'link' ? ' This link has expired, was already used or was withdrawn.' : '') + ' Please ask HR for a new link.</p><p style="margin-top:12px;font-size:12px;color:#777">HR staff: sign in to the CMS first.</p>');
        return;
      }
      uncover();
      if (STAFF) { show('btnDashboard', true); show('btnResumeDraft', false); }
      if (VIEW) return openView();
      if (DRAFT) return openDraft();
      if (GATE.company) {   // the link is for one company: the form is for that company
        var sel = document.getElementById('companySelect');
        if (sel && sel.value !== GATE.company) { sel.value = GATE.company; if (typeof window.onEafCompanyChange === 'function') window.onEafCompanyChange(); }
        if (sel) sel.disabled = true;
      }
      if (STAFF) banner('Signed in to the CMS as <b>' + esc(GATE.name || '') + '</b> — filling in an application for an applicant. It goes straight to Recruitment › Applications.');
      if (typeof origResume === 'function') origResume();
    }).catch(function (e) {
      cover('<h3 style="margin-bottom:8px">The form could not open</h3><p>' + esc(e.message) + '</p><p style="margin-top:12px"><button type="button" onclick="location.reload()">Try again</button></p>');
    });
  }

  function openView() {
    rpc('cms_apply_application', { p_id: VIEW }).then(function (a) {
      window.scheduleAutoSave = function () {};   // nothing of an applicant is kept on this device
      restoreFormData(a.payload || {});
      document.title = (a.name || 'Application') + ' — Employment Application';
      ['btnSaveDraft', 'btnResumeDraft', 'btnSubmit'].forEach(function (id) { show(id, false); });
      Array.prototype.forEach.call(document.querySelectorAll('.action-bar .btn-action'), function (b) { if (/Load from JSON/.test(b.textContent)) b.style.display = 'none'; });
      var bar = document.querySelector('.action-bar'); var pb = document.createElement('button'); pb.className = 'btn-action'; pb.type = 'button'; pb.id = 'btnPrintApp';
      pb.setAttribute('style', 'background:#1565c0;color:#fff'); pb.innerHTML = '&#128424; Print / Save as PDF'; pb.onclick = function () { window.print(); };
      bar.insertBefore(pb, bar.firstChild);
      banner('<b>' + esc(a.name || '') + '</b> · the application as submitted' + (a.submitted_at ? ' on ' + esc(new Date(a.submitted_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })) : '') + ' · view only. Office Use, the offer letter and hiring are in the CMS application window.', 'view');
      setTimeout(lockForm, 1200);   // after the post choices are put back
    }).catch(function (e) { cover('<h3 style="margin-bottom:8px">Could not open the application</h3><p>' + esc(e.message) + '</p>'); });
  }

  function openDraft() {
    rpc('cms_apply_draft', { p_id: DRAFT }).then(function (d) {
      window.scheduleAutoSave = function () {};
      if (d.submitted) { restoreFormData(d.payload || {}); banner('This draft was already submitted as an application.', 'view'); ['btnSaveDraft', 'btnSubmit'].forEach(function (id) { show(id, false); }); setTimeout(lockForm, 1200); return; }
      restoreFormData(d.payload || {}); window.DRAFT_CODE = d.code;
      banner('Draft <b>' + esc(d.code) + '</b> · HR is completing it. <b>Save Draft</b> keeps it; <b>Submit Application</b> sends it to Recruitment › Applications.');
      window.saveDraftServer = function () {
        var btn = document.getElementById('btnSaveDraft'); btn.disabled = true;
        rpc('cms_apply_draft_save', { p_id: DRAFT, p_data: collectFormData() }).then(function () { document.getElementById('autosaveStatus').textContent = 'Draft saved ✓ ' + new Date().toLocaleTimeString(); })
          .catch(function (e) { alert('Could not save the draft: ' + e.message); }).finally(function () { btn.disabled = false; });
      };
      window.submitApplication = function () { submitWith(function (payload) { return rpc('cms_apply_draft_submit', { p_id: DRAFT, p_data: payload }); }); };
    }).catch(function (e) { cover('<h3 style="margin-bottom:8px">Could not open the draft</h3><p>' + esc(e.message) + '</p>'); });
  }

  // ---------------------------------------------------------------- submitting (same checks and wording as MEG-EAF V2)
  function companyName() { var c = (typeof EAF_COMPANIES !== 'undefined' && EAF_COMPANIES[(document.getElementById('companySelect') || {}).value || 'meg']) || {}; return c.name || 'MyEden Group'; }
  function submitWith(send) {
    var errs = validateDraft(); if (errs.length > 0) { showErrors(errs); return; }
    clearErrors();
    if (!confirm('Submit ' + (STAFF ? 'this application' : 'your application') + ' to ' + companyName() + '?\n\nPlease make sure all information is correct — the application cannot be changed after submission.')) return;
    var btn = document.getElementById('btnSubmit'); btn.disabled = true; btn.textContent = 'Submitting...';
    send(collectFormData()).then(function () {
      try { localStorage.removeItem('meg_draft'); localStorage.removeItem('meg_draft_code'); localStorage.removeItem('meg_draft_time'); } catch (e) { /* nothing kept */ }
      var ov = document.getElementById('successOverlay');
      if (STAFF) { var p = ov.querySelector('p'); if (p) p.innerHTML = 'The application is in <b>Recruitment › Applications</b>.'; var a = document.createElement('p'); a.innerHTML = '<a href="../app/#/applications">Back to the CMS</a>'; ov.querySelector('div').appendChild(a); }
      ov.style.display = 'flex';
    }).catch(function (err) {
      alert('Submission failed: ' + err.message + '.\nYour information is still on this page — nothing has been lost. Please try again, or save a draft and contact HR.');
    }).finally(function () { btn.disabled = false; btn.innerHTML = '&#128228; Submit Application'; });
  }
  window.submitApplication = function () { submitWith(function (payload) { return rpc('cms_apply_submit', { p_payload: payload, p_token: TOKEN || null, p_draft_code: window.DRAFT_CODE || null }); }); };
})();
