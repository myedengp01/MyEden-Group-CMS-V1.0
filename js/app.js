// MyEden Group CMS V1.0 · app: sign-in, sidebar, top bar, search (Ctrl+K), router and pages.
// Live pages (Phase 0): Dashboard, View People, Organisation, Approvals, Users & Roles, Companies, Audit Log, Export.
(function () {
  'use strict';
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const store = {
    get(k, d) { try { const v = localStorage.getItem('cms.' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('cms.' + k, JSON.stringify(v)); } catch (e) { /* storage blocked: keep in memory only */ } },
  };
  const API = window.CMS_API;
  const CFG = window.CMS_CONFIG;

  // ---------------------------------------------------------------- menu index
  const PAGES = new Map(); // route -> { ...item, group, section }
  for (const sec of window.CMS_MENU) for (const it of sec.items) {
    if (it.group) for (const sub of it.items) PAGES.set(sub.route, { ...sub, group: it.group, groupIcon: it.icon, section: sec.section });
    else PAGES.set(it.route, { ...it, section: sec.section });
  }
  const groupOf = (route) => PAGES.get(route)?.group || null;
  const moduleOf = (route) => window.CMS_MODULE_OF[route] || route;

  // ---------------------------------------------------------------- state
  const state = {
    collapsed: store.get('collapsed', false),
    theme: store.get('theme', (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light'),
    open: new Set(store.get('openGroups', ['People & Employment'])),
    route: 'dashboard',
    access: null,         // cms_my_access()
    self: null,           // cms_my_self(): the person's own self-service parts
    dash: null,           // last cms_dashboard()
    people: null,         // cache for search
    org: null,
    renderId: 0,
  };
  const applyTheme = () => { document.documentElement.dataset.theme = state.theme; };
  applyTheme();

  // permissions
  const acts = (module) => (state.access?.permissions?.[module] || '');
  const can = (module, a = 'V') => !!state.access?.is_super_admin || acts(module).includes(a);
  const selfOn = (part) => !!state.self?.parts?.includes(part);
  const hasSelf = () => !!state.self?.parts?.length;
  const canRoute = (route) => {
    const it = PAGES.get(route);
    if (it?.self) return it.self === '*' ? hasSelf() : [].concat(it.self).some(selfOn);
    return can(moduleOf(route), 'V');
  };
  const homeRoute = () => (canRoute('dashboard') ? 'dashboard' : hasSelf() ? 'me' : 'dashboard');
  const isSuper = () => !!state.access?.is_super_admin;

  // ---------------------------------------------------------------- small helpers
  const initials = (n) => String(n || '?').trim().split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase() || '?';
  const num = (n) => (n === null || n === undefined || n === '') ? '—' : Number(n).toLocaleString('en-MY');
  const money = (n) => 'RM ' + Number(n || 0).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // amounts typed with or without thousands separators (2,300.50 / 2300.5)
  const mval = (v) => Number(String(v ?? '').replace(/[,\s]|RM/gi, ''));
  // money boxes show 0,000.00 when you leave them and the plain number while you type
  document.addEventListener('focusout', (e) => { const t = e.target; if (t.matches?.('input[data-money]') && t.value.trim() !== '' && !isNaN(mval(t.value))) t.value = mval(t.value).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); });
  document.addEventListener('focusin', (e) => { const t = e.target; if (t.matches?.('input[data-money]') && t.value) { t.value = String(mval(t.value)); t.select(); } });
  const fmtDate = (d) => d.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
  const fmtTime = (d) => d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  const dShort = (s) => { if (!s) return '—'; const d = new Date(s); return isNaN(d) ? esc(s) : d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); };
  const dtShort = (s) => { if (!s) return '—'; const d = new Date(s); return isNaN(d) ? esc(s) : `${d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })} ${fmtTime(d)}`; };
  const ago = (s) => {
    if (!s) return 'never'; const m = Math.round((Date.now() - new Date(s)) / 60000);
    if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; const h = Math.round(m / 60); if (h < 24) return `${h} h ago`;
    const d = Math.round(h / 24); return d < 60 ? `${d} days ago` : dShort(s);
  };
  // employee names are shown in upper case everywhere in the CMS
  const UP = (v) => (v == null || v === '' ? v : String(v).toUpperCase());
  const upKeys = (o, ...keys) => { if (o) keys.forEach((k) => { if (o[k]) o[k] = UP(o[k]); }); return o; };
  const upUser = (u) => { if (!u) return u; upKeys(u, 'name'); upKeys(u.person, 'name'); upKeys(u.suggested_person, 'name'); return u; };
  const greet = () => { const h = new Date().getHours(); return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening'; };
  const phaseTag = (n) => `<span class="tag phase p${n}">${esc(window.CMS_PHASES[n] || '')}</span>`;
  const coShort = (code) => (state.org?.companies || []).find((c) => c.code === code)?.short_name
    || window.CMS_COMPANIES.find((c) => c.code === code)?.short || code || '—';
  const roleName = (code) => state.roleNames?.[code] || ({ super_admin: 'Super Admin', admin: 'Admin', hr: 'HR', payroll: 'Payroll', finance: 'Finance', approver: 'Approver', director: 'CEO / Director', payroll_viewer: 'Payroll Viewer', account_viewer: 'Account Viewer', staff: 'Staff' }[code] || code);
  const scopeTxt = (cos) => (cos && cos.length ? cos.join(', ') : 'all companies');
  const loading = (t = 'Loading…') => `<div class="loading"><span class="spinner"></span>${esc(t)}</div>`;
  const errorCard = (msg) => `<section class="card err-card">${icon('x')}<div><b>Could not load this page</b><p>${esc(msg)}</p><button type="button" class="btn" data-retry>Try again</button></div></section>`;

  function toast(msg, tone = 'ok') {
    let box = $('#toasts'); if (!box) { box = document.createElement('div'); box.id = 'toasts'; document.body.appendChild(box); }
    const t = document.createElement('div'); t.className = `toast ${tone}`; t.setAttribute('role', 'status');
    t.innerHTML = `${icon(tone === 'ok' ? 'check-circle' : 'x')}<span>${esc(msg)}</span>`;
    box.appendChild(t); setTimeout(() => t.classList.add('out'), 3800); setTimeout(() => t.remove(), 4300);
  }

  // modal: resolves to true after a successful submit, or null when cancelled
  function modal({ title, body, ok = 'Save', cancel = 'Cancel', danger = false, wide = false, onOk, onOpen }) {
    return new Promise((resolve) => {
      const wrap = document.createElement('div'); wrap.className = 'modal';
      wrap.innerHTML = `<div class="modal-box ${wide ? 'wide' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title)}">
        <div class="modal-head"><h3>${esc(title)}</h3><button type="button" class="icon-btn sm" data-x aria-label="Close">${icon('x')}</button></div>
        <form class="modal-body" novalidate>${body}<p class="form-err" hidden></p>
          <div class="modal-foot"><button type="button" class="btn ghost" data-x>${esc(cancel)}</button>${ok ? `<button type="submit" class="btn ${danger ? 'danger' : 'primary'}">${esc(ok)}</button>` : ''}</div></form></div>`;
      document.body.appendChild(wrap);
      const close = (v) => { wrap.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
      const onKey = (e) => { if (e.key === 'Escape' && [...document.querySelectorAll('.modal')].pop() === wrap) close(null); };
      document.addEventListener('keydown', onKey);
      $$('[data-x]', wrap).forEach((b) => b.addEventListener('click', () => close(null)));
      wrap.addEventListener('mousedown', (e) => { if (e.target === wrap) close(null); });
      const form = $('form', wrap);
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const btn = $('button[type=submit]', form); const err = $('.form-err', form);
        err.hidden = true; if (btn) { btn.disabled = true; btn.classList.add('busy'); }
        try { if (onOk) await onOk(form); close(true); }
        catch (x) { err.textContent = x.message || String(x); err.hidden = false; if (btn) { btn.disabled = false; btn.classList.remove('busy'); } }
      });
      if (onOpen) onOpen(wrap, close);
      else setTimeout(() => ($('input:not([type=checkbox]):not([type=radio]), select, textarea', form) || $('button[type=submit]', form))?.focus(), 30);
    });
  }
  const confirmBox = (title, text, ok, danger, onOk) => modal({ title, body: `<p class="confirm-txt">${text}</p>`, ok, danger, onOk });

  // ---------------------------------------------------------------- shell
  // the app page lives in app/ (its own install scope); files stay at the site root, so relative paths get CMS_ROOT
  const ROOT = window.CMS_ROOT || '';
  const asset = (p) => (p && !/^([a-z]+:|\/|data:)/i.test(p) ? ROOT + p : p);
  function logo3d(size = 'md') {
    const layers = Array.from({ length: 9 }, (_, i) => `<img src="${asset('assets/logos/myeden-mark.png')}" alt="" style="--z:${(i - 4) * 1.6}px" class="${i === 8 ? 'front' : i === 0 ? 'back' : 'edge'}">`).join('');
    return `<button class="logo3d ${size}" type="button" aria-label="MyEden Group" title="MyEden Group"><span class="glow"></span><span class="spin">${layers}</span></button>`;
  }

  function visibleMenu() {
    return window.CMS_MENU.map((sec) => ({
      ...sec,
      items: sec.items.map((it) => it.group ? { ...it, items: it.items.filter((s) => canRoute(s.route)) } : it)
        .filter((it) => it.group ? it.items.length : canRoute(it.route)),
    })).filter((sec) => sec.items.length);
  }

  function sidebarHtml() {
    const link = (it, sub = false) => {
      const active = state.route === it.route;
      const live = it.phase === 0 || it.live;
      return `<a href="#/${it.route}" class="nav-link ${sub ? 'sub' : ''} ${active ? 'active' : ''}" data-route="${it.route}" title="${esc(it.label)}">
        ${sub ? '<span class="dot"></span>' : icon(it.icon)}<span class="txt">${esc(it.label)}</span>${it.badge ? `<span class="badge">${esc(it.badge)}</span>` : ''}${live && !it.badge ? '<span class="live-dot" title="Live"></span>' : ''}</a>`;
    };
    const sections = visibleMenu().map((sec) => `<div class="nav-section"><div class="nav-title">${esc(sec.section)}</div>${sec.items.map((it) => {
      if (!it.group) return link(it);
      const open = state.open.has(it.group) && !state.collapsed;
      const hasActive = it.items.some((s) => s.route === state.route);
      return `<div class="nav-group ${open ? 'open' : ''} ${hasActive ? 'has-active' : ''}" data-group="${esc(it.group)}">
        <button type="button" class="nav-link group-btn" aria-expanded="${open}" title="${esc(it.group)}">${icon(it.icon)}<span class="txt">${esc(it.group)}</span>${it.badge ? `<span class="badge ok">${esc(it.badge)}</span>` : ''}${icon('chevron', 'chev')}</button>
        <div class="nav-sub"><div class="nav-sub-inner">${it.items.map((s) => link(s, true)).join('')}</div></div></div>`;
    }).join('')}</div>`).join('');
    return `
      <div class="brand">${logo3d()}<div class="brand-txt"><b>MyEden Group</b><span>CMS V1.0</span><small>One Group · One Platform</small></div></div>
      <nav class="nav" aria-label="Main">${sections}</nav>
      <div class="side-foot">
        <div class="status-card"><span class="pulse"></span><div><b>Connected</b><span>${esc(CFG.project)}</span></div></div>
        <div class="ver">${esc(window.CMS_VERSION)}</div>
        <button type="button" class="collapse-btn" title="Collapse menu" aria-label="Collapse menu">${icon('collapse')}<span class="txt">Collapse menu</span></button>
      </div>`;
  }

  function tasksFromDash(d) {
    const t = [...selfTasks(), ...itemTasks(), ...leaveTasks(), ...apprTasks(), ...certTasks(), ...letterTasks()];
    if (state.selfPending && can('selfservice.profile')) t.push({ ic: 'users', tone: 'violet', title: `${num(state.selfPending)} profile changes to approve`, sub: 'Sent by staff from My Profile', href: '#/people/selfservice?tab=requests' });
    if (!d) return t;
    const bs = d.claims_by_stage || {};
    if (d.claims_pending && can('approvals')) t.push({ ic: 'file-check', tone: 'orange', title: `${num(d.claims_pending)} claims waiting`, sub: [bs.approval && `${bs.approval} to approve`, bs.processing && `${bs.processing} to process`, bs.payment && `${bs.payment} to pay`].filter(Boolean).join(' · ') + ` · ${money(d.claims_pending_amount)}`, href: '#/approvals' });
    if (d.applications_pending && can('recruitment')) t.push({ ic: 'search-user', tone: 'blue', title: `${num(d.applications_pending)} applications not yet processed`, sub: 'Screening and decision', href: '#/applications' });
    if (d.handbook_outstanding && can('handbook')) t.push({ ic: 'shield', tone: 'violet', title: `${num(d.handbook_outstanding)} handbook acknowledgements outstanding`, sub: 'Assigned or viewed, not yet acknowledged', href: '#/handbook' });
    if (can('admin.roles') && d.logins - d.logins_with_role > 0) t.push({ ic: 'lock', tone: 'teal', title: `${num(d.logins - d.logins_with_role)} logins have no CMS role yet`, sub: 'Review the suggested roles and accept or skip', href: '#/admin/roles' });
    if (can('admin.roles', 'E') && d.logins_unlinked > 0) t.push({ ic: 'users', tone: 'rose', title: `${num(d.logins_unlinked)} logins are not linked to a person`, sub: 'Link each login to its Employee Master record', href: '#/admin/roles?tab=logins' });
    const ob = state.onbSum;
    if (ob && ob.accepted && can('onboarding')) t.push({ ic: 'user-plus', tone: 'green', title: `${num(ob.accepted)} approved applicants to hire`, sub: 'Create the person and payroll record', href: '#/onboarding' });
    if (ob && ob.toPayroll && can('onboarding')) t.push({ ic: 'users', tone: 'orange', title: `${num(ob.toPayroll)} staff not yet in payroll`, sub: 'Active or onboarding without a payroll record', href: '#/onboarding' });
    if (ob && ob.idPending && can('people')) t.push({ ic: 'users', tone: 'rose', title: `${num(ob.idPending)} Employee IDs incomplete`, sub: 'Number reserved; gender or start date missing', href: '#/onboarding' });
    if (ob && ob.stampSoon && can('onboarding')) t.push({ ic: 'file-check', tone: 'rose', title: `${num(ob.stampSoon)} offer letters: stamp duty due`, sub: 'Due within 7 days or overdue', href: '#/onboarding' });
    const inc = state.incrSum;
    if (inc && (inc.overdue || inc.due) && can('payroll.increments')) t.push({ ic: 'trend', tone: 'orange', title: `${num(inc.overdue + inc.due)} salary reviews due`, sub: [inc.overdue && `${inc.overdue} overdue`, inc.due && `${inc.due} this month`].filter(Boolean).join(' · '), href: '#/payroll/increments' });
    return t;
  }

  function topbarHtml() {
    const a = state.access || {}; const top = a.roles?.[0];
    return `
      <button type="button" class="icon-btn menu-btn" aria-label="Open menu">${icon('menu')}</button>
      <button type="button" class="search-btn" aria-label="Search">${icon('search')}<span>Search pages and people…</span><kbd>Ctrl K</kbd></button>
      <div class="top-actions">
        <button type="button" class="icon-btn theme-btn" aria-label="Switch light / dark" title="Light / dark">${icon(state.theme === 'dark' ? 'sun' : 'moon')}</button>
        <div class="pop-wrap"><button type="button" class="icon-btn bell-btn" aria-label="Notifications" aria-haspopup="true">${icon('bell')}</button>
          <div class="popover" data-pop="bell"><div class="pop-head">Waiting for attention</div><div id="bell-list">${loading('Checking…')}</div></div></div>
        <div class="pop-wrap"><button type="button" class="user-btn" aria-haspopup="true"><span class="avatar">${esc(initials(a.name))}</span><span class="who"><b>${esc(a.name || '')}</b><small>${esc(top ? top.name : hasSelf() ? 'Self-service' : 'No role')}</small></span>${icon('chevron', 'chev down')}</button>
          <div class="popover right" data-pop="user"><div class="pop-head">Signed in as</div><div class="pop-user"><span class="avatar">${esc(initials(a.name))}</span><div><b>${esc(a.name || '')}</b><small>${esc(a.email || '')}</small></div></div>
            <div class="pop-roles">${(a.roles || []).map((r) => `<span class="role-chip r-${esc(r.code)}">${esc(r.name)}${r.companies ? ` · ${esc(r.companies.join(', '))}` : ''}</span>`).join('')}</div>
            ${a.person ? `<div class="pop-note">${icon('users')}${esc(a.person.employee_id || 'No Employee ID')} · ${esc(coShort(a.person.company_code))}</div>` : ''}
            ${can('admin.roles') ? `<a class="pop-item" href="#/admin/roles">${icon('shield')}Users, roles &amp; access</a>` : ''}
            ${isSuper() ? `<a class="pop-item" href="#/admin/export">${icon('download')}Export all data</a>` : ''}
            <button type="button" class="pop-item" data-install hidden>${icon('download')}Install app</button>
            <button type="button" class="pop-item" data-signout>${icon('logout')}Sign out</button></div></div>
      </div>`;
  }

  function drawBell() {
    const el = $('#bell-list'); if (!el) return;
    const t = tasksFromDash(state.dash);
    $('.bell-btn')?.classList.toggle('has', t.length > 0);
    el.innerHTML = t.length ? t.map((x) => `<a class="pop-item task" href="${esc(x.href)}" ${x.ext ? 'target="_blank" rel="noopener"' : ''}>${icon(x.ic)}<span><b>${esc(x.title)}</b><small>${esc(x.sub)}</small></span></a>`).join('')
      : `<div class="empty small">${icon('bell')}<p>Nothing waiting</p><span>Approvals and reminders appear here.</span></div>`;
  }

  function buildShell() {
    document.body.innerHTML = `
      <div class="app ${state.collapsed ? 'collapsed' : ''}">
        <aside class="sidebar" id="sidebar"></aside>
        <div class="scrim"></div>
        <div class="main-col">
          <header class="topbar" id="topbar"></header>
          <main class="page" id="page" tabindex="-1"></main>
          <footer class="foot">
            <span>MyEden Group CMS V1.0 · ${esc(window.CMS_VERSION)}</span>
            <span class="chips">${['Signed in', 'Roles &amp; access', 'Row-level security', 'Audit trail'].map((c) => `<span class="chip ok">${c}</span>`).join('')}</span>
          </footer>
        </div>
      </div>
      <div class="palette" id="palette" hidden><div class="palette-box" role="dialog" aria-label="Search">
        <div class="palette-in">${icon('search')}<input id="pal-q" type="text" placeholder="Go to a page or find a person…" autocomplete="off" aria-label="Search pages and people"><kbd>Esc</kbd></div>
        <div class="palette-list" id="pal-list"></div>
        <div class="palette-foot">↑ ↓ to move · Enter to open · People search covers the Employee Master.</div></div></div>`;
    $('#topbar').innerHTML = topbarHtml();
    wireTopbar();
  }

  function drawSidebar() {
    const sb = $('#sidebar'); if (!sb) return; const scroll = sb.querySelector('.nav')?.scrollTop || 0;
    sb.innerHTML = sidebarHtml();
    sb.querySelector('.nav').scrollTop = scroll;
    sb.querySelectorAll('.group-btn').forEach((b) => b.addEventListener('click', () => {
      const g = b.parentElement.dataset.group;
      if (state.collapsed) { setCollapsed(false); state.open.add(g); }
      else if (state.open.has(g)) state.open.delete(g); else state.open.add(g);
      store.set('openGroups', [...state.open]); drawSidebar();
    }));
    sb.querySelector('.collapse-btn').addEventListener('click', () => setCollapsed(!state.collapsed));
    sb.querySelectorAll('.nav-link[data-route]').forEach((a) => a.addEventListener('click', () => document.querySelector('.app').classList.remove('drawer')));
    const logo = sb.querySelector('.logo3d');
    logo.addEventListener('click', () => { logo.classList.remove('flip'); void logo.offsetWidth; logo.classList.add('flip'); });
  }
  function setCollapsed(v) {
    state.collapsed = v; store.set('collapsed', v);
    document.querySelector('.app').classList.toggle('collapsed', v);
    drawSidebar();
  }

  function wireTopbar() {
    $('.menu-btn').addEventListener('click', () => document.querySelector('.app').classList.toggle('drawer'));
    document.querySelector('.scrim').addEventListener('click', () => document.querySelector('.app').classList.remove('drawer'));
    $('.search-btn').addEventListener('click', openPalette);
    $('.theme-btn').addEventListener('click', () => {
      state.theme = state.theme === 'dark' ? 'light' : 'dark'; store.set('theme', state.theme); applyTheme();
      $('.theme-btn').innerHTML = icon(state.theme === 'dark' ? 'sun' : 'moon');
    });
    $$('.pop-wrap > button').forEach((b) => b.addEventListener('click', (e) => {
      e.stopPropagation(); const pop = b.parentElement.querySelector('.popover');
      const was = pop.classList.contains('show'); closePops(); if (!was) pop.classList.add('show');
    }));
    $('[data-signout]').addEventListener('click', signOut);
    wireInstall();
    drawBell();
  }
  // install as an app (Chrome / Edge / Android): the browser offers it; the user menu shows "Install app" while it can
  let installPrompt = null;
  const showInstall = () => document.querySelectorAll('[data-install]').forEach((b) => { b.hidden = !installPrompt; });
  function wireInstall() {
    document.querySelectorAll('[data-install]').forEach((b) => {
      b.hidden = !installPrompt;
      b.addEventListener('click', async () => {
        if (!installPrompt) return; closePops();
        const p = installPrompt; p.prompt(); await p.userChoice; installPrompt = null; showInstall();
      });
    });
  }
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); installPrompt = e; showInstall(); });
  window.addEventListener('appinstalled', () => { installPrompt = null; showInstall(); toast('MyEden Group CMS installed'); });
  if ('serviceWorker' in navigator) {
    const reg = () => navigator.serviceWorker.register('sw.js').catch(() => {});
    if (document.readyState === 'complete') reg(); else window.addEventListener('load', reg);
  }
  // new release published while the app is open: offer a one-click reload (checked when the app comes back to the front, and every 15 minutes)
  let lastVerCheck = 0;
  async function checkVersion() {
    if (Date.now() - lastVerCheck < 60000 || $('#update-bar')) return; lastVerCheck = Date.now();
    try {
      const t = await (await fetch(ROOT + 'js/version.js?t=' + Date.now(), { cache: 'no-store' })).text();
      const v = (t.match(/CMS_VERSION\s*=\s*'([^']+)'/) || [])[1];
      if (!v || v === window.CMS_VERSION) return;
      const bar = document.createElement('div'); bar.id = 'update-bar'; bar.setAttribute('role', 'status');
      bar.innerHTML = `${icon('check-circle')}<span>A new version of the CMS is ready (<b>${esc(v)}</b>).</span><button type="button" class="btn sm primary">Reload now</button>`;
      $('button', bar).addEventListener('click', () => location.reload());
      document.body.appendChild(bar);
    } catch (e) { /* offline: try later */ }
  }
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') checkVersion(); });
  window.addEventListener('focus', checkVersion);
  setInterval(checkVersion, 15 * 60000);
  const closePops = () => $$('.popover.show').forEach((p) => p.classList.remove('show'));
  document.addEventListener('click', (e) => { if (!e.target.closest('.popover')) closePops(); else if (e.target.closest('a.pop-item')) closePops(); });

  // ---------------------------------------------------------------- Ctrl+K search (pages + people)
  let palSel = 0; let palItems = [];
  async function openPalette() {
    const p = $('#palette'); if (!p) return; p.hidden = false; const q = $('#pal-q'); q.value = ''; drawPalette(''); setTimeout(() => q.focus(), 0);
    if (!state.people && can('people')) { try { state.people = await loadPeople(); drawPalette(q.value); } catch (e) { /* pages still searchable */ } }
  }
  function closePalette() { const p = $('#palette'); if (p) p.hidden = true; }
  function drawPalette(q) {
    const t = q.trim().toLowerCase();
    const pages = [...PAGES.values()].filter((p) => canRoute(p.route))
      .filter((p) => !t || `${p.label} ${p.group || ''} ${p.source || ''} ${p.desc || ''}`.toLowerCase().includes(t)).slice(0, t ? 8 : 12)
      .map((p) => ({ href: '#/' + p.route, ic: p.icon || p.groupIcon || 'sparkle', title: p.label, sub: `${p.group || p.section}${p.source ? ` · now in ${p.source}` : ''}`, tag: (p.phase === 0 || p.live) ? 'Live' : window.CMS_PHASES[p.phase] }));
    const people = (t.length >= 2 && state.people) ? state.people.filter((x) => `${x.name} ${x.employee_id || ''} ${x.previous_id || ''} ${x.job_title || ''}`.toLowerCase().includes(t)).slice(0, 8)
      .map((x) => ({ href: `#/people?q=${encodeURIComponent(x.employee_id || x.name)}`, ic: 'users', title: x.name, sub: `${x.employee_id || 'No Employee ID'} · ${coShort(x.company_code)} · ${x.status}`, tag: 'Person' })) : [];
    palItems = [...pages, ...people]; palSel = 0;
    $('#pal-list').innerHTML = palItems.length ? palItems.map((p, i) => `<a href="${esc(p.href)}" class="pal-item ${i === 0 ? 'sel' : ''}" data-i="${i}">
      ${icon(p.ic)}<span><b>${esc(p.title)}</b><small>${esc(p.sub)}</small></span><em>${esc(p.tag || '')}</em></a>`).join('')
      : `<div class="empty small"><p>Nothing matches “${esc(q)}”.</p></div>`;
    $$('.pal-item', $('#pal-list')).forEach((a) => a.addEventListener('click', closePalette));
  }
  function movePal(d) {
    if (!palItems.length) return; palSel = (palSel + d + palItems.length) % palItems.length;
    $$('.pal-item', $('#pal-list')).forEach((a, i) => a.classList.toggle('sel', i === palSel));
    $$('.pal-item', $('#pal-list'))[palSel].scrollIntoView({ block: 'nearest' });
  }
  document.addEventListener('keydown', (e) => {
    if (document.querySelector('.modal') || !$('#palette')) return;
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); return; }
    if (!$('#palette').hidden) {
      if (e.key === 'Escape') closePalette();
      else if (e.key === 'ArrowDown') { e.preventDefault(); movePal(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); movePal(-1); }
      else if (e.key === 'Enter' && palItems[palSel]) { location.hash = palItems[palSel].href; closePalette(); }
    } else if (e.key === 'Escape') { closePops(); document.querySelector('.app')?.classList.remove('drawer'); }
  });
  document.addEventListener('input', (e) => { if (e.target.id === 'pal-q') drawPalette(e.target.value); });
  document.addEventListener('click', (e) => { if (e.target.id === 'palette') closePalette(); });

  // ---------------------------------------------------------------- page head
  function pageHead(item, extra = '') {
    const live = item.phase === 0 || item.live;
    const home = homeRoute();
    return `<div class="crumbs"><a href="#/${home}">${esc(PAGES.get(home).label)}</a>${item.group ? ` / <span>${esc(item.group)}</span>` : ''} / <span>${esc(item.label)}</span></div>
      <div class="page-head"><div><h1>${esc(item.label)}</h1><p>${esc(item.desc || '')}</p></div><div class="ph-tags">${extra}${item.source ? `<span class="tag src">${icon('plug')}${live ? 'Data from' : 'Now in'} ${esc(item.source)}</span>` : ''}${live ? '<span class="tag live">Live</span>' : phaseTag(item.phase)}</div></div>`;
  }
  function wireRetry(el) { $$('[data-retry]', el).forEach((b) => b.addEventListener('click', render)); }

  // ================================================================ DASHBOARD
  async function dashboardPage(item, el) {
    const a = state.access;
    const first = (a.name || '').split(/\s+/)[0];
    el.innerHTML = `
      <section class="hero">
        <div class="hero-art" aria-hidden="true"><span class="b1"></span><span class="b2"></span><span class="b3"></span><span class="grid"></span></div>
        <div class="hero-top"><span class="eyebrow">MyEden Group CMS V1.0</span>
          <div class="hero-meta"><span class="pill">${icon('calendar')}<span id="h-date">${fmtDate(new Date())}</span></span><span class="pill">${icon('clock')}<span id="h-time">${fmtTime(new Date())}</span></span><span class="pill live"><span class="pulse"></span>Live</span></div></div>
        <h1>${greet()}, ${esc(first || 'welcome')}</h1>
        <p>One platform for every person, from application to offboarding.</p>
        <div class="hero-chips">${(a.roles || []).map((r, i) => `<span class="hchip c${i % 6}">${esc(r.name)}${r.companies ? ' · ' + esc(r.companies.join(', ')) : ''}</span>`).join('')}</div>
      </section>
      <section class="kpis" id="kpis">${['blue', 'green', 'orange', 'violet'].map((t) => `<div class="kpi ${t} skel"><span class="kpi-ic"></span><div><span class="kpi-label">&nbsp;</span><b class="kpi-val">…</b><span class="kpi-note">&nbsp;</span></div></div>`).join('')}</section>
      <div id="dash-rest">${loading()}</div>`;
    let d;
    try { d = await API.rpc('cms_dashboard'); state.dash = d; drawBell(); }
    catch (e) { $('#dash-rest', el).innerHTML = errorCard(e.message); wireRetry(el); $('#kpis', el).innerHTML = ''; return; }

    const kpi = (ic, label, val, note, tone, href) => `<a class="kpi ${tone}" href="${href}"><span class="kpi-ic">${icon(ic)}</span><div><span class="kpi-label">${label}</span><b class="kpi-val">${val}</b><span class="kpi-note">${note}</span></div></a>`;
    const p = d.people || {};
    $('#kpis', el).innerHTML = `
      ${kpi('users', 'Active employees', num(p.active), `${num(p.onboarding)} onboarding · ${num(p.applicants)} applicants`, 'blue', canRoute('people') ? '#/people' : '#/dashboard')}
      ${kpi('briefcase', 'JD positions', num(d.positions), `${num(d.departments)} departments · 4 companies`, 'green', canRoute('org') ? '#/org' : '#/dashboard')}
      ${kpi('file-check', 'Applications pending', num(d.applications_pending), 'In MEG-EAF V2', 'orange', canRoute('approvals') ? '#/approvals' : '#/dashboard')}
      ${kpi('check-circle', 'Claims waiting', num(d.claims_pending), `${num((d.claims_by_stage || {}).approval || 0)} to approve · ${num((d.claims_by_stage || {}).processing || 0)} to process · ${money(d.claims_pending_amount)}`, 'violet', canRoute('approvals') ? '#/approvals' : '#/dashboard')}`;

    const qa = (ic, title, sub, route, tone) => canRoute(route) && (route !== 'admin/export' || isSuper()) ? `<a class="qa ${tone}" href="#/${route}"><span class="qa-ic">${icon(ic)}</span><span><b>${title}</b><small>${sub}</small></span>${icon('arrow', 'qa-go')}</a>` : '';
    const tasks = tasksFromDash(d);
    const systems = [
      ['MyPayroll System V2.0', 'Payroll, leave, overtime, payslips, EA', 2, 'wallet', 'MyPayroll V2.0'],
      ['MEG-FORMS (SCF · OTCF · MTCF · PRFAF · TEC)', 'Claims, overtime and purchase forms', 1, 'file-check', 'MEG-FORMS'],
      ['MEG-Employment & HR System V2', 'Applications, LOEC, JD Manual, handbook, calculators', 3, 'search-user', 'MEG-EAF V2'],
    ];
    const byEmp = d.active_by_employer || {}; const byPay = d.active_by_payer || {};
    const snap = d.snapshot;
    $('#dash-rest', el).innerHTML = `
      <div class="sec-head"><h2>${icon('sparkle')}Quick actions</h2><span class="muted">Shortcuts to the work you do most</span></div>
      <section class="qas">
        ${qa('users', 'View people', 'Search the Employee Master', 'people', 'blue')}
        ${qa('check-circle', 'Approvals', 'Waiting across the apps', 'approvals', 'rose')}
        ${qa('shield', 'Users & roles', 'Who can do what', 'admin/roles', 'violet')}
        ${qa('building', 'Organisation', 'Companies and centres', 'org', 'green')}
        ${qa('list', 'Audit log', 'Every change, by whom', 'admin/audit', 'teal')}
        ${qa('download', 'Export all data', 'Your own backup copy', 'admin/export', 'orange')}
      </section>
      <div class="grid-2">
        <section class="card"><div class="card-head"><h3>${icon('check-circle')}My tasks</h3>${canRoute('approvals') ? `<a href="#/approvals" class="link">View all ${icon('arrow')}</a>` : ''}</div>
          ${tasks.length ? `<ul class="tasks">${tasks.map((x) => `<li><a href="${esc(x.href)}" ${x.ext ? 'target="_blank" rel="noopener"' : ''}><span class="t-ic ${x.tone}">${icon(x.ic)}</span><span><b>${esc(x.title)}</b><small>${esc(x.sub)}</small></span>${x.src ? `<span class="tag src">${esc(x.src)}</span>` : icon('arrow', 'go')}</a></li>`).join('')}</ul>`
            : `<div class="empty">${icon('sparkle')}<p>Nothing waiting for you</p><span>Approvals and reminders for your roles appear here.</span></div>`}</section>
        <section class="card"><div class="card-head"><h3>${icon('clock')}Recent activity</h3>${canRoute('admin/audit') ? `<a href="#/admin/audit" class="link">Audit log ${icon('arrow')}</a>` : ''}</div>
          ${(d.recent || []).length ? `<ul class="activity">${d.recent.map((r) => `<li><span class="a-dot a-${esc(String(r.action).split('.')[0])}"></span><div><b>${esc(r.summary)}</b><small>${esc(r.actor || 'System')} · ${ago(r.at)}</small></div></li>`).join('')}</ul>`
            : `<div class="empty">${icon('list')}<p>No activity to show</p><span>${canRoute('admin/audit') ? 'Changes made in the CMS are recorded in the audit log.' : 'Activity is visible to admins.'}</span></div>`}</section>
      </div>
      <div class="grid-2">
        <section class="card"><div class="card-head"><h3>${icon('building')}Group companies</h3>${canRoute('org') ? `<a href="#/org" class="link">Organisation ${icon('arrow')}</a>` : ''}</div>
          <div class="cos">${window.CMS_COMPANIES.map((c) => `<div class="co"><span class="co-logo"><img src="${esc(asset(c.logo))}" alt="${esc(c.short)} logo"></span><div><b>${esc(c.short)}</b><small>${num(byEmp[c.code] || 0)} employed · ${num(byPay[c.code] || 0)} paid</small></div></div>`).join('')}</div></section>
        <section class="card"><div class="card-head"><h3>${icon('plug')}Integrated systems</h3><span class="tag">3 to join</span></div>
          <ul class="sys">${systems.map(([n, dd, ph, ic, src]) => `<li><span class="sys-ic">${icon(ic)}</span><div><b>${n}</b><small>${dd}</small></div><a class="tag src" href="${esc(window.CMS_SOURCES[src])}" target="_blank" rel="noopener">Open</a>${phaseTag(ph)}</li>`).join('')}</ul></section>
      </div>
      <div class="grid-2">
        <section class="card"><div class="card-head"><h3>${icon('sparkle')}System updates</h3></div>
          <ul class="updates"><li><span class="u-dot"></span><div><b>Phase 0 foundation is live</b><small>${esc(window.CMS_VERSION)} · sign-in, roles &amp; access, people, organisation, audit log and export</small></div></li>
          <li><span class="u-dot done"></span><div><b>Theme approved</b><small>v2026.10.17-13:00 · navy theme, 3D logo, menu and page map</small></div></li>
          <li><span class="u-dot next"></span><div><b>Next: Phase 1 · MEG-FORMS</b><small>SCF, OTCF, MTCF, PRFAF and TEC as CMS modules</small></div></li></ul></section>
        <section class="card"><div class="card-head"><h3>${icon('database')}Database &amp; environment</h3></div>
          <dl class="env"><div><dt>Supabase project</dt><dd>${esc(CFG.project)} · <code>${esc(CFG.projectRef)}</code></dd></div>
          <div><dt>Region</dt><dd>${esc(CFG.region)}</dd></div>
          <div><dt>Logins</dt><dd>${num(d.logins)} · ${num(d.logins_with_role)} with a CMS role</dd></div>
          ${snap ? `<div><dt>Structure snapshot</dt><dd>${dShort(snap.taken_at)} · ${num(snap.summary?.tables)} tables, ${num(snap.summary?.functions)} functions</dd></div>` : ''}
          <div><dt>Version</dt><dd>${esc(window.CMS_VERSION)} · ${esc(window.CMS_STAGE)}</dd></div></dl></section>
      </div>`;
  }

  // ================================================================ PEOPLE
  const STATUS = [['active', 'Active'], ['notice', 'Serving notice'], ['onboarding', 'Onboarding'], ['applicant', 'Applicants'], ['former', 'Former'], ['all', 'All']];
  const inStatus = (r, k) => k === 'all' || (k === 'notice' ? !!r.serving_notice && r.status !== 'former' : r.status === k);
  const CONF = { UP: 'Under probation', C: 'Confirmed', CT: 'Contract', PT: 'Part time', INT: 'Internship', R: 'Resigned', TR: 'Terminated', DM: 'Dismissed' };
  const confCell = (r) => !r.confirmation ? '<span class="muted">—</span>'
    : `<span class="conf c-${esc(r.confirmation)}">${esc(CONF[r.confirmation] || r.confirmation)}</span>${r.confirmed_date ? `<small class="sub">confirmed ${dShort(r.confirmed_date)}</small>` : ''}`;
  const weeksBetween = (a, b) => Math.round((new Date(b) - new Date(a)) / 6048e5);
  const noticeCell = (r) => !r.notice_until ? (r.letter_date ? `<small class="muted">letter ${dShort(r.letter_date)}</small>` : '<span class="muted">—</span>')
    : `${r.serving_notice && r.status !== 'former' ? '<b>' : ''}${dShort(r.notice_until)}${r.serving_notice && r.status !== 'former' ? '</b>' : ''}${r.letter_date ? `<small class="sub">letter ${dShort(r.letter_date)} · ${weeksBetween(r.letter_date, r.notice_until)} weeks</small>` : ''}`;
  async function loadOrg(force) {
    if (state.org && !force) return state.org;
    try { state.org = await API.rpc('cms_org'); } catch (e) { if (force) throw e; }
    return state.org;
  }

  // People list with previous ID and "paid by" from payroll (falls back to the Phase 0 list)
  async function loadPeople() {
    let rows;
    try { rows = await API.rpc('cms_people_list'); }
    catch (e) { if (!/cms_people_list|function/i.test(e.message || '')) throw e; rows = await API.rpc('cms_people'); }
    // leaving reason / rehire from payroll (PRI-002): merged in when the function is there
    try { const lv = new Map((await API.rpc('cms_people_leaving')).map((x) => [x.id, x])); rows.forEach((r) => Object.assign(r, { leave: lv.get(r.id) || null })); } catch (e) { /* older database: no reason column */ }
    return rows.map((r) => upKeys(r, 'name'));
  }
  const REHIRE_TXT = { eligible: ['ok', 'Rehire: eligible'], conditional: ['warn', 'Rehire: with conditions'], not_eligible: ['bad', 'Not eligible for rehire'] };
  const lastDayCell = (r) => {
    const lv = r.leave; const left = !!r.last_day;
    const reason = left ? (lv && lv.leaving_label ? `<small class="sub" title="${esc(lv.leaving_note || '')}">${esc(lv.leaving_label)}</small>` : (lv ? '<small class="sub warn-txt">reason not recorded</small>' : '')) : '';
    const rh = left && lv && lv.rehire && REHIRE_TXT[lv.rehire] ? `<small class="sub"><span class="tag ${REHIRE_TXT[lv.rehire][0]} xs" title="${esc(lv.rehire_note || '')}">${REHIRE_TXT[lv.rehire][1]}</span></small>` : '';
    const again = lv && lv.periods > 1 ? ` <span class="tag xs" title="${lv.periods} employment periods">rehired</span>` : '';
    return `${left ? dShort(r.last_day) : '<span class="muted">—</span>'}${again}${reason}${rh}`;
  };
  // "Paid by" cell: payroll's companies this month (main first); "same" when only the employer pays
  function paidByCell(r) {
    const codes = r.paid_by && r.paid_by.length ? r.paid_by : (r.paying_company_code ? [r.paying_company_code] : []);
    if (!codes.length || (codes.length === 1 && codes[0] === r.company_code)) return '<span class="muted">same</span>';
    return codes.map((c, i) => `<span class="tag ${codes.length > 1 ? 'joint' : 'warn'}" title="${codes.length > 1 ? (i ? 'Joint payment' : 'Main paying company') : 'Paid by another company'}">${esc(coShort(c))}${codes.length > 1 && !i ? ' ★' : ''}</span>`).join(' ');
  }

  // ================================================================ PAYING COMPANIES
  const STAT = [['epf_ee', 'EPF · employee'], ['epf_er', 'EPF · employer'], ['socso_ee', 'SOCSO · employee'], ['socso_er', 'SOCSO · employer'],
    ['eis_ee', 'EIS · employee'], ['eis_er', 'EIS · employer'], ['socso_nei_opt_out', 'SOCSO non-employment injury opt-out']];
  const monthTxt = (s) => { if (!s) return '—'; const d = new Date(s); return isNaN(d) ? esc(s) : d.toLocaleDateString('en-GB', { month: 'short', year: 'numeric' }); };
  const monthNow = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
  const monthNext = (s) => { if (!s) return monthNow(); const d = new Date(s); d.setMonth(d.getMonth() + 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
  const maxMonth = (a, b) => (!a ? b : !b ? a : (a > b ? a : b));
  const payers = () => (state.org?.companies || []).filter((c) => c.is_active && c.is_paying);
  const statBoxes = (cur = {}) => `<fieldset class="fld"><legend>Statutory contributions with this company</legend><div class="checks col stat">${STAT.map(([k, l]) =>
    `<label><input type="checkbox" name="st_${k}" ${(cur[k] ?? (k !== 'socso_nei_opt_out')) ? 'checked' : ''}> ${l}</label>`).join('')}</div></fieldset>`;
  const statOf = (form) => Object.fromEntries(STAT.map(([k]) => [k, !!form[`st_${k}`].checked]));
  const statTxt = (s) => { if (!s) return ''; const off = STAT.filter(([k]) => k !== 'socso_nei_opt_out' && s[k] === false).map(([, l]) => l); return off.length ? `No ${off.join(', ')}` : 'All statutory on'; };
  const stateTag = (st) => ({ current: '<span class="tag ok xs">Paying now</span>', upcoming: '<span class="tag src xs">Starts later</span>', ended: '<span class="tag xs">Ended</span>' }[st] || '');

  // The paying-companies window for one person. Resolves true when something changed.
  async function payingWindow(person, opts = {}) {
    const canE = can('payroll.paying', 'E'); const canC = can('payroll.paying', 'C'); const canA = can('payroll.paying', 'A');
    const seeSalary = can('payroll') || canC;
    let changed = false;
    await loadOrg();
    await modal({
      title: person.name, wide: true, ok: opts.unit ? 'Save centre' : '', cancel: 'Close',
      body: `<p class="muted small"><code>${esc(person.employee_id || 'No Employee ID')}</code>${person.previous_id && person.previous_id !== person.employee_id ? ` · previous ID <code>${esc(person.previous_id)}</code>` : ''} · employer on the contract: <b>${esc(coShort(person.company_code))}</b></p>
        <div class="pay-panel" data-pay>${loading()}</div>
        ${opts.unit ? `<label class="fld"><span>Centre / unit</span><select name="unit"><option value="">Not set</option>${(state.org?.units || []).filter((u) => u.is_active).map((u) => `<option value="${esc(u.code)}" ${person.unit_code === u.code ? 'selected' : ''}>${esc(u.code)} · ${esc(u.name)}</option>`).join('')}</select></label>` : ''}`,
      onOk: async (form) => {
        if (!opts.unit) return;
        const unit = form.unit.value || null;
        await API.rpc('cms_set_person_payroll', { p_person: person.id, p_paying_company: person.manual_paying_code || null, p_unit: unit, p_note: null });
        person.unit_code = unit; changed = true; toast(`Saved ${person.name}`);
      },
      onOpen: (wrap) => {
        const box = $('[data-pay]', wrap);
        const load = async () => {
          box.innerHTML = loading();
          let recs; try { recs = await API.rpc('cms_paying_companies', { p_person: person.id }); }
          catch (e) { box.innerHTML = `<p class="form-err">${esc(e.message)}</p>`; return; }
          draw(recs);
        };
        const draw = (recs) => {
          if (!recs.length) { box.innerHTML = '<div class="empty small"><p>No payroll record</p><span>This person has not been added to payroll yet.</span></div>'; return; }
          const emps = []; recs.forEach((r) => { let e = emps.find((x) => x.id === r.employment_id); if (!e) { e = { id: r.employment_id, join: r.join_date, left: r.resigned_date, latest: r.latest, recs: [] }; emps.push(e); } e.recs.push(r); });
          const lastFin = recs.reduce((m, r) => maxMonth(m, r.finalised_to), null);
          box.innerHTML = emps.map((e) => {
            const live = e.recs.filter((r) => r.state !== 'ended');
            const edit = e.latest && canE;
            return `<section class="pay-emp ${e.latest ? '' : 'old'}">
              <div class="pay-emp-head"><b>${e.latest ? 'Current employment' : 'Earlier employment'}</b><span class="muted small">joined ${dShort(e.join)}${e.left ? ` · left ${dShort(e.left)}` : ''}</span>
                ${e.latest && canC && !e.left ? `<button type="button" class="btn sm" data-add="${e.id}">${icon('plus')}Add second company</button>` : ''}</div>
              <div class="table-wrap fill-modal"><table class="data pay-t"><thead><tr><th>Company</th><th>From</th><th>To</th><th>Status</th>${seeSalary ? '<th>Salary</th>' : ''}<th>Paid</th><th>Statutory</th></tr></thead><tbody>
              ${e.recs.map((r) => { const btns = !edit ? '' : [
                  r.state !== 'ended' ? `<button type="button" class="btn sm" data-a="transfer" data-id="${r.assignment_id}">Transfer</button>` : '',
                  r.state !== 'ended' && !r.is_main && live.length > 1 ? `<button type="button" class="btn sm" data-a="main" data-id="${r.assignment_id}">Set main</button>` : '',
                  r.state !== 'ended' && live.length > 1 ? `<button type="button" class="btn sm" data-a="end" data-id="${r.assignment_id}">End</button>` : '',
                  !r.finalised_to || canA ? `<button type="button" class="btn sm ghost" data-a="correct" data-id="${r.assignment_id}" title="Fix a wrong record">Correct a mistake</button>` : ''].join('');
                return `<tr class="${r.state}${btns ? ' has-acts' : ''}">
                <td class="nowrap"><b>${esc(coShort(r.company_code))}</b>${r.is_main ? ` <span class="tag ${r.state === 'ended' ? '' : 'ok '}xs" title="Main paying company for the months of this record">Main</span>` : ''}</td>
                <td class="nowrap">${dShort(r.start_date || e.join)}</td><td class="nowrap">${r.end_date ? dShort(r.end_date) : '<span class="muted">open</span>'}</td>
                <td>${stateTag(r.state)}</td>
                ${seeSalary ? `<td class="nowrap">${r.salary == null ? '—' : `${money(r.salary)}${r.pay_basis === 'hourly' ? ' /h' : ''}`}</td>` : ''}
                <td class="nowrap small">${r.months_paid ? `${r.months_paid} mo · ${monthTxt(r.first_paid)}–${monthTxt(r.last_paid)}${r.finalised_to ? `<br><span class="muted">finalised to ${monthTxt(r.finalised_to)}</span>` : ''}` : '<span class="muted">not yet</span>'}</td>
                <td class="small">${esc(statTxt(r.statutory))}</td></tr>${btns ? `<tr class="pay-acts-row"><td colspan="${seeSalary ? 7 : 6}"><div class="pay-acts">${btns}</div></td></tr>` : ''}`; }).join('')}
              </tbody></table></div></section>`;
          }).join('') + `<p class="muted small">${canE ? `Changes take effect from a payroll month and are logged. Months already finalised${lastFin ? ` (to ${monthTxt(lastFin)})` : ''} stay as they were paid${canA ? '' : '; correcting a record used in a finalised month needs an Admin'}.` : 'View only.'}</p>`;
          $$('[data-a]', box).forEach((b) => b.addEventListener('click', () => act(b.dataset.a, recs.find((r) => String(r.assignment_id) === b.dataset.id), recs)));
          $$('[data-add]', box).forEach((b) => b.addEventListener('click', () => addCompany(Number(b.dataset.add), recs.filter((r) => r.employment_id === Number(b.dataset.add)))));
        };
        const done = async (msg) => { changed = true; toast(msg); await load(); };
        const firstOpen = (r) => monthNext(maxMonth(r.finalised_to, null)) > monthNow() ? monthNext(r.finalised_to) : monthNow();
        const coOpts = (skip = [], sel) => payers().filter((c) => !skip.includes(c.code)).map((c) => `<option value="${esc(c.code)}" ${sel === c.code ? 'selected' : ''}>${esc(c.name)}</option>`).join('');
        const act = async (a, r, recs) => {
          if (!r) return;
          const live = recs.filter((x) => x.employment_id === r.employment_id && x.state !== 'ended');
          if (a === 'transfer') {
            const ok = await modal({ title: `Transfer ${person.name}`, ok: 'Transfer',
              body: `<p class="muted small">Now paid by <b>${esc(coShort(r.company_code))}</b>. From the month you choose, another company pays instead, with the same salary, allowances and statutory switches. Earlier months stay with ${esc(coShort(r.company_code))}, which keeps its record${r.is_main ? ' and its main-company mark' : ''} for those months.</p>
                <label class="fld"><span>New paying company</span><select name="co" required>${coOpts([r.company_code, ...live.map((x) => x.company_code)])}</select></label>
                <label class="fld"><span>First payroll month under the new company</span><input type="month" name="m" required value="${firstOpen(r)}"></label>
                <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" placeholder="e.g. moved to Edu Hub for the new centre"></label>`,
              onOk: async (f) => { if (!f.co.value || !f.m.value) throw new Error('Choose the company and month.'); await API.rpc('cms_pay_transfer', { p_assignment: r.assignment_id, p_company: f.co.value, p_from: `${f.m.value}-01`, p_note: f.note.value || null }); } });
            if (ok) done(`${person.name} transferred`);
          } else if (a === 'main') {
            const ok = await modal({ title: 'Set main company', ok: 'Set main',
              body: `<p class="muted small">From the month you choose, <b>${esc(coShort(r.company_code))}</b> is the main paying company for ${esc(person.name)}. Earlier months keep the current main company, and the other company keeps paying its part.</p>
                <label class="fld"><span>First payroll month with ${esc(coShort(r.company_code))} as main</span><input type="month" name="m" required value="${firstOpen(r)}"></label>
                <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
              onOk: async (f) => { if (!f.m.value) throw new Error('Choose the month.'); await API.rpc('cms_pay_set_main', { p_assignment: r.assignment_id, p_from: `${f.m.value}-01`, p_note: f.note.value || null }); } });
            if (ok) done(`Main company is now ${coShort(r.company_code)}`);
          } else if (a === 'end') {
            const ok = await modal({ title: `End ${coShort(r.company_code)} for ${person.name}`, ok: 'End this company', danger: true,
              body: `<p class="muted small">${esc(coShort(r.company_code))} stops paying after the month you choose. ${esc(person.name)} stays paid by ${esc(live.filter((x) => x.assignment_id !== r.assignment_id).map((x) => coShort(x.company_code)).join(' and '))}.${r.is_main ? ' The other company becomes the main company from the next month; earlier months keep this one as main.' : ''}</p>
                <label class="fld"><span>Last payroll month paid by ${esc(coShort(r.company_code))}</span><input type="month" name="m" required value="${firstOpen(r)}"></label>
                <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
              onOk: async (f) => { if (!f.m.value) throw new Error('Choose the month.'); await API.rpc('cms_pay_end_company', { p_assignment: r.assignment_id, p_last_month: `${f.m.value}-01`, p_note: f.note.value || null }); } });
            if (ok) done(`${coShort(r.company_code)} ended for ${person.name}`);
          } else if (a === 'correct') {
            const ok = await modal({ title: 'Correct a mistake', ok: 'Save correction',
              body: `<p class="muted small">Use this only when the record was entered wrongly. To change who pays from a month, use Transfer instead.${r.finalised_to ? ` <b>This record was used in finalised months (to ${monthTxt(r.finalised_to)}).</b> Those payslips stay as they were paid; reopen and re-finalise them in payroll if they must change.` : ''}</p>
                <label class="fld"><span>Paying company</span><select name="co">${coOpts([], r.company_code)}</select></label>
                <div class="grid-2 tight"><label class="fld"><span>Start date</span><input type="date" name="s" value="${esc(r.start_date || '')}"></label>
                <label class="fld"><span>End date (blank = still paying)</span><input type="date" name="e" value="${esc(r.end_date || '')}"></label></div>
                ${statBoxes(r.statutory || {})}
                <label class="fld"><span>Reason (required, kept in the audit log)</span><textarea name="reason" rows="2" maxlength="500" required class="ta"></textarea></label>`,
              onOk: async (f) => { if (f.reason.value.trim().length < 5) throw new Error('Give the reason for the correction.');
                await API.rpc('cms_pay_correct', { p_assignment: r.assignment_id, p_company: f.co.value, p_start: f.s.value || null, p_end: f.e.value || null, p_statutory: statOf(f), p_reason: f.reason.value.trim() }); } });
            if (ok) done('Correction saved');
          }
        };
        const addCompany = async (empId, recs) => {
          const live = recs.filter((x) => x.state !== 'ended');
          const lastFin = recs.reduce((m, r) => maxMonth(m, r.finalised_to), null);
          const ok = await modal({ title: `Add second company · ${person.name}`, ok: 'Add company',
            body: `<p class="muted small">Joint payment: ${live.length ? `${esc(live.map((x) => coShort(x.company_code)).join(' and '))} ${live.length > 1 ? 'keep' : 'keeps'} paying, and` : ''} this company also pays its own part from the month you choose, with its own salary and statutory contributions.</p>
              <label class="fld"><span>Company</span><select name="co" required>${coOpts(live.map((x) => x.company_code))}</select></label>
              <div class="grid-2 tight"><label class="fld"><span>First payroll month</span><input type="month" name="m" required value="${lastFin && monthNext(lastFin) > monthNow() ? monthNext(lastFin) : monthNow()}"></label>
              <label class="fld"><span>Pay basis</span><select name="basis"><option value="monthly">Monthly salary</option><option value="hourly">Hourly rate</option></select></label></div>
              <label class="fld"><span>Salary paid by this company (RM)</span><input type="text" inputmode="decimal" data-money name="amt" required placeholder="0.00"></label>
              ${statBoxes({})}
              <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" placeholder="e.g. teaches 2 days a week at Edu Hub"></label>`,
            onOk: async (f) => { if (!f.co.value || !f.m.value || f.amt.value === '') throw new Error('Choose the company and month, and enter the salary.');
              await API.rpc('cms_pay_add_company', { p_employment: empId, p_company: f.co.value, p_from: `${f.m.value}-01`, p_salary: mval(f.amt.value), p_pay_basis: f.basis.value, p_statutory: statOf(f), p_note: f.note.value || null }); } });
          if (ok) done(`Second company added for ${person.name}`);
        };
        load();
      },
    });
    return changed;
  }

  // Payroll › Paying Companies: who pays each person now, with joint payments and transfers
  async function payingPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="pay-body">${loading()}</div>`;
    let rows;
    try { [rows] = await Promise.all([loadPeople(), loadOrg()]); }
    catch (e) { $('#pay-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { q: '', co: 'all', view: 'active' };
    const VIEWS = [['active', 'Active'], ['other', 'Paid by another company'], ['joint', 'Joint payment'], ['former', 'Former'], ['nopay', 'Not in payroll']];
    const isOther = (r) => (r.paid_by || []).some((c) => c !== r.company_code);
    const inView = (r, v) => v === 'active' ? r.status === 'active' && r.in_payroll : v === 'other' ? r.status !== 'former' && isOther(r)
      : v === 'joint' ? r.status !== 'former' && (r.paid_by || []).length > 1 : v === 'former' ? r.status === 'former' && r.in_payroll : !r.in_payroll;
    const counts = Object.fromEntries(VIEWS.map(([k]) => [k, rows.filter((r) => inView(r, k)).length]));
    $('#pay-body', el).innerHTML = `
      <section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input id="yq" type="search" placeholder="Name or Employee ID (new or previous)" aria-label="Search"></label>
          <select id="yco" aria-label="Paying company"><option value="all">All paying companies</option>${payers().map((c) => `<option value="${esc(c.code)}">${esc(c.short_name || c.name)}</option>`).join('')}</select>
          <div class="seg">${VIEWS.map(([k, l]) => `<button type="button" data-v="${k}" class="${f.view === k ? 'on' : ''}">${l} <span>${counts[k]}</span></button>`).join('')}</div>
        </div>
        <div class="table-wrap fill"><table class="data freeze2" id="ytable"><thead><tr><th>Employee ID</th><th>Name</th><th>Employer</th><th>Paid by now</th><th>Status</th><th>Start</th></tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="ycount"></p>
        <p class="muted small">Employer is the company on the contract. “Paid by now” comes from payroll; ★ marks the main company when two companies share the pay. Click a person to see the full timeline${can('payroll.paying', 'E') ? ', transfer, add a second company, end one, set the main company or correct a mistake' : ''}.</p>
      </section>`;
    const draw = () => {
      const t = f.q.trim().toLowerCase();
      const list = rows.filter((r) => inView(r, f.view) && (f.co === 'all' || (r.paid_by || []).includes(f.co))
        && (!t || `${r.name} ${r.employee_id || ''} ${r.previous_id || ''}`.toLowerCase().includes(t)));
      $('#ytable tbody', el).innerHTML = list.length ? list.map((r) => `<tr data-id="${esc(r.id)}" class="${r.in_payroll ? 'click' : ''}" ${r.in_payroll ? 'tabindex="0"' : ''}>
        <td class="nowrap"><code>${esc(r.employee_id || '—')}</code>${r.previous_id && r.previous_id !== r.employee_id ? `<small class="prev-id">was ${esc(r.previous_id)}</small>` : ''}</td>
        <td><b>${esc(r.name)}</b></td><td>${esc(coShort(r.company_code))}</td>
        <td>${r.in_payroll ? paidByCell(r) : '<span class="muted">not in payroll</span>'}</td>
        <td><span class="st st-${esc(r.status)}">${esc(r.status)}</span></td><td class="nowrap">${dShort(r.start_date)}</td></tr>`).join('')
        : `<tr><td colspan="6"><div class="empty small"><p>No one here</p><span>Try another view or clear the search.</span></div></td></tr>`;
      $('#ycount', el).textContent = `${list.length} ${list.length === 1 ? 'person' : 'people'}`;
    };
    draw();
    $('#yq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('#yco', el).addEventListener('change', (e) => { f.co = e.target.value; draw(); });
    $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.view = b.dataset.v; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
    const open = async (id) => {
      const r = rows.find((x) => x.id === id); if (!r || !r.in_payroll) return;
      if (await payingWindow(r)) { rows = await loadPeople(); state.people = rows; draw(); }
    };
    $('#ytable tbody', el).addEventListener('click', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) open(tr.dataset.id); });
    $('#ytable tbody', el).addEventListener('keydown', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr && e.key === 'Enter') open(tr.dataset.id); });
  }

  // ================================================================ INCREMENTS & REVIEWS (PRI-001)
  const INC_STATE = { overdue: ['Overdue', 'bad'], due: ['Due this month', 'warn'], soon: ['Next 3 months', 'info'], later: ['Later', ''], unknown: ['No date', ''] };
  const incTag = (r) => { const [l, c] = INC_STATE[r.state] || ['', '']; return `<span class="tag inc ${c} xs">${esc(l)}</span>`; };
  const salaryTxt = (amt, basis) => (amt == null ? '—' : `${money(amt)}${basis === 'hourly' ? ' /h' : ''}`);
  const changeTxt = (r) => (!r.last_change_date ? '<span class="muted">none since joining</span>'
    : `<b class="${r.last_change < 0 ? 'neg' : 'pos'}">${r.last_change < 0 ? '−' : '+'}${money(Math.abs(r.last_change)).replace('RM ', 'RM ')}</b><small class="sub">${monthTxt(r.last_change_date)}</small>`);
  async function loadIncrSummary() {
    if (!can('payroll.increments')) return;
    try {
      const rows = await API.rpc('cms_increments');
      state.incr = rows; state.incrSum = { overdue: rows.filter((r) => r.state === 'overdue').length, due: rows.filter((r) => r.state === 'due').length };
      drawBell();
    } catch (e) { /* reminders are a convenience */ }
  }

  async function incrementWindow(r0, onChange) {
    const canC = can('payroll.increments', 'C'); const canE = can('payroll.increments', 'E');
    let r = r0; let changed = false;
    let intervals = []; try { intervals = await API.rpc('cms_review_intervals'); } catch (e) { /* shown below */ }
    await modal({
      title: r.name, wide: true, ok: '', cancel: 'Close',
      body: `<div data-inc>${loading()}</div>`,
      onOpen: (wrap) => {
        const box = $('[data-inc]', wrap);
        const load = async () => {
          box.innerHTML = loading();
          let hist;
          try { [hist, [r]] = await Promise.all([API.rpc('cms_salary_changes', { p_employment: r.employment_id }), API.rpc('cms_increments', { p_person: r.person_id })]); }
          catch (e) { box.innerHTML = `<p class="form-err">${esc(e.message)}</p>`; return; }
          box.innerHTML = `
            <p class="muted small"><code>${esc(r.employee_id || '—')}</code> · ${esc(CONF[r.confirmation] || r.confirmation || '—')} · joined ${dShort(r.join_date)}${r.confirmed_date ? ` · confirmed ${dShort(r.confirmed_date)}` : ''} · paid by <b>${esc(coShort(r.paid_by))}</b></p>
            <div class="inc-sum">
              <div><span>Current salary</span><b>${salaryTxt(r.current_salary, r.pay_basis)}</b></div>
              <div><span>Last increment</span><b>${r.last_change_date ? `${r.last_change < 0 ? '−' : '+'}${money(Math.abs(r.last_change))}` : '—'}</b><small>${r.last_change_date ? monthTxt(r.last_change_date) : 'none since joining'}</small></div>
              <div><span>Review every</span><b>${esc(r.interval_label || '—')}</b><small>${r.interval_is_default ? 'default for this status' : 'set for this person'}</small></div>
              <div class="st-${esc(r.state)}"><span>Next review</span><b>${dShort(r.next_review)}</b><small>${r.next_review_set ? 'date set by hand' : `from ${dShort(r.base_date)}`} ${incTag(r)}</small></div>
            </div>
            ${r.review_note ? `<p class="muted small">Note: ${esc(r.review_note)}</p>` : ''}
            <div class="btn-row">${canC ? `<button type="button" class="btn primary sm" data-a="inc">${icon('plus')}Record increment</button>` : ''}${canE ? '<button type="button" class="btn sm" data-a="rev">Change review</button>' : ''}</div>
            <h4 class="inc-h">Salary history</h4>
            <div class="table-wrap fill-modal"><table class="data"><thead><tr><th>From</th><th>Salary</th><th>Change</th><th>Company</th><th>Reason</th></tr></thead><tbody>
              ${hist.map((h) => `<tr><td class="nowrap">${monthTxt(h.effective_from)}</td><td class="nowrap">${salaryTxt(h.amount, h.pay_basis)}</td>
                <td class="nowrap">${h.change == null ? '<span class="muted">start</span>' : h.change === 0 ? '<span class="muted">no change</span>' : `<b class="${h.change < 0 ? 'neg' : 'pos'}">${h.change < 0 ? '−' : '+'}${money(Math.abs(h.change))}</b>`}</td>
                <td>${esc(coShort(h.company))}</td><td class="small">${esc(h.reason || '')}${h.note ? `<br><span class="muted">${esc(h.note)}</span>` : ''}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">No salary recorded.</td></tr>'}
            </tbody></table></div>`;
          $('[data-a=inc]', box)?.addEventListener('click', recordInc);
          $('[data-a=rev]', box)?.addEventListener('click', changeReview);
        };
        const recordInc = async () => {
          const ok = await modal({ title: `Record increment · ${r.name}`, ok: 'Save increment',
            body: `<p class="muted small">Current salary ${salaryTxt(r.current_salary, r.pay_basis)} with ${esc(coShort(r.paid_by))}. The new salary applies from the month you choose; payroll picks it up from then. Months already finalised cannot be changed.</p>
              <div class="grid-2 tight"><label class="fld"><span>New salary (RM)</span><input type="text" inputmode="decimal" data-money name="amt" required value="${r.current_salary == null ? '' : m2(r.current_salary)}"></label>
              <label class="fld"><span>From payroll month</span><input type="month" name="m" required value="${monthNow()}"></label></div>
              <p class="muted small" data-diff></p>
              <label class="fld"><span>Reason</span><select name="reason"><option>Annual increment</option><option>Confirmation increment</option><option>Promotion</option><option>Merit increment</option><option>Adjustment</option></select></label>
              <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
            onOpen: (w) => { const f = $('form', w); const upd = () => { const d = mval(f.amt.value) - Number(r.current_salary || 0); $('[data-diff]', w).textContent = f.amt.value ? `Change: ${d < 0 ? '−' : '+'}${money(Math.abs(d))}${r.current_salary ? ` (${(d / r.current_salary * 100).toFixed(1)}%)` : ''}` : ''; }; f.amt.addEventListener('input', upd); upd(); setTimeout(() => f.amt.select(), 30); },
            onOk: async (f) => { if (!f.amt.value || !f.m.value) throw new Error('Enter the new salary and the month.');
              await API.rpc('cms_record_increment', { p_employment: r.employment_id, p_from: `${f.m.value}-01`, p_salary: mval(f.amt.value), p_reason: f.reason.value, p_note: f.note.value || null }); } });
          if (ok) { changed = true; toast(`Increment saved for ${r.name}`); load(); }
        };
        const changeReview = async () => {
          const ok = await modal({ title: `Review · ${r.name}`, ok: 'Save',
            body: `<label class="fld"><span>Review every</span><select name="iv"><option value="">Default for ${esc(CONF[r.confirmation] || 'this status')}</option>${intervals.filter((i) => i.is_active).map((i) => `<option value="${esc(i.code)}" ${!r.interval_is_default && r.interval_code === i.code ? 'selected' : ''}>${esc(i.label)}</option>`).join('')}</select></label>
              <label class="fld"><span>Next review date (optional, overrides the interval)</span><input type="date" name="next" value="${r.next_review_set ? esc(r.next_review) : ''}"></label>
              <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" value="${esc(r.review_note || '')}" placeholder="e.g. review together with confirmation"></label>
              <p class="muted small">A date set by hand is cleared when the next increment is recorded.</p>`,
            onOk: async (f) => { await API.rpc('cms_set_review', { p_employment: r.employment_id, p_interval: f.iv.value || null, p_next: f.next.value || null, p_note: f.note.value || null }); } });
          if (ok) { changed = true; toast('Review saved'); load(); }
        };
        load();
      },
    });
    if (changed) { loadIncrSummary(); onChange?.(); }
    return changed;
  }

  async function incrementsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="inc-body">${loading()}</div>`;
    let rows, intervals;
    try { [rows, intervals] = await Promise.all([API.rpc('cms_increments'), API.rpc('cms_review_intervals'), loadOrg()]); }
    catch (e) { $('#inc-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    rows.forEach((r) => upKeys(r, 'name')); state.incr = rows;
    // PRI-007/008: show where each salary sits against the level cap (Career Paths)
    const capFlag = new Map();
    if (can('careers')) try {
      const C = await API.rpc('cms_careers'); const byId = new Map(C.positions.map((p) => [p.id, p]));
      C.people.forEach((x) => { const pos = byId.get(x.position_id); const cap = pos ? levelCap(pos) : null;
        if (!pos || cap == null || !x.salary || (x.salary.basis && x.salary.basis !== 'monthly')) return;
        const s = Number(x.salary.amount); if (s > cap) capFlag.set(x.employee_id, ['bad', 'above cap']); else if (s >= cap * 0.95) capFlag.set(x.employee_id, ['warn', 'near cap']); });
    } catch (e) { /* the cap check is extra */ }
    const f = { q: '', v: rows.some((r) => r.state === 'overdue' || r.state === 'due') ? 'attention' : 'all' };
    const V = [['attention', 'Needs attention', (r) => r.state === 'overdue' || r.state === 'due'], ['overdue', 'Overdue', (r) => r.state === 'overdue'],
      ['due', 'Due this month', (r) => r.state === 'due'], ['soon', 'Next 3 months', (r) => r.state === 'soon'], ['all', 'All active staff', () => true]];
    const admin = can('payroll.increments', 'A');
    const draw = () => {
      const cnt = Object.fromEntries(V.map(([k, , fn]) => [k, rows.filter(fn).length]));
      $('#inc-body', el).innerHTML = `
        <section class="card">
          <div class="toolbar">
            <label class="search-in">${icon('search')}<input id="iq" type="search" placeholder="Name or Employee ID" aria-label="Search" value="${esc(f.q)}"></label>
            <div class="seg">${V.map(([k, l]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${cnt[k]}</span></button>`).join('')}</div>
          </div>
          <div class="table-wrap fill"><table class="data freeze2" id="itable"><thead><tr><th>Employee ID</th><th>Name</th><th>Paid by</th><th>Confirmation</th><th>Current salary</th><th>Last increment</th><th>Review every</th><th>Next review</th></tr></thead><tbody></tbody></table></div>
          <p class="muted small" id="icount"></p>
          <p class="muted small">Last increment is the last salary change in payroll. Next review = the later of the last increment, confirmation and join date, plus the review interval (or a date set by hand). Click a person to see the salary history, record an increment or change the review.</p>
        </section>
        <section class="card"><div class="card-head"><h3>${icon('calendar')}Review intervals</h3>${admin ? `<button type="button" class="btn sm" data-add-iv>${icon('plus')}Add interval</button>` : ''}</div>
          <div class="table-wrap"><table class="data"><thead><tr><th>Interval</th><th>Months</th><th>Default for</th><th>People</th><th>Status</th>${admin ? '<th></th>' : ''}</tr></thead><tbody>
          ${intervals.map((i) => `<tr><td><b>${esc(i.label)}</b> <code>${esc(i.code)}</code></td><td>${i.months}</td><td>${(i.default_for || []).map((c) => esc(CONF[c] || c)).join(', ') || '<span class="muted">—</span>'}</td>
            <td>${rows.filter((r) => r.interval_code === i.code).length}</td><td>${i.is_active ? '<span class="tag ok xs">active</span>' : '<span class="tag xs">inactive</span>'}</td>
            ${admin ? `<td><button type="button" class="btn sm ghost" data-iv="${esc(i.code)}">Edit</button></td>` : ''}</tr>`).join('')}
          </tbody></table></div>
          <p class="muted small">A confirmation status can be the default of one interval. ${admin ? 'Changes apply to everyone on the default straight away.' : 'Only an Admin can change the intervals.'}</p></section>`;
      const body = () => {
        const t = f.q.trim().toLowerCase(); const fn = V.find((x) => x[0] === f.v)[2];
        const list = rows.filter((r) => fn(r) && (!t || `${r.name} ${r.employee_id || ''}`.toLowerCase().includes(t)));
        $('#itable tbody', el).innerHTML = list.length ? list.map((r) => `<tr data-e="${r.employment_id}" class="click" tabindex="0">
          <td class="nowrap"><code>${esc(r.employee_id || '—')}</code></td><td><b>${esc(r.name)}</b></td><td>${esc(coShort(r.paid_by))}</td>
          <td class="nowrap">${confCell(r)}</td><td class="nowrap">${salaryTxt(r.current_salary, r.pay_basis)}${capFlag.has(r.employee_id) ? ` <span class="tag ${capFlag.get(r.employee_id)[0]} xs" title="Against the level cap in Career Paths">${capFlag.get(r.employee_id)[1]}</span>` : ''}</td><td class="nowrap">${changeTxt(r)}</td>
          <td class="nowrap">${esc(r.interval_label || '—')}${r.interval_is_default ? '' : ' <span class="tag xs" title="Set for this person">set</span>'}</td>
          <td class="nowrap"><b>${dShort(r.next_review)}</b> ${incTag(r)}${r.next_review_set ? '<small class="sub">set by hand</small>' : ''}</td></tr>`).join('')
          : '<tr><td colspan="8"><div class="empty small"><p>No one here</p><span>Try another view.</span></div></td></tr>';
        $('#icount', el).textContent = `${list.length} ${list.length === 1 ? 'person' : 'people'}`;
      };
      body();
      $('#iq', el).addEventListener('input', (e) => { f.q = e.target.value; body(); });
      $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); body(); }));
      const open = (id) => { const r = rows.find((x) => String(x.employment_id) === String(id)); if (r) incrementWindow(r, reload); };
      $('#itable tbody', el).addEventListener('click', (e) => { const tr = e.target.closest('tr[data-e]'); if (tr) open(tr.dataset.e); });
      $('#itable tbody', el).addEventListener('keydown', (e) => { const tr = e.target.closest('tr[data-e]'); if (tr && e.key === 'Enter') open(tr.dataset.e); });
      $$('[data-iv]', el).forEach((b) => b.addEventListener('click', () => editInterval(intervals.find((i) => i.code === b.dataset.iv))));
      $('[data-add-iv]', el)?.addEventListener('click', () => editInterval(null));
    };
    const reload = async () => { [rows, intervals] = await Promise.all([API.rpc('cms_increments'), API.rpc('cms_review_intervals')]); rows.forEach((r) => upKeys(r, 'name')); state.incr = rows; draw(); };
    const editInterval = async (iv) => {
      const ok = await modal({ title: iv ? `Edit ${iv.label}` : 'Add review interval', ok: 'Save',
        body: `<div class="grid-2 tight"><label class="fld"><span>Name</span><input name="label" maxlength="40" value="${esc(iv?.label || '')}" placeholder="e.g. 3 months"></label>
          <label class="fld"><span>Months</span><input type="number" name="months" min="1" max="60" required value="${iv?.months || ''}"></label></div>
          <fieldset class="fld"><legend>Default for these confirmation statuses</legend><div class="checks col stat">${['UP', 'C', 'CT', 'PT', 'INT'].map((c) => `<label><input type="checkbox" name="d_${c}" ${(iv?.default_for || []).includes(c) ? 'checked' : ''}> ${esc(CONF[c])}</label>`).join('')}</div></fieldset>
          <label class="fld"><span>Status</span><select name="act"><option value="1" ${iv?.is_active !== false ? 'selected' : ''}>Active</option><option value="0" ${iv?.is_active === false ? 'selected' : ''}>Inactive (not offered for new choices)</option></select></label>`,
        onOk: async (fm) => { if (!fm.months.value) throw new Error('Enter the number of months.');
          await API.rpc('cms_review_interval_save', { p_code: iv?.code || null, p_label: fm.label.value || null, p_months: Number(fm.months.value),
            p_default_for: ['UP', 'C', 'CT', 'PT', 'INT'].filter((c) => fm[`d_${c}`].checked), p_active: fm.act.value === '1', p_sort: iv?.sort_order ?? null }); } });
      if (ok) { toast('Review interval saved'); reload(); }
    };
    draw();
  }

  // ---------------------------------------------------------------- former staff: reason for leaving + rehire (PRI-002)
  const REHIRE_OPTS = [['', 'Not assessed'], ['eligible', 'Eligible for rehire'], ['conditional', 'Eligible, with conditions'], ['not_eligible', 'Not eligible for rehire']];
  function periodsTable(X) {
    const showSal = X.periods.some((p) => p.last_salary != null);
    return `<div class="table-wrap"><table class="data compact periods"><thead><tr><th>Joined</th><th>Last day</th><th>Position</th><th>Centre</th><th>Paid by</th>${showSal ? '<th class="num">Last salary</th>' : ''}<th>Reason for leaving</th><th>Rehire</th></tr></thead><tbody>
      ${X.periods.map((p) => `<tr><td class="nowrap">${dShort(p.join_date)}</td>
        <td class="nowrap">${p.resigned_date ? dShort(p.resigned_date) : '<span class="muted">still employed</span>'}${p.short_notice ? '<small class="sub"><span class="tag warn xs">left before notice ended</span></small>' : ''}</td>
        <td>${esc(p.position || '—')}</td><td>${esc(p.centre || '—')}</td><td>${esc(p.company || '—')}</td>
        ${showSal ? `<td class="num">${p.last_salary != null ? money(p.last_salary) : '—'}</td>` : ''}
        <td>${p.resigned_date ? (p.leaving_label ? esc(p.leaving_label) : '<span class="warn-txt">not recorded</span>') : ''}${p.leaving_note ? `<small class="sub">${esc(p.leaving_note)}</small>` : ''}</td>
        <td>${p.rehire ? `<span class="tag ${REHIRE_TXT[p.rehire][0]} xs">${esc(REHIRE_TXT[p.rehire][1])}</span>` : '<span class="muted">—</span>'}${p.rehire_note ? `<small class="sub">${esc(p.rehire_note)}</small>` : ''}</td></tr>`).join('')}
      </tbody></table></div>`;
  }
  async function exitWindow(r) {
    let X;
    try { X = await API.rpc('cms_person_exit', { p_person: r.id }); } catch (e) { toast(e.message, 'err'); return false; }
    const last = X.periods.find((p) => p.resigned_date) || {};
    const opt = (list, cur) => list.map(([v, l]) => `<option value="${esc(v)}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`).join('');
    let rehire = false;
    const ok = await modal({
      title: r.name, wide: true, ok: X.can_edit ? 'Save reason' : null, cancel: 'Close',
      body: `<p class="muted small">${esc(r.employee_id || '')} · ${X.periods.length} employment period${X.periods.length === 1 ? '' : 's'} in payroll${X.periods.length > 1 ? ' · rehired before' : ''}</p>
        ${periodsTable(X)}
        ${X.can_edit ? `<h4 class="sec-h">Reason for leaving · last day ${dShort(last.resigned_date)}</h4>
          <div class="fld-2"><label class="fld"><span>Reason for leaving</span><select name="reason" required><option value="">Choose…</option>${opt(X.reasons.map((x) => [x.code, x.label]), last.leaving_reason)}</select></label>
            <label class="fld"><span>Rehire</span><select name="rehire">${opt(REHIRE_OPTS, last.rehire)}</select></label></div>
          <label class="fld"><span>Details <small class="muted" id="needs"></small></span><textarea class="ta" name="note" rows="2" maxlength="500">${esc(last.leaving_note || '')}</textarea></label>
          <label class="fld"><span>Rehire note <small class="muted">— conditions, or why not eligible</small></span><textarea class="ta" name="rnote" rows="2" maxlength="500">${esc(last.rehire_note || '')}</textarea></label>
          <div class="rehire-cta"><div><b>Rehire ${esc(r.name)}</b><span class="muted small">Starts a new employment period with the same Employee ID (${esc(r.employee_id || '—')}).</span></div>
            <button type="button" class="btn" data-rehire>${icon('user-plus')} Rehire…</button></div>`
        : '<p class="muted small">Only HR and Admin can change the reason for leaving or rehire.</p>'}`,
      onOpen: (wrap, close) => {
        const form = $('form', wrap);
        const needs = () => { const x = X.reasons.find((y) => y.code === form.reason?.value); const n = $('#needs', wrap); if (n) n.textContent = x?.needs_note ? '(required for “Other”)' : ''; };
        form.reason?.addEventListener('change', needs); needs();
        $('[data-rehire]', wrap)?.addEventListener('click', () => { rehire = true; close(null); });
        setTimeout(() => form.reason?.focus(), 30);
      },
      onOk: async (form) => {
        await API.rpc('cms_set_leaving', { p_person: r.id, p_reason: form.reason.value || null, p_note: form.note.value || null, p_rehire: form.rehire.value || null, p_rehire_note: form.rnote.value || null });
      },
    });
    if (ok) { toast(`Saved the reason for ${r.name}`); return 'saved'; }
    if (rehire) return (await rehireWindow(r, X)) ? 'rehired' : false;
    return false;
  }
  async function rehireWindow(r, X) {
    const blocked = X.periods.some((p) => p.rehire === 'not_eligible');
    const last = X.periods[0] || {};
    const today = new Date(); const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const opt = (list, cur, blank) => `${blank ? `<option value="">${esc(blank)}</option>` : ''}${list.map(([v, l]) => `<option value="${esc(v)}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`).join('')}`;
    const comp0 = X.companies.find((c) => (last.company || '').includes(c.name)) || X.companies[0] || {};
    return modal({
      title: `Rehire ${r.name}`, wide: true, ok: blocked && !X.can_override ? null : 'Rehire', cancel: 'Cancel',
      body: `<p class="muted small">Previous employment — check before rehiring.</p>${periodsTable(X)}
        ${blocked ? `<p class="${X.can_override ? 'warn-box' : 'err-box'}">Marked <b>not eligible for rehire</b>. ${X.can_override ? 'As Admin you can still rehire: give the override reason below. It is kept in the employment notes and the audit log.' : 'Only an Admin can rehire, with an override reason.'}</p>` : ''}
        <div class="fld-2">
          <label class="fld"><span>New date joined</span><input type="date" name="join" required min="${esc(last.resigned_date || '')}" value="${iso(today)}"></label>
          <label class="fld"><span>Paying company</span><select name="company" required>${opt(X.companies.map((c) => [c.id, c.name]), comp0.id)}</select></label>
          <label class="fld"><span>Centre / department</span><select name="dept">${opt(X.departments.map((d) => [d.id, d.code === d.name ? d.code : `${d.code} · ${d.name}`]), null, 'Not set')}</select></label>
          <label class="fld"><span>Job title</span><select name="title">${opt(X.titles.map((t) => [t.id, t.name]), null, 'Not set')}</select></label>
          <label class="fld"><span>Employment status</span><select name="conf">${opt(X.statuses.map((x) => [x.code, x.label]), 'UP')}</select></label>
          <label class="fld"><span>Job status</span><select name="job">${opt(X.job_statuses.map((x) => [x.code, x.label]), null, 'Same as before')}</select></label>
        </div>
        ${blocked && X.can_override ? '<label class="fld"><span>Override reason (Admin)</span><textarea class="ta" name="override" rows="2" required maxlength="500"></textarea></label>' : ''}
        <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" placeholder="e.g. returning after studies"></label>
        <p class="muted small">Keeps Employee ID <b>${esc(r.employee_id || '—')}</b>. The new period starts its own service, leave and notice; working hours and OT settings are copied from the last period. Add the salary in MyPayroll (Employee › Pay) before the first payroll.</p>`,
      onOk: async (form) => {
        if (!form.join.value) throw new Error('Enter the new date joined.');
        if (last.resigned_date && form.join.value <= last.resigned_date) throw new Error(`The new date joined must be after the last working day (${dShort(last.resigned_date)}).`);
        if (blocked && !(form.override?.value || '').trim()) throw new Error('Give the override reason.');
        await API.rpc('cms_rehire', { p: { person: r.id, join_date: form.join.value, company_id: Number(form.company.value), department_id: form.dept.value || null,
          job_title_id: form.title.value || null, confirmation_status: form.conf.value || 'UP', job_status: form.job.value || null, note: form.note.value || null, override_reason: form.override?.value || null } });
      },
    });
  }

  async function peoplePage(item, el) {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const f = { q: params.get('q') || '', status: item.route === 'people/former' ? 'former' : params.get('q') ? 'all' : 'active', co: 'all', noReason: params.get('missing') === 'reason' };
    el.innerHTML = `${pageHead(item)}<div id="people-body">${loading()}</div>`;
    let rows;
    try { [rows] = await Promise.all([loadPeople(), loadOrg(), can('payroll.increments') ? loadIncrSummary() : null, can('handbook') ? loadHandbook() : null]); state.people = rows; }
    catch (e) { $('#people-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const editable = can('people', 'E'); const payView = can('payroll.paying');
    const hbCol = can('handbook') && !!state.hb;
    const clickable = editable || payView;
    const exitRow = (r) => r.status === 'former' && r.in_payroll;           // former staff open the leaving / rehire window
    const noReason = (r) => r.status === 'former' && !(r.leave && r.leave.leaving_reason);
    const counts = Object.fromEntries(STATUS.map(([k]) => [k, rows.filter((r) => inStatus(r, k)).length]));
    const cos = [...new Set(rows.map((r) => r.company_code).filter(Boolean))].sort();
    $('#people-body', el).innerHTML = `
      <section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input id="pq" type="search" placeholder="Name, Employee ID (new or previous), title or department" value="${esc(f.q)}" aria-label="Search people"></label>
          <select id="pco" aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}">${esc(coShort(c))}</option>`).join('')}</select>
          <div class="seg">${STATUS.map(([k, l]) => `<button type="button" data-st="${k}" class="${f.status === k ? 'on' : ''}">${l} <span>${counts[k]}</span></button>`).join('')}</div>
          <button type="button" id="pnoreason" class="chip-filter ${f.noReason ? 'on' : ''}" title="Former staff whose reason for leaving is not recorded">Reason missing <span>${rows.filter(noReason).length}</span></button>
        </div>
        <div class="table-wrap fill"><table class="data freeze2" id="ptable"><thead><tr><th>Employee ID</th><th>Name</th><th>Employer</th><th>Paid by</th><th>Centre</th><th>Title</th><th>Status</th><th>Start</th><th>Confirmation</th>${can('payroll.increments') ? '<th>Next review</th>' : ''}<th>Notice until</th><th>Last working day</th>${hbCol ? '<th>Handbook</th>' : ''}</tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="pcount"></p>
        <p class="muted small">Employer is the company on the contract (Employee Master). “Paid by” is the paying company for payroll; “same” means the employer pays; two companies means joint payment, main company first. The previous ID is shown under the Employee ID.${clickable ? ` Click a row to see${can('payroll.paying', 'E') ? ' and change' : ''} the paying companies${editable ? ' and centre' : ''}.` : ''} Confirmation, notice, last working day, leaving reason and rehire eligibility come from payroll; notice is counted from the resignation letter by the notice-period policy unless HR set an agreed date. IC, bank and salary details are not shown here.</p>
      </section>`;
    const incCol = can('payroll.increments'); const incBy = new Map((state.incr || []).map((x) => [x.person_id, x]));
    const hbBy = new Map((state.hb || []).map((x) => [x.person_id, x]));
    const reviewCell = (x) => !x ? '<span class="muted">—</span>' : `${dShort(x.next_review)} ${incTag(x)}<small class="sub">${x.last_change_date ? `last ${x.last_change < 0 ? '−' : '+'}${money(Math.abs(x.last_change))} · ${monthTxt(x.last_change_date)}` : 'no increment yet'}</small>`;
    const draw = () => {
      const t = f.q.trim().toLowerCase();
      const list = rows.filter((r) => (f.noReason ? noReason(r) : inStatus(r, f.status)) && (f.co === 'all' || r.company_code === f.co)
        && (!t || `${r.name} ${r.employee_id || ''} ${r.previous_id || ''} ${r.job_title || ''} ${r.department || ''} ${r.unit_code || ''}`.toLowerCase().includes(t)));
      $('#ptable tbody', el).innerHTML = list.length ? list.map((r) => `<tr data-id="${esc(r.id)}" class="${clickable || exitRow(r) ? 'click' : ''}" ${clickable || exitRow(r) ? 'tabindex="0"' : ''}>
        <td class="nowrap"><code>${esc(r.employee_id || '—')}</code>${r.previous_id && r.previous_id !== r.employee_id ? `<small class="prev-id" title="Previous Employee ID">was ${esc(r.previous_id)}</small>` : ''}</td><td><b>${esc(r.name)}</b>${r.login_email ? ` <span class="tag ok xs" title="CMS login: ${esc(r.login_email)}">login</span>` : ''}</td>
        <td>${esc(coShort(r.company_code))}</td>
        <td>${paidByCell(r)}</td>
        <td>${esc(r.unit_code || '—')}</td>
        <td>${esc(r.job_title || '—')}${r.level ? ` <span class="muted">${esc(r.level)}</span>` : ''}</td>
        <td><span class="st st-${esc(r.status)}">${esc(r.status)}</span></td>
        <td class="nowrap">${dShort(r.start_date)}</td>
        <td class="nowrap">${confCell(r)}</td>${incCol ? `<td class="nowrap">${reviewCell(incBy.get(r.id))}</td>` : ''}<td class="nowrap">${noticeCell(r)}</td>
        <td class="nowrap">${lastDayCell(r)}</td>${hbCol ? `<td class="nowrap">${r.status === 'former' ? '<span class="muted">—</span>' : hbCell(hbBy.get(r.id) || { })}</td>` : ''}</tr>`).join('')
        : `<tr><td colspan="${(incCol ? 12 : 11) + (hbCol ? 1 : 0)}"><div class="empty small"><p>No one matches</p><span>Try another status or clear the search.</span></div></td></tr>`;
      $('#pcount', el).textContent = `${list.length} of ${rows.length} people`;
    };
    draw();
    $('#pq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('#pco', el).addEventListener('change', (e) => { f.co = e.target.value; draw(); });
    $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.status = b.dataset.st; f.noReason = false; $('#pnoreason', el).classList.remove('on'); $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
    $('#pnoreason', el).addEventListener('click', (e) => {
      f.noReason = !f.noReason; e.currentTarget.classList.toggle('on', f.noReason);
      if (f.noReason) { f.status = 'former'; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x.dataset.st === 'former')); }
      draw();
    });
    const edit = async (id) => {
      const r = rows.find((x) => x.id === id); if (!r) return;
      if (exitRow(r)) {
        const changed = await exitWindow(r);
        if (changed) { state.people = null; peoplePage(item, el); if (changed === 'rehired') toast(`${r.name} rehired: now in Active`); }
        return;
      }
      if (!clickable) return;
      if (r.in_payroll && payView) {   // payroll knows who pays: open the paying-companies window
        const changed = await payingWindow(r, editable ? { unit: true } : {});
        if (changed) { state.people = null; rows = await loadPeople(); state.people = rows; draw(); }
        return;
      }
      if (!editable) return;
      const payers = (state.org?.companies || []).filter((c) => c.is_active && c.is_paying);
      const units = (state.org?.units || []).filter((u) => u.is_active);
      const ok = await modal({
        title: r.name,
        body: `<p class="muted small">${esc(r.employee_id || 'No Employee ID')} · employer on the contract: <b>${esc(coShort(r.company_code))}</b></p>
          <label class="fld"><span>Paying company</span><select name="pay"><option value="">Same as employer (${esc(coShort(r.company_code))})</option>${payers.map((c) => `<option value="${esc(c.code)}" ${r.manual_paying_code === c.code ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
          <label class="fld"><span>Centre / unit</span><select name="unit"><option value="">Not set</option>${units.map((u) => `<option value="${esc(u.code)}" ${r.unit_code === u.code ? 'selected' : ''}>${esc(u.code)} · ${esc(u.name)}</option>`).join('')}</select></label>
          <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" placeholder="e.g. paid by Edu Hub from Jan 2026"></label>
          <p class="muted small">Saved with an audit entry. ${r.in_payroll ? '' : 'This person has no payroll record yet, so the paying company is noted here until payroll adds them.'}</p>`,
        onOk: async (form) => {
          const pay = form.pay.value || null; const unit = form.unit.value || null;
          await API.rpc('cms_set_person_payroll', { p_person: r.id, p_paying_company: pay, p_unit: unit, p_note: form.note.value || null });
          r.paying_company_code = pay; r.manual_paying_code = pay; r.unit_code = unit;
        },
      });
      if (ok) { toast(`Saved ${r.name}`); draw(); }
    };
    $('#ptable tbody', el).addEventListener('click', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) edit(tr.dataset.id); });
    $('#ptable tbody', el).addEventListener('keydown', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr && e.key === 'Enter') edit(tr.dataset.id); });
  }

  // ================================================================ ORGANISATION / COMPANIES
  async function orgPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="org-body">${loading()}</div>`;
    let o; try { o = await loadOrg(true); } catch (e) { $('#org-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const active = o.companies.filter((c) => c.is_active); const old = o.companies.filter((c) => !c.is_active);
    const unitsBy = (code) => o.units.filter((u) => u.company_code === code && u.is_active);
    const isAdminPage = item.route === 'admin/companies';
    $('#org-body', el).innerHTML = `
      <div class="cos big">${active.map((c) => `<section class="card co"><span class="co-logo lg">${c.logo ? `<img src="${esc(asset(c.logo))}" alt="${esc(c.short_name)} logo">` : icon('building')}</span>
        <div><b>${esc(c.name)}</b><small><code>${esc(c.code)}</code>${c.aliases?.length ? ` · also written ${esc(c.aliases.join(', '))}` : ''}</small>
        <div class="co-stats"><span><b>${num(c.employed)}</b>employed</span><span><b>${num(c.paid)}</b>paid</span><span><b>${num(c.jd_positions)}</b>JD positions</span></div>
        <small>${unitsBy(c.code).map((u) => esc(u.code)).join(' · ') || 'No centres'}</small></div></section>`).join('')}</div>
      <div class="grid-2">
        <section class="card"><div class="card-head"><h3>${icon('building')}Centres and units</h3><span class="tag live">Live</span></div>
          <div class="table-wrap"><table class="data"><thead><tr><th>Code</th><th>Name</th><th>Company</th><th>Status</th></tr></thead><tbody>
          ${o.units.map((u) => `<tr class="${u.is_active ? '' : 'dim'}"><td><code>${esc(u.code)}</code></td><td>${esc(u.name)}${u.note ? `<br><small class="muted">${esc(u.note)}</small>` : ''}</td><td>${esc(u.company_code ? coShort(u.company_code) : '—')}</td><td>${u.is_active ? '<span class="st st-active">active</span>' : '<span class="st st-former">inactive</span>'}</td></tr>`).join('')}</tbody></table></div></section>
        <section class="card"><div class="card-head"><h3>${icon('briefcase')}JD departments</h3><span class="muted small">From the JD Manual</span></div>
          <div class="table-wrap tall"><table class="data"><thead><tr><th>Company</th><th>Department</th><th>Positions</th></tr></thead><tbody>
          ${o.departments.map((d) => `<tr><td>${esc(coShort(d.company))}</td><td>${esc(d.name)}</td><td>${num(d.positions)}</td></tr>`).join('')}</tbody></table></div></section>
      </div>
      <section class="card"><div class="card-head"><h3>${icon('list')}Old and inactive codes</h3><span class="muted small">Kept so older records still resolve</span></div>
        <div class="table-wrap"><table class="data"><thead><tr><th>Code</th><th>Name</th><th>Note</th></tr></thead><tbody>
        ${old.map((c) => `<tr class="dim"><td><code>${esc(c.code)}</code></td><td>${esc(c.name)}</td><td>${esc(c.note || '')}</td></tr>`).join('')}</tbody></table></div>
        ${isAdminPage ? '<p class="muted small">Editing companies, letterheads, statutory numbers and holidays comes in a later update.</p>' : ''}</section>`;
  }

  // ================================================================ CLAIMS (Phase 1)
  const STAGES = [['approval', 'Waiting for approval'], ['processing', 'Ready to process'], ['payment', 'Waiting for payment'], ['paid', 'Paid'], ['disapproved', 'Disapproved']];
  const WAITING = ['approval', 'processing', 'payment'];
  const FORM_APP = { scf: 'MEG-SCF', otcf: 'MEG-OTCF', mtcf: 'MEG-MTCF', tec: 'MEG-TEC', 'tec-v2': 'MEG-TEC-V2', prfaf: 'MEG-PRFAF' };
  const stageTag = (c) => `<span class="st st-${esc(c.stage)}">${esc(c.display_status)}</span>`;
  const fmtAmt = (c) => (c.amount === null || c.amount === undefined) ? '—' : c.amount_unit === 'RM' ? money(c.amount) : `${num(c.amount)} ${esc(c.amount_unit)}`;

  // list + filters, used by Approvals (all forms) and by each form page
  function claimsView(el, rows, { showForm, defaultFilter = 'waiting', onOpen, onChanged }) {
    const f = { stage: defaultFilter, q: '', co: 'all' };
    const count = (k) => k === 'all' ? rows.length : k === 'waiting' ? rows.filter((r) => WAITING.includes(r.stage)).length : rows.filter((r) => r.stage === k).length;
    const cos = [...new Set(rows.map((r) => r.company_code).filter(Boolean))].sort();
    const chips = [['waiting', 'Waiting'], ...STAGES, ['all', 'All']];
    el.innerHTML = `<section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input type="search" data-cq placeholder="Serial no., claimant or Employee ID" aria-label="Search claims"></label>
          ${cos.length > 1 ? `<select data-cco aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}">${esc(coShort(c))}</option>`).join('')}</select>` : ''}
          <div class="seg">${chips.map(([k, l]) => `<button type="button" data-cs="${k}" class="${f.stage === k ? 'on' : ''}">${esc(l)} <span>${count(k)}</span></button>`).join('')}</div>
        </div>
        <div class="bulk" hidden><span data-bn></span><button type="button" class="btn sm ghost" data-bclear>Clear</button><button type="button" class="btn sm danger" data-bno>Disapprove selected</button><button type="button" class="btn sm primary" data-bgo>Approve selected</button></div>
        <div class="table-wrap fill"><table class="data claims freeze2"><thead><tr><th class="sel"><span class="sr">Select</span></th><th>Serial no.</th>${showForm ? '<th>Form</th>' : ''}<th>Claimant</th><th>Company</th><th class="num">Amount</th><th>Submitted</th><th>Status</th></tr></thead><tbody></tbody></table></div>
        <p class="muted small" data-ccount></p></section>`;
    const draw = () => {
      const t = f.q.trim().toLowerCase();
      const list = rows.filter((r) => (f.stage === 'all' || (f.stage === 'waiting' ? WAITING.includes(r.stage) : r.stage === f.stage))
        && (f.co === 'all' || r.company_code === f.co)
        && (!t || `${r.serial_no} ${r.claimant_name} ${r.employee_id || ''}`.toLowerCase().includes(t)))
        .sort((a, b) => new Date(b.event_at || b.submitted_at) - new Date(a.event_at || a.submitted_at));
      $('tbody', el).innerHTML = list.length ? list.map((r) => `<tr class="click" tabindex="0" data-f="${esc(r.form_code)}" data-id="${esc(r.id)}">
          <td class="sel">${canDecide(r) ? `<input type="checkbox" data-pick="${esc(r.form_code)}|${esc(r.id)}" ${picked.has(`${r.form_code}|${r.id}`) ? 'checked' : ''} aria-label="Select ${esc(r.serial_no)}">` : ''}</td>
          <td><code>${esc(r.serial_no)}</code></td>${showForm ? `<td>${esc(r.form_name)}</td>` : ''}
          <td><b>${esc(r.claimant_name)}</b>${r.employee_id ? `<br><small class="muted">${esc(r.employee_id)}</small>` : ''}</td>
          <td>${esc(r.company_code ? coShort(r.company_code) : '—')}</td><td class="num nowrap">${fmtAmt(r)}</td>
          <td class="nowrap">${dShort(r.submitted_at)}</td><td>${stageTag(r)}${r.stage === 'approval' && r.is_mine ? ' <span class="tag mine">Yours</span>' : ''}</td></tr>`).join('')
        : `<tr><td colspan="${showForm ? 8 : 7}"><div class="empty small">${icon('check-circle')}<p>Nothing here</p><span>${f.stage === 'waiting' ? 'No claims are waiting.' : 'Try another filter or clear the search.'}</span></div></td></tr>`;
      $('[data-ccount]', el).textContent = `${list.length} of ${rows.length} claims · drafts and deleted claims are not shown`;
      drawBulk();
    };
    const picked = new Set();
    const drawBulk = () => {
      const b = $('.bulk', el); b.hidden = picked.size === 0;
      const tec = [...picked].every((k) => k.startsWith('tec'));
      $('[data-bn]', el).textContent = `${picked.size} selected`;
      $('[data-bgo]', el).textContent = tec ? 'Mark selected as done' : 'Approve selected';
      const noTec = [...picked].every((k) => !k.startsWith('tec'));
      $('[data-bno]', el).hidden = !noTec;
    };
    $('[data-bclear]', el).addEventListener('click', () => { picked.clear(); draw(); });
    const pickedItems = () => [...picked].map((k) => { const [f, i] = k.split('|'); return rows.find((r) => r.form_code === f && r.id === i); }).filter(Boolean);
    const planList = (items) => `<ul class="plan">${items.map((r) => `<li>${esc(r.serial_no)} · ${esc(r.claimant_name)} · ${fmtAmt(r)}</li>`).join('')}</ul>`;
    $('[data-bno]', el).addEventListener('click', async () => {
      const items = pickedItems().filter((r) => !r.form_code.startsWith('tec'));
      if (!items.length) return;
      let reason = null;
      const ok = await modal({ title: `Disapprove ${items.length} claim${items.length > 1 ? 's' : ''}`, ok: `Disapprove ${items.length} claim${items.length > 1 ? 's' : ''}`, danger: true, wide: true,
        body: `<p class="small">Every claim below gets the same reason, and each claimant is notified.</p>${planList(items)}
          <label class="fld"><span>Reason (the claimants see this)</span><textarea name="reason" rows="3" maxlength="1000" required class="ta"></textarea></label>`,
        onOk: (f) => { reason = f.reason.value.trim(); if (!reason) throw new Error('Give a reason for disapproving.'); } });
      if (!ok) return;
      await runBulk(items, 'Disapproving', () => 'disapprove', reason);
    });
    $('[data-bgo]', el).addEventListener('click', async () => {
      const items = pickedItems();
      if (!items.length) return;
      const ok = await confirmBox(`Approve ${items.length} claim${items.length > 1 ? 's' : ''}?`, `Each one is approved (teacher tuition claims marked as done), gets its signed PDF and its claimant is notified.${planList(items)}`, `Approve ${items.length} claim${items.length > 1 ? 's' : ''}`, false);
      if (!ok) return;
      await runBulk(items, 'Approving', (r) => r.form_code.startsWith('tec') ? 'done' : 'approve', null);
    });
    async function runBulk(items, title, decOf, reason) {
      await modal({ title, ok: null, cancel: 'Close', wide: true, body: '<div class="decide-log big"></div>', onOpen: async (wrap) => {
        const logEl = $('.decide-log', wrap); const closeBtn = $('.modal-foot [data-x]', wrap); closeBtn.disabled = true;
        for (const r of items) {
          logEl.insertAdjacentHTML('beforeend', `<h4>${esc(r.serial_no)} · ${esc(r.claimant_name)}</h4>`);
          const log = (m, tone) => logEl.insertAdjacentHTML('beforeend', `<div class="lg ${tone || ''}">${icon(tone === 'ok' ? 'check-circle' : tone === 'err' ? 'x' : 'clock')}<span>${esc(m)}</span></div>`);
          try { await decideClaim(r.form_code, r.id, decOf(r), reason, log); } catch (x) { log(x.message, 'err'); }
          picked.delete(`${r.form_code}|${r.id}`);
        }
        logEl.insertAdjacentHTML('beforeend', '<p class="muted small">Finished.</p>'); closeBtn.disabled = false;
      } });
      if (onChanged) onChanged();
    }
    draw();
    $('[data-cq]', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('[data-cco]', el)?.addEventListener('change', (e) => { f.co = e.target.value; draw(); });
    $$('[data-cs]', el).forEach((b) => b.addEventListener('click', () => { f.stage = b.dataset.cs; $$('[data-cs]', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
    const open = (tr) => tr && onOpen(tr.dataset.f, tr.dataset.id);
    $('tbody', el).addEventListener('click', (e) => {
      const cb = e.target.closest('input[data-pick]');
      if (cb) { if (cb.checked) picked.add(cb.dataset.pick); else picked.delete(cb.dataset.pick); drawBulk(); return; }
      if (e.target.closest('td.sel')) return;
      open(e.target.closest('tr[data-id]'));
    });
    $('tbody', el).addEventListener('keydown', (e) => { if (e.key === 'Enter') open(e.target.closest('tr[data-id]')); });
  }

  // values in a claim, shown as label / value pairs and tables
  const SKIP = /^(id|submitted_by|approved_by|disapproved_by|done_by|revision_returned_by|ledger_account_id|fund_in_transaction_id|purchase_out_transaction_id|pdf_url|deleted_at|deleted_by_name|approval_token|updated_at)$/;
  const nice = (k) => String(k).replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()).replace(/\bRm\b/, 'RM').replace(/\bKm\b/, 'km');
  const showVal = (v, k) => {
    if (v === true) return 'Yes'; if (v === false) return 'No';
    if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v)) return dtShort(v);
    if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) return dShort(v);
    if (typeof v === 'number' && /amount|total|subtotal|pay|rate|price|claim/i.test(k)) return Number(v).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return esc(v);
  };
  function claimDetailsHtml(c) {
    const scal = Object.entries(c).filter(([k, v]) => !SKIP.test(k) && v !== null && v !== '' && typeof v !== 'object');
    const arrs = Object.entries(c).filter(([k, v]) => Array.isArray(v) && v.length && typeof v[0] === 'object' && v[0] !== null);
    const table = (k, arr) => {
      const cols = [...new Set(arr.flatMap((r) => Object.keys(r).filter((x) => r[x] !== null && typeof r[x] !== 'object' && !SKIP.test(x))))].slice(0, 9);
      return `<h4>${esc(nice(k))} <span class="muted">(${arr.length})</span></h4><div class="table-wrap fill-modal"><table class="data mini"><thead><tr>${cols.map((x) => `<th>${esc(nice(x))}</th>`).join('')}</tr></thead>
        <tbody>${arr.map((r) => `<tr>${cols.map((x) => `<td>${r[x] === undefined || r[x] === null ? '' : showVal(r[x], x)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
    };
    return `<dl class="kv">${scal.map(([k, v]) => `<div><dt>${esc(nice(k))}</dt><dd>${showVal(v, k)}</dd></div>`).join('')}</dl>${arrs.map(([k, v]) => table(k, v)).join('')}`;
  }

  const DECIDABLE = ['otcf', 'mtcf', 'tec', 'tec-v2'];
  const isDirector = () => (state.access?.roles || []).some((r) => r.code === 'director');
  const canDecide = (r) => r.stage === 'approval' && DECIDABLE.includes(r.form_code) && can3(r.module, 'A', r.company_code)
    && !r.is_mine && (!r.needs_director || isDirector());
  // claims plus, for those still waiting, whether each is the viewer's own and whether it needs the CEO / a Director
  async function loadClaims(form) {
    const [rows, flags] = await Promise.all([API.rpc('cms_claims', form ? { p_form: form } : {}), API.rpc('cms_claim_flags').catch(() => [])]);
    const fl = new Map((flags || []).map((x) => [`${x.form_code}|${x.id}`, x]));
    return rows.map((r) => {
      const x = fl.get(`${r.form_code}|${r.id}`) || {};
      const o = upKeys({ ...r, is_mine: !!x.is_mine, needs_director: !!x.needs_director }, 'claimant_name');
      if (o.stage === 'approval' && o.needs_director) o.display_status = 'Waiting for CEO / Director';
      return o;
    });
  }
  // approve / disapprove / mark as done, then the signed PDF and the claimant notification, exactly as the form apps do
  async function decideClaim(form, id, dec, reason, log) {
    const r = await API.rpc('cms_claim_decide', { p_form: form, p_id: id, p_decision: dec, p_reason: reason || null });
    log(dec === 'approve' ? 'Approved' : dec === 'done' ? 'Marked as done' : 'Disapproved', 'ok');
    let pdf = null;
    if (window.CMS_CLAIM_PDF.supported(form) && (dec === 'approve' || form === 'otcf')) {
      try {
        log('Creating the signed PDF…');
        pdf = await window.CMS_CLAIM_PDF.makePdf(form, r, dec);
        if (pdf) { await window.CMS_CLAIM_PDF.savePdf(form, id, pdf.blob, pdf.fileName); log('Signed PDF saved to the claim', 'ok'); }
      } catch (e) { pdf = null; log(`PDF not created (${e.message}). The decision stands; print it from the form app.`, 'err'); }
    }
    if (form === 'otcf' || form === 'mtcf') {
      try {
        const { error } = await API.sb().functions.invoke(`${form}-notify`, { body: { event: dec === 'approve' ? 'approved' : 'disapproved', submission_id: id } });
        if (error) throw error;
        log('Claimant notified', 'ok');
      } catch (e) {
        // read the email function's own message (e.g. the email service is still in test mode)
        let why = e.message || String(e);
        try { const b = await e.context.json(); if (b && b.error) why = b.error; } catch (x) { /* keep the generic message */ }
        log(/only send testing emails/i.test(why)
          ? 'Email not sent: the email service (Resend) is still in test mode and only delivers to myeden.group@gmail.com. The decision stands. See Known issues in the README.'
          : `Email not sent (${why}). The decision stands.`, 'err');
      }
    }
    return { row: r, pdf };
  }
  const can3 = (module, a, co) => can(module, a) && (!co || isSuper() || (state.access.roles || []).some((r) => !r.companies || r.companies.includes(co)));

  async function openClaim(form, id, after) {
    let changed = false;
    await modal({
      title: 'Claim', wide: true, ok: null, cancel: 'Close', body: `<div class="claim-body">${loading()}</div>`,
      onOpen: (wrap) => {
        const box = $('.claim-body', wrap); const head = $('.modal-head h3', wrap);
        const load = async () => {
          let d;
          try { d = await API.rpc('cms_claim', { p_form: form, p_id: id }); upKeys(d.claim, 'claimed_by', 'approved_by_name', 'name'); } catch (e) { box.innerHTML = `<p class="form-err">${esc(e.message)}</p>`; return; }
          const row = (await loadClaims(form)).find((r) => r.id === id) || {};
          const c = d.claim; const p = d.processing || {}; const fin = d.finance || {};
          head.textContent = `${row.form_name || form.toUpperCase()} · ${row.serial_no || c.serial_no || ''}`;
          const app = FORM_APP[form];
          const canPro = d.can_edit && row.processing_eligible; const paid = row.payment_status === 'done';
          box.innerHTML = `
            <div class="claim-top">${stageTag(row)}<span class="claim-amt">${fmtAmt(row)}</span>
              <span class="muted">${esc(row.claimant_name || '')}${d.person ? ` · <a href="#/people?q=${encodeURIComponent(d.person.employee_id || row.claimant_name)}" data-x>${esc(d.person.employee_id || 'Employee Master')}</a>` : ' · not matched to the Employee Master'} · ${esc(d.company_code ? coShort(d.company_code) : '—')}</span></div>
            ${row.stage === 'approval' ? (d.is_mine ? `<div class="claim-note">${icon('shield')}<div><b>Your own claim</b><p>Someone else must decide this claim${d.needs_director ? ': the CEO / a Director' : ''}.</p></div></div>`
              : d.needs_director && !d.is_director ? `<div class="claim-note">${icon('shield')}<div><b>Waiting for CEO / Director</b><p>This claim was submitted by a Super Admin or Admin, so only the CEO / a Director can approve or disapprove it.</p></div></div>`
              : d.can_approve && DECIDABLE.includes(form) ? `<div class="claim-note decide">${icon('check-circle')}<div><b>Waiting for ${form.startsWith('tec') ? 'you to mark it as done' : 'your decision'}</b><p>${form.startsWith('tec') ? 'Recorded with your name and the time, as in MEG-TEC.' : `Approving records your name, the time and an approval code, creates the signed PDF (the same one ${esc(app)} makes) and emails the claimant.`}</p></div>
                <div class="decide-btns">${form.startsWith('tec') ? '<button type="button" class="btn primary sm" data-act="done">Mark as done</button>' : '<button type="button" class="btn ghost sm" data-act="disapprove">Disapprove</button><button type="button" class="btn primary sm" data-act="approve">Approve</button>'}</div></div>
                <div class="decide-log" hidden></div>`
              : `<div class="claim-note">${icon('check-circle')}<div><b>Waiting for approval</b><p>${form === 'prfaf' ? `Approve PRFAF requests in ${esc(app)}: approving there also sets up the fund release.` : `Your CMS role does not include approving this form.`}</p></div>${d.app_link ? `<a class="btn primary sm" href="${esc(d.app_link)}" target="_blank" rel="noopener">Review in ${esc(app)}</a>` : ''}</div>`) : ''}
            ${c.pdf_url ? `<p class="small"><a href="${esc(c.pdf_url)}" target="_blank" rel="noopener">${icon('download')} Signed PDF</a> <span class="muted">(link valid 30 days from the decision)</span></p>` : ''}
            <div class="claim-grid">
              <section><h4>Payroll / Account processing</h4>
                ${row.processing_eligible ? `<div class="checks col">${[['d', 'documents_checked', 'Documents checked'], ['s', 'supporting_docs_checked', 'Supporting documents checked'], ['p', 'payment_process_checked', 'Payment process checked'], ['f', 'fully_processed', 'Fully processed']].map(([k, f2, l]) => `<label><input type="checkbox" data-pc="${k}" ${p[f2] ? 'checked' : ''} ${canPro ? '' : 'disabled'}> ${l}</label>`).join('')}</div>
                  ${p.processed_by_name ? `<p class="muted small">Processed by ${esc(p.processed_by_name)} · ${dtShort(p.processed_at)}</p>` : ''}
                  ${canPro ? '<button type="button" class="btn sm primary" data-act="process">Save checklist</button>' : '<p class="muted small">Your CMS role can view this but not change it.</p>'}`
                  : `<p class="muted small">${row.stage === 'disapproved' ? 'Disapproved claims are not processed.' : 'Becomes available once the claim is approved.'}</p>`}
              </section>
              <section><h4>Payment</h4>
                ${!row.supports_payment ? '<p class="muted small">This form has no payment step.</p>'
                  : paid ? `<p><span class="st st-paid">Paid</span> ${row.payment_done_at ? dtShort(row.payment_done_at) : ''}${row.payment_done_by_name ? ` · ${esc(row.payment_done_by_name)}` : ''}</p>${d.can_pay ? '<button type="button" class="btn sm ghost" data-act="unpay">Undo payment</button>' : ''}`
                  : row.processing_eligible ? (d.can_pay ? `<p class="muted small">${row.fully_processed ? 'Processing is complete.' : 'Tip: finish the processing checklist first.'}</p><button type="button" class="btn sm primary" data-act="pay">Mark as paid</button>` : '<p class="muted small">Waiting for Finance.</p>')
                  : '<p class="muted small">Becomes available once the claim is approved.</p>'}
              </section>
            </div>
            <section class="claim-sec"><h4>Claim details</h4>${claimDetailsHtml(c)}</section>
            <section class="claim-sec"><h4>Notes</h4>
              ${d.notes.length ? `<ul class="notes">${d.notes.map((n) => `<li><p>${esc(n.note)}</p><small class="muted">${esc(n.by || '')} · ${dtShort(n.at)}</small></li>`).join('')}</ul>` : '<p class="muted small">No notes yet.</p>'}
              <div class="note-add"><textarea data-note rows="2" maxlength="1000" placeholder="Add a processing note (shared with MEG-FORMS)"></textarea><button type="button" class="btn sm" data-act="note">Add note</button></div>
            </section>
            ${d.app_link ? `<p class="muted small">Receipts, attachments and the PDF are in <a href="${esc(d.app_link)}" target="_blank" rel="noopener">${esc(app)}</a>.</p>` : ''}`;
          const pc = (k) => $(`[data-pc="${k}"]`, box);
          const syncFull = () => { if (pc('f')) { const ok3 = pc('d').checked && pc('s').checked && pc('p').checked; pc('f').disabled = !canPro || !ok3; if (!ok3) pc('f').checked = false; } };
          if (pc('d')) { ['d', 's', 'p'].forEach((k) => pc(k).addEventListener('change', syncFull)); syncFull(); }
          box.onclick = async (e) => {
            const b = e.target.closest('button[data-act]'); if (!b) return;
            const act = b.dataset.act;
            const run = async (fn, msg) => { b.disabled = true; b.classList.add('busy'); try { await fn(); changed = true; toast(msg); await load(); } catch (x) { toast(x.message, 'err'); b.disabled = false; b.classList.remove('busy'); } };
            if (act === 'approve' || act === 'disapprove' || act === 'done') {
              let reason = null;
              if (act === 'disapprove') {
                const okR = await modal({ title: `Disapprove ${row.serial_no}`, ok: 'Disapprove', danger: true,
                  body: `<label class="fld"><span>Reason (the claimant sees this)</span><textarea name="reason" rows="3" maxlength="1000" required class="ta"></textarea></label>`,
                  onOk: (f) => { reason = f.reason.value.trim(); if (!reason) throw new Error('Give a reason for disapproving.'); } });
                if (!okR) return;
              } else {
                const okC = await confirmBox(act === 'approve' ? 'Approve this claim?' : 'Mark this claim as done?', `<b>${esc(row.serial_no)}</b> · ${esc(row.claimant_name)} · ${fmtAmt(row)}`, act === 'approve' ? 'Approve' : 'Mark as done', false);
                if (!okC) return;
              }
              const logEl = $('.decide-log', box); logEl.hidden = false; logEl.innerHTML = '';
              $$('.decide-btns button', box).forEach((x) => { x.disabled = true; });
              const log = (m, tone) => { logEl.insertAdjacentHTML('beforeend', `<div class="lg ${tone || ''}">${icon(tone === 'ok' ? 'check-circle' : tone === 'err' ? 'x' : 'clock')}<span>${esc(m)}</span></div>`); };
              try {
                const res = await decideClaim(form, id, act, reason, log); changed = true;
                toast(act === 'approve' ? 'Approved' : act === 'done' ? 'Marked as done' : 'Disapproved');
                if (res.pdf) { const url = URL.createObjectURL(res.pdf.blob); logEl.insertAdjacentHTML('beforeend', `<a class="btn sm" href="${url}" download="${esc(res.pdf.fileName)}">${icon('download')}Download the PDF</a>`); }
                setTimeout(load, res.pdf ? 2500 : 900);
              } catch (x) { log(x.message, 'err'); $$('.decide-btns button', box).forEach((y) => { y.disabled = false; }); }
              return;
            }
            if (act === 'process') await run(() => API.rpc('cms_claim_process', { p_form: form, p_id: id, p_documents: pc('d').checked, p_supporting: pc('s').checked, p_payment_process: pc('p').checked, p_fully: pc('f').checked }), 'Checklist saved');
            else if (act === 'note') { const t = $('[data-note]', box).value.trim(); if (!t) { toast('Write a note first', 'err'); return; } await run(() => API.rpc('cms_claim_note', { p_form: form, p_id: id, p_note: t }), 'Note added'); }
            else if (act === 'pay' || act === 'unpay') {
              const ok = await confirmBox(act === 'pay' ? 'Mark this claim as paid?' : 'Undo the payment?', act === 'pay' ? `<b>${esc(row.serial_no)}</b> · ${esc(row.claimant_name)} · ${fmtAmt(row)}<br><small class="muted">The claimant sees it as paid in ${esc(app)}.</small>` : `<b>${esc(row.serial_no)}</b> goes back to waiting for payment. SCF payments can only be undone within 60 days.`, act === 'pay' ? 'Mark as paid' : 'Undo payment', act === 'unpay');
              if (ok) await run(() => API.rpc('cms_claim_paid', { p_form: form, p_id: id, p_done: act === 'pay' }), act === 'pay' ? 'Marked as paid' : 'Payment undone');
            }
          };
        };
        load();
      },
    });
    if (changed && after) after();
  }

  async function claimsPage(item, el) {
    const mod = moduleOf(item.route);
    const url = item.source && window.CMS_SOURCES[item.source];
    el.innerHTML = `${pageHead(item, url ? `<a class="tag src" href="${esc(url)}" target="_blank" rel="noopener">${icon('plug')}Open ${esc(item.source)}</a>` : '')}<div id="cl-body">${loading()}</div>
      <p class="muted small">Staff keep submitting in ${esc(item.source || 'the form app')}. Approving, processing, payment and notes can all be done here${mod === 'prfaf' ? ', except approving PRFAF requests, which stays in MEG-PRFAF because it also sets up the fund release' : ''}.</p>`;
    const body = $('#cl-body', el);
    const reload = async () => {
      try { const rows = await loadClaims(mod); claimsView(body, rows, { showForm: mod === 'tec', onOpen: (f, i) => openClaim(f, i, reload), onChanged: reload }); }
      catch (e) { body.innerHTML = errorCard(e.message); wireRetry(el); }
    };
    await reload();
  }

  async function approvalsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="ap-claims">${loading()}</div><div id="ap-other"></div>`;
    const reload = async () => {
      try {
        const rows = await loadClaims();
        claimsView($('#ap-claims', el), rows, { showForm: true, onOpen: (f, i) => openClaim(f, i, reload), onChanged: reload });
      } catch (e) { $('#ap-claims', el).innerHTML = errorCard(e.message); wireRetry(el); }
    };
    await reload();
    try {
      const d = state.dash = await API.rpc('cms_dashboard'); drawBell();
      $('#ap-other', el).innerHTML = `<section class="card"><div class="card-head"><h3>${icon('search-user')}Recruitment and onboarding</h3></div>
        <ul class="tasks">
          <li><a href="${esc(window.CMS_SOURCES['MEG-EAF V2'])}" target="_blank" rel="noopener"><span class="t-ic blue">${icon('search-user')}</span><span><b>${num(d.applications_pending)} applications pending</b><small>Office Use and decision</small></span><span class="tag src">Open MEG-EAF V2</span></a></li>
          <li><a href="${esc(window.CMS_SOURCES['MEG-EAF V2'])}" target="_blank" rel="noopener"><span class="t-ic violet">${icon('shield')}</span><span><b>${num(d.handbook_outstanding)} handbook acknowledgements outstanding</b><small>Assigned or viewed, not yet acknowledged</small></span><span class="tag src">Open MEG-EAF V2</span></a></li>
        </ul></section>`;
    } catch (e) { /* claims above still work */ }
  }

  // ================================================================ USERS, ROLES & ACCESS
  async function rolesPage(item, el) {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    let tab = params.get('tab') || 'logins';
    el.innerHTML = `${pageHead(item)}
      <div class="tabs" role="tablist">${[['logins', 'Logins'], ['roles', 'Roles & permissions'], ['grid', 'Compare roles'], ['rules', 'Position rules']].map(([k, l]) => `<button type="button" role="tab" data-tab="${k}" class="${tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <div id="roles-body">${loading()}</div>`;
    let users, matrix, extra = {};
    const names = () => { state.roleNames = Object.fromEntries(matrix.roles.map((r) => [r.code, r.name])); };
    try { [users, matrix, extra] = await Promise.all([API.rpc('cms_users'), API.rpc('cms_roles_matrix'), API.rpc('cms_user_permissions_all').catch(() => ({})), loadOrg()]); users.forEach(upUser); names(); }
    catch (e) { $('#roles-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const body = $('#roles-body', el);
    const sup = isSuper(); const canLink = can('people.link'); let canPerm = !!matrix.can_permissions;
    const grantOn = (u) => !!matrix.can_grant && (sup || u.id !== matrix.me);
    const filter = { q: '', show: 'all' };
    const reload = async () => { [users, matrix, extra] = await Promise.all([API.rpc('cms_users'), API.rpc('cms_roles_matrix'), API.rpc('cms_user_permissions_all').catch(() => ({}))]); users.forEach(upUser); names(); canPerm = !!matrix.can_permissions; draw(); };
    // ---- the complete permission list
    const ACT = { V: 'View', C: 'Create', E: 'Edit', A: 'Approve', D: 'Delete', X: 'Export' };
    const norm = (a) => 'VCEADX'.split('').filter((x) => String(a || '').includes(x)).join('');
    const byOrder = (a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0);
    const orderedMods = () => { const secs = matrix.modules.filter((m) => m.kind !== 'special').sort(byOrder); const sp = matrix.modules.filter((m) => m.kind === 'special').sort(byOrder);
      return [...secs.flatMap((x) => [x, ...sp.filter((y) => y.parent === x.code)]), ...sp.filter((y) => !secs.some((x) => x.code === y.parent))]; };
    const actsOf = (m) => (m.kind === 'special' ? 'V' : (m.acts || 'VCEADX'));
    function permList(cur, dflt, canEdit) {
      let grp = '';
      return `<div class="pl">${orderedMods().map((m) => {
        const head = m.kind !== 'special' && m.grp !== grp ? `<h4 class="pl-grp">${esc((grp = m.grp))}</h4>` : '';
        const a = norm(cur[m.code]); const d = dflt ? norm(dflt[m.code]) : null; const chg = d != null && a !== d; const ed = canEdit(m);
        const boxes = m.kind === 'special' ? `<label class="pl-a"><input type="checkbox" data-pm="${esc(m.code)}" data-a="V" ${a.includes('V') ? 'checked' : ''} ${ed ? '' : 'disabled'}> Allowed</label>`
          : actsOf(m).split('').map((l) => `<label class="pl-a"><input type="checkbox" data-pm="${esc(m.code)}" data-a="${l}" ${a.includes(l) ? 'checked' : ''} ${ed ? '' : 'disabled'}> ${esc(m.act_labels?.[l] || ACT[l])}</label>`).join('');
        return `${head}<div class="pl-row ${m.kind === 'special' ? 'sp' : ''} ${chg ? 'chg' : ''}" data-row="${esc(m.code)}"><div class="pl-l"><b>${m.locked ? `<span class="lock-ic" title="Locked: only a Super Admin can change this">${icon('lock')}</span>` : ''}${esc(m.label)}</b>${m.from_phase ? ` <span class="tag phase p${m.from_phase} xs">from Phase ${m.from_phase}</span>` : ''}${chg ? ` <span class="tag warn xs" title="Default: ${esc(d || 'none')}">changed from default</span>` : ''}<small>${esc(m.description || '')}</small></div><div class="pl-acts">${boxes}</div></div>`;
      }).join('')}</div>`;
    }
    const readPerm = (box) => { const out = {}; $$('[data-pm]', box).forEach((i) => { if (!(i.dataset.pm in out)) out[i.dataset.pm] = ''; if (i.checked) out[i.dataset.pm] += i.dataset.a; }); return out; };
    const wirePerm = (box, onChange) => box.addEventListener('change', (e) => { const i = e.target.closest('[data-pm]'); if (!i) return;
      const row = $$(`[data-pm="${CSS.escape(i.dataset.pm)}"]`, box);
      if (i.checked && i.dataset.a !== 'V') row.forEach((x) => { if (x.dataset.a === 'V') x.checked = true; });
      if (!i.checked && i.dataset.a === 'V') row.forEach((x) => { x.checked = false; });
      onChange?.(); });
    let selRole = params.get('role') || 'hr';

    function companyPicker() {
      const cos = (state.org?.companies || window.CMS_COMPANIES.map((c) => ({ code: c.code, short_name: c.short, is_active: true }))).filter((c) => c.is_active);
      return `<fieldset class="fld"><legend>Companies</legend>
        <label class="radio"><input type="radio" name="scope" value="all" checked> All companies</label>
        <label class="radio"><input type="radio" name="scope" value="some"> Only these:</label>
        <div class="checks">${cos.map((c) => `<label><input type="checkbox" name="co" value="${esc(c.code)}"> ${esc(c.short_name)}</label>`).join('')}</div></fieldset>`;
    }
    const readScope = (form) => {
      if (form.scope.value === 'all') return null;
      const v = $$('input[name=co]:checked', form).map((x) => x.value);
      if (!v.length) throw new Error('Tick at least one company, or choose All companies.');
      return v;
    };
    async function grant(u, role, cos, note) {
      await API.rpc('cms_grant_role', { p_user: u.id, p_role: role, p_companies: cos, p_note: note || null });
      toast(`${roleName(role)} granted to ${u.name}`); await reload();
    }

    function drawLogins() {
      const t = filter.q.trim().toLowerCase();
      const list = users.filter((u) => (filter.show === 'all' || (filter.show === 'role' && u.roles.length) || (filter.show === 'sugg' && u.suggestions.length) || (filter.show === 'none' && !u.roles.length))
        && (!t || `${u.name} ${u.email} ${u.person?.name || ''} ${u.person?.employee_id || ''}`.toLowerCase().includes(t)));
      const c = { all: users.length, role: users.filter((u) => u.roles.length).length, sugg: users.filter((u) => u.suggestions.length).length, none: users.filter((u) => !u.roles.length).length };
      return `
        <section class="card">
          <div class="toolbar">
            <label class="search-in">${icon('search')}<input id="uq" type="search" placeholder="Name or email" value="${esc(filter.q)}" aria-label="Search logins"></label>
            <div class="seg">${[['all', 'All'], ['role', 'With a role'], ['sugg', 'Has suggestions'], ['none', 'No access']].map(([k, l]) => `<button type="button" data-show="${k}" class="${filter.show === k ? 'on' : ''}">${l} <span>${c[k]}</span></button>`).join('')}</div>
          </div>
          <p class="muted small">${matrix.can_grant ? 'Accept a suggestion with one click, add any role, or give one person extra permissions on top of their roles. Suggestions come from MEG-EAF V2 and MEG-FORMS permissions and from the person’s JD position; nothing is granted until you accept it. Only a Super Admin gives the Super Admin role, and nobody changes their own access.' : 'Only Admin and Super Admin can grant or remove roles.'}</p>
          <div class="ulist">${list.map((u) => `
            <article class="urow" data-u="${esc(u.id)}">
              <div class="u-main"><span class="avatar ${u.roles.length ? '' : 'off'}">${esc(initials(u.name))}</span>
                <div class="u-id"><b>${esc(u.name)}</b><small>${esc(u.email)} · last sign-in ${ago(u.last_sign_in_at)}${u.profile_status === 'pending' ? ' · <span class="st st-onboarding">pending</span>' : ''}</small>
                  <div class="u-person">${u.person ? `${icon('users')}<span>${esc(u.person.name)} · ${esc(u.person.employee_id || 'no ID')} · ${esc(coShort(u.person.company_code))}${u.person.title ? ' · ' + esc(u.person.title) : ''}</span>${canLink ? '<button type="button" class="lnk" data-act="unlink">Unlink</button>' : ''}`
                    : u.suggested_person ? `${icon('users')}<span class="muted">Same email as ${esc(u.suggested_person.name)} (${esc(u.suggested_person.employee_id || 'no ID')})</span>${canLink ? '<button type="button" class="lnk" data-act="link-sugg">Link</button>' : ''}`
                    : `<span class="muted">Not linked to a person</span>${canLink ? '<button type="button" class="lnk" data-act="link">Link to person…</button>' : ''}`}</div></div></div>
              <div class="u-roles">${u.roles.map((r) => `<span class="role-chip r-${esc(r.code)}" title="${esc(r.note || '')}">${esc(roleName(r.code))}<em>${esc(scopeTxt(r.companies))}</em>${grantOn(u) && (sup || r.code !== 'super_admin') ? `<button type="button" data-act="revoke" data-role="${esc(r.code)}" aria-label="Remove ${esc(roleName(r.code))}">${icon('x')}</button>` : ''}</span>`).join('') || '<span class="muted small">No CMS role · cannot use the CMS</span>'}
                ${Object.keys(extra[u.id] || {}).length ? `<span class="role-chip r-extra" title="${esc(Object.keys(extra[u.id]).map((k) => (matrix.modules.find((m) => m.code === k) || {}).label || k).join(', '))}">+${Object.keys(extra[u.id]).length} extra permission${Object.keys(extra[u.id]).length === 1 ? '' : 's'}</span>` : ''}
                ${grantOn(u) ? `<button type="button" class="btn sm ghost" data-act="add">${icon('plus')}Add role</button><button type="button" class="btn sm ghost" data-act="extra">${icon('lock')}Extra permissions</button>` : ''}</div>
              ${u.suggestions.length ? `<div class="u-sugg"><span class="lbl">${icon('sparkle')}Suggested</span>${u.suggestions.map((s, i) => `<span class="sugg"><span><b>${esc(roleName(s.role))}</b> · ${esc(scopeTxt(s.companies))}<small>${esc(s.reason)}</small></span>${grantOn(u) && (sup || s.role !== 'super_admin') ? `<button type="button" class="btn sm primary" data-act="accept" data-i="${i}">Accept</button>` : ''}</span>`).join('')}</div>` : ''}
            </article>`).join('') || '<div class="empty small"><p>No logins match</p></div>'}</div>
        </section>`;
    }

    function drawGrid() {
      const roles = matrix.roles; const mods = orderedMods(); let grp = '';
      return `<section class="card"><div class="card-head"><h3>${icon('lock')}Who can do what</h3><span class="muted small">V view · C create · E edit · A approve · D delete · X export</span></div>
        <p class="muted small">${canPerm ? `Click a cell to change it, or use the Roles &amp; permissions tab to change one role at a time. Every change needs a reason and goes into the Audit Log. Super Admin always has everything. ${icon('lock')} Locked items${sup ? '' : ' and the Admin role'} can only be changed by a Super Admin. ✓ = special permission allowed.` : 'Only Admin and Super Admin can change permissions.'}</p>
        <div class="table-wrap fill"><table class="grid perm-grid freeze1"><thead><tr><th>Module</th>${roles.map((r) => `<th title="${esc(r.description)}">${esc(r.name)}<small>${r.users} ${r.users === 1 ? 'user' : 'users'}</small></th>`).join('')}</tr></thead><tbody>
        ${mods.map((m) => { const head = m.kind !== 'special' && m.grp !== grp ? `<tr class="grp"><td colspan="${roles.length + 1}">${esc(m.grp)}</td></tr>` : ''; if (m.kind !== 'special') grp = m.grp;
          return `${head}<tr class="${m.kind === 'special' ? 'sp' : ''}"><td>${m.kind === 'special' ? '<span class="sp-ind">↳</span>' : ''}${m.locked ? `<span class="lock-ic" title="Locked: only a Super Admin can change this">${icon('lock')}</span>` : ''}${esc(m.label)} ${m.kind === 'special' ? (m.from_phase ? `<span class="tag phase p${m.from_phase} xs">P${m.from_phase}</span>` : '') : m.phase === 0 ? '<span class="tag live xs">Live</span>' : `<span class="tag phase p${m.phase} xs">P${m.phase}</span>`}</td>${roles.map((r) => {
            const a = r.code === 'super_admin' ? actsOf(m) : norm(matrix.permissions[r.code]?.[m.code]);
            return `<td><button type="button" class="pcell ${a ? 'on' : ''}" data-role="${esc(r.code)}" data-mod="${esc(m.code)}" ${canPerm && r.code !== 'super_admin' && (sup || (!m.locked && r.code !== 'admin')) ? '' : 'disabled'} aria-label="${esc(r.name)} · ${esc(m.label)}: ${a || 'none'}">${a ? (m.kind === 'special' ? '<i>✓</i>' : 'VCEADX'.split('').filter((x) => a.includes(x)).map((x) => `<i>${x}</i>`).join('')) : '·'}</button></td>`; }).join('')}</tr>`; }).join('')}
        </tbody></table></div></section>
        <section class="card"><div class="card-head"><h3>${icon('shield')}Roles</h3></div>
          <ul class="role-desc">${roles.map((r) => `<li><span class="role-chip r-${esc(r.code)}">${esc(r.name)}</span><span>${esc(r.description)}</span>${r.phase > 0 ? `<span class="tag phase p${r.phase}">used from ${esc(window.CMS_PHASES[r.phase])}</span>` : ''}</li>`).join('')}</ul></section>`;
    }

    function drawRoles() {
      const roles = matrix.roles; const r = roles.find((x) => x.code === selRole) || roles.find((x) => x.code !== 'super_admin') || roles[0]; selRole = r.code;
      const isSup = r.code === 'super_admin'; const editable = (m) => canPerm && !isSup && (sup || (!m.locked && r.code !== 'admin'));
      const cur = isSup ? Object.fromEntries(matrix.modules.map((m) => [m.code, actsOf(m)])) : (matrix.permissions[r.code] || {});
      const dflt = (matrix.defaults || {})[r.code] || {};
      const changed = isSup ? 0 : matrix.modules.filter((m) => norm(cur[m.code]) !== norm(dflt[m.code])).length;
      const anyEdit = matrix.modules.some(editable);
      return `<div class="rr">
        <aside class="card rr-list"><div class="rr-h"><b>Roles</b>${canPerm ? '<button type="button" class="btn sm" data-newrole>+ New role</button>' : ''}</div>
          ${roles.map((x) => `<button type="button" class="rr-i ${x.code === r.code ? 'on' : ''}" data-rolepick="${esc(x.code)}"><span class="role-chip r-${esc(x.code)}">${esc(x.name)}</span><small>${x.users} ${x.users === 1 ? 'user' : 'users'}${x.is_system === false ? ' · made in the CMS' : ''}</small></button>`).join('')}</aside>
        <section class="card rr-d"><div class="card-head"><h3>${icon('shield')}${esc(r.name)}</h3><div class="btn-row">
            ${canPerm && !isSup && (sup || r.code !== 'admin') ? '<button type="button" class="btn sm ghost" data-rolename>Rename…</button>' : ''}
            ${canPerm && !isSup && changed ? `<button type="button" class="btn sm ghost" data-rolereset>Reset to default (${changed})</button>` : ''}
            ${canPerm && r.is_system === false ? '<button type="button" class="btn sm ghost" data-rolearch>Remove role…</button>' : ''}</div></div>
          <p class="muted small">${esc(r.description || '')}</p>
          ${isSup ? '<p class="note">Super Admin always has every permission.</p>' : !canPerm ? '<p class="muted small">Only Admin and Super Admin can change permissions.</p>' : r.code === 'admin' && !sup ? '<p class="muted small">Only a Super Admin can change the Admin role.</p>' : changed ? `<p class="small">${changed} item${changed === 1 ? '' : 's'} changed from the default (marked below).</p>` : '<p class="muted small">Same as the default.</p>'}
          <div id="pl-box">${permList(cur, isSup ? null : dflt, editable)}</div>
          ${anyEdit ? '<div class="pl-save"><span class="muted small" id="pl-n">No unsaved changes</span><input id="pl-why" maxlength="300" placeholder="Reason for the change"><button type="button" class="btn primary" data-plsave disabled>Save changes</button></div>' : ''}</section></div>`;
    }
    function wireRoles() {
      const r = matrix.roles.find((x) => x.code === selRole); const box = $('#pl-box', body); const cur = matrix.permissions[selRole] || {};
      const diff = () => Object.fromEntries(Object.entries(readPerm(box)).filter(([k, v]) => norm(v) !== norm(cur[k])));
      wirePerm(box, () => { const n = Object.keys(diff()).length; $('#pl-n', body).textContent = n ? `${n} unsaved change${n === 1 ? '' : 's'}` : 'No unsaved changes'; $('[data-plsave]', body).disabled = !n; });
      $$('[data-rolepick]', body).forEach((b) => b.addEventListener('click', () => { selRole = b.dataset.rolepick; draw(); }));
      $('[data-plsave]', body)?.addEventListener('click', async () => {
        const why = $('#pl-why', body).value.trim(); if (!why) { toast('Give a reason for the change.', 'err'); $('#pl-why', body).focus(); return; }
        try { const n = await API.rpc('cms_role_permissions_save', { p_role: selRole, p_perms: diff(), p_reason: why }); toast(`${r.name}: ${n} change${n === 1 ? '' : 's'} saved`); await reload(); }
        catch (e) { toast(e.message, 'err'); } });
      $('[data-rolereset]', body)?.addEventListener('click', async () => {
        const ok = await modal({ title: `Reset ${r.name} to its default`, ok: 'Reset', danger: true, body: '<p class="muted small">Every item marked “changed from default” goes back to the default.</p><label class="fld"><span>Reason</span><input name="why" required maxlength="300"></label>',
          onOk: async (f) => { if (!f.why.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_role_reset', { p_role: selRole, p_reason: f.why.value.trim() }); } });
        if (ok) { toast(`${r.name} reset to default`); await reload(); } });
      $('[data-rolename]', body)?.addEventListener('click', async () => {
        const ok = await modal({ title: `Rename ${r.name}`, body: `<label class="fld"><span>Name</span><input name="nm" required value="${esc(r.name)}"></label><label class="fld"><span>What this role is for</span><input name="ds" value="${esc(r.description || '')}"></label>`,
          onOk: async (f) => { await API.rpc('cms_role_save', { p: { code: selRole, name: f.nm.value.trim(), description: f.ds.value.trim() } }); } });
        if (ok) { toast('Role saved'); await reload(); } });
      $('[data-rolearch]', body)?.addEventListener('click', async () => {
        const ok = await modal({ title: `Remove ${r.name}`, ok: 'Remove role', danger: true, body: '<p class="muted small">Only possible when nobody holds this role. Its history stays in the Audit Log.</p><label class="fld"><span>Reason</span><input name="why" required></label>',
          onOk: async (f) => { if (!f.why.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_role_archive', { p_code: selRole, p_reason: f.why.value.trim() }); } });
        if (ok) { toast('Role removed'); selRole = 'hr'; await reload(); } });
      $('[data-newrole]', body)?.addEventListener('click', async () => {
        let code = null;
        const ok = await modal({ title: 'New role', body: `<label class="fld"><span>Name</span><input name="nm" required maxlength="60" placeholder="e.g. Centre Manager"></label>
            <label class="fld"><span>What this role is for</span><input name="ds" maxlength="200"></label>
            <label class="fld"><span>Start from the permissions of</span><select name="src"><option value="">Nothing (an empty role)</option>${matrix.roles.filter((x) => x.code !== 'super_admin').map((x) => `<option value="${esc(x.code)}">${esc(x.name)}</option>`).join('')}</select></label>
            <p class="muted small">You can change its permissions straight after. What it starts with becomes its default.</p>`,
          ok: 'Create role', onOk: async (f) => { if (!f.nm.value.trim()) throw new Error('Give the role a name.'); code = await API.rpc('cms_role_save', { p: { name: f.nm.value.trim(), description: f.ds.value.trim(), copy_from: f.src.value || null } }); } });
        if (ok && code) { toast('Role created'); selRole = code; await reload(); } });
    }

    function drawRules() {
      return `<section class="card"><div class="card-head"><h3>${icon('briefcase')}JD position → suggested role</h3><span class="muted small">For logins linked to a person</span></div>
        <p class="muted small">When a login is linked to a person, their JD position (title, level and department in the JD Manual) suggests a role. Suggestions are never granted automatically: a Super Admin accepts each one.</p>
        <div class="table-wrap"><table class="data"><thead><tr><th>Company</th><th>Department</th><th>From level</th><th>Suggested role</th><th>Companies</th></tr></thead><tbody>
        ${matrix.rules.map((r) => `<tr><td>${esc(r.entity_code ? coShort(r.entity_code) : 'Any')}</td><td>${esc(r.department_name || 'Any department')}${r.note ? `<br><small class="muted">${esc(r.note)}</small>` : ''}</td><td>L${r.min_level}</td><td><span class="role-chip r-${esc(r.role_code)}">${esc(roleName(r.role_code))}</span></td><td>${r.scope === 'all' ? 'All companies' : 'Own company'}</td></tr>`).join('')}
        <tr class="dim"><td>Any</td><td>Everyone else with a JD position</td><td>L1</td><td><span class="role-chip r-staff">Staff</span></td><td>Own company</td></tr></tbody></table></div>
        <p class="muted small">Staff, Approver, Finance and Payroll start to matter as their modules go live; you can accept them now or later.</p></section>`;
    }

    function draw() {
      $$('.tabs button', el).forEach((b) => b.classList.toggle('on', b.dataset.tab === tab));
      body.innerHTML = tab === 'grid' ? drawGrid() : tab === 'rules' ? drawRules() : tab === 'roles' ? drawRoles() : drawLogins();
      if (tab === 'roles') wireRoles();
      if (tab === 'logins') {
        $('#uq', body).addEventListener('input', (e) => { filter.q = e.target.value; const pos = e.target.selectionStart; draw(); const i = $('#uq', body); i.focus(); i.setSelectionRange(pos, pos); });
        $$('[data-show]', body).forEach((b) => b.addEventListener('click', () => { filter.show = b.dataset.show; draw(); }));
      }
    }
    $$('.tabs button', el).forEach((b) => b.addEventListener('click', () => { tab = b.dataset.tab; draw(); }));
    draw();

    body.addEventListener('click', async (e) => {
      const btn = e.target.closest('button[data-act], button.pcell'); if (!btn || btn.disabled) return;
      if (btn.classList.contains('pcell')) { editCell(btn.dataset.role, btn.dataset.mod); return; }
      const u = users.find((x) => x.id === btn.closest('[data-u]')?.dataset.u); if (!u) return;
      const act = btn.dataset.act;
      if (act === 'accept') {
        const s = u.suggestions[+btn.dataset.i];
        await confirmBox(`Grant ${roleName(s.role)}?`, `<b>${esc(u.name)}</b> (${esc(u.email)}) gets <b>${esc(roleName(s.role))}</b> for ${esc(scopeTxt(s.companies))}.<br><small class="muted">Reason: ${esc(s.reason)}</small>`, 'Grant role', false,
          () => grant(u, s.role, s.companies, 'Accepted suggestion: ' + s.reason));
      } else if (act === 'add') {
        const opts = matrix.roles.filter((r) => !u.roles.some((x) => x.code === r.code) && (sup || r.code !== 'super_admin'));
        await modal({
          title: `Add a role · ${u.name}`,
          body: `<label class="fld"><span>Role</span><select name="role">${opts.map((r) => `<option value="${esc(r.code)}">${esc(r.name)}</option>`).join('')}</select></label>
            <p class="muted small" id="role-desc">${esc(opts[0]?.description || '')}</p>
            ${companyPicker()}<label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
          ok: 'Grant role',
          onOk: async (form) => { if (!form.role.value) throw new Error('This login already holds every role.'); await grant(u, form.role.value, form.role.value === 'super_admin' ? null : readScope(form), form.note.value); },
        });
      } else if (act === 'extra') {
        const cur = extra[u.id] || {};
        await modal({ title: `Extra permissions · ${u.name}`, wide: true, ok: 'Save',
          body: `<p class="muted small">Added on top of ${u.roles.length ? `the roles ${esc(u.roles.map((r) => roleName(r.code)).join(', '))}` : 'any roles'} for this login only. Untick to take one away. Locked items can only be given by a Super Admin.</p>
            <div class="pl-modal">${permList(cur, null, (m) => sup || !m.locked)}</div>
            <label class="fld"><span>Reason for the change</span><input name="why" required maxlength="300" placeholder="e.g. Accounts needs to see payroll totals"></label>`,
          onOpen: (w) => wirePerm($('.pl-modal', w)),
          onOk: async (form) => { if (!form.why.value.trim()) throw new Error('Give a reason for the change.');
            const want = Object.fromEntries(Object.entries(readPerm($('.pl-modal', form))).filter(([, v]) => v));
            const n = await API.rpc('cms_user_permissions_save', { p_user: u.id, p_perms: want, p_reason: form.why.value.trim() }); toast(n ? `${n} permission change${n === 1 ? '' : 's'} saved for ${u.name}` : 'No changes'); await reload(); } });
      } else if (act === 'revoke') {
        const role = btn.dataset.role;
        await confirmBox(`Remove ${roleName(role)}?`, `<b>${esc(u.name)}</b> will lose <b>${esc(roleName(role))}</b>${u.roles.length === 1 ? ' and will no longer be able to use the CMS' : ''}.`, 'Remove role', true, async () => {
          await API.rpc('cms_revoke_role', { p_user: u.id, p_role: role, p_note: null }); toast(`${roleName(role)} removed from ${u.name}`); await reload();
        });
      } else if (act === 'unlink') {
        await confirmBox('Unlink this login?', `<b>${esc(u.email)}</b> will no longer be linked to <b>${esc(u.person.name)}</b>.`, 'Unlink', true, async () => {
          await API.rpc('cms_link_user', { p_user: u.id, p_person: null }); toast('Unlinked'); await reload();
        });
      } else if (act === 'link-sugg') {
        await confirmBox('Link this login?', `Link <b>${esc(u.email)}</b> to <b>${esc(u.suggested_person.name)}</b> (${esc(u.suggested_person.employee_id || 'no Employee ID')}). Their JD position may then suggest a role.`, 'Link', false, async () => {
          await API.rpc('cms_link_user', { p_user: u.id, p_person: u.suggested_person.id }); toast(`Linked to ${u.suggested_person.name}`); await reload();
        });
      } else if (act === 'link') {
        let cands; try { cands = (await API.rpc('cms_link_candidates')).map((c) => upKeys(c, 'name')); } catch (x) { toast(x.message, 'err'); return; }
        await modal({
          title: `Link ${u.email} to a person`, wide: true,
          body: `<label class="search-in">${icon('search')}<input type="search" name="lq" placeholder="Search name or Employee ID" aria-label="Search people"></label>
            <div class="pick">${cands.map((c) => `<label class="pick-row" data-t="${esc(`${c.name} ${c.employee_id || ''}`.toLowerCase())}"><input type="radio" name="pid" value="${esc(c.id)}"><span><b>${esc(c.name)}</b><small>${esc(c.employee_id || 'No Employee ID')} · ${esc(coShort(c.company_code))} · ${esc(c.status)}${c.title ? ' · ' + esc(c.title) : ''}</small></span></label>`).join('') || '<p class="muted">Everyone is already linked.</p>'}</div>`,
          ok: 'Link',
          onOk: async (form) => { const id = $('input[name=pid]:checked', form)?.value; if (!id) throw new Error('Choose a person.'); await API.rpc('cms_link_user', { p_user: u.id, p_person: id }); toast('Linked'); await reload(); },
        });
      }
    });

    async function editCell(role, mod) {
      const cur = matrix.permissions[role]?.[mod] || '';
      const r = matrix.roles.find((x) => x.code === role); const m = matrix.modules.find((x) => x.code === mod);
      const L = m.kind === 'special' ? [['V', 'Allowed']] : actsOf(m).split('').map((l) => [l, m.act_labels?.[l] || ACT[l]]);
      await modal({
        title: `${r.name} · ${m.label}`,
        body: `<div class="checks big">${L.map(([k, l]) => `<label><input type="checkbox" name="a" value="${k}" ${cur.includes(k) ? 'checked' : ''}> <b>${k}</b> ${l}</label>`).join('')}</div>
          <p class="muted small">Any action also needs View, which is added automatically. People holding this role see the change on their next page load.${mod === 'payroll' ? ' Payroll “Edit” also gives MyPayroll access (prepare and finalise).' : ''}${role === 'hr' && mod === 'letters' ? ' HR cannot approve letters.' : ''}</p>
          <label class="fld"><span>Reason for the change</span><input name="why" required maxlength="300" placeholder="e.g. HR now runs the monthly payroll"></label>`,
        onOk: async (form) => {
          const v = $$('input[name=a]:checked', form).map((x) => x.value).join('');
          if (!form.why.value.trim()) throw new Error('Give a reason for the change.');
          const saved = await API.rpc('cms_permission_change', { p_role: role, p_module: mod, p_actions: v, p_reason: form.why.value.trim() }); matrix = await API.rpc('cms_roles_matrix');
          matrix.permissions[role] = matrix.permissions[role] || {}; matrix.permissions[role][mod] = saved;
          toast(`${r.name} · ${m.label}: ${saved || 'none'}`); draw();
        },
      });
    }
  }
  // live filters inside modals (link picker, role description)
  document.addEventListener('input', (e) => {
    if (e.target.name === 'lq') { const t = e.target.value.trim().toLowerCase(); $$('.pick-row').forEach((r) => { r.hidden = !!t && !r.dataset.t.includes(t); }); }
  });
  document.addEventListener('change', (e) => {
    if (e.target.name === 'role' && $('#role-desc')) {
      const d = { super_admin: 'Everything, including roles and export. Companies do not apply.', director: 'Sees everything. Decides claims for all companies, including claims by Super Admins and Admins.', admin: 'Sees, edits and approves everything.', hr: 'People, recruitment, onboarding, handbook, leave and letters.', payroll: 'Payroll and claim processing.', finance: 'Marks claims and funding paid.', approver: 'Approves claims, overtime and leave.', payroll_viewer: 'Sees claims, people, payroll and reports. Cannot change, approve, pay or export.', staff: 'Own payslips, leave and claims.' };
      $('#role-desc').textContent = d[e.target.value] || '';
    }
    if (e.target.name === 'co' && e.target.checked) { const s = $('input[name=scope][value=some]'); if (s) s.checked = true; }
  });

  // ================================================================ AUDIT LOG
  async function auditPage(item, el) {
    el.innerHTML = `${pageHead(item)}
      <section class="card"><div class="toolbar"><label class="search-in">${icon('search')}<input id="aq" type="search" placeholder="Search who, action or summary" aria-label="Search the audit log"></label><span class="muted small">Append-only: entries cannot be edited or deleted, even by a Super Admin.</span></div>
        <div id="audit-list">${loading()}</div><div class="more-wrap"><button type="button" class="btn ghost" id="amore" hidden>Load older</button></div></section>`;
    let rows = []; let q = ''; let timer;
    const load = async (more) => {
      const before = more && rows.length ? rows[rows.length - 1].id : null;
      try {
        const got = await API.rpc('cms_audit', { p_limit: 50, p_before: before, p_search: q || null });
        rows = more ? rows.concat(got) : got;
        $('#amore', el).hidden = got.length < 50;
        $('#audit-list', el).innerHTML = rows.length ? `<div class="table-wrap fill"><table class="data audit"><thead><tr><th>When</th><th>Who</th><th>Action</th><th>What</th></tr></thead><tbody>
          ${rows.map((r) => `<tr><td class="nowrap">${dtShort(r.at)}</td><td>${esc(r.actor_email || 'System')}</td><td><span class="act a-${esc(String(r.action).split('.')[0])}">${esc(r.action)}</span></td>
            <td>${esc(r.summary)}${r.details && Object.keys(r.details).length ? `<details><summary>details</summary><pre>${esc(JSON.stringify(r.details, null, 2))}</pre></details>` : ''}</td></tr>`).join('')}</tbody></table></div>`
          : `<div class="empty small">${icon('list')}<p>No entries${q ? ' match' : ' yet'}</p></div>`;
      } catch (e) { $('#audit-list', el).innerHTML = errorCard(e.message); wireRetry(el); }
    };
    $('#aq', el).addEventListener('input', (e) => { clearTimeout(timer); timer = setTimeout(() => { q = e.target.value.trim(); load(false); }, 300); });
    $('#amore', el).addEventListener('click', () => load(true));
    load(false);
  }

  // ================================================================ EXPORT ALL DATA
  function loadScript(src) {
    return new Promise((res, rej) => { const s = document.createElement('script'); s.src = src; s.onload = res; s.onerror = () => rej(new Error('Could not load the spreadsheet library. Check the internet connection.')); document.head.appendChild(s); });
  }
  function download(name, blob) {
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1500);
  }
  const stamp = () => { const d = new Date(); const p = (n) => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}`; };

  async function exportPage(item, el) {
    el.innerHTML = `${pageHead(item)}
      <section class="card"><div class="card-head"><h3>${icon('download')}Download a full copy</h3><span class="tag warn">Super Admin only</span></div>
        <p>Every table in the CMS database (MEG-EAF V2, MEG-FORMS, JD Manual, handbook, HR Letters and the CMS itself) in one file. The free Supabase plan has no automatic backups, so keep a copy somewhere safe.</p>
        <ul class="plan"><li>The file contains personal data: IC numbers, bank details and salaries. Store it as carefully as the originals.</li>
          <li>Uploaded files (receipts, signed letters, documents) stay in storage and are not part of this file.</li>
          <li>Each export is recorded in the audit log.</li></ul>
        <div class="btn-row"><button type="button" class="btn primary" data-fmt="xlsx">${icon('download')}Download Excel (.xlsx)</button><button type="button" class="btn ghost" data-fmt="json">${icon('download')}Download JSON</button><button type="button" class="btn ghost" data-fmt="structure">${icon('database')}Structure snapshot only</button></div>
        <div class="progress" hidden><div class="bar"><span></span></div><p class="muted small" id="xp-txt"></p></div></section>
      <section class="card"><div class="card-head"><h3>${icon('database')}Tables</h3><span class="muted small" id="xt-sum"></span></div><div id="xt"><p class="muted small">Listed when an export starts.</p></div></section>`;
    const btns = $$('[data-fmt]', el);
    btns.forEach((b) => b.addEventListener('click', () => run(b.dataset.fmt)));
    const prog = $('.progress', el); const bar = $('.bar span', el); const txt = $('#xp-txt', el);
    async function run(fmt) {
      btns.forEach((b) => { b.disabled = true; }); prog.hidden = false; bar.style.width = '0%';
      try {
        if (fmt === 'structure') {
          txt.textContent = 'Fetching the structure snapshot…';
          const snaps = await API.rpc('cms_export_table', { p_table: 'cms_schema_snapshots' });
          download(`MyEden-CMS_structure_${stamp()}.json`, new Blob([JSON.stringify(snaps, null, 2)], { type: 'application/json' }));
          await API.rpc('cms_export_done', { p_format: 'structure snapshot', p_tables: 1, p_rows: snaps.length });
          bar.style.width = '100%'; txt.textContent = `Done: ${snaps.length} snapshot(s).`; toast('Structure snapshot downloaded'); return;
        }
        txt.textContent = 'Listing tables…';
        const tables = await API.rpc('cms_export_tables');
        const total = tables.reduce((s, t) => s + Number(t.rows), 0);
        $('#xt-sum', el).textContent = `${tables.length} tables · ${num(total)} rows`;
        $('#xt', el).innerHTML = `<div class="xt-grid">${tables.map((t) => `<span data-t="${esc(t.table)}"><code>${esc(t.table)}</code><em>${num(t.rows)}</em></span>`).join('')}</div>`;
        const data = {}; let done = 0;
        for (const t of tables) {
          txt.textContent = `Reading ${t.table} (${done + 1} of ${tables.length})…`;
          data[t.table] = Number(t.rows) ? await API.rpc('cms_export_table', { p_table: t.table }) : [];
          done++; bar.style.width = `${Math.round(done / tables.length * (fmt === 'xlsx' ? 85 : 100))}%`;
          $(`[data-t="${CSS.escape(t.table)}"]`, el)?.classList.add('ok');
        }
        const meta = { exported_at: new Date().toISOString(), exported_by: state.access.email, project: CFG.project, project_ref: CFG.projectRef, version: window.CMS_VERSION, tables: tables.length, rows: total };
        if (fmt === 'json') {
          download(`MyEden-CMS_export_${stamp()}.json`, new Blob([JSON.stringify({ meta, tables: data })], { type: 'application/json' }));
        } else {
          txt.textContent = 'Building the Excel file…';
          if (!window.XLSX) await loadScript('https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js');
          const X = window.XLSX; const wb = X.utils.book_new(); const used = new Set();
          const sheetName = (n) => { const b = n.replace(/[\\/?*[\]:]/g, '_').slice(0, 31); let s = b; let i = 2; while (used.has(s.toLowerCase())) { const suf = '~' + i++; s = b.slice(0, 31 - suf.length) + suf; } used.add(s.toLowerCase()); return s; };
          const cell = (v) => { if (v === null || v === undefined) return ''; if (typeof v === 'object') v = JSON.stringify(v); if (typeof v === 'string' && v.length > 32000) return v.slice(0, 32000) + ' …[cut: see the JSON export for the full value]'; return v; };
          const contents = sheetName('Contents');
          const sheets = tables.map((t) => ({ t, name: sheetName(t.table) }));
          X.utils.book_append_sheet(wb, X.utils.aoa_to_sheet([
            ['MyEden Group CMS V1.0 · full export'], ['Exported at', meta.exported_at], ['Exported by', meta.exported_by], ['Project', `${meta.project} (${meta.project_ref})`], ['Version', meta.version], [],
            ['Table', 'Sheet', 'Rows'], ...sheets.map(({ t, name }) => [t.table, name, Number(t.rows)])]), contents);
          for (const { t, name } of sheets) {
            const rows = (data[t.table] || []).map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, cell(v)])));
            X.utils.book_append_sheet(wb, rows.length ? X.utils.json_to_sheet(rows) : X.utils.aoa_to_sheet([['(no rows)']]), name);
          }
          X.writeFile(wb, `MyEden-CMS_export_${stamp()}.xlsx`, { compression: true });
        }
        bar.style.width = '100%';
        await API.rpc('cms_export_done', { p_format: fmt.toUpperCase(), p_tables: tables.length, p_rows: total });
        txt.textContent = `Done: ${tables.length} tables, ${num(total)} rows.`; toast('Export downloaded');
      } catch (e) { txt.textContent = e.message; toast(e.message, 'err'); }
      finally { btns.forEach((b) => { b.disabled = false; }); }
    }
  }

  // ================================================================ RECRUITMENT & ONBOARDING (Phase 3, MEG-EAF V2 data)
  const EAF = 'https://myedengp01.github.io/MEG-EAF-V2/';
  const EAF_LINK = { hr: EAF + 'hr.html', jd: EAF + 'jd-manual.html', handbook: EAF + 'handbook-status.html', law: EAF + 'employment-act.html', letters: EAF + 'hr-letters.html' };
  const eafBtn = (key, label = 'Open in MEG-EAF V2', cls = '') => `<a class="btn ${cls}" href="${esc(EAF_LINK[key])}" target="_blank" rel="noopener">${icon('plug')}${esc(label)}</a>`;
  const APP_STAGES = [
    ['submitted', 'New', 'blue'], ['under_review', 'Under review', 'blue'], ['kiv', 'KIV', 'warn'], ['shortlisted', 'Shortlisted', 'joint'],
    ['offer_preparation', 'Preparing offer', 'joint'], ['offer_issued', 'Offer issued', 'joint'], ['offer_accepted', 'Offer accepted', 'ok'],
    ['ready_for_onboarding', 'Ready for onboarding', 'ok'], ['completed', 'Hired / completed', ''], ['offer_declined', 'Offer declined', ''], ['rejected', 'Not selected', ''],
  ];
  const appStageOf = (s) => APP_STAGES.find((x) => x[0] === s) || [s, s || '—', ''];
  const appStageTag = (s) => { const [, l, t] = appStageOf(s); return `<span class="tag ${t} xs">${esc(l)}</span>`; };
  const LOEC = { draft: 'Draft', issued: 'Issued', signed_uploaded: 'Signed copy uploaded', verified: 'Verified', stamp_pending: 'Stamp pending', stamped: 'Stamped', completed: 'Completed' };
  const STAMP = { pending: 'Pending', submitted: 'Submitted', stamped: 'Stamped', not_required: 'Not required' };
  const today0 = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
  const daysTo = (s) => (s ? Math.round((new Date(s) - today0()) / 86400000) : null);

  // ---------------------------------------------------------------- reminders (bell): offers, hires, stamp duty
  async function loadRecruitSummary() {
    if (!can('onboarding')) return;
    try {
      const o = await API.rpc('cms_onboarding');
      state.onb = o;
      const stampSoon = o.offers.filter((x) => x.stamp_status === 'pending' && x.stamp_due && daysTo(x.stamp_due) <= 7).length;
      let idp = []; try { if (can('people')) idp = await API.rpc('cms_id_pending'); } catch (e) { /* optional */ }
      state.idPending = idp;
      state.onbSum = { accepted: o.accepted.length, toPayroll: o.to_payroll.length, stampSoon, idPending: idp.length };
      drawBell();
    } catch (e) { /* reminders are a convenience */ }
  }

  // ---------------------------------------------------------------- 3.1 applications (and Shortlist & Interviews)
  async function applicationsPage(item, el) {
    el.innerHTML = `${pageHead(item, eafBtn('hr', 'Open MEG-EAF V2 HR', 'ghost'))}<div id="ap-body">${loading()}</div>`;
    let rows;
    try { [rows] = await Promise.all([API.rpc('cms_recruit_applications'), loadOrg()]); }
    catch (e) { $('#ap-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const interviews = item.route === 'interviews';
    const V = [
      ['open', 'In progress', (r) => !['completed', 'rejected', 'offer_declined'].includes(r.stage)],
      ['new', 'New & under review', (r) => ['submitted', 'under_review', 'kiv'].includes(r.stage)],
      ['short', 'Shortlisted & offers', (r) => ['shortlisted', 'offer_preparation', 'offer_issued', 'offer_accepted', 'ready_for_onboarding'].includes(r.stage)],
      ['done', 'Hired / completed', (r) => r.stage === 'completed'],
      ['closed', 'Declined / not selected', (r) => ['rejected', 'offer_declined'].includes(r.stage)],
      ['all', 'All', () => true]];
    const f = { q: '', v: interviews ? 'short' : 'open', co: 'all' };
    const cos = [...new Set(rows.map((r) => r.company).filter(Boolean))].sort();
    const byStage = Object.fromEntries(APP_STAGES.map(([k]) => [k, rows.filter((r) => r.stage === k).length]));
    $('#ap-body', el).innerHTML = `
      <div class="pipe">${APP_STAGES.filter(([k]) => byStage[k]).map(([k, l, t]) => `<div class="pipe-step ${t}"><b>${num(byStage[k])}</b><span>${esc(l)}</span></div>`).join('') || '<p class="muted">No applications yet.</p>'}</div>
      <section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input id="aq" type="search" placeholder="Name, position, email or phone" aria-label="Search applications"></label>
          <select id="aco" aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}">${esc(coShort(c))}</option>`).join('')}</select>
          <div class="seg">${V.map(([k, l, fn]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${rows.filter(fn).length}</span></button>`).join('')}</div>
        </div>
        <div class="table-wrap fill"><table class="data freeze2" id="atable"><thead><tr><th>Submitted</th><th>Applicant</th><th>Company</th><th>Position</th><th>Stage</th><th>Offer letter</th><th>Start</th><th>Employee</th></tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="acount"></p>
        <p class="muted small">From MEG-EAF V2. Click an application for its summary and stage history. Screening, Office Use, shortlisting, interviews and the offer letter are done in MEG-EAF V2; once an offer is accepted and the onboarding handoff is prepared, the person is created in <a href="#/onboarding">Offers &amp; Onboarding</a>.</p>
      </section>`;
    const draw = () => {
      const t = f.q.trim().toLowerCase(); const fn = V.find((x) => x[0] === f.v)[2];
      const list = rows.filter((r) => fn(r) && (f.co === 'all' || r.company === f.co)
        && (!t || `${r.name} ${r.position || ''} ${r.title || ''} ${r.email || ''} ${r.contact || ''}`.toLowerCase().includes(t)));
      $('#atable tbody', el).innerHTML = list.length ? list.map((r) => `<tr data-id="${esc(r.id)}" class="click" tabindex="0">
          <td class="nowrap">${dShort(r.submitted_at)}</td><td><b>${esc(r.name)}</b>${r.email ? `<small class="sub">${esc(r.email)}</small>` : ''}</td>
          <td>${esc(coShort(r.company))}</td><td>${esc(r.title || r.position || '—')}${r.title && r.position && r.title !== r.position ? `<small class="sub">applied: ${esc(r.position)}</small>` : ''}</td>
          <td>${appStageTag(r.stage)}</td><td>${r.loec ? esc(LOEC[r.loec] || r.loec) : '<span class="muted">—</span>'}</td>
          <td class="nowrap">${r.start ? dShort(r.start) : '<span class="muted">—</span>'}</td>
          <td class="nowrap">${r.employee_id ? `<code>${esc(r.employee_id)}</code>${r.in_payroll ? '' : '<small class="sub warn-txt">not in payroll</small>'}` : '<span class="muted">—</span>'}</td></tr>`).join('')
        : '<tr><td colspan="8"><div class="empty small"><p>No applications here</p><span>Try another tab or clear the search.</span></div></td></tr>';
      $('#acount', el).textContent = `${list.length} of ${rows.length} applications`;
      fitTables();
    };
    draw();
    $('#aq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('#aco', el).addEventListener('change', (e) => { f.co = e.target.value; draw(); });
    $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
    const open = (id) => applicationWindow(id);
    $('#atable tbody', el).addEventListener('click', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) open(tr.dataset.id); });
    $('#atable tbody', el).addEventListener('keydown', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr && e.key === 'Enter') open(tr.dataset.id); });
  }

  async function applicationWindow(id) {
    let a;
    try { a = await API.rpc('cms_recruit_application', { p_id: id }); } catch (e) { toast(e.message, 'err'); return; }
    const kv = (k, v) => (v ? `<div><dt>${esc(k)}</dt><dd>${v}</dd></div>` : '');
    await modal({
      title: a.name, wide: true, ok: null, cancel: 'Close',
      body: `<p class="muted small">${esc(coShort(a.company))} · submitted ${dShort(a.submitted_at)} · ${appStageTag(a.stage)}${a.decision ? ` · decision: ${esc(a.decision)}` : ''}</p>
        <dl class="kv2">
          ${kv('Applied for', esc(a.position || ''))}${kv('Approved job title', esc([a.title, a.level].filter(Boolean).join(' · ')))}${kv('JD reference', esc(a.jd_ref || ''))}
          ${kv('Chinese name', esc(a.chinese_name || ''))}${kv('Email', esc(a.email || ''))}${kv('Phone', esc(a.contact || ''))}
          ${kv('Available from', a.available_from ? dShort(a.available_from) : '')}${kv('Expected salary', a.expected_salary ? esc(a.expected_salary) : '')}
          ${kv('Interviewed by', esc(a.interviewed_by || ''))}${kv('Department', esc(a.department || ''))}${kv('Work location', esc(a.location || ''))}
          ${kv('Start date', a.start ? dShort(a.start) : '')}${kv('Working hours', esc(a.hours || ''))}${kv('Final salary', a.final_salary ? money(a.final_salary) : '')}
          ${kv('Employment type', esc(a.employment_type || ''))}${kv('Pay basis', esc(a.pay_basis || ''))}${kv('Probation', a.probation_months ? `${esc(a.probation_months)} months` : '')}
          ${kv('Reporting to', esc(a.reporting || ''))}${kv('Office comments', esc(a.office_comments || ''))}
          ${kv('Offer letter', a.loec ? `${esc(LOEC[a.loec.status] || a.loec.status)} · revision ${esc(a.loec.revision)}${a.loec.stamp_status ? ` · stamp ${esc(STAMP[a.loec.stamp_status] || a.loec.stamp_status)}` : ''}` : '')}
          ${kv('Employee', a.person ? `<code>${esc(a.person.employee_id || '—')}</code> · ${esc(a.person.status)}${a.person.in_payroll ? ' · in payroll' : ' · <span class="warn-txt">not in payroll yet</span>'}` : '')}
        </dl>
        <h4 class="sec-h">Stage history</h4>
        ${a.events.length ? `<ol class="timeline">${a.events.map((e) => `<li><b>${esc(appStageOf(e.to)[1])}</b>${e.from ? ` <span class="muted small">from ${esc(appStageOf(e.from)[1])}</span>` : ''}<small class="sub">${dShort(e.at)} · ${esc(e.by || '—')}${e.note ? ` · ${esc(e.note)}` : ''}</small></li>`).join('')}</ol>` : '<p class="muted small">No stage changes recorded yet.</p>'}
        <div class="btn-row">${eafBtn('hr', 'Open in MEG-EAF V2', 'primary')}${['offer_accepted', 'ready_for_onboarding'].includes(a.stage) ? '<a class="btn" href="#/onboarding">Go to Offers &amp; Onboarding</a>' : ''}</div>
        <p class="muted small">MEG-EAF V2 opens on its HR page; search for ${esc(a.name)} there. Photos and IC images stay in MEG-EAF V2.</p>`,
    });
  }

  // ---------------------------------------------------------------- 3.2 JD Manual and Positions & Vacancies
  async function jdPage(item, el) {
    const positions = item.route === 'positions';
    el.innerHTML = `${pageHead(item, eafBtn('jd', 'Open the JD Manual in MEG-EAF V2', 'ghost'))}<div id="jd-body">${loading()}</div>`;
    let J;
    try { [J] = await Promise.all([API.rpc('cms_jd'), loadOrg()]); } catch (e) { $('#jd-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const ent = Object.fromEntries(J.entities.map((x) => [x.id, x])); const dep = Object.fromEntries(J.departments.map((x) => [x.id, x]));
    const f = { q: '', co: 'all', dept: 'all', v: positions ? 'all' : 'all' };
    const V = positions
      ? [['all', 'All positions', () => true], ['open', 'Open for applications', (p) => p.open], ['staffed', 'With staff', (p) => p.staff > 0], ['apps', 'With applications', (p) => p.applications > 0], ['vacant', 'No staff yet', (p) => !p.staff]]
      : [['all', 'All', () => true]];
    $('#jd-body', el).innerHTML = `
      <section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input id="jq" type="search" placeholder="Job title, reference or level" aria-label="Search positions"></label>
          <select id="jco" aria-label="Company"><option value="all">All companies</option>${J.entities.map((e) => `<option value="${esc(e.id)}">${esc(coShort(e.code) || e.name)}</option>`).join('')}</select>
          <select id="jdept" aria-label="Department"><option value="all">All departments</option></select>
          ${V.length > 1 ? `<div class="seg">${V.map(([k, l, fn]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${J.positions.filter(fn).length}</span></button>`).join('')}</div>` : ''}
        </div>
        <div class="table-wrap fill"><table class="data freeze2" id="jtable"><thead><tr><th>Reference</th><th>Job title</th><th>Company</th><th>Department</th><th>Level</th>${positions ? '<th>Staff</th><th>Applications</th><th>Open</th>' : '<th>Type</th><th>Reports to</th><th>Version</th>'}</tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="jcount"></p>
        <p class="muted small">${positions ? 'Staff counts active and onboarding people whose approved job title and employer match the position. “Open for applications” is set in the JD Manual (MEG-EAF V2) and controls what applicants can choose.' : 'The controlled JD master from MEG-EAF V2. Click a position for its purpose, responsibilities, KPIs and competencies'}${J.can_see_pay ? ' and salary bands (HR and Admin only).' : '.'} Changes are made in the JD Manual in MEG-EAF V2.</p>
      </section>`;
    const fillDept = () => { $('#jdept', el).innerHTML = `<option value="all">All departments</option>${J.departments.filter((d) => f.co === 'all' || String(d.entity_id) === f.co).map((d) => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join('')}`; f.dept = 'all'; };
    fillDept();
    const draw = () => {
      const t = f.q.trim().toLowerCase(); const fn = V.find((x) => x[0] === f.v)[2];
      const list = J.positions.filter((p) => fn(p) && (f.co === 'all' || String(p.entity_id) === f.co) && (f.dept === 'all' || String(p.department_id) === f.dept)
        && (!t || `${p.reference} ${p.title} ${p.level || ''}`.toLowerCase().includes(t)));
      $('#jtable tbody', el).innerHTML = list.length ? list.map((p) => `<tr data-id="${esc(p.id)}" class="click" tabindex="0">
          <td class="nowrap"><code>${esc(p.reference || '—')}</code></td><td><b>${esc(p.title)}</b></td>
          <td>${esc(coShort(ent[p.entity_id]?.code) || '—')}</td><td>${esc(dep[p.department_id]?.name || '—')}</td><td>${esc(p.level || '—')}</td>
          ${positions ? `<td class="num">${p.staff ? num(p.staff) : '<span class="muted">0</span>'}</td><td class="num">${p.applications ? num(p.applications) : '<span class="muted">0</span>'}</td><td>${p.open ? '<span class="tag ok xs">Open</span>' : '<span class="muted small">Closed</span>'}</td>`
            : `<td>${esc(p.employment_type || '—')}</td><td>${esc(p.reports_to || '—')}</td><td class="nowrap">${esc(p.version || '—')}${p.effective_date ? `<small class="sub">from ${dShort(p.effective_date)}</small>` : ''}</td>`}</tr>`).join('')
        : '<tr><td colspan="8"><div class="empty small"><p>No positions match</p><span>Clear the search or filters.</span></div></td></tr>';
      $('#jcount', el).textContent = `${list.length} of ${J.positions.length} positions`;
      fitTables();
    };
    draw();
    $('#jq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('#jco', el).addEventListener('change', (e) => { f.co = e.target.value; fillDept(); draw(); });
    $('#jdept', el).addEventListener('change', (e) => { f.dept = e.target.value; draw(); });
    $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
    const open = async (id) => {
      let p; try { p = await API.rpc('cms_jd_position', { p_id: id }); } catch (e) { toast(e.message, 'err'); return; }
      let caps = []; try { if (p.salary_bands && p.salary_bands.length) caps = await API.rpc('cms_position_caps', { p_position: id }); } catch (e) { /* caps are extra */ }
      const capOf = (b, i) => caps[i] && (caps[i].cap_min != null || caps[i].cap_max != null) ? `${caps[i].cap_min != null ? money(caps[i].cap_min) : '—'} – ${caps[i].cap_max != null ? money(caps[i].cap_max) : '—'}` : '<span class="muted">not set</span>';
      const para = (k, v) => (v ? `<h4 class="sec-h">${esc(k)}</h4><p class="pre">${esc(v)}</p>` : '');
      await modal({
        title: p.job_title, wide: true, ok: null, cancel: 'Close',
        body: `<p class="muted small"><code>${esc(p.reference || '')}</code> · ${esc(coShort(p.entity) || '')} · ${esc(p.department || '')}${p.level ? ` · ${esc(p.level)}` : ''}${p.version ? ` · version ${esc(p.version)}` : ''} · ${p.is_open_for_recruitment ? '<span class="tag ok xs">Open for applications</span>' : 'closed for applications'}</p>
          <dl class="kv2">${[['Reports to', p.reports_to], ['Direct reports', p.direct_reports], ['Location', p.location], ['Employment type', p.employment_type], ['Works closely with', p.works_closely_with]]
            .filter(([, v]) => v).map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>
          ${para('Purpose', p.purpose)}
          ${p.responsibilities.length ? `<h4 class="sec-h">Responsibilities</h4><ol class="jd-list">${p.responsibilities.map((r) => `<li><b>${esc(r.title || '')}</b>${r.description ? `<span>${esc(r.description)}</span>` : ''}</li>`).join('')}</ol>` : ''}
          ${p.kpis.length ? `<h4 class="sec-h">KPIs</h4><div class="table-wrap"><table class="data compact"><thead><tr><th>Area</th><th>Measure</th><th>Review</th></tr></thead><tbody>${p.kpis.map((k) => `<tr><td>${esc(k.area || '')}</td><td>${esc(k.measure || '')}</td><td>${esc(k.frequency || '')}</td></tr>`).join('')}</tbody></table></div>` : ''}
          ${p.competencies.length ? `<h4 class="sec-h">Competencies</h4><p>${p.competencies.map((c) => `<span class="tag xs">${esc(c)}</span>`).join(' ')}</p>` : ''}
          ${para('Minimum qualifications', p.minimum_qualifications)}${para('Experience', p.required_experience)}${para('Skills & knowledge', p.skills_knowledge)}
          ${para('Safety & child protection', p.safety_child_protection)}${para('Career path', p.career_path)}
          ${p.salary_bands ? (p.salary_bands.length ? `<h4 class="sec-h">Salary bands <small class="muted">HR and Admin only</small></h4><div class="table-wrap"><table class="data compact"><thead><tr><th>Tier</th><th>Market range (JD)</th>${caps.length ? '<th>MyEden cap</th>' : ''}<th>Typical profile</th></tr></thead><tbody>${p.salary_bands.map((b, i) => `<tr><td>${esc(b.tier || '')}</td><td class="nowrap">${b.min != null && b.max != null ? `${money(b.min)} – ${money(b.max)}` : esc(b.range || '—')}</td>${caps.length ? `<td class="nowrap">${capOf(b, i)}</td>` : ''}<td>${esc(b.profile || '')}</td></tr>`).join('')}</tbody></table></div>` : '') : ''}
          <div class="btn-row">${eafBtn('jd', 'Edit in the JD Manual (MEG-EAF V2)')}</div>`,
      });
    };
    $('#jtable tbody', el).addEventListener('click', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) open(tr.dataset.id); });
    $('#jtable tbody', el).addEventListener('keydown', (e) => { const tr = e.target.closest('tr[data-id]'); if (tr && e.key === 'Enter') open(tr.dataset.id); });
  }

  // ---------------------------------------------------------------- 3.3 + 3.4 offers & onboarding, hire
  async function onboardingPage(item, el) {
    el.innerHTML = `${pageHead(item, eafBtn('hr', 'Open MEG-EAF V2 HR', 'ghost'))}<div id="on-body">${loading()}</div>`;
    let o;
    try { [o] = await Promise.all([API.rpc('cms_onboarding'), loadOrg()]); state.onb = o; } catch (e) { $('#on-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const hireBtn = (attrs) => (o.can_hire ? `<button type="button" class="btn sm primary" ${attrs}>${icon('user-plus')}Hire…</button>` : '');
    const stampCell = (x) => {
      if (!x.stamp_status) return '<span class="muted">—</span>';
      const d = daysTo(x.stamp_due); const late = x.stamp_status === 'pending' && d !== null && d < 0; const soon = x.stamp_status === 'pending' && d !== null && d >= 0 && d <= 7;
      return `${esc(STAMP[x.stamp_status] || x.stamp_status)}${x.stamp_due ? `<small class="sub ${late ? 'bad-txt' : soon ? 'warn-txt' : ''}">due ${dShort(x.stamp_due)}${late ? ` · ${-d} days late` : soon ? ` · in ${d} days` : ''}</small>` : ''}`;
    };
    $('#on-body', el).innerHTML = `
      <div class="pipe">
        <div class="pipe-step ok"><b>${num(o.accepted.length)}</b><span>Approved, to hire</span></div>
        <div class="pipe-step warn"><b>${num(o.to_payroll.length)}</b><span>Not yet in payroll</span></div>
        <div class="pipe-step joint"><b>${num(o.offers.filter((x) => !['completed'].includes(x.status)).length)}</b><span>Offer letters open</span></div>
        <div class="pipe-step ${state.onbSum?.stampSoon ? 'bad' : ''}"><b>${num(o.offers.filter((x) => x.stamp_status === 'pending' && x.stamp_due && daysTo(x.stamp_due) <= 7).length)}</b><span>Stamp duty due ≤ 7 days</span></div>
      </div>
      <section class="card"><div class="card-head"><h3>Approved applicants</h3><span class="muted small">Decision Approved in MEG-EAF V2 and no employee record yet. Hire creates the person record, Employee ID and payroll record together, and assigns the handbook.</span></div>
        ${o.accepted.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Applicant</th><th>Company</th><th>Job title</th><th>Start</th><th>Office Use / check</th><th></th></tr></thead><tbody>
          ${o.accepted.map((x) => `<tr><td><b>${esc(x.name)}</b></td><td>${esc(coShort(x.company))}</td><td>${esc(x.title || '—')}${x.department ? `<small class="sub">${esc(x.department)}</small>` : ''}</td>
            <td class="nowrap">${x.start ? dShort(x.start) : '—'}</td>
            <td>${(x.matches || []).length ? `<span class="tag warn xs">Already an employee?</span>${x.matches.map((m) => `<small class="sub">${esc(m.employee_id || 'no Employee ID')} · ${esc(m.name)} · ${esc(m.status)} (same ${esc(m.by)})</small>`).join('')}` : x.handoff === 'pending_import' || x.ready ? '<span class="tag ok xs">Ready to hire</span>' : '<span class="tag warn xs">Office Use incomplete</span><small class="sub">add start date and salary in MEG-EAF V2</small>'}${x.decision ? `<small class="sub">decision: ${esc(x.decision)}</small>` : ''}</td>
            <td class="nowrap">${(x.matches || []).length ? (o.can_hire ? x.matches.map((m) => `<button type="button" class="btn sm" data-link-a="${esc(x.application_id)}" data-link-p="${esc(m.person_id)}" data-name="${esc(x.name)}" data-eid="${esc(m.employee_id || '')}">${icon('users')}Link to ${esc(m.employee_id || 'this person')}</button>`).join(' ') : '') : x.handoff === 'pending_import' ? hireBtn(`data-hire-h="${esc(x.handoff_id)}"`) : x.ready ? hireBtn(`data-hire-a="${esc(x.application_id)}"`) : eafBtn('hr', 'Open MEG-EAF V2', 'sm')}</td></tr>`).join('')}
          </tbody></table></div>` : '<div class="empty small"><p>No accepted applicants waiting</p><span>When an offer is accepted in MEG-EAF V2 it appears here.</span></div>'}
      </section>
      ${(state.idPending || []).length ? `<section class="card"><div class="card-head"><h3>Employee ID incomplete</h3><span class="muted small">A group number is reserved for each person (first come, first served); the ID is completed automatically once gender and start date are entered.</span></div>
        <div class="table-wrap"><table class="data"><thead><tr><th>Reserved number</th><th>Name</th><th>Company</th><th>Missing</th></tr></thead><tbody>
        ${state.idPending.map((x) => `<tr><td><code>${esc(String(x.serial).padStart(4, '0'))}</code></td><td><b>${esc(x.name)}</b></td><td>${esc(coShort(x.company))}</td><td class="warn-txt">${esc((x.missing || []).join(', ') || '—')}</td></tr>`).join('')}
        </tbody></table></div><p class="muted small">Enter the missing details with <b>Add to payroll…</b> below, or in the Office Use section in MEG-EAF V2.</p></section>` : ''}
      <section class="card"><div class="card-head"><h3>Not yet in payroll</h3><span class="muted small">People who are active or onboarding in the CMS but have no payroll record.</span></div>
        ${o.to_payroll.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Employee ID</th><th>Name</th><th>Company</th><th>Job title</th><th>Start</th><th>Status</th><th></th></tr></thead><tbody>
          ${o.to_payroll.map((x) => `<tr><td><code>${esc(x.employee_id || '—')}</code></td><td><b>${esc(x.name)}</b></td><td>${esc(coShort(x.company))}</td><td>${esc(x.title || '—')}</td>
            <td class="nowrap">${dShort(x.start)}</td><td><span class="st st-${esc(x.status)}">${esc(x.status)}</span></td><td class="nowrap">${hireBtn(`data-hire-p="${esc(x.person_id)}"`).replace('Hire…', 'Add to payroll…')}${o.can_hire && x.status === 'onboarding' ? ` <button type="button" class="btn sm ghost" data-nojoin="${esc(x.person_id)}" data-name="${esc(x.name)}">Did not join…</button>` : ''}</td></tr>`).join('')}
          </tbody></table></div>` : '<div class="empty small"><p>Everyone is in payroll</p><span>Nothing to add.</span></div>'}
      </section>
      <section class="card"><div class="card-head"><h3>Offer letters (LOEC)</h3><span class="muted small">Draft → Issued → Signed copy uploaded → Verified → Stamp → Completed. Issued, signed and stamped in MEG-EAF V2.</span></div>
        ${o.offers.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Applicant</th><th>Company</th><th>Document</th><th>Status</th><th>Issued</th><th>Signed</th><th>Stamp duty</th><th>Original</th></tr></thead><tbody>
          ${o.offers.map((x) => `<tr><td><b>${esc(x.name)}</b></td><td>${esc(coShort(x.company))}</td><td class="nowrap"><code>${esc(x.document_id || '—')}</code><small class="sub">rev ${esc(x.revision)}${x.jd_reference ? ` · ${esc(x.jd_reference)}` : ''}</small></td>
            <td>${esc(LOEC[x.status] || x.status)}</td><td class="nowrap">${dShort(x.issued_at)}</td>
            <td class="nowrap">${x.employee_signed ? `${dShort(x.employee_signed)}<small class="sub">employer ${dShort(x.employer_signed)}</small>` : '<span class="muted">—</span>'}</td>
            <td class="nowrap">${stampCell(x)}</td><td>${x.original_received ? '<span class="tag ok xs">Received</span>' : '<span class="muted">—</span>'}</td></tr>`).join('')}
          </tbody></table></div>` : '<div class="empty small"><p>No offer letters yet</p><span>Offer letters issued in MEG-EAF V2 are tracked here, with stamp-duty due dates.</span></div>'}
      </section>`;
    const reload = () => { state.onb = null; loadRecruitSummary(); onboardingPage(item, el); };
    $$('[data-hire-h]', el).forEach((b) => b.addEventListener('click', async () => { if (await hireWindow({ handoff: b.dataset.hireH })) reload(); }));
    $$('[data-hire-p]', el).forEach((b) => b.addEventListener('click', async () => { if (await hireWindow({ person: b.dataset.hireP })) reload(); }));
    $$('[data-nojoin]', el).forEach((b) => b.addEventListener('click', async () => {
      const ok = await modal({ title: `Did not join · ${b.dataset.name}`, ok: 'Mark as did not join', danger: true,
        body: `<p>The person is moved to Former Staff with the reason <b>Did not join</b> and the handbook assignment is withdrawn. Their Employee ID number is kept and never given to anyone else, so the gap in the sequence is explained.</p>
          <label class="fld"><span>Note</span><input name="note" required maxlength="300" placeholder="e.g. declined the offer on 25 Oct"></label>`,
        onOk: async (form) => { if (!form.note.value.trim()) throw new Error('Give a short note.'); await API.rpc('cms_not_joined', { p_person: b.dataset.nojoin, p_note: form.note.value.trim() }); } });
      if (ok) { toast(`${b.dataset.name}: marked did not join`); reload(); }
    }));
    $$('[data-hire-a]', el).forEach((b) => b.addEventListener('click', async () => { if (await hireWindow({ application: b.dataset.hireA })) reload(); }));
    $$('[data-link-a]', el).forEach((b) => b.addEventListener('click', async () => {
      const ok = await modal({ title: `Link application · ${b.dataset.name}`, ok: 'Link',
        body: `<p>This approved application matches an existing employee${b.dataset.eid ? ` (<b>${esc(b.dataset.eid)}</b>)` : ''}. Linking records the application on that person and marks it completed in MEG-EAF V2. No new person, Employee ID or payroll record is created.</p>
          <p class="muted small">If this is a different person with the same name, do not link: ask Admin to check the record first.</p>`,
        onOk: async () => { await API.rpc('cms_link_application', { p_application: b.dataset.linkA, p_person: b.dataset.linkP }); } });
      if (ok) { toast(`${b.dataset.name}: application linked`); reload(); }
    }));
  }

  async function hireWindow({ handoff = null, person = null, application = null }) {
    let P;
    try { P = application ? await API.rpc('cms_hire_prefill_app', { p_application: application }) : await API.rpc('cms_hire_prefill', { p_handoff: handoff, p_person: person }); }
    catch (e) { toast(e.message, 'err'); return false; }
    const opt = (list, cur, blank) => `${blank ? `<option value="">${esc(blank)}</option>` : ''}${list.map(([v, l]) => `<option value="${esc(v)}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`).join('')}`;
    const t5 = (s) => (s ? String(s).slice(0, 5) : '');
    const comp0 = P.companies.find((c) => c.code === P.employer) || P.companies[0] || {};
    const dept0 = P.departments.find((d) => d.code === P.department || d.name === P.department);
    const title0 = P.titles.find((t) => (t.name || '').toLowerCase() === (P.title || '').toLowerCase());
    const idNote = P.employee_id ? `Keeps Employee ID <b>${esc(P.employee_id)}</b>.` : `Gets the next group number, <b>${esc(String(P.next_serial).padStart(4, '0'))}</b>; the Employee ID is built from the employer, start month and gender (e.g. ${esc((P.employer || 'MEG')[0])}${esc((P.join_date || '').slice(5, 7) + (P.join_date || '').slice(2, 4))}${esc(P.gender || 'F')}${esc(String(P.next_serial).padStart(4, '0'))}).`;
    return modal({
      title: `${P.person_id ? 'Add to payroll' : 'Hire'} · ${P.name}`, wide: true, ok: P.person_id ? 'Add to payroll' : 'Hire', cancel: 'Cancel',
      body: `<p class="muted small">Filled in from the Office Use section in MEG-EAF V2. Check every field: the person record and the payroll record are created together. ${idNote}</p>
        <div class="fld-2">
          <label class="fld"><span>Name</span><input name="name" required value="${esc(P.name || '')}"></label>
          <label class="fld"><span>Gender <small class="muted">— used in the Employee ID</small></span><select name="gender" required>${opt([['F', 'Female'], ['M', 'Male']], P.gender, 'Confirm…')}</select></label>
          <label class="fld"><span>Employer on the contract</span><select name="employer" required>${opt([['MEG', 'MyEden Group'], ['MEH', 'MyEden Edu Hub'], ['HD', 'Happy Dino'], ['ABP', 'Aborne Project']], P.employer)}</select></label>
          <label class="fld"><span>Paying company</span><select name="company" required>${opt(P.companies.map((c) => [c.id, c.name]), comp0.id)}</select></label>
          <label class="fld"><span>Start date</span><input type="date" name="join" required value="${esc(P.join_date || '')}"></label>
          <label class="fld"><span>Centre / department${P.department ? ` <small class="muted">— offer: ${esc(P.department)}</small>` : ''}</span><select name="dept">${opt(P.departments.map((d) => [d.id, d.code === d.name ? d.code : `${d.code} · ${d.name}`]), dept0?.id, 'Choose…')}</select></label>
          <label class="fld"><span>Job title${P.title && !title0 ? ` <small class="muted">— “${esc(P.title)}” is new to payroll</small>` : ''}</span><select name="title">${opt(P.titles.map((t) => [t.id, t.name]), title0?.id, P.title && !title0 ? `Add “${P.title}” to payroll titles` : 'Not set')}</select></label>
          <label class="fld"><span>Employment status</span><select name="conf">${opt(P.statuses.map((x) => [x.code, x.label]), 'UP')}</select></label>
          <label class="fld"><span>Job status${P.employment_type ? ` <small class="muted">— offer: ${esc(P.employment_type)}</small>` : ''}</span><select name="job">${opt(P.job_statuses.map((x) => [x.code, x.label]), /part/i.test(P.employment_type || '') ? 'PT' : 'FT', 'Not set')}</select></label>
          <label class="fld"><span>Working hours</span><span class="hours"><input type="time" name="from" value="${esc(t5(P.work_from))}"> – <input type="time" name="to" value="${esc(t5(P.work_to))}"></span></label>
          <label class="fld"><span>Starting salary (RM)</span><input type="text" inputmode="decimal" data-money name="salary" required value="${P.salary == null || P.salary === '' ? '' : m2(P.salary)}"></label>
          <label class="fld"><span>Pay basis</span><select name="basis">${opt([['monthly', 'Monthly'], ['hourly', 'Hourly'], ['daily', 'Daily']], /hour/i.test(P.pay_basis || '') ? 'hourly' : /dai/i.test(P.pay_basis || '') ? 'daily' : 'monthly')}</select></label>
          <label class="fld"><span>Email</span><input name="email" type="email" value="${esc(P.email || '')}"></label>
          <label class="fld"><span>Phone</span><input name="phone" value="${esc(P.phone || '')}"></label>
          <label class="fld"><span>Date of birth</span><input type="date" name="dob" value="${esc(P.dob || '')}"></label>
          <label class="fld"><span>NRIC <small class="muted">— payroll only</small></span><input name="nric" value="${esc(P.nric || '')}" autocomplete="off"></label>
        </div>
        <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>
        <p class="muted small">After this: bank, EPF / SOCSO / tax numbers and allowances are added in MyPayroll (Employee › Identity &amp; bank, Pay). The handbook is assigned automatically.</p>`,
      onOk: async (form) => {
        if (!form.gender.value) throw new Error('Confirm the gender: the Employee ID is built from it.');
        if (!form.join.value) throw new Error('Enter the start date.');
        if (!(mval(form.salary.value) >= 0) || form.salary.value === '') throw new Error('Enter the starting salary.');
        const r = await API.rpc('cms_hire', { p: {
          application_id: P.application_id || null, handoff_id: P.handoff_id, person_id: P.person_id, name: form.name.value, gender: form.gender.value, employer: form.employer.value,
          company_id: Number(form.company.value), join_date: form.join.value, department_id: form.dept.value || null,
          job_title_id: form.title.value || null, job_title_name: form.title.value ? null : (P.title || null),
          confirmation_status: form.conf.value, job_status: form.job.value || null, work_from: form.from.value || null, work_to: form.to.value || null,
          salary: mval(form.salary.value), pay_basis: form.basis.value, email: form.email.value || null, phone: form.phone.value || null,
          dob: form.dob.value || null, nric: form.nric.value || null, note: form.note.value || null } });
        toast(`${form.name.value.toUpperCase()} hired · Employee ID ${r.employee_id}`);
        state.people = null;
      },
    });
  }

  // ---------------------------------------------------------------- 3.6 handbook progress
  const HB = { assigned: ['Assigned', 'warn'], viewed: ['Opened', 'blue'], read: ['Read', 'joint'], acknowledged: ['Acknowledged', 'ok'] };
  const hbState = (r) => (r.acknowledged_at ? 'acknowledged' : r.read_at ? 'read' : r.viewed_at ? 'viewed' : r.status ? 'assigned' : null);
  async function loadHandbook() { if (!can('handbook')) return null; try { state.hb = await API.rpc('cms_handbook_progress'); } catch (e) { state.hb = null; } return state.hb; }
  const hbCell = (r) => {
    if (!r) return '<span class="muted">—</span>';
    const s = hbState(r); if (!s) return '<span class="muted small">not assigned</span>';
    const late = s !== 'acknowledged' && r.due_at && daysTo(r.due_at) < 0;
    return `<span class="tag ${HB[s][1]} xs">${HB[s][0]}</span>${s === 'acknowledged' ? `<small class="sub">${dShort(r.acknowledged_at)}</small>` : r.progress != null ? `<small class="sub ${late ? 'bad-txt' : ''}">${r.progress}% read${r.due_at ? ` · due ${dShort(r.due_at)}` : ''}</small>` : ''}`;
  };
  async function handbookPage(item, el) {
    el.innerHTML = `${pageHead(item, eafBtn('handbook', 'Open handbook status in MEG-EAF V2', 'ghost'))}<div id="hb-body">${loading()}</div>`;
    let rows;
    try { [rows] = await Promise.all([loadHandbook(), loadOrg()]); if (!rows) throw new Error('Could not load handbook progress.'); } catch (e) { $('#hb-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    rows.forEach((r) => upKeys(r, 'name'));
    const V = [['open', 'Not yet acknowledged', (r) => hbState(r) && hbState(r) !== 'acknowledged'], ['late', 'Past due', (r) => hbState(r) && hbState(r) !== 'acknowledged' && r.due_at && daysTo(r.due_at) < 0],
      ['none', 'Not assigned', (r) => !hbState(r)], ['done', 'Acknowledged', (r) => hbState(r) === 'acknowledged'], ['all', 'All active staff', () => true]];
    const f = { q: '', v: 'open', co: 'all' };
    const cos = [...new Set(rows.map((r) => r.company).filter(Boolean))].sort();
    $('#hb-body', el).innerHTML = `
      <section class="card">
        <div class="toolbar">
          <label class="search-in">${icon('search')}<input id="hq" type="search" placeholder="Name, Employee ID or centre" aria-label="Search"></label>
          <select id="hco" aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}">${esc(coShort(c))}</option>`).join('')}</select>
          <div class="seg">${V.map(([k, l, fn]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${rows.filter(fn).length}</span></button>`).join('')}</div>
        </div>
        <div class="table-wrap fill"><table class="data freeze2" id="htable"><thead><tr><th>Employee ID</th><th>Name</th><th>Employer</th><th>Centre</th><th>Handbook</th><th>Assigned</th><th>Progress</th></tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="hcount"></p>
        <p class="muted small">Active and onboarding staff with their latest handbook assignment from MEG-EAF V2. Staff read and acknowledge the handbook in MEG-EAF V2; assignments, deadlines and reminders are managed there.</p>
      </section>`;
    const draw = () => {
      const t = f.q.trim().toLowerCase(); const fn = V.find((x) => x[0] === f.v)[2];
      const list = rows.filter((r) => fn(r) && (f.co === 'all' || r.company === f.co) && (!t || `${r.name} ${r.employee_id || ''} ${r.unit || ''}`.toLowerCase().includes(t)));
      $('#htable tbody', el).innerHTML = list.length ? list.map((r) => `<tr><td class="nowrap"><code>${esc(r.employee_id || '—')}</code></td><td><b>${esc(r.name)}</b></td>
          <td>${esc(coShort(r.company))}</td><td>${esc(r.unit || '—')}</td><td>${esc(r.version || '—')}</td><td class="nowrap">${dShort(r.assigned_at)}</td><td class="nowrap">${hbCell(r)}</td></tr>`).join('')
        : '<tr><td colspan="7"><div class="empty small"><p>No one here</p><span>Try another tab.</span></div></td></tr>';
      $('#hcount', el).textContent = `${list.length} of ${rows.length} people`;
      fitTables();
    };
    draw();
    $('#hq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); });
    $('#hco', el).addEventListener('change', (e) => { f.co = e.target.value; draw(); });
    $$('.seg button', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; $$('.seg button', el).forEach((x) => x.classList.toggle('on', x === b)); draw(); }));
  }

  // ---------------------------------------------------------------- 3.7 Employment Act & calculators
  function hrlawPage(item, el) {
    el.innerHTML = `${pageHead(item)}
      <section class="card coming"><div class="coming-art">${icon('scale')}</div>
        <div><h3>Employment Act 1955 &amp; calculators</h3>
        <p>The statutory reference and the overtime, leave, notice, maternity and final-pay calculators are in MEG-EAF V2. They open in a new tab with your same sign-in.</p>
        <div class="btn-row">${eafBtn('law', 'Open Employment Act & calculators', 'primary')}${can('letters') ? eafBtn('letters', 'Open HR Letters') : ''}</div></div></section>`;
  }


  // ================================================================ PHASE 4 · STAFF SELF-SERVICE
  // Every part is off by default; HR / Admin switch parts on per person (Self-service Access).
  const PARTS = [
    ['profile', 'Profile', 'My Profile: details, and change requests HR approves'],
    ['payslips', 'Payslips', 'Payslips HR releases month by month (finalised months only)'],
    ['ea', 'EA forms', 'EA forms HR releases year by year'],
    ['salary', 'Salary history', 'Their salary and each change'],
    ['items', 'Items', 'My Items: confirm items received, hand them over when leaving'],
    ['claims', 'Claims', 'My Claims: their SCF / OTCF / MTCF claims and status'],
    ['leave', 'Leave', 'My Leave: apply for leave (not in use yet: leave runs in the other system)'],
    ['handbook', 'Handbook', 'My Handbook: open the handbook and see what they acknowledged'],
    ['certs', 'Certificates', 'My Certificates: their certificates and expiry; send a new certificate to HR'],
  ];
  const PART_READY = (p) => !(PARTS.find((x) => x[0] === p) || [])[3];
  const PROFILE_FIELDS = [['contact', 'Phone'], ['email', 'Email'], ['home_address', 'Home address'], ['emergency_name', 'Emergency contact'],
    ['emergency_relation', 'Relationship'], ['emergency_phone', 'Emergency phone'], ['bank_code', 'Bank'], ['bank_account_no', 'Bank account no.']];
  const fieldLabel = (k) => (PROFILE_FIELDS.find((x) => x[0] === k) || [k, k])[1];
  const monthName = (p) => (p ? new Date(`${String(p).slice(0, 7)}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }) : '');
  const monthShort = (p) => (p ? new Date(`${String(p).slice(0, 7)}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'short', year: 'numeric' }) : '');
  const m2 = (v) => Number(v || 0).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  function selfTasks() {
    const t = []; const s = state.self; if (!s) return t;
    (s.new_payslips || []).slice(-3).forEach((p) => t.push({ ic: 'wallet', tone: 'green', title: `Your payslip for ${monthName(p)} is ready`, sub: 'View, print or save as PDF', href: '#/me/payslips' }));
    (s.profile_decided || []).slice(0, 1).forEach((x) => t.push({ ic: 'users', tone: x.status === 'approved' ? 'green' : 'rose', title: `HR ${x.status} your profile change`, sub: dShort(x.at), href: '#/me/profile' }));
    return t;
  }
  async function loadSelfPending() {
    if (!can('selfservice.profile')) return;
    try { state.selfPending = await API.rpc('cms_self_pending'); drawBell(); } catch (e) { /* reminder only */ }
  }
  async function refreshSelf() { try { state.self = await API.rpc('cms_my_self'); drawBell(); } catch (e) { /* keep the last */ } }

  // ---------------------------------------------------------------- My Home
  function meHomePage(item, el) {
    const s = state.self || {};
    const tiles = [
      ['me/profile', 'users', 'My Profile', 'Your details; send changes to HR', selfOn('profile')],
      ['me/payslips', 'wallet', 'My Payslips & EA', s.payslips ? `${s.payslips} payslip${s.payslips === 1 ? '' : 's'} released${(s.new_payslips || []).length ? ` · ${s.new_payslips.length} new` : ''}` : 'Released by HR month by month', selfOn('payslips') || selfOn('ea')],
      ['me/salary', 'trend', 'My Salary History', 'Your salary and each change', selfOn('salary')],
      ['me/claims', 'file-check', 'My Claims', 'Staff, overtime and mileage claims', selfOn('claims')],
      ['me/handbook', 'shield', 'My Handbook', 'Read and acknowledge', selfOn('handbook')],
      ['me/leave', 'calendar', 'My Leave', 'Apply and follow your requests', selfOn('leave')],
      ['me/appraisal', 'trend', 'My Appraisal', 'Self-assessment and results', selfOn('appraisal')],
      ['me/certs', 'shield', 'My Certificates', 'Certificates and expiry dates', selfOn('certs')],
      ['me/items', 'box', 'My Items', state.itemsPending?.mine_to_confirm ? `${state.itemsPending.mine_to_confirm} to confirm` : 'Company items issued to you', selfOn('items')],
    ].filter((x) => x[4]);
    el.innerHTML = `${pageHead(item)}
      <section class="card me-hero"><div class="avatar lg">${esc(initials(s.name))}</div><div><h3>${esc(s.name || '')}</h3>
        <p class="muted">${esc([s.employee_id, s.title, coShort(s.company)].filter(Boolean).join(' · '))}</p></div></section>
      <div class="me-tiles">${tiles.map(([r, ic, t, sub]) => `<a class="card me-tile" href="#/${r}"><span class="t-ic">${icon(ic)}</span><div><b>${esc(t)}</b><small>${esc(sub)}</small></div>${icon('chevron', 'chev')}</a>`).join('')}</div>
      <p class="muted small">Only the parts HR has switched on for you are shown. Ask HR if you need something else.</p>`;
  }

  // ---------------------------------------------------------------- My Profile
  async function meProfilePage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="mp-body">${loading()}</div>`;
    let P;
    try { P = await API.rpc('cms_my_profile'); } catch (e) { $('#mp-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const V = P.values || {}; const bankName = (c) => (P.banks.find((b) => b.code === c) || {}).label || c || '';
    const kv = (k, v) => `<dt>${esc(k)}</dt><dd>${v === null || v === undefined || v === '' ? '<span class="muted">—</span>' : esc(v)}</dd>`;
    const pending = P.requests.find((r) => r.status === 'pending');
    const showVal = (k, v) => (k === 'bank_code' ? bankName(v) : v) || '—';
    $('#mp-body', el).innerHTML = `
      ${pending ? `<div class="warn-box">${icon('clock')}<div><b>Change waiting for HR</b> · sent ${dShort(pending.requested_at)}
        <ul class="chg">${Object.entries(pending.changes).map(([k, v]) => `<li>${esc(fieldLabel(k))}: <s>${esc(showVal(k, (pending.previous || {})[k]))}</s> → <b>${esc(showVal(k, v))}</b></li>`).join('')}</ul>
        <button type="button" class="btn sm ghost" data-cancel="${esc(pending.id)}">Cancel this request</button></div></div>` : ''}
      <div class="grid-2">
        <section class="card"><div class="card-head"><h3>Employment</h3></div><dl class="kv2">
          ${kv('Employee ID', P.employee_id)}${kv('Employer', coShort(P.company))}${kv('Job title', P.title)}${kv('Department / centre', P.department)}
          ${kv('Work location', P.work_location)}${kv('Employment type', P.employment_type)}${kv('Start date', P.start ? dShort(P.start) : '')}
          ${kv('Working hours', P.hours)}${kv('Confirmation', P.confirmation)}${kv('Reports to', P.reports_to)}</dl></section>
        <section class="card"><div class="card-head"><h3>Personal</h3>${pending ? '' : '<button type="button" class="btn sm primary" id="mp-edit">Request a change…</button>'}</div><dl class="kv2">
          ${kv('Name', P.name)}${kv('NRIC / passport', P.nric || P.passport_no)}${kv('Date of birth', P.dob ? dShort(P.dob) : '')}
          ${kv('Phone', V.contact)}${kv('Email', V.email)}${kv('Home address', V.home_address)}
          ${kv('Emergency contact', [V.emergency_name, V.emergency_relation && `(${V.emergency_relation})`, V.emergency_phone].filter(Boolean).join(' '))}
          ${kv('Bank', [bankName(V.bank_code), V.bank_account_no].filter(Boolean).join(' · '))}
          ${kv('EPF / SOCSO / tax no.', [P.epf_no || '—', P.socso_no || '—', P.tax_no || '—'].join(' · '))}</dl>
          <p class="muted small">Name, IC and statutory numbers are changed by HR only: contact HR with your document.</p></section>
      </div>
      ${P.requests.filter((r) => r.status !== 'pending').length ? `<section class="card"><div class="card-head"><h3>Earlier requests</h3></div><div class="table-wrap"><table class="data compact"><thead><tr><th>Sent</th><th>Changes</th><th>Result</th></tr></thead><tbody>
        ${P.requests.filter((r) => r.status !== 'pending').map((r) => `<tr><td class="nowrap">${dShort(r.requested_at)}</td><td>${esc(Object.keys(r.changes).map(fieldLabel).join(', '))}</td>
          <td><span class="tag ${r.status === 'approved' ? 'ok' : r.status === 'rejected' ? 'bad' : ''} xs">${esc(r.status)}</span>${r.decision_note ? `<small class="sub">${esc(r.decision_note)}</small>` : ''}</td></tr>`).join('')}</tbody></table></div></section>` : ''}`;
    $('[data-cancel]', el)?.addEventListener('click', async (e) => {
      if (!(await confirmBox('Cancel the change request?', 'HR will no longer see it. You can send a new one afterwards.', 'Cancel request', true,
        () => API.rpc('cms_my_profile_cancel', { p_id: e.currentTarget.dataset.cancel })))) return;
      toast('Request cancelled'); refreshSelf(); render();
    });
    $('#mp-edit', el)?.addEventListener('click', async () => {
      let photo = null;
      const ok = await modal({ title: 'Request a change', ok: 'Send to HR', wide: true,
        body: `<p class="muted small">Change only what is different. HR checks and approves the change before it takes effect.</p>
          <div class="grid-2 tight">
            <label class="fld"><span>Phone</span><input name="contact" value="${esc(V.contact || '')}" inputmode="tel"></label>
            <label class="fld"><span>Email</span><input name="email" type="email" value="${esc(V.email || '')}"></label>
            <label class="fld fld-2"><span>Home address</span><textarea name="home_address" rows="2">${esc(V.home_address || '')}</textarea></label>
            <label class="fld"><span>Emergency contact</span><input name="emergency_name" value="${esc(V.emergency_name || '')}"></label>
            <label class="fld"><span>Relationship</span><input name="emergency_relation" value="${esc(V.emergency_relation || '')}"></label>
            <label class="fld"><span>Emergency phone</span><input name="emergency_phone" value="${esc(V.emergency_phone || '')}" inputmode="tel"></label>
            <label class="fld"><span>Bank</span><select name="bank_code"><option value="">—</option>${P.banks.map((b) => `<option value="${esc(b.code)}" ${b.code === V.bank_code ? 'selected' : ''}>${esc(b.label)}</option>`).join('')}</select></label>
            <label class="fld"><span>Bank account no.</span><input name="bank_account_no" value="${esc(V.bank_account_no || '')}" inputmode="numeric"></label>
            <label class="fld fld-2"><span>Photo of bank statement or bank card (needed for a bank change)</span><input name="photo" type="file" accept="image/*"></label>
            <label class="fld fld-2"><span>Note to HR (optional)</span><input name="note" maxlength="300"></label>
          </div>`,
        onOpen: (w) => { $('input[name=photo]', w).addEventListener('change', async (e) => { photo = e.target.files[0] ? await shrinkImage(e.target.files[0]) : null; }); },
        onOk: async (f) => {
          const ch = {}; PROFILE_FIELDS.forEach(([k]) => { const v = (f[k].value || '').trim(); if (v !== (V[k] || '')) ch[k] = v; });
          if (!Object.keys(ch).length) throw new Error('Nothing has changed.');
          if ((ch.bank_code !== undefined || ch.bank_account_no !== undefined) && !photo) throw new Error('Attach a photo of your bank statement or bank card for a bank change.');
          await API.rpc('cms_my_profile_request', { p_changes: ch, p_note: f.note.value || null, p_attachment: photo });
        } });
      if (ok) { toast('Sent to HR'); refreshSelf(); render(); }
    });
  }
  // phone photos are large: scale to at most 1600 px and save as JPEG
  function shrinkImage(file) {
    return new Promise((resolve, reject) => {
      const img = new Image(); const url = URL.createObjectURL(file);
      img.onload = () => {
        const k = Math.min(1, 1600 / Math.max(img.width, img.height)); const c = document.createElement('canvas');
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url); resolve(c.toDataURL('image/jpeg', 0.8));
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('That file is not a picture.')); };
      img.src = url;
    });
  }

  // ---------------------------------------------------------------- payslip and EA figures (same as MyPayroll · Payslips & reports)
  const r2 = (x) => Math.round((Number(x) + Number.EPSILON) * 100) / 100;
  const itemAmt = (i) => Number(i.override ?? i.amount) || 0;
  const PS_ORDER = ['BASIC', 'ALLOW_A1', 'ALLOW_A2', 'ALLOW_A3', 'LEADER', 'FIRST_AID', 'SKM1', 'SKM2', 'TRANSPORT', 'MVC', 'COMMISSION', 'INCENTIVE',
    'FULL_ATT', 'REFERRAL', 'BONUS', 'ANG_BAO', 'AL_BUYBACK', 'OT_NORMAL', 'OT_RESTDAY', 'OT_PH', 'UNPAID_LEAVE', 'CHILDCARE', 'LOAN', 'OTHER_DED'];
  const psOrder = (code) => { const i = PS_ORDER.indexOf(code); return i >= 0 ? i : 100; };
  const isPersonalItem = (i) => i.kind === 'deduction' && i.category === 'personal';
  const SUM_KEYS = ['gross', 'epf_ee', 'epf_er', 'socso_ee', 'socso_ee_nei', 'socso_er', 'eis_ee', 'eis_er', 'pcb', 'net', 'personal_deductions', 'reimbursements', 'net_paid'];
  function sumPayLines(lines) {
    const t = Object.fromEntries(SUM_KEYS.map((k) => [k, 0])); t.lines = 0;
    for (const l of (lines || []).filter((x) => !x.excluded)) { t.lines += 1; for (const k of SUM_KEYS) t[k] = r2(t[k] + (Number(l[k]) || 0)); }
    return t;
  }
  function payslipModel(line, ytdLines) {
    const earn = new Map(), ded = new Map(), pers = new Map(), claims = new Map();
    for (const i of line.items || []) {
      const a = itemAmt(i); if (!a) continue;
      const target = i.category === 'reimbursement' ? claims : i.kind === 'earning' ? earn : isPersonalItem(i) ? pers : ded;
      const key = i.label || i.code; const prev = target.get(key);
      target.set(key, { label: key, code: i.code, amount: r2((prev?.amount || 0) + a), order: psOrder(i.code) });
    }
    const sort = (m) => [...m.values()].sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));
    const statutory = [
      { label: 'EPF (KWSP)', ee: r2(line.epf_ee), er: r2(line.epf_er) },
      { label: 'SOCSO (PERKESO) – Invalidity', ee: r2((Number(line.socso_ee) || 0) - (Number(line.socso_ee_nei) || 0)), er: r2(line.socso_er) },
      { label: 'SOCSO – Non-employment injury (NEI)', ee: r2(line.socso_ee_nei), er: null },
      { label: 'EIS (SIP)', ee: r2(line.eis_ee), er: r2(line.eis_er) }];
    const statEe = r2(statutory.reduce((x, r) => x + r.ee, 0));
    const s = { earnings: sort(earn), deductions: sort(ded), personal: sort(pers), claims: sort(claims) };
    return { ...s, statutory, pcb: r2(line.pcb), gross: r2(line.gross), totalDeductions: r2(statEe + Number(line.pcb || 0) + Number(line.personal_deductions || 0)),
      netPaid: r2(line.net_paid), claimsTotal: r2(s.claims.reduce((x, c) => x + c.amount, 0)), ytd: sumPayLines(ytdLines) };
  }
  function eaSection(i) {
    if (isPersonalItem(i) || i.category === 'reimbursement') return null;
    if (i.kind === 'earning' && i.category === 'compensation') return '6';
    if (i.kind === 'earning' && i.pcb_subject === false) return 'F';
    if (['basic', 'overtime', 'leave'].includes(i.category)) return '1a';
    if (['incentive', 'bonus'].includes(i.category)) return '1b';
    if (i.kind === 'deduction') return '1a';
    return '1c';
  }
  function eaFigures(lines) {
    const by = new Map();
    for (const l of (lines || []).filter((x) => !x.excluded)) {
      const key = String(l.company_id || 0);
      const t = by.get(key) || { company_id: l.company_id, emp_name: l.emp_name, emp_code: l.emp_code, months: 0, b1a: 0, b1b: 0, b1c: 0, b6: 0, f_exempt: 0, d1_pcb: 0, e1_epf: 0, e2_perkeso: 0 };
      t.months += 1; t.emp_name = l.emp_name || t.emp_name; t.emp_code = l.emp_code || t.emp_code;
      for (const i of l.items || []) {
        const sec = eaSection(i); if (!sec) continue;
        const a = itemAmt(i) * (i.kind === 'deduction' ? -1 : 1);
        if (sec === '1a') t.b1a += a; else if (sec === '1b') t.b1b += a; else if (sec === '1c') t.b1c += a; else if (sec === '6') t.b6 += a; else t.f_exempt += a;
      }
      t.d1_pcb += Number(l.pcb) || 0; t.e1_epf += Number(l.epf_ee) || 0; t.e2_perkeso += (Number(l.socso_ee) || 0) + (Number(l.eis_ee) || 0);
      by.set(key, t);
    }
    return [...by.values()].map((t) => { for (const k of ['b1a', 'b1b', 'b1c', 'b6', 'f_exempt', 'd1_pcb', 'e1_epf', 'e2_perkeso']) t[k] = r2(t[k]); t.totalB = r2(t.b1a + t.b1b + t.b1c + t.b6); return t; });
  }
  const docHead = (c, title, sub) => `<div class="doc-head">${c.logo ? `<img class="doc-logo" src="${esc(asset(c.logo))}" alt="">` : ''}
    <div class="doc-co"><div class="doc-co-name">${esc(c.name || '')}</div><div>${esc([c.registration_no ? `(${c.registration_no})` : null, c.address].filter(Boolean).join(' · '))}</div>
      <div>${esc([c.phone ? `Tel ${c.phone}` : null, c.email].filter(Boolean).join(' · '))}</div></div>
    <div class="doc-title"><div>${esc(title)}</div>${sub ? `<div class="doc-sub">${esc(sub)}</div>` : ''}</div></div>`;
  function payslipSheet(D, l) {
    const c = D.companies[String(l.company_id)] || {}; const p = D.person || {}; const e = D.employment || {};
    const m = payslipModel(l, (D.ytd || []).filter((y) => String(y.company_id || 0) === String(l.company_id || 0)));
    const kv = (k, v) => `<div class="kv-row"><span>${esc(k)}</span><b>${esc(v || '—')}</b></div>`;
    const rows = (list, sign = '') => list.map((i) => `<tr><td>${esc(i.label)}</td><td class="num">${sign}${m2(i.amount)}</td></tr>`).join('');
    const tbl = (h, body, foot, small) => `<table class="doc-table${small ? ' small' : ''}"><thead><tr><th>${h}</th><th class="num">RM</th></tr></thead><tbody>${body}</tbody>${foot ? `<tfoot><tr><th>${foot[0]}</th><th class="num">${m2(foot[1])}</th></tr></tfoot>` : ''}</table>`;
    const yr = String(D.period).slice(0, 4);
    return `<section class="sheet payslip">${docHead(c, 'PAYSLIP', monthName(D.period))}
      <div class="doc-grid"><div>${kv('Employee', l.emp_name || p.name)}${kv('Employee ID', l.emp_code || p.employee_id)}${kv('NRIC / Passport', p.nric || p.passport_no)}</div>
        <div>${kv('Department', e.department)}${kv('Job title', e.title)}${kv('EPF / SOCSO / Tax no.', [p.epf_no || '—', p.socso_no || (p.nric ? String(p.nric).replace(/\D/g, '') : '') || '—', p.tax_no || '—'].join(' · '))}</div></div>
      <div class="doc-two">${tbl('Earnings', rows(m.earnings) + rows(m.deductions, '−'), ['Gross pay', m.gross])}
        ${tbl('Deductions', m.statutory.map((s) => `<tr><td>${esc(s.label)}</td><td class="num">${m2(s.ee)}</td></tr>`).join('') + `<tr><td>PCB (monthly tax deduction)</td><td class="num">${m2(m.pcb)}</td></tr>` + rows(m.personal), ['Total deductions', m.totalDeductions])}</div>
      ${m.claims.length ? tbl('Claims reimbursed (not taxed)', rows(m.claims), ['Total claims', m.claimsTotal]) : ''}
      <div class="doc-net"><span>${m.claims.length ? 'NET PAY (incl. claims)' : 'NET PAY'}</span><b>RM ${m2(m.netPaid)}</b></div>
      <div class="doc-two">${tbl('Employer contributions', m.statutory.filter((s) => s.er !== null).map((s) => `<tr><td>${esc(s.label.replace(' – Invalidity', ''))}</td><td class="num">${m2(s.er)}</td></tr>`).join(''), null, true)}
        ${tbl(`Year to date ${yr}`, [['Gross pay', m.ytd.gross], ['EPF', m.ytd.epf_ee], ['SOCSO – Invalidity', r2(m.ytd.socso_ee - m.ytd.socso_ee_nei)], ['SOCSO – NEI', m.ytd.socso_ee_nei], ['EIS', m.ytd.eis_ee], ['PCB', m.ytd.pcb], ['Net paid', m.ytd.net_paid]]
          .map(([k, v]) => `<tr><td>${k}</td><td class="num">${m2(v)}</td></tr>`).join(''), null, true)}</div>
      <div class="doc-foot"><span>Paid to: ${esc([p.bank, p.bank_account_no].filter(Boolean).join(' ') || 'bank details not recorded')}</span><span>This is a computer-generated payslip; no signature is required.</span></div></section>`;
  }
  function eaSheet(D, e) {
    const c = D.companies[String(e.company_id)] || {}; const p = D.person || {}; const s = D.signatory || {}; const y = D.year;
    const joined = (D.employments || []).find((x) => x.join_date && x.join_date.startsWith(String(y)) && x.join_date > `${y}-01-01`);
    const left = (D.employments || []).find((x) => x.resigned_date && x.resigned_date.startsWith(String(y)));
    const row = (no, label, v) => `<tr><td class="ea-no">${no}</td><td>${label}</td><td class="num">${v === null ? '' : m2(v)}</td></tr>`;
    const sec = (h, body) => `<h3 class="ea-h">${h}</h3><table class="doc-table ea-tbl"><tbody>${body}</tbody></table>`;
    return `<section class="sheet ea">
      <div class="ea-top"><div><div class="small">Malaysia · Cukai Pendapatan</div><div class="ea-form">EA</div><div class="small">C.P.8A – Pin. 2023</div></div>
        <div class="ea-title"><b>PENYATA SARAAN DARIPADA PENGGAJIAN BAGI TAHUN BERAKHIR 31 DISEMBER ${y}</b><div class="small">Statement of remuneration from employment for the year ended 31 December ${y}</div></div>
        <div class="ea-ids"><div>No. Majikan E: <b>${esc(c.tax_employer_no || '—')}</b></div><div>No. Pengenalan Cukai (TIN) Pekerja: <b>${esc(p.tax_no || '—')}</b></div><div>LHDNM Negeri: <b></b></div></div></div>
      ${sec('A. BUTIRAN PEKERJA / EMPLOYEE PARTICULARS', [['1', 'Nama penuh pekerja / Full name', e.emp_name || p.name], ['2', 'Jawatan / Position', (D.employment || {}).title], ['3', 'No. kakitangan / Staff no.', e.emp_code || p.employee_id],
        ['4', 'No. K.P. baru / NRIC', p.nric], ['5', 'No. pasport / Passport no.', p.passport_no], ['6', 'No. KWSP / EPF no.', p.epf_no], ['7', 'No. PERKESO / SOCSO no.', p.socso_no || (p.nric ? String(p.nric).replace(/\D/g, '') : '')],
        ['8', 'Bilangan anak yang layak untuk pelepasan cukai / Children qualifying for tax relief', ''],
        ['9', 'Jika bekerja tidak genap setahun / If employed for part of the year: (a) tarikh mula / start date (b) tarikh berhenti / end date', [joined ? `(a) ${dShort(joined.join_date)}` : null, left ? `(b) ${dShort(left.resigned_date)}` : null].filter(Boolean).join('   ')]]
        .map(([n, l, v]) => `<tr><td class="ea-no">${n}</td><td>${l}</td><td><b>${esc(v || '')}</b></td></tr>`).join(''))}
      <h3 class="ea-h">B. PENDAPATAN PENGGAJIAN, MANFAAT DAN TEMPAT KEDIAMAN / EMPLOYMENT INCOME, BENEFITS AND LIVING ACCOMMODATION</h3>
      <table class="doc-table ea-tbl"><tbody>
        ${row('1(a)', 'Gaji kasar, upah atau gaji cuti (termasuk gaji lebih masa) / Gross salary, wages or leave pay (including overtime)', e.b1a)}
        ${row('1(b)', 'Fi (termasuk fi pengarah), komisen atau bonus / Fees (including director fees), commission or bonus', e.b1b)}
        ${row('1(c)', 'Tip kasar, perkuisit, penerimaan sagu hati atau elaun-elaun lain / Gross tips, perquisites, awards or other allowances', e.b1c)}
        ${row('1(d)', 'Cukai pendapatan yang dibayar oleh majikan bagi pihak pekerja / Income tax borne by the employer', 0)}
        ${row('1(e)', 'Manfaat Skim Opsyen Saham Pekerja (ESOS) / ESOS benefit', 0)}${row('1(f)', 'Ganjaran / Gratuity', 0)}
        ${row('2', 'Bayaran tunggakan dan lain-lain bagi tahun terdahulu / Arrears and others for preceding years', 0)}${row('3', 'Manfaat berupa barangan / Benefits in kind', 0)}
        ${row('4', 'Nilai tempat kediaman / Value of living accommodation', 0)}${row('5', 'Bayaran balik daripada Kumpulan Wang Simpanan/Pencen yang tidak diluluskan / Refund from unapproved provident/pension fund', 0)}
        ${row('6', 'Pampasan kerana kehilangan pekerjaan / Compensation for loss of employment', e.b6 || 0)}</tbody>
        <tfoot><tr><th></th><th>JUMLAH / TOTAL</th><th class="num">${m2(e.totalB)}</th></tr></tfoot></table>
      ${sec('C. PENCEN DAN LAIN-LAIN / PENSION AND OTHERS', row('1', 'Pencen / Pension', 0) + row('2', 'Anuiti atau bayaran berkala yang lain / Annuities or other periodical payments', 0))}
      ${sec('D. JUMLAH POTONGAN / TOTAL DEDUCTIONS', row('1', 'Potongan cukai bulanan (PCB) yang dibayar kepada LHDNM / Monthly tax deductions (MTD) remitted to LHDNM', e.d1_pcb)
        + row('2', 'Arahan potongan CP38 / CP38 deductions', 0) + row('3', 'Zakat yang dibayar melalui potongan gaji / Zakat paid via salary deduction', 0)
        + row('4', 'Derma / hadiah / sumbangan diluluskan melalui potongan gaji / Approved donations via salary deduction', 0)
        + row('5', 'Jumlah tuntutan potongan oleh pekerja melalui Borang TP1 / Total claims via Form TP1: (a) pelepasan / relief (b) zakat', 0) + row('6', 'Jumlah pelepasan bagi anak yang layak / Total qualifying child relief', 0))}
      ${sec('E. CARUMAN YANG DIBAYAR OLEH PEKERJA / CONTRIBUTIONS PAID BY THE EMPLOYEE', row('1', 'Nama Kumpulan Wang: KUMPULAN WANG SIMPANAN PEKERJA (KWSP) — amaun caruman yang wajib dibayar (bahagian pekerja sahaja) / compulsory contribution (employee share only)', e.e1_epf)
        + row('2', 'PERKESO (termasuk SIP) — amaun caruman yang wajib dibayar (bahagian pekerja sahaja) / SOCSO incl. EIS, employee share only', e.e2_perkeso))}
      ${sec('F. JUMLAH ELAUN / PERKUISIT / PEMBERIAN / MANFAAT YANG DIKECUALIKAN CUKAI / TOTAL TAX-EXEMPT ALLOWANCES / PERQUISITES / GIFTS / BENEFITS', row('', 'RM', e.f_exempt))}
      <div class="ea-sign"><div><div class="small muted">Nama pegawai / Officer</div><b>${esc(s.name || ' ')}</b><div class="small muted">Jawatan / Position</div><b>${esc(s.position || ' ')}</b></div>
        <div><div class="small muted">Nama dan alamat majikan / Employer</div><b>${esc(c.name || '')}</b><div>${esc(c.address || '')}</div><div class="small muted">No. telefon majikan / Telephone</div><b>${esc(c.phone || s.phone || '')}</b></div>
        <div><div class="small muted">Tarikh / Date</div><b>${esc(dShort(new Date().toISOString().slice(0, 10)))}</b><div class="ea-sigline">Tandatangan / Signature</div></div></div></section>`;
  }
  // a document on screen, with print / save as PDF (the rest of the app is hidden when printing)
  function docView(el, title, sheets, back) {
    el.innerHTML = `<div class="print-bar no-print"><button type="button" class="btn" data-back>‹ Back</button><span class="muted small">On a phone, use Share › Print or “Save as PDF”.</span>
      <button type="button" class="btn primary" data-print>${icon('download')}Print / Save as PDF</button></div><div class="doc-scroll"><div class="print-doc">${sheets.join('')}</div></div>`;
    document.body.classList.add('doc-mode'); const prev = document.title; document.title = title;
    const done = () => { document.body.classList.remove('doc-mode'); document.title = prev; };
    $('[data-back]', el).addEventListener('click', () => { done(); back(); });
    $('[data-print]', el).addEventListener('click', () => window.print());
    window.addEventListener('hashchange', done, { once: true });
  }

  // ---------------------------------------------------------------- My Payslips & EA
  async function mePayslipsPage(item, el) {
    document.body.classList.remove('doc-mode');
    el.innerHTML = `${pageHead(item)}<div id="ps-body">${loading()}</div>`;
    let L;
    try { L = await API.rpc('cms_my_payslips'); } catch (e) { $('#ps-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const showSlip = async (period) => {
      let D; try { D = await API.rpc('cms_my_payslip', { p_period: period }); } catch (e) { toast(e.message, 'err'); return; }
      if (!D.lines.length) { toast('No payslip found for that month.', 'err'); return; }
      docView(el, `Payslip ${monthShort(period)} · ${D.person?.name || ''}`, D.lines.map((l) => payslipSheet(D, l)), () => mePayslipsPage(item, el));
      refreshSelf();
    };
    const showEa = async (year) => {
      let D; try { D = await API.rpc('cms_my_ea', { p_year: year }); } catch (e) { toast(e.message, 'err'); return; }
      const figs = eaFigures(D.lines); if (!figs.length) { toast('No EA figures for that year.', 'err'); return; }
      docView(el, `EA ${year} · ${D.person?.name || ''}`, figs.map((f) => eaSheet(D, f)), () => mePayslipsPage(item, el));
    };
    const newOnes = new Set(state.self?.new_payslips || []);
    $('#ps-body', el).innerHTML = `
      ${L.payslips ? `<section class="card"><div class="card-head"><h3>Payslips</h3><span class="muted small">Released to you by HR</span></div>
        ${L.payslips.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Month</th><th>Paid by</th><th class="num">Gross (RM)</th><th class="num">Net paid (RM)</th><th></th></tr></thead><tbody>
          ${L.payslips.map((x) => `<tr><td class="nowrap"><b>${esc(monthName(x.period))}</b>${newOnes.has(String(x.period).slice(0, 7)) ? ' <span class="tag ok xs">New</span>' : ''}</td><td>${esc((x.companies || []).join(', '))}</td>
            <td class="num">${m2(x.gross)}</td><td class="num"><b>${m2(x.net_paid)}</b></td><td><button type="button" class="btn sm primary" data-slip="${esc(x.period)}">${icon('eye')}View</button></td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No payslips released yet</p><span>HR releases each month after payroll is finalised.</span></div>'}</section>` : ''}
      ${L.ea ? `<section class="card"><div class="card-head"><h3>EA forms</h3><span class="muted small">Statement of remuneration for your income tax return</span></div>
        ${L.ea.length ? `<div class="btn-row">${L.ea.map((y) => `<button type="button" class="btn" data-ea="${y}">${icon('file-check')}EA ${y}</button>`).join('')}</div>`
          : '<div class="empty small"><p>No EA form released yet</p><span>HR releases the EA form after the year ends (by end of February).</span></div>'}</section>` : ''}`;
    $$('[data-slip]', el).forEach((b) => b.addEventListener('click', () => showSlip(b.dataset.slip)));
    $$('[data-ea]', el).forEach((b) => b.addEventListener('click', () => showEa(Number(b.dataset.ea))));
  }

  // ---------------------------------------------------------------- My Salary History
  async function meSalaryPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="sh-body">${loading()}</div>`;
    let rows; try { rows = await API.rpc('cms_my_salary'); } catch (e) { $('#sh-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const asc = [...rows].reverse();
    $('#sh-body', el).innerHTML = `<section class="card">${rows.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>From</th><th class="num">Salary (RM)</th><th class="num">Change (RM)</th><th>Paid by</th><th>Reason</th></tr></thead><tbody>
      ${rows.map((r) => { const prev = asc[asc.indexOf(r) - 1]; const d = prev && prev.pay_basis === r.pay_basis ? r2(r.amount - prev.amount) : null;
        return `<tr><td class="nowrap">${esc(monthName(r.from))}</td><td class="num"><b>${m2(r.amount)}</b>${r.pay_basis === 'hourly' ? ' /h' : r.pay_basis === 'daily' ? ' /day' : ''}</td>
          <td class="num">${d === null ? '—' : `${d < 0 ? '−' : d > 0 ? '+' : ''}${m2(Math.abs(d))}`}</td><td>${esc(r.company || '')}</td><td>${esc(r.reason || '')}</td></tr>`; }).join('')}</tbody></table></div>`
      : '<div class="empty small"><p>No salary recorded yet</p></div>'}</section>`;
  }

  // ---------------------------------------------------------------- Self-service Access (HR / Admin)
  async function selfServicePage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="ss-body">${loading()}</div>`;
    let S;
    const load = async () => { S = await API.rpc('cms_self_service'); S.people.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#ss-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const q = new URLSearchParams(location.hash.split('?')[1] || '');
    const f = { tab: q.get('tab') || 'access', q: '', co: 'all', former: false, sel: new Set(), month: S.months[0] || '', kind: 'payslip' };
    const years = [...new Set(S.months.map((m) => Number(m.slice(0, 4))))];
    f.year = years[0] || new Date().getFullYear();
    const edit = S.can_edit;
    const TABS = [['access', 'Access'], ['docs', 'Payslips & EA'], ['reports', 'Reports to'], ['requests', 'Change requests']];
    const cos = [...new Set(S.people.map((r) => r.company).filter(Boolean))].sort();
    const people = () => { const t = f.q.trim().toLowerCase(); return S.people.filter((r) => (f.former || r.status !== 'former') && (f.co === 'all' || r.company === f.co) && (!t || `${r.name} ${r.employee_id || ''} ${r.title || ''} ${r.login || ''}`.toLowerCase().includes(t))); };
    const shell = () => {
      $('#ss-body', el).innerHTML = `<section class="card">
        <div class="seg ss-tabs">${TABS.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}${k === 'requests' && S.requests.length ? ` <span>${S.requests.length}</span>` : ''}</button>`).join('')}</div>
        ${f.tab === 'requests' ? '' : `<div class="toolbar">
          <label class="search-in">${icon('search')}<input id="sq" type="search" placeholder="Name, Employee ID, job title or login" aria-label="Search" value="${esc(f.q)}"></label>
          <select id="sco" aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}" ${f.co === c ? 'selected' : ''}>${esc(coShort(c))}</option>`).join('')}</select>
          <label class="chk"><input type="checkbox" id="sfm" ${f.former ? 'checked' : ''}> Include recent former staff</label></div>`}
        <div id="ss-tab"></div></section>`;
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; f.sel.clear(); shell(); }));
      $('#sq', el)?.addEventListener('input', (e) => { f.q = e.target.value; tab(); });
      $('#sco', el)?.addEventListener('change', (e) => { f.co = e.target.value; tab(); });
      $('#sfm', el)?.addEventListener('change', (e) => { f.former = e.target.checked; tab(); });
      tab();
    };
    const reload = async () => { try { await load(); loadSelfPending(); } catch (e) { toast(e.message, 'err'); } shell(); };
    const selBox = (r) => (edit ? `<td class="sel"><input type="checkbox" data-sel="${esc(r.person_id)}" ${f.sel.has(r.person_id) ? 'checked' : ''} aria-label="Select ${esc(r.name)}"></td>` : '');
    const selAll = (list) => (edit ? `<th class="sel"><input type="checkbox" data-selall ${list.length && list.every((r) => f.sel.has(r.person_id)) ? 'checked' : ''} aria-label="Select all"></th>` : '');
    const wireSel = (box, list, after) => {
      $$('[data-sel]', box).forEach((c) => c.addEventListener('change', () => { if (c.checked) f.sel.add(c.dataset.sel); else f.sel.delete(c.dataset.sel); after(); }));
      $('[data-selall]', box)?.addEventListener('change', (e) => { list.forEach((r) => (e.target.checked ? f.sel.add(r.person_id) : f.sel.delete(r.person_id))); tab(); });
    };
    const who = (r) => `<td><b>${esc(r.name)}</b>${r.director ? ' <span class="tag blue xs">Director</span>' : ''}<small class="sub">${esc([r.employee_id, r.title].filter(Boolean).join(' · '))}</small></td>`;
    const tab = () => {
      const box = $('#ss-tab', el); const list = people();
      // keep the reader where they were after a change (list box and page)
      const keep = { list: $('.table-wrap', box)?.scrollTop || 0, page: pageScroller().scrollTop };
      requestAnimationFrame(() => { const w = $('.table-wrap', box); if (w) w.scrollTop = keep.list; pageScroller().scrollTop = keep.page; });
      if (f.tab === 'access') {
        box.innerHTML = `${edit ? `<div class="bulk-bar"><span id="ssn">${f.sel.size} selected</span><select id="bpart" aria-label="Part">${PARTS.filter((p) => PART_READY(p[0])).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join('')}</select>
            <button type="button" class="btn sm primary" data-bulk="1" ${f.sel.size ? '' : 'disabled'}>Switch on</button><button type="button" class="btn sm" data-bulk="0" ${f.sel.size ? '' : 'disabled'}>Switch off</button></div>` : ''}
          <div class="table-wrap fill"><table class="data freeze2 ss-grid"><thead><tr>${selAll(list)}<th>Name</th><th>Login</th>${PARTS.map(([k, l, d, ph]) => `<th class="ctr" title="${esc(d)}">${esc(l)}${ph ? `<small class="sub">${ph}</small>` : ''}</th>`).join('')}</tr></thead><tbody>
          ${list.map((r) => `<tr>${selBox(r)}${who(r)}<td>${r.login ? `<small>${esc(r.login)}</small>` : '<span class="tag warn xs">No login</span>'}</td>
            ${PARTS.map(([k, , , ph]) => `<td class="ctr"><input type="checkbox" class="sw" data-part="${k}" data-p="${esc(r.person_id)}" ${r.parts.includes(k) ? 'checked' : ''} ${!edit || ph ? 'disabled' : ''} aria-label="${esc(k)} for ${esc(r.name)}"></td>`).join('')}</tr>`).join('')
          || `<tr><td colspan="${PARTS.length + 3}"><div class="empty small"><p>No one here</p></div></td></tr>`}</tbody></table></div>
          <p class="muted small">Everything is off until you switch it on. A person needs a login linked to their record (Users, Roles &amp; Access) to see their self-service. Payslips and EA forms also need each month / year released (next tab). Leave stays off while leave runs in the other system.</p>`;
        wireSel(box, list, () => { $('#ssn', box).textContent = `${f.sel.size} selected`; $$('[data-bulk]', box).forEach((b) => { b.disabled = !f.sel.size; }); });
        $$('.sw', box).forEach((c) => c.addEventListener('change', async () => {
          try { await API.rpc('cms_self_set', { p_people: [c.dataset.p], p_part: c.dataset.part, p_enabled: c.checked });
            const r = S.people.find((x) => x.person_id === c.dataset.p); r.parts = c.checked ? [...r.parts, c.dataset.part] : r.parts.filter((x) => x !== c.dataset.part);
            toast(`${r.name}: ${PARTS.find((p) => p[0] === c.dataset.part)[1]} ${c.checked ? 'on' : 'off'}`);
          } catch (e) { c.checked = !c.checked; toast(e.message, 'err'); }
        }));
        $$('[data-bulk]', box).forEach((b) => b.addEventListener('click', async () => {
          const part = $('#bpart', box).value; const on = b.dataset.bulk === '1';
          try { const n = await API.rpc('cms_self_set', { p_people: [...f.sel], p_part: part, p_enabled: on }); toast(`${PARTS.find((p) => p[0] === part)[1]} switched ${on ? 'on' : 'off'} for ${n} ${n === 1 ? 'person' : 'people'}`); f.sel.clear(); reload(); }
          catch (e) { toast(e.message, 'err'); }
        }));
      } else if (f.tab === 'docs') {
        const key = f.kind === 'ea' ? f.year : f.month;
        const has = (r) => (f.kind === 'ea' ? r.paid.some((m) => m.startsWith(String(f.year))) : r.paid.includes(f.month));
        const rel = (r) => (f.kind === 'ea' ? r.ea.includes(Number(f.year)) : r.payslips.includes(f.month));
        const partOn = (r) => r.parts.includes(f.kind === 'ea' ? 'ea' : 'payslips');
        box.innerHTML = `<div class="toolbar"><div class="seg sm">${[['payslip', 'Payslips'], ['ea', 'EA forms']].map(([k, l]) => `<button type="button" data-kind="${k}" class="${f.kind === k ? 'on' : ''}">${l}</button>`).join('')}</div>
            ${f.kind === 'ea' ? `<select id="sper" aria-label="Year">${years.map((y) => `<option ${Number(f.year) === y ? 'selected' : ''}>${y}</option>`).join('')}</select>`
              : `<select id="sper" aria-label="Month">${S.months.map((m) => `<option value="${m}" ${f.month === m ? 'selected' : ''}>${esc(monthName(m))}</option>`).join('')}</select>`}
            ${edit ? `<span id="ssn" class="muted small">${f.sel.size} selected</span><button type="button" class="btn sm primary" data-rel="1" ${f.sel.size ? '' : 'disabled'}>Release</button><button type="button" class="btn sm" data-rel="0" ${f.sel.size ? '' : 'disabled'}>Withdraw</button>` : ''}</div>
          ${S.months.length ? '' : '<div class="warn-box">No payroll month is finalised yet.</div>'}
          <div class="table-wrap fill"><table class="data freeze2"><thead><tr>${selAll(list.filter(has))}<th>Name</th><th>${f.kind === 'ea' ? `EA ${f.year}` : esc(monthName(f.month))}</th><th>Can see ${f.kind === 'ea' ? 'EA forms' : 'payslips'}</th><th>Released ${f.kind === 'ea' ? 'years' : 'months'}</th></tr></thead><tbody>
          ${list.map((r) => `<tr>${has(r) ? selBox(r) : (edit ? '<td class="sel"></td>' : '')}${who(r)}
            <td>${!has(r) ? '<span class="muted small">No payslip this ' + (f.kind === 'ea' ? 'year' : 'month') + '</span>' : rel(r) ? '<span class="tag ok xs">Released</span>' : '<span class="tag xs">Not released</span>'}</td>
            <td>${partOn(r) ? '<span class="tag ok xs">On</span>' : '<span class="tag warn xs">Off</span>'}</td>
            <td class="small muted">${esc((f.kind === 'ea' ? r.ea : r.payslips.map(monthShort)).slice(-6).join(', ') || '—')}</td></tr>`).join('')}</tbody></table></div>
          <p class="muted small">Only finalised payroll months can be released. If a month is reopened in payroll, its payslips disappear from self-service until it is finalised again. A released document shows only if that part is switched on for the person (Access tab).</p>`;
        $$('[data-kind]', box).forEach((b) => b.addEventListener('click', () => { f.kind = b.dataset.kind; f.sel.clear(); tab(); }));
        $('#sper', box)?.addEventListener('change', (e) => { if (f.kind === 'ea') f.year = Number(e.target.value); else f.month = e.target.value; f.sel.clear(); tab(); });
        wireSel(box, list.filter(has), () => { $('#ssn', box).textContent = `${f.sel.size} selected`; $$('[data-rel]', box).forEach((b) => { b.disabled = !f.sel.size; }); });
        $$('[data-rel]', box).forEach((b) => b.addEventListener('click', async () => {
          const on = b.dataset.rel === '1';
          try {
            const r = await API.rpc('cms_self_release', { p_people: [...f.sel], p_kind: f.kind, p_period: f.kind === 'ea' ? `${f.year}-01-01` : `${key}-01`, p_release: on });
            toast(`${f.kind === 'ea' ? `EA ${f.year}` : monthName(f.month)}: ${on ? 'released to' : 'withdrawn from'} ${r.done} ${r.done === 1 ? 'person' : 'people'}${r.skipped ? ` (${r.skipped} without a payslip skipped)` : ''}`);
            f.sel.clear(); reload();
          } catch (e) { toast(e.message, 'err'); }
        }));
      } else if (f.tab === 'reports') {
        const active = S.people.filter((r) => r.status !== 'former').sort((a, b) => a.name.localeCompare(b.name));
        const nameOf = (id) => (S.people.find((x) => x.person_id === id) || {}).name || '';
        box.innerHTML = `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Name</th><th>Reports to</th><th>Leave approvers</th></tr></thead><tbody>
          ${list.map((r) => {
            const chain = []; let cur = r.reports_to_id; const seen = new Set();
            while (cur && !seen.has(cur)) { seen.add(cur); chain.push(nameOf(cur)); cur = (S.people.find((x) => x.person_id === cur) || {}).reports_to_id; }
            return `<tr>${who(r)}<td>${edit ? `<select data-rt="${esc(r.person_id)}" aria-label="Reports to"><option value="">— not set —</option>${active.filter((x) => x.person_id !== r.person_id).map((x) => `<option value="${esc(x.person_id)}" ${x.person_id === r.reports_to_id ? 'selected' : ''}>${esc(x.name)}${x.title ? ` · ${esc(x.title)}` : ''}</option>`).join('')}</select>` : esc(nameOf(r.reports_to_id) || '—')}
              ${!r.reports_to_id && r.reporting_name ? `<small class="sub warn-txt">From the offer: “${esc(r.reporting_name)}” (no exact match: choose the person)</small>` : ''}</td>
              <td class="small">${r.director ? 'The other director, or HR' : chain.length ? esc(chain.join(' → ')) : '<span class="muted">HR (no reports-to set)</span>'}</td></tr>`;
          }).join('')}</tbody></table></div>
          <p class="muted small">Leave approval (Phase 4d) follows this line: the person they report to, or anyone above in the same line, can approve. A director is approved by the other director or HR. Where no one is set, HR approves.</p>`;
        $$('[data-rt]', box).forEach((s) => s.addEventListener('change', async () => {
          const r = S.people.find((x) => x.person_id === s.dataset.rt);
          try { await API.rpc('cms_set_reports_to', { p_person: r.person_id, p_manager: s.value || null }); r.reports_to_id = s.value || null; toast(`${r.name} reports to ${nameOf(s.value) || 'nobody'}`); tab(); }
          catch (e) { s.value = r.reports_to_id || ''; toast(e.message, 'err'); }
        }));
      } else {
        const show = (k, v) => esc((k === 'bank_code' ? S.banks[v] || v : v) || '—');
        box.innerHTML = S.requests.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Person</th><th>Sent</th><th>Change</th><th></th></tr></thead><tbody>
          ${S.requests.map((q) => `<tr><td><b>${esc(q.name)}</b><small class="sub">${esc(q.employee_id || '')}</small></td><td class="nowrap">${dShort(q.requested_at)}</td>
            <td><ul class="chg">${Object.entries(q.changes).map(([k, v]) => `<li>${esc(fieldLabel(k))}: <s>${show(k, (q.previous || {})[k])}</s> → <b>${show(k, v)}</b></li>`).join('')}</ul>
              ${q.note ? `<small class="sub">“${esc(q.note)}”</small>` : ''}${q.has_attachment ? `<button type="button" class="btn sm ghost" data-att="${esc(q.id)}">${icon('eye')}View photo</button>` : ''}</td>
            <td class="nowrap">${edit ? `<button type="button" class="btn sm primary" data-dec="1" data-id="${esc(q.id)}">Approve</button> <button type="button" class="btn sm" data-dec="0" data-id="${esc(q.id)}">Reject…</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No changes waiting</p><span>When staff send a change from My Profile it appears here.</span></div>';
        $$('[data-att]', box).forEach((b) => b.addEventListener('click', async () => {
          try { const src = await API.rpc('cms_profile_attachment', { p_id: b.dataset.att }); await modal({ title: 'Supporting photo', ok: null, cancel: 'Close', wide: true, body: `<img class="att-img" src="${esc(src)}" alt="Supporting photo">` }); }
          catch (e) { toast(e.message, 'err'); }
        }));
        $$('[data-dec]', box).forEach((b) => b.addEventListener('click', async () => {
          const q = S.requests.find((x) => x.id === b.dataset.id); const approve = b.dataset.dec === '1';
          const ok = await modal({ title: `${approve ? 'Approve' : 'Reject'} · ${q.name}`, ok: approve ? 'Approve and update the record' : 'Reject', danger: !approve,
            body: `${approve ? '<p>The new details replace the old ones in the Employee Master and payroll record. The change is logged.</p>' : ''}
              <label class="fld"><span>${approve ? 'Note (optional)' : 'Reason (the staff member sees it)'}</span><input name="note" maxlength="300" ${approve ? '' : 'required'}></label>`,
            onOk: async (fm) => { if (!approve && !fm.note.value.trim()) throw new Error('Give the reason for rejecting.'); await API.rpc('cms_profile_decide', { p_id: q.id, p_approve: approve, p_note: fm.note.value || null }); } });
          if (ok) { toast(`${q.name}: change ${approve ? 'approved' : 'rejected'}`); reload(); }
        }));
      }
      fitTables();
    };
    shell();
  }

  // ================================================================ 4b · ITEMS & HAND-OVER (PRI-006)
  const ITEM_ST = { issued: ['Waiting for the person to confirm', 'warn'], held: ['With the person', 'ok'], returned: ['Returned', ''], lost: ['Lost', 'bad'],
    damaged: ['Damaged', 'bad'], transferred: ['Moved to someone else', ''], written_off: ['Written off', ''] };
  const EV_LABEL = { issued: 'Issued', confirmed: 'Received (confirmed by the person)', returned: 'Returned', return_confirmed: 'Return confirmed by the person', replaced: 'Replaced',
    renewed: 'Renewed', lost: 'Lost', damaged: 'Damaged', transferred: 'Moved to another person', credential_changed: 'Password changed / reset', note: 'Note', edited: 'Details changed',
    written_off: 'Written off', reported: 'Reported by the person' };
  const itemTag = (i) => { const [l, c] = ITEM_ST[i.status] || [i.status, '']; return `<span class="tag ${c} xs">${esc(l)}</span>${i.status === 'returned' && !i.return_confirmed_at ? '<small class="sub">return not yet confirmed by the person</small>' : ''}`; };
  const itemName = (i) => `<b>${esc(i.type_label)}</b>${i.quantity > 1 ? ` × ${i.quantity}` : ''}${i.description ? `<small class="sub">${esc(i.description)}</small>` : ''}${i.asset_tag ? `<small class="sub">Tag / serial ${esc(i.asset_tag)}</small>` : ''}`;
  const photoField = (label = 'Photo (optional)') => `<label class="fld fld-2"><span>${esc(label)}</span><input name="photo" type="file" accept="image/*" capture="environment"></label>`;
  const wirePhoto = (w, holder) => { $('input[name=photo]', w)?.addEventListener('change', async (e) => { holder.v = e.target.files[0] ? await shrinkImage(e.target.files[0]) : null; }); };
  function itemHistoryHtml(i) {
    return `<ol class="timeline">${i.history.map((h) => `<li><b>${esc(EV_LABEL[h.event] || h.event)}</b> · ${dShort(h.at)}${h.by ? ` · ${esc(h.by)}` : ''}${h.note ? `<br><span class="muted">${esc(h.note)}</span>` : ''}
      ${h.photo ? ` <button type="button" class="lnk" data-evphoto="${esc(h.id)}" data-item="${esc(i.id)}">photo</button>` : ''}</li>`).join('')}</ol>`;
  }
  async function showItemPhoto(item, ev) {
    try { const src = await API.rpc('cms_item_photo', { p_item: item, p_kind: 'issue', p_event: Number(ev) }); if (!src) throw new Error('No photo.');
      await modal({ title: 'Photo', ok: null, cancel: 'Close', wide: true, body: `<img class="att-img" src="${esc(src)}" alt="Item photo">` }); }
    catch (e) { toast(e.message, 'err'); }
  }

  // ---------------------------------------------------------------- HR / Admin page
  async function itemsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="it-body">${loading()}</div>`;
    let D;
    const load = async () => { D = await API.rpc('cms_items_admin'); D.people.forEach((r) => upKeys(r, 'name')); D.handovers.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#it-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { tab: 'people', q: '', type: 'all', st: 'out' };
    const edit = D.can_edit;
    const byPerson = (pid) => D.items.filter((i) => i.person_id === pid);
    const pName = (pid) => (D.people.find((p) => p.person_id === pid) || {}).name || '';
    const openH = (pid) => D.handovers.find((h) => h.person_id === pid && h.status === 'open');
    const reload = async () => { try { await load(); loadItemsPending(); } catch (e) { toast(e.message, 'err'); } draw(); };
    const draw = () => {
      const T = [['people', 'By person'], ['items', 'All items'], ['handovers', `Hand-overs${D.handovers.filter((h) => h.status === 'open').length ? ` <span>${D.handovers.filter((h) => h.status === 'open').length}</span>` : ''}`], ['types', 'Item types']];
      $('#it-body', el).innerHTML = `<section class="card"><div class="seg ss-tabs">${T.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div><div id="it-tab"></div></section>`;
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; draw(); }));
      const box = $('#it-tab', el); const t = f.q.trim().toLowerCase();
      if (f.tab === 'people') {
        const list = D.people.filter((p) => !t || `${p.name} ${p.employee_id || ''} ${p.title || ''}`.toLowerCase().includes(t));
        box.innerHTML = `<div class="toolbar"><label class="search-in">${icon('search')}<input id="iq" type="search" placeholder="Name or Employee ID" value="${esc(f.q)}" aria-label="Search"></label></div>
          <div class="table-wrap fill"><table class="data freeze2 click"><thead><tr><th>Name</th><th class="num">With the person</th><th class="num">To confirm</th><th>Leaving</th><th>Hand-over</th><th>Self-service</th></tr></thead><tbody>
          ${list.map((p) => { const its = byPerson(p.person_id); const h = openH(p.person_id);
            return `<tr data-person="${esc(p.person_id)}"><td><b>${esc(p.name)}</b><small class="sub">${esc([p.employee_id, p.title].filter(Boolean).join(' · '))}</small></td>
              <td class="num">${its.filter((i) => ['issued', 'held'].includes(i.status)).length || '—'}</td><td class="num">${its.filter((i) => i.status === 'issued').length || '—'}</td>
              <td class="nowrap">${p.leaving ? dShort(p.leaving) : '—'}</td><td>${h ? `<span class="tag warn xs">Open · due ${dShort(h.deadline)}</span>` : '—'}</td>
              <td>${p.items_on ? '<span class="tag ok xs">My Items on</span>' : '<span class="muted small">off</span>'}</td></tr>`; }).join('')}</tbody></table></div>
          <p class="muted small">Click a person to issue items, record returns and changes, and run their hand-over. Staff confirm items in My Items once it is switched on for them (Self-service Access).</p>`;
        $('#iq', box).addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#iq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
        $$('[data-person]', box).forEach((r) => r.addEventListener('click', () => personItems(r.dataset.person)));
      } else if (f.tab === 'items') {
        const ST = [['out', 'With staff'], ['issued', 'Not yet confirmed'], ['back', 'Returned / closed'], ['all', 'All']];
        const okSt = (i) => f.st === 'all' || (f.st === 'out' ? ['issued', 'held'].includes(i.status) : f.st === 'issued' ? i.status === 'issued' : !['issued', 'held'].includes(i.status));
        const list = D.items.filter((i) => okSt(i) && (f.type === 'all' || i.type === f.type) && (!t || `${pName(i.person_id)} ${i.description || ''} ${i.asset_tag || ''} ${i.type_label}`.toLowerCase().includes(t)));
        box.innerHTML = `<div class="toolbar"><label class="search-in">${icon('search')}<input id="iq" type="search" placeholder="Person, description or tag" value="${esc(f.q)}" aria-label="Search"></label>
            <select id="ity" aria-label="Type"><option value="all">All types</option>${D.types.map((x) => `<option value="${esc(x.code)}" ${f.type === x.code ? 'selected' : ''}>${esc(x.label)}</option>`).join('')}</select>
            <div class="seg">${ST.map(([k, l]) => `<button type="button" data-st="${k}" class="${f.st === k ? 'on' : ''}">${l}</button>`).join('')}</div></div>
          <div class="table-wrap fill"><table class="data freeze2 click"><thead><tr><th>Item</th><th>Person</th><th>Issued</th><th>Status</th></tr></thead><tbody>
          ${list.map((i) => `<tr data-person="${esc(i.person_id)}"><td>${itemName(i)}</td><td>${esc(pName(i.person_id))}</td><td class="nowrap">${dShort(i.issued_on)}</td><td>${itemTag(i)}</td></tr>`).join('')
            || '<tr><td colspan="4"><div class="empty small"><p>No items here</p></div></td></tr>'}</tbody></table></div>`;
        $('#iq', box).addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#iq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
        $('#ity', box).addEventListener('change', (e) => { f.type = e.target.value; draw(); });
        $$('[data-st]', box).forEach((b) => b.addEventListener('click', () => { f.st = b.dataset.st; draw(); }));
        $$('[data-person]', box).forEach((r) => r.addEventListener('click', () => personItems(r.dataset.person)));
      } else if (f.tab === 'handovers') {
        box.innerHTML = D.handovers.length ? `<div class="table-wrap"><table class="data click"><thead><tr><th>Person</th><th>Deadline</th><th class="num">Still with the person</th><th>Approver</th><th>Status</th></tr></thead><tbody>
          ${D.handovers.map((h) => `<tr data-person="${esc(h.person_id)}"><td><b>${esc(h.name)}</b><small class="sub">${esc(h.opened_reason || '')}</small></td>
            <td class="nowrap">${h.deadline ? `${dShort(h.deadline)}${h.status === 'open' && daysTo(h.deadline) < 0 ? ' <span class="tag bad xs">overdue</span>' : ''}` : '—'}</td>
            <td class="num">${h.outstanding || (h.status === 'open' ? '<span class="tag ok xs">all back</span>' : '—')}</td><td>${esc(h.approver || 'HR / Admin')}</td>
            <td>${h.status === 'open' ? '<span class="tag warn xs">Open</span>' : `<span class="tag ok xs">Approved</span><small class="sub">${dShort(h.approved_at)} · ${esc(h.approved_by || '')}</small>`}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No hand-overs</p><span>A hand-over opens by itself when a leaving date is confirmed for someone who holds items, or start one from the person.</span></div>';
        $$('[data-person]', box).forEach((r) => r.addEventListener('click', () => personItems(r.dataset.person)));
      } else {
        box.innerHTML = `<div class="table-wrap"><table class="data"><thead><tr><th>Item type</th><th>Kind</th><th>Must be returned</th><th>Account (password changes)</th><th>Looked after by</th><th class="num">Replacement (RM)</th><th></th></tr></thead><tbody>
          ${D.types.map((x) => `<tr class="${x.is_active ? '' : 'muted'}"><td><b>${esc(x.label)}</b>${x.is_active ? '' : ' <span class="tag xs">not used</span>'}</td><td>${esc(x.category)}</td><td>${x.must_return ? 'Yes' : 'No'}</td>
            <td>${x.is_credential ? 'Yes' : '—'}</td><td>${esc(x.custodian || '—')}</td><td class="num">${x.replacement_cost != null ? m2(x.replacement_cost) : '—'}</td>
            <td>${D.can_types ? `<button type="button" class="btn sm ghost" data-type="${esc(x.code)}">Edit</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
          ${D.can_types ? '<div class="btn-row"><button type="button" class="btn" data-type="">+ Add item type</button></div>' : ''}`;
        $$('[data-type]', box).forEach((b) => b.addEventListener('click', async () => {
          const x = D.types.find((y) => y.code === b.dataset.type) || { must_return: true, is_active: true, category: 'other' };
          const ok = await modal({ title: x.code ? `Item type · ${x.label}` : 'New item type', ok: 'Save',
            body: `<div class="grid-2 tight"><label class="fld fld-2"><span>Name</span><input name="label" required value="${esc(x.label || '')}"></label>
              <label class="fld"><span>Kind</span><select name="category">${['account', 'key', 'device', 'uniform', 'document', 'other'].map((c) => `<option ${x.category === c ? 'selected' : ''}>${c}</option>`).join('')}</select></label>
              <label class="fld"><span>Looked after by</span><input name="custodian" value="${esc(x.custodian || '')}" placeholder="HR, Admin, IT, centre head"></label>
              <label class="fld"><span>Replacement cost (RM)</span><input name="cost" data-money inputmode="decimal" value="${x.replacement_cost != null ? m2(x.replacement_cost) : ''}"></label>
              <div class="fld"><label class="chk"><input type="checkbox" name="ret" ${x.must_return ? 'checked' : ''}> Must be returned when leaving</label>
                <label class="chk"><input type="checkbox" name="cred" ${x.is_credential ? 'checked' : ''}> Account with a password (record changes, never the password)</label>
                <label class="chk"><input type="checkbox" name="act" ${x.is_active ? 'checked' : ''}> In use</label></div></div>`,
            onOk: async (fm) => { await API.rpc('cms_item_type_save', { p: { code: x.code || null, label: fm.label.value, category: fm.category.value, custodian: fm.custodian.value,
              replacement_cost: fm.cost.value ? mval(fm.cost.value) : null, must_return: fm.ret.checked, is_credential: fm.cred.checked, is_active: fm.act.checked } }); } });
          if (ok) { toast('Item type saved'); reload(); }
        }));
      }
      fitTables();
    };

    // one person: their items, actions and hand-over
    const personItems = async (pid) => {
      const p = D.people.find((x) => x.person_id === pid) || { person_id: pid, name: pName(pid) };
      const its = byPerson(pid); const h = openH(pid); const out = its.filter((i) => ['issued', 'held'].includes(i.status));
      const others = D.people.filter((x) => x.person_id !== pid && x.status !== 'former');
      const done = await modal({ title: `Items · ${p.name}`, ok: null, cancel: 'Close', wide: true,
        body: `<div class="it-head">${p.leaving ? `<span class="tag warn">Leaving ${dShort(p.leaving)}</span>` : ''}${p.items_on ? '' : '<span class="tag xs">My Items is off for this person: they cannot confirm yet</span>'}</div>
          ${h ? `<div class="warn-box"><b>Hand-over open</b> · deadline ${h.deadline ? dShort(h.deadline) : 'not set'} · approver ${esc(h.approver || 'HR / Admin')} · ${h.outstanding} still with the person
              ${h.notes ? `<br><span class="muted">${esc(h.notes)}</span>` : ''}
              <ul class="ho-steps">${(h.checklist || []).map((c) => `<li><label class="chk"><input type="checkbox" data-step="${esc(c.key)}" ${c.done ? 'checked' : ''} ${edit ? '' : 'disabled'}> ${esc(c.label)}</label>${c.done ? ` <small class="muted">${esc(c.by || '')} · ${dShort(c.at)}</small>` : ''}</li>`).join('')}</ul>
              ${edit ? `<div class="btn-row"><button type="button" class="btn sm" data-ho="edit">Deadline, approver, notes…</button><button type="button" class="btn sm primary" data-ho="approve">Approve hand-over…</button><button type="button" class="btn sm ghost" data-ho="cancel">Cancel hand-over…</button></div>` : ''}</div>`
            : (edit && out.length ? '<div class="btn-row"><button type="button" class="btn sm" data-ho="start">Start hand-over…</button></div>' : '')}
          <div class="table-wrap"><table class="data compact"><thead><tr><th>Item</th><th>Issued</th><th>Status</th><th></th></tr></thead><tbody>
          ${its.map((i) => `<tr><td>${itemName(i)}${i.credential_changed_at ? `<small class="sub">password last changed ${dShort(i.credential_changed_at)}</small>` : ''}</td><td class="nowrap">${dShort(i.issued_on)}</td><td>${itemTag(i)}</td>
            <td class="nowrap">${edit && ['issued', 'held'].includes(i.status) ? `<select data-act="${esc(i.id)}" aria-label="Action"><option value="">Action…</option><option value="return">Returned</option><option value="replace">Replace / renew with a new one</option>
              <option value="renew">Renewed (same item)</option><option value="transfer">Move to another person</option>${i.is_credential ? '<option value="credential">Password changed / reset</option>' : ''}
              <option value="lost">Lost</option><option value="damaged">Damaged</option><option value="write_off">Write off</option><option value="note">Add a note</option></select>` : ''}
              <button type="button" class="btn sm ghost" data-hist="${esc(i.id)}">History</button></td></tr>`).join('') || '<tr><td colspan="4"><div class="empty small"><p>No items yet</p></div></td></tr>'}</tbody></table></div>
          ${edit ? '<div class="btn-row"><button type="button" class="btn primary" data-issue>+ Issue item…</button></div>' : ''}`,
        onOpen: (w) => {
          const close = () => $('[data-x]', w)?.click();
          $('[data-issue]', w)?.addEventListener('click', async () => { close(); await issueWindow(pid); });
          $$('[data-hist]', w).forEach((b) => b.addEventListener('click', async () => { const i = its.find((x) => x.id === b.dataset.hist); close();
            await modal({ title: `${i.type_label}${i.description ? ` · ${i.description}` : ''}`, ok: null, cancel: 'Close', body: itemHistoryHtml(i),
              onOpen: (w2) => $$('[data-evphoto]', w2).forEach((x) => x.addEventListener('click', () => showItemPhoto(x.dataset.item, x.dataset.evphoto))) });
            personItems(pid); }));
          $$('[data-act]', w).forEach((s) => s.addEventListener('change', async () => { const a = s.value; if (!a) return; const i = its.find((x) => x.id === s.dataset.act); close(); await itemAction(i, a, others); }));
          $$('[data-ho]', w).forEach((b) => b.addEventListener('click', async () => { close(); await handoverAction(p, h, b.dataset.ho); }));
          $$('[data-step]', w).forEach((c) => c.addEventListener('change', async () => {
            try { await API.rpc('cms_handover_step', { p_id: h.id, p_key: c.dataset.step, p_done: c.checked, p_note: null }); const st = h.checklist.find((x) => x.key === c.dataset.step); st.done = c.checked; toast(c.checked ? 'Step done' : 'Step reopened'); }
            catch (e) { c.checked = !c.checked; toast(e.message, 'err'); } }));
        } });
      return done;
    };
    const issueWindow = async (pid) => {
      const ph = { v: null };
      const ok = await modal({ title: `Issue item · ${pName(pid)}`, ok: 'Issue', wide: true,
        body: `<div class="grid-2 tight"><label class="fld"><span>Item type</span><select name="type" required><option value="">Choose…</option>${D.types.filter((x) => x.is_active).map((x) => `<option value="${esc(x.code)}">${esc(x.label)}</option>`).join('')}</select></label>
          <label class="fld"><span>Quantity</span><input name="qty" type="number" min="1" value="1"></label>
          <label class="fld fld-2"><span>Description (e.g. the email address, which key, size)</span><input name="desc" maxlength="200"></label>
          <label class="fld"><span>Tag / serial / key no. (optional)</span><input name="tag" maxlength="80"></label>
          <label class="fld"><span>Date issued</span><input name="on" type="date" value="${new Date().toISOString().slice(0, 10)}"></label>
          <label class="fld"><span>Condition</span><input name="cond" value="Good"></label>
          <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>${photoField()}</div>
          <p class="muted small">For an email or system account, record the account only. Never type a password here: give it to the person directly.</p>`,
        onOpen: (w) => wirePhoto(w, ph),
        onOk: async (fm) => { if (!fm.type.value) throw new Error('Choose the item type.');
          if (/(password|pwd|pass)\s*[:=]/i.test(`${fm.desc.value} ${fm.note.value}`)) throw new Error('Do not type a password here.');
          await API.rpc('cms_item_issue', { p: { person_id: pid, type: fm.type.value, quantity: fm.qty.value, description: fm.desc.value, asset_tag: fm.tag.value, issued_on: fm.on.value, condition: fm.cond.value, note: fm.note.value, photo: ph.v } }); } });
      if (ok) { toast('Item issued: the person confirms it in My Items'); await reload(); personItems(pid); }
    };
    const itemAction = async (i, a, others) => {
      const ph = { v: null }; const today = new Date().toISOString().slice(0, 10);
      const T = { return: 'Returned', replace: 'Replace with a new one', renew: 'Renewed', transfer: 'Move to another person', credential: 'Password changed / reset', lost: 'Lost', damaged: 'Damaged', write_off: 'Write off', note: 'Add a note' };
      const body = {
        return: `<label class="fld"><span>Date received back</span><input name="date" type="date" value="${today}"></label><label class="fld"><span>Condition</span><input name="cond" value="Good"></label>
          <label class="fld"><span>Received by</span><input name="by" placeholder="${esc(state.access?.name || '')}"></label><label class="fld"><span>Note</span><input name="note"></label>${photoField()}`,
        replace: `<label class="fld"><span>Old item</span><select name="old"><option value="returned">Returned</option><option value="lost">Lost</option><option value="damaged">Damaged</option></select></label>
          <label class="fld"><span>Date</span><input name="date" type="date" value="${today}"></label><label class="fld fld-2"><span>New item description</span><input name="desc" value="${esc(i.description || '')}"></label>
          <label class="fld"><span>New tag / serial</span><input name="tag"></label><label class="fld"><span>Note</span><input name="note"></label>${photoField('Photo of the new item (optional)')}`,
        renew: `<label class="fld"><span>Condition</span><input name="cond" value="${esc(i.condition || 'Good')}"></label><label class="fld"><span>Note</span><input name="note" placeholder="e.g. uniform renewed for 2027"></label>${photoField()}`,
        transfer: `<label class="fld fld-2"><span>Move to</span><select name="to" required><option value="">Choose…</option>${others.map((x) => `<option value="${esc(x.person_id)}">${esc(x.name)}</option>`).join('')}</select></label>
          <label class="fld"><span>Date</span><input name="date" type="date" value="${today}"></label><label class="fld"><span>Note</span><input name="note"></label>`,
        credential: `<p class="muted small">Record only that the password was changed or reset, and by whom. <b>Never type the password.</b></p><label class="fld fld-2"><span>Changed by / note</span><input name="note" placeholder="e.g. reset by IT after leaving"></label>`,
        lost: `<label class="fld"><span>Date</span><input name="date" type="date" value="${today}"></label><label class="fld fld-2"><span>What happened</span><input name="note" required></label><label class="fld"><span>Deduction reference (optional)</span><input name="ded"></label>${photoField()}`,
        damaged: `<label class="fld"><span>Date</span><input name="date" type="date" value="${today}"></label><label class="fld fld-2"><span>What happened</span><input name="note" required></label><label class="fld"><span>Deduction reference (optional)</span><input name="ded"></label>${photoField()}`,
        write_off: `<label class="fld fld-2"><span>Reason</span><input name="note" required></label>`,
        note: `<label class="fld fld-2"><span>Note</span><input name="note" required></label>${photoField()}`,
      }[a];
      const ok = await modal({ title: `${T[a]} · ${i.type_label}${i.description ? ` · ${i.description}` : ''}`, ok: 'Save', danger: ['lost', 'damaged', 'write_off'].includes(a), body: `<div class="grid-2 tight">${body}</div>`,
        onOpen: (w) => wirePhoto(w, ph),
        onOk: async (fm) => { const v = (n) => (fm[n] ? fm[n].value : undefined);
          if (a === 'transfer' && !v('to')) throw new Error('Choose who receives the item.');
          if (['lost', 'damaged', 'write_off', 'note'].includes(a) && !String(v('note') || '').trim()) throw new Error('Write what happened.');
          if (/(password|pwd|pass)\s*[:=]/i.test(v('note') || '')) throw new Error('Do not type a password here.');
          await API.rpc('cms_item_action', { p_item: i.id, p_action: a, p: { date: v('date'), condition: v('cond'), received_by: v('by'), note: v('note'), photo: ph.v, old_status: v('old'),
            description: v('desc'), asset_tag: v('tag'), to_person: v('to'), deduction_ref: v('ded') } }); } });
      if (ok) { toast(`${i.type_label}: ${T[a].toLowerCase()} recorded`); await reload(); }
      personItems(i.person_id);
    };
    const handoverAction = async (p, h, a) => {
      if (a === 'start' || a === 'edit') {
        const approvers = D.people.filter((x) => x.person_id !== p.person_id && x.status !== 'former');
        const ok = await modal({ title: `${a === 'start' ? 'Start hand-over' : 'Hand-over'} · ${p.name}`, ok: 'Save',
          body: `<div class="grid-2 tight"><label class="fld"><span>Deadline</span><input name="deadline" type="date" value="${esc((h && h.deadline) || p.leaving || '')}"></label>
            <label class="fld"><span>Approved by</span><select name="ap"><option value="">HR / Admin</option>${approvers.map((x) => `<option value="${esc(x.person_id)}" ${h && h.approver_id === x.person_id ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></label>
            <label class="fld fld-2"><span>Notes</span><textarea name="notes" rows="2">${esc((h && h.notes) || '')}</textarea></label></div>
            <p class="muted small">Every item still with the person is on the hand-over. The person they report to, anyone above them, the approver and HR / Admin can approve. Approving sets their clearance to “cleared”.</p>`,
          onOk: async (fm) => { await API.rpc('cms_handover_save', { p_person: p.person_id, p: { deadline: fm.deadline.value || null, approver_id: fm.ap.value || '', notes: fm.notes.value, reason: a === 'start' ? 'Started by HR' : undefined } }); } });
        if (ok) { toast('Hand-over saved'); await reload(); }
      } else {
        const approve = a === 'approve';
        const ok = await modal({ title: `${approve ? 'Approve' : 'Cancel'} hand-over · ${p.name}`, ok: approve ? 'Approve' : 'Cancel hand-over', danger: !approve,
          body: `${approve && h.outstanding ? `<div class="warn-box">${h.outstanding} item(s) are still with ${esc(p.name)}. Record them first, or give the reason for approving anyway.</div>` : ''}
            <label class="fld"><span>${approve ? 'Note' : 'Reason'}${approve && !h.outstanding ? ' (optional)' : ''}</span><input name="note"></label>`,
          onOk: async (fm) => { await API.rpc('cms_handover_approve', { p_id: h.id, p_note: fm.note.value || null, p_cancel: !approve }); } });
        if (ok) { toast(approve ? 'Hand-over approved: clearance done' : 'Hand-over cancelled'); await reload(); }
      }
      personItems(p.person_id);
    };
    draw();
  }

  // ---------------------------------------------------------------- staff: My Items
  async function meItemsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="mi-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_my_items'); } catch (e) { $('#mi-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const toConfirm = D.items.filter((i) => i.status === 'issued' || (['returned', 'transferred'].includes(i.status) && !i.return_confirmed_at));
    const held = D.items.filter((i) => i.status === 'held'); const past = D.items.filter((i) => !['issued', 'held'].includes(i.status) && !toConfirm.includes(i));
    const H = D.handover;
    const row = (i, btns) => `<div class="me-item"><div>${itemName(i)}<small class="sub">Issued ${dShort(i.issued_on)}${i.confirmed_at ? ` · received ${dShort(i.confirmed_at)}` : ''}${i.returned_on ? ` · returned ${dShort(i.returned_on)}` : ''}</small></div><div class="btn-row">${btns}</div></div>`;
    $('#mi-body', el).innerHTML = `
      ${H ? `<div class="warn-box">${icon('clock')}<div><b>Hand-over before you leave</b> · return every item below by <b>${H.deadline ? dShort(H.deadline) : 'your last day'}</b>${H.approver ? ` · approved by ${esc(H.approver)}` : ''}${H.notes ? `<br>${esc(H.notes)}` : ''}</div></div>` : ''}
      ${toConfirm.length ? `<section class="card"><div class="card-head"><h3>Please confirm</h3><span class="muted small">Your confirmation is saved with the date and time and cannot be changed</span></div>
        ${toConfirm.map((i) => row(i, i.status === 'issued' ? `<button type="button" class="btn sm primary" data-conf="${esc(i.id)}">${icon('check-circle')}I received this</button><button type="button" class="btn sm ghost" data-rep="${esc(i.id)}">Report a problem</button>`
          : `<span class="muted small">HR recorded this as ${i.status === 'transferred' ? 'moved on' : 'returned'}${i.received_by_name ? ` to ${esc(i.received_by_name)}` : ''}</span><button type="button" class="btn sm primary" data-conf="${esc(i.id)}">${icon('check-circle')}Confirm</button><button type="button" class="btn sm ghost" data-rep="${esc(i.id)}">Report a problem</button>`)).join('')}</section>` : ''}
      <section class="card"><div class="card-head"><h3>${H ? 'To hand over' : 'With you now'}</h3></div>
        ${held.length ? held.map((i) => row(i, `<span class="tag ok xs">Received</span>${i.is_credential && i.credential_changed_at ? `<small class="muted">password last changed ${dShort(i.credential_changed_at)}</small>` : ''}<button type="button" class="btn sm ghost" data-rep="${esc(i.id)}">Report a problem</button>`)).join('')
          : '<div class="empty small"><p>No items with you</p></div>'}</section>
      ${D.to_approve.length ? `<section class="card"><div class="card-head"><h3>Hand-overs for you to approve</h3><span class="muted small">People who report to you</span></div>
        ${D.to_approve.map((h) => `<div class="me-item"><div><b>${esc(h.name)}</b><small class="sub">${esc(h.employee_id || '')}${h.deadline ? ` · deadline ${dShort(h.deadline)}` : ''}</small>
          <ul class="chg">${h.items.map((x) => `<li>${esc(x.label)}${x.description ? ` · ${esc(x.description)}` : ''}: ${esc((ITEM_ST[x.status] || [x.status])[0])}</li>`).join('')}</ul></div>
          <div class="btn-row">${h.outstanding ? `<span class="tag warn xs">${h.outstanding} not back yet</span>` : `<button type="button" class="btn sm primary" data-appr="${esc(h.id)}" data-name="${esc(h.name)}">Approve</button>`}</div></div>`).join('')}</section>` : ''}
      ${past.length ? `<details class="card"><summary><b>Earlier items</b> <span class="muted small">${past.length}</span></summary>${past.map((i) => row(i, itemTag(i))).join('')}</details>` : ''}`;
    $$('[data-conf]', el).forEach((b) => b.addEventListener('click', async () => {
      const i = D.items.find((x) => x.id === b.dataset.conf); const ph = { v: null };
      const ok = await modal({ title: `${i.status === 'issued' ? 'I received' : 'Confirm return'} · ${i.type_label}`, ok: 'Confirm',
        body: `<p>${itemName(i)}</p><label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>${i.status === 'issued' ? photoField('Photo of the item (optional)') : ''}
          <p class="muted small">Once confirmed, it is saved with today's date and time.</p>`,
        onOpen: (w) => wirePhoto(w, ph),
        onOk: async (fm) => { await API.rpc('cms_my_item_confirm', { p_item: i.id, p_note: fm.note.value || null, p_photo: ph.v }); } });
      if (ok) { toast('Confirmed'); loadItemsPending(); render(); }
    }));
    $$('[data-rep]', el).forEach((b) => b.addEventListener('click', async () => {
      const i = D.items.find((x) => x.id === b.dataset.rep); const ph = { v: null };
      const ok = await modal({ title: `Report a problem · ${i.type_label}`, ok: 'Send to HR',
        body: `<label class="fld"><span>What happened? (not received, lost, damaged, wrong size …)</span><input name="note" required maxlength="300"></label>${photoField()}`,
        onOpen: (w) => wirePhoto(w, ph),
        onOk: async (fm) => { if (!fm.note.value.trim()) throw new Error('Say what happened.'); await API.rpc('cms_my_item_report', { p_item: i.id, p_note: fm.note.value, p_photo: ph.v }); } });
      if (ok) toast('Sent to HR');
    }));
    $$('[data-appr]', el).forEach((b) => b.addEventListener('click', async () => {
      const ok = await confirmBox(`Approve hand-over · ${b.dataset.name}`, 'Every item is back. Approving completes the hand-over and their clearance.', 'Approve', false,
        () => API.rpc('cms_handover_approve', { p_id: b.dataset.appr, p_note: null, p_cancel: false }));
      if (ok) { toast('Hand-over approved'); loadItemsPending(); render(); }
    }));
  }

  async function loadItemsPending() {
    try { state.itemsPending = await API.rpc('cms_items_pending'); drawBell(); } catch (e) { /* reminders only */ }
  }
  function itemTasks() {
    const x = state.itemsPending; const t = []; if (!x) return t;
    if (x.mine_to_confirm && selfOn('items')) t.push({ ic: 'box', tone: 'green', title: `${num(x.mine_to_confirm)} item${x.mine_to_confirm === 1 ? '' : 's'} for you to confirm`, sub: 'My Items', href: '#/me/items' });
    if (x.my_handover && selfOn('items')) t.push({ ic: 'box', tone: 'orange', title: 'Hand over your items', sub: `By ${dShort(x.my_handover)}`, href: '#/me/items' });
    if (x.to_approve) t.push({ ic: 'check-circle', tone: 'violet', title: `${num(x.to_approve)} hand-over${x.to_approve === 1 ? '' : 's'} for you to approve`, sub: 'Everything is back', href: selfOn('items') ? '#/me/items' : '#/assets' });
    if (x.hr_handover_due && can('assets', 'E')) t.push({ ic: 'box', tone: 'rose', title: `${num(x.hr_handover_due)} hand-over${x.hr_handover_due === 1 ? '' : 's'} due within 7 days`, sub: 'Items & Hand-over', href: '#/assets' });
    if (x.hr_handover_ready && can('assets', 'E')) t.push({ ic: 'check-circle', tone: 'green', title: `${num(x.hr_handover_ready)} hand-over${x.hr_handover_ready === 1 ? '' : 's'} ready to approve`, sub: 'All items are back', href: '#/assets' });
    if (x.hr_unconfirmed && can('assets', 'E')) t.push({ ic: 'box', tone: 'orange', title: `${num(x.hr_unconfirmed)} items not confirmed by staff`, sub: 'Issued more than 3 days ago', href: '#/assets' });
    return t;
  }

  // ================================================================ 4c · MY CLAIMS, MY HANDBOOK
  const CLAIM_APPS = { scf: ['MEG-SCF', 'Staff Claim (SCF)'], otcf: ['MEG-OTCF', 'Overtime (OTCF)'], mtcf: ['MEG-MTCF', 'Mileage (MTCF)'] };
  async function meClaimsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="mc-body">${loading()}</div>`;
    let rows; try { rows = await API.rpc('cms_my_claims'); } catch (e) { $('#mc-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { v: 'open' };
    const V = [['open', 'In progress', (r) => ['approval', 'processing', 'payment', 'draft'].includes(r.stage)], ['paid', 'Paid', (r) => r.stage === 'paid'],
      ['no', 'Not approved', (r) => r.stage === 'disapproved'], ['all', 'All', () => true]];
    const tone = { approval: 'warn', processing: 'blue', payment: 'blue', paid: 'ok', disapproved: 'bad', draft: '' };
    const draw = () => {
      const list = rows.filter(V.find((x) => x[0] === f.v)[2]);
      $('#mc-body', el).innerHTML = `<div class="btn-row">${Object.entries(CLAIM_APPS).map(([k, [app, l]]) => `<a class="btn" href="${esc(window.CMS_SOURCES[app])}" target="_blank" rel="noopener">${icon('plus')}New ${esc(l)}</a>`).join('')}</div>
        <section class="card"><div class="toolbar"><div class="seg">${V.map(([k, l, fn]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${rows.filter(fn).length}</span></button>`).join('')}</div></div>
        ${list.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Claim</th><th>Sent</th><th class="num">Amount</th><th>Where it is</th></tr></thead><tbody>
          ${list.map((r) => `<tr><td><b>${esc(r.form_name)}</b><small class="sub">${esc(r.serial_no)}</small></td><td class="nowrap">${dShort(r.submitted_at)}</td>
            <td class="num nowrap">${r.unit === 'RM' ? m2(r.amount) : `${num(r.amount)} ${esc(r.unit)}`}</td>
            <td><span class="tag ${tone[r.stage] || ''} xs">${esc(r.status)}</span>${r.paid_at ? `<small class="sub">paid ${dShort(r.paid_at)}</small>` : r.approved_at && r.stage !== 'disapproved' ? `<small class="sub">approved ${dShort(r.approved_at)}${r.approved_by ? ` · ${esc(r.approved_by)}` : ''}</small>` : ''}
              ${r.note ? `<small class="sub">${esc(r.note)}</small>` : ''}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No claims here</p><span>New claims are made in the claim forms (buttons above).</span></div>'}</section>
        <p class="muted small">Amounts in RM, overtime in hours. Approved claims are paid with your salary or by transfer, as shown on your payslip.</p>`;
      $$('[data-v]', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; draw(); }));
    };
    draw();
  }
  async function meHandbookPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="mh-body">${loading()}</div>`;
    let rows; try { rows = await API.rpc('cms_my_handbook'); } catch (e) { $('#mh-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const a = rows.find((r) => !r.revoked_at);
    const steps = a ? [['Assigned', a.assigned_at], ['Opened', a.first_viewed_at], ['Read', a.read_at], ['Receipt signed', a.receipt_at], ['Acknowledged', a.acknowledged_at]] : [];
    $('#mh-body', el).innerHTML = a ? `<section class="card"><div class="card-head"><h3>Employee Handbook ${esc(a.version || '')}</h3>
        ${a.acknowledged_at ? '<span class="tag ok">Acknowledged</span>' : a.due_at ? `<span class="tag ${daysTo(a.due_at) < 0 ? 'bad' : 'warn'}">Due ${dShort(a.due_at)}</span>` : ''}</div>
        <ol class="timeline">${steps.map(([l, d]) => `<li class="${d ? 'done' : ''}"><b>${l}</b> · ${d ? dShort(d) : '<span class="muted">not yet</span>'}</li>`).join('')}</ol>
        <div class="btn-row"><a class="btn primary" href="${esc(EAF + 'handbook.html')}" target="_blank" rel="noopener">${icon('shield')}${a.acknowledged_at ? 'Open the handbook' : 'Read and acknowledge'}</a></div>
        <p class="muted small">The handbook opens in MEG-EAF V2 with the same sign-in. Your reading and acknowledgement are saved there and show here.</p></section>`
      : '<section class="card"><div class="empty small"><p>No handbook assigned to you yet</p><span>HR assigns the handbook when you join.</span></div></section>';
  }

  // ================================================================ 4d · LEAVE REQUESTS (built; switched off per person until used)
  const LV_ST = { pending: ['Waiting for approval', 'warn'], approved: ['Approved', 'ok'], rejected: ['Not approved', 'bad'], cancelled: ['Cancelled', ''] };
  const lvDates = (r) => `${dShort(r.from)}${r.to !== r.from ? ` – ${dShort(r.to)}` : ''}${r.half_day ? ' (half day)' : ''}`;
  const lvTag = (r) => `<span class="tag ${LV_ST[r.status][1]} xs">${LV_ST[r.status][0]}</span>${r.decided_by && r.status !== 'pending' ? `<small class="sub">${esc(r.decided_by)} · ${dShort(r.decided_at)}</small>` : ''}${r.decision_note ? `<small class="sub">${esc(r.decision_note)}</small>` : ''}`;
  async function leaveDecide(r, approve) {
    const ok = await modal({ title: `${approve ? 'Approve' : 'Do not approve'} leave · ${r.name}`, ok: approve ? 'Approve' : 'Not approved', danger: !approve,
      body: `<p><b>${esc(r.type_label || r.type)}</b> · ${lvDates(r)} · ${esc(String(r.days))} day${Number(r.days) === 1 ? '' : 's'}${r.reason ? `<br><span class="muted">${esc(r.reason)}</span>` : ''}</p>
        ${r.has_attachment ? `<button type="button" class="btn sm ghost" data-lvatt="${esc(r.id)}">${icon('eye')}View attachment</button>` : ''}
        <label class="fld"><span>${approve ? 'Note (optional)' : 'Reason (the staff member sees it)'}</span><input name="note" maxlength="300"></label>`,
      onOpen: (w) => $('[data-lvatt]', w)?.addEventListener('click', async () => { try { const src = await API.rpc('cms_leave_attachment', { p_id: r.id }); window.open(src, '_blank'); } catch (e) { toast(e.message, 'err'); } }),
      onOk: async (f) => { if (!approve && !f.note.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_leave_decide', { p_id: r.id, p_approve: approve, p_note: f.note.value || null }); } });
    if (ok) { toast(`${r.name}: leave ${approve ? 'approved' : 'not approved'}`); loadLeavePending(); render(); }
  }
  async function meLeavePage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="ml-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_my_leave'); } catch (e) { $('#ml-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const tl = (c) => (D.types.find((t) => t.code === c) || {}).label || c;
    $('#ml-body', el).innerHTML = `
      <section class="card"><div class="card-head"><h3>Apply for leave</h3><span class="muted small">Approved by: ${esc(D.approvers || 'HR')}</span></div>
        <div class="btn-row"><button type="button" class="btn primary" id="ml-new">${icon('plus')}New leave request…</button></div>
        ${Object.keys(D.taken || {}).length ? `<p class="muted small">Taken this year (from payroll): ${Object.entries(D.taken).map(([k, v]) => `${esc(tl(k))} ${esc(String(v))} d`).join(' · ')}</p>` : ''}</section>
      ${D.to_approve.length ? `<section class="card"><div class="card-head"><h3>For you to approve</h3></div><div class="table-wrap"><table class="data"><thead><tr><th>Person</th><th>Leave</th><th>Days</th><th></th></tr></thead><tbody>
        ${D.to_approve.map((r) => `<tr><td><b>${esc(r.name)}</b><small class="sub">${esc(r.employee_id || '')}</small></td><td>${esc(r.type_label || r.type)}<small class="sub">${lvDates(r)}</small>${r.reason ? `<small class="sub">${esc(r.reason)}</small>` : ''}</td>
          <td>${esc(String(r.days))}</td><td class="nowrap"><button type="button" class="btn sm primary" data-ok="${esc(r.id)}">Approve</button> <button type="button" class="btn sm" data-no="${esc(r.id)}">Not approve…</button></td></tr>`).join('')}</tbody></table></div></section>` : ''}
      <section class="card"><div class="card-head"><h3>My requests</h3></div>
        ${D.requests.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Leave</th><th>Days</th><th>Status</th><th></th></tr></thead><tbody>
          ${D.requests.map((r) => `<tr><td><b>${esc(r.type_label || r.type)}</b><small class="sub">${lvDates(r)}</small></td><td>${esc(String(r.days))}</td><td>${lvTag(r)}</td>
            <td>${r.status === 'pending' ? `<button type="button" class="btn sm ghost" data-cancel="${esc(r.id)}">Cancel</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No requests yet</p></div>'}</section>`;
    $$('[data-ok]', el).forEach((b) => b.addEventListener('click', () => leaveDecide(D.to_approve.find((r) => r.id === b.dataset.ok), true)));
    $$('[data-no]', el).forEach((b) => b.addEventListener('click', () => leaveDecide(D.to_approve.find((r) => r.id === b.dataset.no), false)));
    $$('[data-cancel]', el).forEach((b) => b.addEventListener('click', async () => {
      if (await confirmBox('Cancel this leave request?', 'Your approver will no longer see it.', 'Cancel request', true, () => API.rpc('cms_my_leave_cancel', { p_id: b.dataset.cancel }))) { toast('Request cancelled'); render(); }
    }));
    $('#ml-new', el).addEventListener('click', async () => {
      const ph = { v: null };
      const ok = await modal({ title: 'New leave request', ok: 'Send for approval',
        body: `<div class="grid-2 tight"><label class="fld fld-2"><span>Type of leave</span><select name="type" required><option value="">Choose…</option>${D.types.map((t) => `<option value="${esc(t.code)}">${esc(t.label)}</option>`).join('')}</select></label>
          <label class="fld"><span>First day</span><input name="from" type="date" required></label><label class="fld"><span>Last day</span><input name="to" type="date"></label>
          <label class="fld"><span>Working days</span><input name="days" type="number" min="0.5" step="0.5" placeholder="counted from the dates"></label>
          <label class="fld"><span>&nbsp;</span><label class="chk"><input type="checkbox" name="half"> Half day</label></label>
          <label class="fld fld-2"><span>Reason (optional)</span><input name="reason" maxlength="300"></label>
          <label class="fld fld-2"><span>Medical certificate / supporting photo (needed for sick and hospitalisation leave)</span><input name="photo" type="file" accept="image/*" capture="environment"></label></div>`,
        onOpen: (w) => wirePhoto(w, ph),
        onOk: async (f) => { if (!f.type.value || !f.from.value) throw new Error('Choose the type and the first day.');
          await API.rpc('cms_my_leave_apply', { p: { type: f.type.value, from: f.from.value, to: f.to.value || f.from.value, days: f.days.value || null, half_day: f.half.checked, reason: f.reason.value, attachment: ph.v } }); } });
      if (ok) { toast('Sent for approval'); render(); }
    });
  }
  async function leaveRequestsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="lr-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_leave_requests'); D.requests.forEach((r) => upKeys(r, 'name')); } catch (e) { $('#lr-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { v: 'pending' };
    const V = [['pending', 'Waiting', (r) => r.status === 'pending'], ['topay', 'Approved, not in payroll', (r) => r.status === 'approved' && !r.payroll_done],
      ['done', 'In payroll', (r) => r.payroll_done], ['all', 'All', () => true]];
    const draw = () => {
      const list = D.requests.filter(V.find((x) => x[0] === f.v)[2]);
      $('#lr-body', el).innerHTML = `<section class="card"><div class="toolbar"><div class="seg">${V.map(([k, l, fn]) => `<button type="button" data-v="${k}" class="${f.v === k ? 'on' : ''}">${l} <span>${D.requests.filter(fn).length}</span></button>`).join('')}</div></div>
        ${list.length ? `<div class="table-wrap"><table class="data"><thead><tr><th>Person</th><th>Leave</th><th>Days</th><th>Status</th><th>Payroll</th></tr></thead><tbody>
          ${list.map((r) => `<tr><td><b>${esc(r.name)}</b><small class="sub">${esc(r.employee_id || '')}</small></td><td>${esc(r.type_label || r.type)}<small class="sub">${lvDates(r)}</small></td><td>${esc(String(r.days))}</td>
            <td>${lvTag(r)}${r.can_decide ? `<div class="btn-row"><button type="button" class="btn sm primary" data-ok="${esc(r.id)}">Approve</button><button type="button" class="btn sm" data-no="${esc(r.id)}">Not approve…</button></div>` : ''}</td>
            <td>${r.status === 'approved' ? `<label class="chk"><input type="checkbox" data-pay="${esc(r.id)}" ${r.payroll_done ? 'checked' : ''} ${D.can_edit ? '' : 'disabled'}> Entered in payroll</label>` : '—'}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No requests here</p><span>Leave requests come from My Leave, which is switched on per person (Self-service Access).</span></div>'}</section>
        <p class="muted small">Approval follows Reports to: the person they report to or anyone above (directors can approve anyone; a director is approved by the other director or HR; no Reports-to set → HR). Approved leave is entered in payroll by hand for now — tick it when done.</p>`;
      $$('[data-v]', el).forEach((b) => b.addEventListener('click', () => { f.v = b.dataset.v; draw(); }));
      $$('[data-ok]', el).forEach((b) => b.addEventListener('click', () => leaveDecide(D.requests.find((r) => r.id === b.dataset.ok), true)));
      $$('[data-no]', el).forEach((b) => b.addEventListener('click', () => leaveDecide(D.requests.find((r) => r.id === b.dataset.no), false)));
      $$('[data-pay]', el).forEach((c) => c.addEventListener('change', async () => {
        try { await API.rpc('cms_leave_payroll_done', { p_id: c.dataset.pay, p_done: c.checked }); const r = D.requests.find((x) => x.id === c.dataset.pay); r.payroll_done = c.checked; toast(c.checked ? 'Marked as entered in payroll' : 'Unmarked'); loadLeavePending(); }
        catch (e) { c.checked = !c.checked; toast(e.message, 'err'); }
      }));
    };
    draw();
  }
  async function loadLeavePending() { try { state.leavePending = await API.rpc('cms_leave_pending'); drawBell(); } catch (e) { /* reminders only */ } }
  function leaveTasks() {
    const x = state.leavePending; const t = []; if (!x) return t;
    if (x.to_approve) t.push({ ic: 'calendar', tone: 'violet', title: `${num(x.to_approve)} leave request${x.to_approve === 1 ? '' : 's'} to approve`, sub: 'Leave', href: canRoute('leave/requests') ? '#/leave/requests' : '#/me/leave' });
    if (x.to_payroll) t.push({ ic: 'calendar', tone: 'orange', title: `${num(x.to_payroll)} approved leave not yet in payroll`, sub: 'Enter in payroll, then tick', href: '#/leave/requests?v=topay' });
    return t;
  }

  // ================================================================ 5a · CAREER PATHS, MYEDEN SALARY CAPS (PRI-007, PRI-008)
  const lvNum = (l) => Number(String(l || '').replace(/\D/g, '')) || 0;
  const effBands = (pos) => (pos?.bands || []).map((b) => ({ ...b, lo: b.cap_min ?? b.min, hi: b.cap_max ?? b.max, mine: b.cap_min != null || b.cap_max != null }));
  const levelCap = (pos) => { const b = effBands(pos); return b.length ? b[b.length - 1].hi : null; };
  const capMine = (pos) => effBands(pos).some((b) => b.mine);
  function placeIn(pos, sal) {
    if (!sal || sal.amount == null) return { txt: 'no salary yet', cls: '' };
    if (sal.basis && sal.basis !== 'monthly') return { txt: `${sal.basis} pay`, cls: '' };
    const b = effBands(pos); if (!b.length) return { txt: 'no bands in the JD', cls: '' };
    const s = Number(sal.amount);
    if (b[0].lo != null && s < b[0].lo) return { txt: 'Below the range', cls: 'warn' };
    const cap = levelCap(pos); if (cap != null && s > cap) return { txt: 'Above the cap', cls: 'bad' };
    const hit = b.find((x) => x.lo != null && x.hi != null && s >= x.lo && s <= x.hi);
    return hit ? { txt: hit.tier, cls: 'ok' } : { txt: 'Between tiers', cls: '' };
  }
  const tenure = (d) => { if (!d) return '—'; const m = Math.max(0, Math.round((Date.now() - new Date(d).getTime()) / (30.44 * 864e5))); return m < 12 ? `${m} mth${m === 1 ? '' : 's'}` : `${Math.floor(m / 12)} yr${m >= 24 ? 's' : ''}${m % 12 ? ` ${m % 12} m` : ''}`; };
  const words = (t) => new Set(String(t || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').split(/\s+/).filter((w) => w.length > 2));
  function suggestPositions(C, person) {
    const pw = words(person.title);
    return C.positions.map((p) => { const w = words(p.title); let n = 0; pw.forEach((x) => { if (w.has(x)) n += 1; }); return { p, n: n + (p.company === person.company ? 0.5 : 0) }; })
      .filter((x) => x.n >= 1).sort((a, b) => b.n - a.n).slice(0, 5).map((x) => x.p);
  }

  async function careersPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="cp-body">${loading()}</div>`;
    let C;
    const load = async () => { C = await API.rpc('cms_careers'); C.people.forEach((r) => upKeys(r, 'name')); C.byId = new Map(C.positions.map((p) => [p.id, p])); };
    try { await load(); } catch (e) { $('#cp-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { tab: 'people', q: '', co: 'all', dept: '' };
    const posOf = (r) => C.byId.get(r.position_id);
    const nextOf = (pos) => (pos ? C.positions.filter((p) => p.company === pos.company && p.department_id === pos.department_id && lvNum(p.level) === lvNum(pos.level) + 1) : []);
    const capTxt = (pos) => { const c = levelCap(pos); return c == null ? '—' : `${money(c)}${capMine(pos) ? ' <span class="tag blue xs">MyEden</span>' : ' <small class="muted">JD</small>'}`; };
    const reload = async () => { const y = pageScroller().scrollTop; try { await load(); } catch (e) { toast(e.message, 'err'); } draw(); requestAnimationFrame(() => { pageScroller().scrollTop = y; }); };
    const draw = () => {
      const unplaced = C.people.filter((r) => !r.position_id);
      const T = [['people', 'People'], ['ladders', 'Ladders & salary caps'], ['unplaced', `Not placed <span>${unplaced.length}</span>`]];
      const cos = [...new Set(C.positions.map((p) => p.company))].sort();
      $('#cp-body', el).innerHTML = `<section class="card"><div class="seg ss-tabs">${T.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
        <div class="toolbar">${f.tab !== 'ladders' ? `<label class="search-in">${icon('search')}<input id="cq" type="search" placeholder="Name, Employee ID or job title" value="${esc(f.q)}" aria-label="Search"></label>` : ''}
          <select id="cco" aria-label="Company"><option value="all">All companies</option>${cos.map((c) => `<option value="${esc(c)}" ${f.co === c ? 'selected' : ''}>${esc(coShort(c))}</option>`).join('')}</select>
          ${f.tab === 'ladders' ? `<select id="cdp" aria-label="Department"><option value="">All departments</option>${[...new Set(C.positions.filter((p) => f.co === 'all' || p.company === f.co).map((p) => p.department || '—'))].sort().map((d) => `<option ${f.dept === d ? 'selected' : ''}>${esc(d)}</option>`).join('')}</select>` : ''}</div>
        <div id="cp-tab"></div></section>`;
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; draw(); }));
      $('#cq', el)?.addEventListener('input', (e) => { f.q = e.target.value; tab(); });
      $('#cco', el).addEventListener('change', (e) => { f.co = e.target.value; f.dept = ''; draw(); });
      $('#cdp', el)?.addEventListener('change', (e) => { f.dept = e.target.value; tab(); });
      tab();
    };
    const tab = () => {
      const box = $('#cp-tab', el); const t = f.q.trim().toLowerCase();
      const keep = { list: $('.table-wrap', box)?.scrollTop || 0, page: pageScroller().scrollTop };
      requestAnimationFrame(() => { const w = $('.table-wrap', box); if (w) w.scrollTop = keep.list; pageScroller().scrollTop = keep.page; });
      const ppl = C.people.filter((r) => (f.co === 'all' || r.company === f.co) && (!t || `${r.name} ${r.employee_id || ''} ${r.title || ''}`.toLowerCase().includes(t)));
      if (f.tab === 'people') {
        box.innerHTML = `<div class="table-wrap fill"><table class="data freeze2 click"><thead><tr><th>Name</th><th>JD level</th><th>In role</th>${C.can_pay ? '<th class="num">Salary (RM)</th><th>Place in band</th><th class="num">Level cap (RM)</th>' : ''}<th>Next level</th></tr></thead><tbody>
          ${ppl.map((r) => { const pos = posOf(r); const nx = nextOf(pos)[0]; const pl = pos ? placeIn(pos, r.salary) : null;
            return `<tr data-p="${esc(r.person_id)}"><td><b>${esc(r.name)}</b><small class="sub">${esc([r.employee_id, r.title].filter(Boolean).join(' · '))}</small></td>
              <td>${pos ? `<b>${esc(pos.level || '')}</b> · ${esc(pos.title)}${r.auto ? ' <small class="muted">(matched by title)</small>' : ''}` : '<span class="tag warn xs">Not placed</span>'}</td>
              <td class="nowrap">${tenure(r.since)}</td>
              ${C.can_pay ? `<td class="num">${r.salary ? `${m2(r.salary.amount)}${r.salary.basis === 'hourly' ? ' /h' : ''}` : '—'}</td><td>${pl ? `<span class="tag ${pl.cls} xs">${esc(pl.txt)}</span>` : '—'}</td><td class="num nowrap">${pos ? capTxt(pos) : '—'}</td>` : ''}
              <td>${nx ? `${esc(nx.level)} · ${esc(nx.title)}${C.can_pay && levelCap(nx) != null ? `<small class="sub">cap ${money(levelCap(nx))}</small>` : ''}` : pos ? '<span class="muted small">top of this ladder</span>' : '—'}</td></tr>`; }).join('')
          || '<tr><td colspan="7"><div class="empty small"><p>No one here</p></div></td></tr>'}</tbody></table></div>
          <p class="muted small">Level and next level come from the JD Manual (MEG-EAF V2). The cap is the top of the level's highest band: the MyEden cap where HR has set one, otherwise the JD (market) range. Click a person for their timeline and to change their JD position.</p>`;
        $$('[data-p]', box).forEach((r) => r.addEventListener('click', () => personWindow(r.dataset.p)));
      } else if (f.tab === 'unplaced') {
        const list = ppl.filter((r) => !r.position_id);
        box.innerHTML = list.length ? `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Name</th><th>Job title on record</th><th>Possible JD positions</th><th></th></tr></thead><tbody>
          ${list.map((r) => `<tr><td><b>${esc(r.name)}</b><small class="sub">${esc(r.employee_id || '')} · ${esc(coShort(r.company))}</small></td><td>${esc(r.title || '—')}</td>
            <td class="small">${suggestPositions(C, r).map((p) => `${esc(p.level)} · ${esc(p.title)} <span class="muted">(${esc(coShort(p.company))})</span>`).join('<br>') || '<span class="muted">no close match</span>'}</td>
            <td>${C.can_edit ? `<button type="button" class="btn sm primary" data-place="${esc(r.person_id)}">Place…</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
          <p class="muted small">These people's job title on record does not match a JD position for their employer. Choose the JD position they hold, once; it is kept even if the title wording differs.</p>`
          : '<div class="empty small"><p>Everyone is placed</p></div>';
        $$('[data-place]', box).forEach((b) => b.addEventListener('click', () => placeWindow(b.dataset.place)));
      } else {
        const pos = C.positions.filter((p) => (f.co === 'all' || p.company === f.co) && (!f.dept || (p.department || '—') === f.dept));
        const groups = new Map(); pos.forEach((p) => { const k = `${p.company}|${p.department || '—'}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(p); });
        const at = (p) => C.people.filter((r) => r.position_id === p.id);
        box.innerHTML = [...groups.entries()].map(([k, list]) => { const [co, dept] = k.split('|');
          return `<div class="ladder"><h4 class="sec-h">${esc(coShort(co))} · ${esc(dept)}</h4><div class="table-wrap"><table class="data compact"><thead><tr><th>Level</th><th>Position</th>${C.can_pay ? '<th>Tier</th><th>JD (market) range</th><th>MyEden cap</th>' : ''}<th>People</th></tr></thead><tbody>
            ${list.sort((a, b) => lvNum(a.level) - lvNum(b.level)).map((p) => { const bs = C.can_pay && p.bands.length ? p.bands : [null]; const ppl = at(p);
              return bs.map((b, i) => `<tr>${i === 0 ? `<td rowspan="${bs.length}"><b>${esc(p.level || '')}</b></td><td rowspan="${bs.length}">${esc(p.title)}<small class="sub">${esc(p.reference || '')}</small></td>` : ''}
                ${C.can_pay ? (b ? `<td>${esc(b.tier || '')}</td><td class="nowrap">${b.min != null ? `${money(b.min)} – ${money(b.max)}` : esc(b.range || '—')}</td>
                  <td class="nowrap">${b.cap_min != null || b.cap_max != null ? `<b>${b.cap_min != null ? money(b.cap_min) : '—'} – ${b.cap_max != null ? money(b.cap_max) : '—'}</b>` : '<span class="muted small">not set</span>'}
                    ${C.can_caps ? ` <button type="button" class="btn sm ghost" data-cap="${esc(b.id)}" data-pos="${esc(p.id)}">${b.cap_min != null || b.cap_max != null ? 'Edit' : 'Set'}</button>` : ''}</td>` : '<td colspan="3" class="muted small">no bands in the JD</td>') : ''}
                ${i === 0 ? `<td rowspan="${bs.length}" class="small">${ppl.map((r) => esc(r.name)).join('<br>') || '<span class="muted">—</span>'}</td>` : ''}</tr>`).join('');
            }).join('')}</tbody></table></div></div>`; }).join('') || '<div class="empty small"><p>No positions</p></div>';
        $$('[data-cap]', box).forEach((b) => b.addEventListener('click', () => capWindow(b.dataset.pos, b.dataset.cap)));
      }
      fitTables();
    };

    const capWindow = async (posId, bandId) => {
      const p = C.byId.get(posId); const b = p.bands.find((x) => x.id === bandId);
      let hist = []; try { hist = await API.rpc('cms_salary_cap_history', { p_band: bandId }); } catch (e) { /* optional */ }
      const ok = await modal({ title: `MyEden cap · ${p.level} ${p.title} · ${b.tier}`, ok: 'Save cap',
        body: `<p class="muted small">JD (market) range: <b>${b.min != null ? `${money(b.min)} – ${money(b.max)}` : esc(b.range || '—')}</b>. The MyEden cap is what MyEden Group pays for this tier; leave a box empty to use the JD figure.</p>
          <div class="grid-2 tight"><label class="fld"><span>MyEden minimum (RM)</span><input name="min" data-money inputmode="decimal" value="${b.cap_min != null ? m2(b.cap_min) : ''}"></label>
          <label class="fld"><span>MyEden maximum (RM)</span><input name="max" data-money inputmode="decimal" value="${b.cap_max != null ? m2(b.cap_max) : ''}"></label>
          <label class="fld"><span>Effective from</span><input name="from" type="date" value="${new Date().toISOString().slice(0, 10)}"></label>
          <label class="fld"><span>Reason / note</span><input name="note" maxlength="300" placeholder="e.g. 2027 budget review"></label></div>
          ${hist.length ? `<h4 class="sec-h">Changes</h4><ol class="timeline">${hist.map((h) => `<li><b>${h.min != null ? money(h.min) : '—'} – ${h.max != null ? money(h.max) : '—'}</b> from ${dShort(h.from)} · ${esc(h.by || '')} · ${dShort(h.at)}${h.note ? `<br><span class="muted">${esc(h.note)}</span>` : ''}</li>`).join('')}</ol>` : ''}`,
        onOk: async (fm) => { const mn = fm.min.value.trim() ? mval(fm.min.value) : null; const mx = fm.max.value.trim() ? mval(fm.max.value) : null;
          if ((mn != null && isNaN(mn)) || (mx != null && isNaN(mx))) throw new Error('Enter amounts as numbers.');
          if (mn != null && mx != null && mx < mn) throw new Error('The maximum is below the minimum.');
          await API.rpc('cms_salary_cap_save', { p_band: bandId, p_min: mn, p_max: mx, p_from: fm.from.value || null, p_note: fm.note.value || null }); } });
      if (ok) { toast('MyEden cap saved'); reload(); }
    };
    const placeWindow = async (pid) => {
      const r = C.people.find((x) => x.person_id === pid); const sug = suggestPositions(C, r);
      const opts = (list) => list.map((p) => `<option value="${esc(p.id)}" ${p.id === r.position_id ? 'selected' : ''}>${esc(p.level || '')} · ${esc(p.title)} — ${esc(coShort(p.company))} · ${esc(p.department || '')}</option>`).join('');
      const groups = new Map(); C.positions.forEach((p) => { const k = `${coShort(p.company)} · ${p.department || '—'}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(p); });
      const ok = await modal({ title: `JD position · ${r.name}`, ok: 'Save', wide: true,
        body: `<p class="muted small">Job title on record: <b>${esc(r.title || '—')}</b> (${esc(coShort(r.company))}).</p>
          <div class="grid-2 tight"><label class="fld fld-2"><span>JD position held</span><select name="pos" required><option value="">Choose…</option>
            ${sug.length ? `<optgroup label="Closest matches">${opts(sug)}</optgroup>` : ''}${[...groups.entries()].map(([k, l]) => `<optgroup label="${esc(k)}">${opts(l.sort((a, b) => lvNum(a.level) - lvNum(b.level)))}</optgroup>`).join('')}</select></label>
          <label class="fld"><span>In this level since</span><input name="since" type="date" value="${esc(r.auto ? '' : (r.since || ''))}"></label>
          <label class="fld"><span>Note (e.g. promoted)</span><input name="note" maxlength="300"></label></div>`,
        onOk: async (fm) => { if (!fm.pos.value) throw new Error('Choose the JD position.'); await API.rpc('cms_person_position_set', { p_person: pid, p_position: fm.pos.value, p_since: fm.since.value || null, p_note: fm.note.value || null }); } });
      if (ok) { toast(`${r.name}: JD position saved`); reload(); }
    };
    const personWindow = async (pid) => {
      const r = C.people.find((x) => x.person_id === pid); const pos = posOf(r); const nx = nextOf(pos);
      let tl = []; try { tl = await API.rpc('cms_person_timeline', { p_person: pid }); } catch (e) { toast(e.message, 'err'); }
      const KIND = { recruit: 'blue', job: 'ok', pay: 'green', leave: 'warn', item: '', event: '' };
      const pl = pos ? placeIn(pos, r.salary) : null;
      await modal({ title: r.name, ok: null, cancel: 'Close', wide: true,
        body: `<div class="grid-2 tight"><div>
            <h4 class="sec-h">Career</h4>
            ${pos ? `<dl class="kv2"><dt>JD level</dt><dd><b>${esc(pos.level)}</b> · ${esc(pos.title)}<br><small class="muted">${esc(pos.reference || '')} · ${esc(coShort(pos.company))} · ${esc(pos.department || '')}</small></dd>
              <dt>In this level</dt><dd>${tenure(r.since)}${r.since ? ` (since ${dShort(r.since)})` : ''}</dd>
              ${C.can_pay ? `<dt>Salary</dt><dd>${r.salary ? `RM ${m2(r.salary.amount)}${r.salary.basis === 'hourly' ? ' /h' : ''}` : '—'} ${pl ? `<span class="tag ${pl.cls} xs">${esc(pl.txt)}</span>` : ''}</dd><dt>Level cap</dt><dd>${capTxt(pos)}</dd>` : ''}
              <dt>Next level</dt><dd>${nx.length ? nx.map((n) => `${esc(n.level)} · ${esc(n.title)}${C.can_pay && levelCap(n) != null ? ` — cap ${money(levelCap(n))}` : ''}`).join('<br>') : 'Top of this ladder'}</dd></dl>
              ${Array.isArray(pos.career_path) && pos.career_path.length ? `<p class="small muted">${pos.career_path.map(esc).join(' → ')}</p>` : ''}`
              : '<p class="warn-txt">Not placed on a JD position yet.</p>'}
            ${C.can_edit ? `<button type="button" class="btn sm" data-place>${pos ? 'Change JD position…' : 'Place on a JD position…'}</button>` : ''}</div>
          <div><h4 class="sec-h">Timeline</h4><ol class="timeline tl-kinds">${tl.map((x) => `<li class="k-${esc(x.kind)}"><span class="tag ${KIND[x.kind] || ''} xs">${dShort(x.at)}</span> <b>${esc(x.title)}</b>${x.amount != null ? ` · RM ${m2(x.amount)}${x.basis === 'hourly' ? ' /h' : ''}` : ''}${x.note ? `<br><span class="muted small">${esc(x.note)}</span>` : ''}</li>`).join('') || '<li class="muted">Nothing recorded yet</li>'}</ol></div></div>`,
        onOpen: (w) => $('[data-place]', w)?.addEventListener('click', () => { $('[data-x]', w).click(); placeWindow(pid); }) });
    };
    draw();
  }

  // ================================================================ 5b · KPI & APPRAISAL
  const GRADE_LBL = { E: 'Excellent', S: 'Satisfactory', A: 'Average', I: 'Needs improvement', U: 'Under performing' };
  const REC_LBL = { confirm: 'Confirm', extend: 'Extend probation', end: 'Do not confirm (end employment)', increment: 'Salary increment', promote: 'Promote to the next level',
    no_change: 'No change', pip: 'Performance improvement plan' };
  const AP_ST = { open: ['In progress', 'warn'], reviewed: ['Reviewed · waiting for approval', 'blue'], approved: ['Approved', 'ok'], cancelled: ['Cancelled', ''] };
  const PROB_SRC = { recorded: 'set on the record', offer: 'from the offer (probation months)', assumed: 'assumed 3 months — set it when starting the review' };
  const SELF_Q = [['achievements', 'What went well / what you achieved'], ['challenges', 'What was difficult'], ['goals', 'Your goals for the next period'], ['support', 'Support or training you need'], ['comment', 'Anything else']];
  const apTag = (a) => `<span class="tag ${AP_ST[a.status][1]} xs">${AP_ST[a.status][0]}</span>${a.status === 'approved' && a.recommendation === 'extend' && !a.letter_issued_at ? ' <span class="tag bad xs">extension letter to issue</span>' : ''}${a.follow_up ? ' <span class="tag xs">after extension</span>' : ''}${a.self_requested ? (a.self_done ? ' <span class="tag ok xs">self-assessment in</span>' : ' <span class="tag xs">self-assessment pending</span>') : ''}`;
  const apName = (a) => (a.kind === 'annual' ? `Annual appraisal ${a.year}` : 'Probation review');
  const gradeTag = (g, L = GRADE_LBL) => (g ? `<span class="tag ${g === 'E' || g === 'S' ? 'ok' : g === 'A' ? 'blue' : 'bad'} xs">${esc(g)} · ${esc(L[g] || '')}</span>` : '—');

  async function appraisalWindow(id, after) {
    let A; try { A = await API.rpc('cms_appraisal', { p_id: id }); } catch (e) { toast(e.message, 'err'); return; }
    const L = { ...GRADE_LBL, ...(A.grade_labels || {}) };
    if (A.role === 'self') {
      const canSelf = A.self_requested && A.status === 'open' && !A.self_done; const R = A.result;
      const ok = await modal({ title: apName(A), ok: canSelf ? 'Send to my reviewer' : null, cancel: 'Close', wide: true,
        body: `${R ? `<h4 class="sec-h">Result</h4><p>Overall: ${gradeTag(R.rating, L)}</p>
            <div class="table-wrap"><table class="data compact"><thead><tr><th>Area</th><th class="num">Score</th><th>Comment</th></tr></thead><tbody>${(R.scores || []).map((s) => `<tr><td>${esc(s.area)}</td><td class="num">${s.score ?? '—'} / 5</td><td>${esc(s.comment || '')}</td></tr>`).join('')}</tbody></table></div>
            ${R.strengths ? `<p><b>Strengths:</b> ${esc(R.strengths)}</p>` : ''}${R.improvements ? `<p><b>To improve:</b> ${esc(R.improvements)}</p>` : ''}${R.goals ? `<p><b>Goals:</b> ${esc(R.goals)}</p>` : ''}` : ''}
          ${A.self_requested ? `<h4 class="sec-h">My self-assessment ${A.self_done ? `<small class="muted">sent ${dShort(A.self_at)}</small>` : ''}</h4>
            ${SELF_Q.map(([k, l]) => `<label class="fld"><span>${l}</span><textarea name="${k}" rows="2" ${canSelf ? '' : 'disabled'}>${esc((A.self_answers || {})[k] || '')}</textarea></label>`).join('')}` : ''}
          ${!R && !canSelf ? '<p class="muted">Your reviewer is working on this appraisal. You will see the result here once it is approved.</p>' : ''}`,
        onOk: async (f) => { const ans = Object.fromEntries(SELF_Q.map(([k]) => [k, f[k].value.trim()])); if (!ans.achievements) throw new Error('Write at least what went well.');
          await API.rpc('cms_appraisal_self', { p_id: id, p_answers: ans }); } });
      if (ok) { toast('Sent to your reviewer'); after?.(); }
      return;
    }
    const scores = A.scores || []; const prob = A.kind === 'probation';
    const recs = prob ? ['confirm', 'extend', 'end'] : ['increment', 'promote', 'no_change', 'pip'];
    const edit = A.can_review;
    const ok = await modal({ title: `${apName(A)} · ${A.name}`, ok: edit ? (A.status === 'reviewed' ? 'Save changes' : 'Save review') : null, cancel: 'Close', wide: true,
      body: `<p class="muted small">${esc([A.employee_id, A.title, coShort(A.company)].filter(Boolean).join(' · '))}${A.position ? ` · JD ${esc(A.position.level)} ${esc(A.position.title)}` : ' · not placed on a JD position (Career Paths)'}
          · reviewer ${esc(A.reviewer || 'HR')} ${apTag(A)}</p>
        ${prob ? `<p class="small">Probation ends (= confirmation date): <b>${A.probation_end ? dShort(A.probation_end) : '—'}</b> <span class="muted">${esc(PROB_SRC[A.probation_source] || '')}</span></p>` : ''}
        ${A.self_requested ? `<details class="card" ${A.self_done ? 'open' : ''}><summary><b>Self-assessment</b> ${A.self_done ? `<small class="muted">${dShort(A.self_at)}</small>` : '<small class="muted">not sent yet</small>'}</summary>
          ${A.self_answers ? SELF_Q.map(([k, l]) => (A.self_answers[k] ? `<p><b>${l}:</b> ${esc(A.self_answers[k])}</p>` : '')).join('') : ''}</details>` : ''}
        <div class="table-wrap"><table class="data compact ap-scores"><thead><tr><th>KPI area</th><th>Score (1–5)</th><th>Comment</th></tr></thead><tbody>
          ${scores.map((s, i) => `<tr><td><b>${esc(s.area)}</b><small class="sub">${esc(s.measure || '')}</small></td>
            <td><select name="s${i}" ${edit ? '' : 'disabled'}><option value="">—</option>${[5, 4, 3, 2, 1].map((n) => `<option ${Number(s.score) === n ? 'selected' : ''}>${n}</option>`).join('')}</select></td>
            <td><input name="c${i}" value="${esc(s.comment || '')}" ${edit ? '' : 'disabled'}></td></tr>`).join('')}</tbody></table></div>
        <div class="grid-2 tight">
          <label class="fld"><span>Overall KPI grade</span><select name="rating" ${edit ? '' : 'disabled'}><option value="">Choose…</option>${Object.keys(GRADE_LBL).map((g) => `<option value="${g}" ${A.rating === g ? 'selected' : ''}>${g} · ${esc(L[g])}</option>`).join('')}</select></label>
          <label class="fld"><span>Recommendation</span><select name="rec" ${edit ? '' : 'disabled'}><option value="">Choose…</option>${recs.map((r) => `<option value="${r}" ${A.recommendation === r ? 'selected' : ''}>${esc(REC_LBL[r])}</option>`).join('')}</select></label>
          <label class="fld" data-show="extend"><span>New probation end date</span><input name="ext" type="date" value="${esc(A.rec_extend_to || '')}" ${edit ? '' : 'disabled'}></label>
          <label class="fld" data-show="promote"><span>Promote to</span><select name="pos" ${edit ? '' : 'disabled'}><option value="">Choose…</option>${(A.next_positions || []).map((p) => `<option value="${esc(p.id)}" ${A.rec_position === p.id ? 'selected' : ''}>${esc(p.level)} · ${esc(p.title)}</option>`).join('')}</select></label>
          <label class="fld" data-show="increment promote"><span>Recommended new salary (RM)</span><input name="inc" data-money inputmode="decimal" value="${A.rec_increment != null ? m2(A.rec_increment) : ''}" ${edit ? '' : 'disabled'}></label>
          <label class="fld fld-2"><span>Strengths</span><textarea name="str" rows="2" ${edit ? '' : 'disabled'}>${esc(A.strengths || '')}</textarea></label>
          <label class="fld fld-2"><span>To improve</span><textarea name="imp" rows="2" ${edit ? '' : 'disabled'}>${esc(A.improvements || '')}</textarea></label>
          <label class="fld fld-2"><span>Goals for the next period</span><textarea name="goals" rows="2" ${edit ? '' : 'disabled'}>${esc(A.goals || '')}</textarea></label></div>
        ${A.status === 'approved' && A.recommendation === 'extend' ? (A.letter_issued_at ? `<p class="small">Extension letter issued ${dShort(A.letter_issued_at)}${A.letter_ref ? ` · ${esc(A.letter_ref)}` : ''}</p>`
          : `<div class="err-box"><b>Issue the probation extension letter</b> (new end date ${dShort(A.rec_extend_to)}).<div class="btn-row">${A.role === 'hr' ? '<button type="button" class="btn sm primary" data-pel>Issue extension letter…</button><button type="button" class="btn sm" data-letter>Already issued: mark it…</button>' : ''}</div></div>`) : ''}
        ${A.status === 'approved' && A.recommendation === 'confirm' && A.role === 'hr' ? '<div class="btn-row"><button type="button" class="btn sm" data-loc>Issue confirmation letter…</button></div>' : ''}
        ${A.status === 'approved' && A.recommendation === 'promote' && A.role === 'hr' ? '<div class="btn-row"><button type="button" class="btn sm" data-lop>Issue promotion letter…</button></div>' : ''}
        ${A.status === 'approved' ? `<div class="warn-box"><b>Approved</b> by ${esc(A.approved_by || '')} · ${dShort(A.approved_at)}${A.outcome ? `<br>${esc(Object.entries(A.outcome).map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`).join(' · '))}` : ''}</div>` : ''}
        ${A.can_approve ? `<div class="btn-row"><button type="button" class="btn primary" data-appr>Approve and apply…</button><button type="button" class="btn" data-ret>Return to reviewer…</button></div>
          <p class="muted small">Approving applies the outcome: ${prob ? 'confirmation in payroll and the Employee Master, or the new probation end date' : 'the KPI grade goes to payroll (annual-leave carry forward); a promotion moves them to the new JD level; a salary increment is then recorded in Increments &amp; Reviews'}.</p>` : ''}`,
      onOpen: (w) => {
        const sync = () => { const r = $('select[name=rec]', w).value; $$('[data-show]', w).forEach((x) => { x.hidden = !x.dataset.show.split(' ').includes(r); }); };
        $('select[name=rec]', w).addEventListener('change', sync); sync();
        const act = async (ret) => {
          const close = () => $('[data-x]', w).click(); close();
          const done = await modal({ title: `${ret ? 'Return' : 'Approve'} · ${A.name}`, ok: ret ? 'Return to reviewer' : 'Approve', danger: false,
            body: `<label class="fld"><span>${ret ? 'What should be changed' : 'Note (optional)'}</span><input name="note" maxlength="300" ${ret ? 'required' : ''}></label>`,
            onOk: async (f) => { if (ret && !f.note.value.trim()) throw new Error('Say what should be changed.');
              const out = await API.rpc('cms_appraisal_approve', { p_id: id, p_note: f.note.value || null, p_return: ret });
              if (!ret && out) toast(Object.entries(out).map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`).join(' · ') || 'Approved'); } });
          if (done) { if (ret) toast('Returned to the reviewer'); after?.(); }
        };
        $('[data-appr]', w)?.addEventListener('click', () => act(false));
        const issueFrom = (code, extra = {}) => { $('[data-x]', w).click(); location.hash = `#/letters?ws=new&person=${encodeURIComponent(A.person_id)}&type=${code}${extra.appraisal_id ? `&appraisal=${encodeURIComponent(extra.appraisal_id)}` : ''}`; };
        $('[data-pel]', w)?.addEventListener('click', () => issueFrom('PEL', { appraisal_id: id }));
        $('[data-loc]', w)?.addEventListener('click', () => issueFrom('LOC'));
        $('[data-lop]', w)?.addEventListener('click', () => issueFrom('LOP'));
        $('[data-letter]', w)?.addEventListener('click', async () => { $('[data-x]', w).click();
          const done = await modal({ title: `Extension letter · ${A.name}`, ok: 'Mark as issued', body: '<label class="fld"><span>Letter reference (optional)</span><input name="ref" maxlength="80"></label>',
            onOk: async (f) => { await API.rpc('cms_appraisal_letter', { p_id: id, p_ref: f.ref.value || null }); } });
          if (done) { toast('Extension letter recorded'); after?.(); } });
        $('[data-ret]', w)?.addEventListener('click', () => act(true));
      },
      onOk: async (f) => {
        const sc = scores.map((s, i) => ({ area: s.area, measure: s.measure, score: f[`s${i}`].value ? Number(f[`s${i}`].value) : null, comment: f[`c${i}`].value.trim() || null }));
        if (sc.some((s) => s.score == null)) throw new Error('Score every KPI area (1–5).');
        await API.rpc('cms_appraisal_review', { p_id: id, p: { scores: sc, rating: f.rating.value, recommendation: f.rec.value, rec_extend_to: f.ext.value || null, rec_position: f.pos.value || null,
          rec_increment: f.inc.value ? mval(f.inc.value) : null, strengths: f.str.value, improvements: f.imp.value, goals: f.goals.value } });
      } });
    if (ok) { toast('Review saved'); after?.(); }
  }

  async function appraisalsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="ap2-body">${loading()}</div>`;
    let D; const load = async () => { D = await API.rpc('cms_appraisals'); D.people.forEach((r) => upKeys(r, 'name')); D.appraisals.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#ap2-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const L = { ...GRADE_LBL, ...(D.grade_labels || {}) };
    const f = { tab: 'progress', q: '' };
    const reload = async () => { try { await load(); loadApprPending(); } catch (e) { toast(e.message, 'err'); } draw(); };
    const draw = () => {
      const prog = D.appraisals.filter((a) => ['open', 'reviewed'].includes(a.status)); const t = f.q.trim().toLowerCase();
      const probDue = D.people.filter((p) => p.on_probation && !p.probation_open);
      const annualTodo = D.people.filter((p) => !p.on_probation && !p.annual_done);
      const T = [['progress', `In progress <span>${prog.length}</span>`], ['probation', `Probation due <span>${probDue.length}</span>`], ['annual', `Annual ${D.year} <span>${annualTodo.length}</span>`], ['done', 'Approved']];
      const match = (r) => !t || `${r.name} ${r.employee_id || ''} ${r.title || ''}`.toLowerCase().includes(t);
      $('#ap2-body', el).innerHTML = `<section class="card"><div class="seg ss-tabs">${T.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
        <div class="toolbar"><label class="search-in">${icon('search')}<input id="aq" type="search" placeholder="Name or Employee ID" value="${esc(f.q)}" aria-label="Search"></label>
          ${D.can_edit && f.tab === 'annual' && annualTodo.length ? `<button type="button" class="btn sm" data-bulk>Start annual appraisals for all ${annualTodo.length}…</button>` : ''}</div>
        <div id="ap2-tab"></div></section>
        <p class="muted small">KPI grade (${Object.entries(L).map(([k, v]) => `${k} ${v}`).join(' · ')}) is set by the approved annual appraisal and goes to payroll for annual-leave carry forward (cut-off month ${D.kpi_cutoff_month}).
          The reviewer is the person they report to (or HR); HR / Admin or a director approves.</p>`;
      const box = $('#ap2-tab', el);
      const apRows = (list) => (list.length ? `<div class="table-wrap fill"><table class="data freeze2 click"><thead><tr><th>Person</th><th>Appraisal</th><th>Reviewer</th><th>Due</th><th>Grade</th><th>Status</th></tr></thead><tbody>
        ${list.map((a) => `<tr data-a="${esc(a.id)}"><td><b>${esc(a.name)}</b><small class="sub">${esc([a.employee_id, a.title].filter(Boolean).join(' · '))}</small></td><td>${esc(apName(a))}</td>
          <td>${esc(a.reviewer || 'HR')}</td><td class="nowrap">${a.due ? dShort(a.due) : '—'}</td><td>${gradeTag(a.rating, L)}${a.recommendation ? `<small class="sub">${esc(REC_LBL[a.recommendation])}</small>` : ''}</td><td>${apTag(a)}</td></tr>`).join('')}</tbody></table></div>`
        : '<div class="empty small"><p>Nothing here</p></div>');
      if (f.tab === 'progress') box.innerHTML = apRows(prog.filter(match));
      else if (f.tab === 'done') box.innerHTML = apRows(D.appraisals.filter((a) => a.status === 'approved' && match(a)));
      else {
        const list = (f.tab === 'probation' ? probDue : annualTodo).filter(match);
        box.innerHTML = list.length ? `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Person</th><th>Started</th><th>${f.tab === 'probation' ? 'Probation ends' : `KPI grade ${D.year}`}</th><th></th></tr></thead><tbody>
          ${list.map((p) => `<tr><td><b>${esc(p.name)}</b><small class="sub">${esc([p.employee_id, p.title].filter(Boolean).join(' · '))}</small></td><td class="nowrap">${p.start ? dShort(p.start) : '—'}</td>
            <td class="nowrap">${f.tab === 'probation' ? `${p.probation_end ? dShort(p.probation_end) : '—'}${p.probation_source === 'assumed' ? ' <small class="muted">assumed</small>' : p.probation_source === 'offer' ? ' <small class="muted">from offer</small>' : ''}${p.probation_end && daysTo(p.probation_end) < 0 ? ' <span class="tag bad xs">overdue</span>' : p.probation_end && daysTo(p.probation_end) <= 30 ? ' <span class="tag warn xs">within 30 days</span>' : ''}` : gradeTag(p.grade, L)}</td>
            <td>${D.can_edit ? `<button type="button" class="btn sm primary" data-start="${esc(p.person_id)}" data-kind="${f.tab}">Start…</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`
          : '<div class="empty small"><p>No one due</p></div>';
      }
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; draw(); }));
      $('#aq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#aq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
      $$('[data-a]', box).forEach((r) => r.addEventListener('click', () => appraisalWindow(r.dataset.a, reload)));
      $$('[data-start]', box).forEach((b) => b.addEventListener('click', () => startWindow([b.dataset.start], b.dataset.kind)));
      $('[data-bulk]', el)?.addEventListener('click', () => startWindow(annualTodo.map((p) => p.person_id), 'annual'));
      fitTables();
    };
    const startWindow = async (ids, kind) => {
      const one = ids.length === 1 ? D.people.find((p) => p.person_id === ids[0]) : null;
      const reviewers = D.people.slice().sort((a, b) => a.name.localeCompare(b.name));
      const ok = await modal({ title: `${kind === 'annual' ? `Annual appraisal ${D.year}` : 'Probation review'} · ${one ? one.name : `${ids.length} people`}`, ok: 'Start',
        body: `<div class="grid-2 tight">${kind === 'probation' && one ? `<label class="fld"><span>Probation ends (= confirmation date)</span><input name="pend" type="date" value="${esc(one.probation_end || '')}"><small class="muted">${esc(PROB_SRC[one.probation_source] || '')}. 3–6 months or longer.</small></label>` : ''}
          <label class="fld"><span>Review due by</span><input name="due" type="date" value="${esc(one?.probation_end || '')}"></label>
          ${one ? `<label class="fld"><span>Reviewer</span><select name="rev"><option value="">Reports to (default) / HR</option>${reviewers.filter((r) => r.person_id !== one.person_id).map((r) => `<option value="${esc(r.person_id)}" ${r.person_id === one.reports_to_id ? 'selected' : ''}>${esc(r.name)}</option>`).join('')}</select></label>` : '<p class="muted small fld">Each person is reviewed by the person they report to (or HR where none is set).</p>'}
          <label class="fld fld-2"><span>&nbsp;</span><label class="chk"><input type="checkbox" name="self" checked> Ask for a self-assessment (in My Appraisal; the person needs a linked login)</label></label></div>`,
        onOk: async (fm) => { let n = 0; const errs = [];
          for (const id of ids) { try { await API.rpc('cms_appraisal_start', { p: { person_id: id, kind, year: D.year, due: fm.due.value || null, probation_end: fm.pend ? fm.pend.value || null : null, reviewer_id: fm.rev ? fm.rev.value || null : null, self_requested: fm.self.checked } }); n += 1; } catch (e) { errs.push(e.message); } }
          if (!n && errs.length) throw new Error(errs[0]);
          toast(`${n} appraisal${n === 1 ? '' : 's'} started${errs.length ? ` (${errs.length} skipped)` : ''}`); } });
      if (ok) { f.tab = 'progress'; reload(); }
    };
    draw();
  }

  async function meAppraisalPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="ma-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_my_appraisals'); } catch (e) { $('#ma-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const rows = (list, who) => list.map((a) => `<div class="me-item" data-a="${esc(a.id)}"><div><b>${esc(who ? a.name : apName(a))}</b><small class="sub">${esc(who ? apName(a) : (a.reviewer ? `Reviewer ${a.reviewer}` : ''))}${a.due ? ` · due ${dShort(a.due)}` : ''}</small></div>
      <div class="btn-row">${apTag(a)}${a.status === 'approved' && !who ? gradeTag(a.rating) : ''}<button type="button" class="btn sm ${(!who && a.self_requested && !a.self_done && a.status === 'open') || (who && a.status === 'open') ? 'primary' : ''}">Open</button></div></div>`).join('');
    $('#ma-body', el).innerHTML = `${D.to_review.length ? `<section class="card"><div class="card-head"><h3>For you to review</h3><span class="muted small">People who report to you</span></div>${rows(D.to_review, true)}</section>` : ''}
      <section class="card"><div class="card-head"><h3>My appraisals</h3></div>${D.mine.length ? rows(D.mine, false) : '<div class="empty small"><p>No appraisal for you yet</p></div>'}</section>`;
    $$('[data-a]', el).forEach((r) => r.querySelector('button').addEventListener('click', () => appraisalWindow(r.dataset.a, () => { refreshSelf(); loadApprPending(); render(); })));
  }
  async function loadApprPending() { try { state.apprPending = await API.rpc('cms_appraisals_pending'); drawBell(); } catch (e) { /* reminders only */ } }
  function apprTasks() {
    const x = state.apprPending; const t = []; if (!x) return t;
    if (x.self_to_do) t.push({ ic: 'trend', tone: 'blue', title: 'Your self-assessment is waiting', sub: 'My Appraisal', href: '#/me/appraisal' });
    if (x.to_review) t.push({ ic: 'trend', tone: 'violet', title: `${num(x.to_review)} appraisal${x.to_review === 1 ? '' : 's'} for you to review`, sub: 'People who report to you', href: selfOn('appraisal') ? '#/me/appraisal' : '#/performance' });
    if (x.to_approve) t.push({ ic: 'check-circle', tone: 'green', title: `${num(x.to_approve)} appraisal${x.to_approve === 1 ? '' : 's'} to approve`, sub: 'KPI & Appraisal', href: '#/performance' });
    if (x.letters_due) t.push({ ic: 'mail', tone: 'rose', title: `${num(x.letters_due)} probation extension letter${x.letters_due === 1 ? '' : 's'} to issue`, sub: 'KPI & Appraisal › Approved', href: '#/performance' });
    if (x.probation_due) t.push({ ic: 'trend', tone: 'orange', title: `${num(x.probation_due)} probation review${x.probation_due === 1 ? '' : 's'} due`, sub: 'Ending within 30 days or overdue', href: '#/performance' });
    return t;
  }

  // ================================================================ 5c · TRAINING & CERTIFICATES
  const CERT_ST = { valid: ['Valid', 'ok'], expiring: ['Expiring soon', 'warn'], expired: ['Expired', 'bad'], pending: ['Waiting for HR', 'blue'], rejected: ['Not accepted', 'bad'] };
  const certTag = (c) => `<span class="tag ${(CERT_ST[c.state] || ['', ''])[1]} xs">${esc((CERT_ST[c.state] || [c.state])[0])}</span>`;
  const certName = (c) => `<b>${esc(c.type_label)}</b>${c.title && c.title !== c.type_label ? `<small class="sub">${esc(c.title)}</small>` : ''}${c.cert_no ? `<small class="sub">No. ${esc(c.cert_no)}</small>` : ''}`;
  const fileField = (label = 'Copy of the certificate (photo or PDF)') => `<label class="fld fld-2"><span>${esc(label)}</span><input name="file" type="file" accept="image/*,application/pdf"></label>`;
  async function readDoc(file) {
    if (!file) return null;
    if (file.type === 'application/pdf') {
      if (file.size > 2 * 1024 * 1024) throw new Error('The PDF is too large (2 MB at most).');
      return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(new Error('Could not read the file.')); r.readAsDataURL(file); });
    }
    return shrinkImage(file);
  }
  const wireDoc = (w, holder) => { $('input[name=file]', w)?.addEventListener('change', async (e) => { try { holder.v = await readDoc(e.target.files[0]); } catch (x) { holder.v = null; toast(x.message, 'err'); } }); };
  async function showCertFile(id) {
    try { const src = await API.rpc('cms_cert_file', { p_id: id }); if (!src) throw new Error('No copy attached.');
      if (src.startsWith('data:application/pdf')) { const w = window.open(); if (w) w.document.write(`<iframe src="${src}" style="border:0;width:100%;height:100vh"></iframe>`); return; }
      await modal({ title: 'Certificate', ok: null, cancel: 'Close', wide: true, body: `<img class="att-img" src="${esc(src)}" alt="Certificate">` }); }
    catch (e) { toast(e.message, 'err'); }
  }

  async function trainingPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="tc-body">${loading()}</div>`;
    let D; const load = async () => { D = await API.rpc('cms_training'); D.people.forEach((r) => upKeys(r, 'name')); D.certificates.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#tc-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { tab: 'expiring', q: '', type: 'all' };
    const reload = async () => { const y = pageScroller().scrollTop; try { await load(); loadCertsPending(); } catch (e) { toast(e.message, 'err'); } draw(); requestAnimationFrame(() => { pageScroller().scrollTop = y; }); };
    const typeOf = (c) => D.types.find((t) => t.code === c) || {};
    const draw = () => {
      const exp = D.certificates.filter((c) => ['expiring', 'expired'].includes(c.state));
      const pend = D.certificates.filter((c) => c.status === 'pending');
      const req = D.types.filter((t) => t.required_all && t.is_active);
      const missing = []; D.people.forEach((p) => req.forEach((t) => { if (!D.certificates.some((c) => c.person_id === p.person_id && c.type === t.code && c.status === 'verified' && c.state !== 'expired')) missing.push({ p, t }); }));
      const T = [['expiring', `Expiring & expired <span>${exp.length}</span>`], ['missing', `Missing required <span>${missing.length}</span>`], ['verify', `To verify <span>${pend.length}</span>`],
        ['all', 'All certificates'], ['trainings', 'Training sessions'], ['types', 'Certificate types']];
      $('#tc-body', el).innerHTML = `<section class="card"><div class="seg ss-tabs">${T.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
        ${['all', 'expiring', 'missing'].includes(f.tab) ? `<div class="toolbar"><label class="search-in">${icon('search')}<input id="tq" type="search" placeholder="Name or Employee ID" value="${esc(f.q)}" aria-label="Search"></label>
          <select id="tty" aria-label="Type"><option value="all">All types</option>${D.types.map((t) => `<option value="${esc(t.code)}" ${f.type === t.code ? 'selected' : ''}>${esc(t.label)}</option>`).join('')}</select>
          ${D.can_edit ? '<button type="button" class="btn sm primary" data-add>+ Add certificate…</button>' : ''}</div>` : ''}<div id="tc-tab"></div></section>`;
      const box = $('#tc-tab', el); const t = f.q.trim().toLowerCase();
      const okp = (r) => (!t || `${r.name} ${r.employee_id || ''}`.toLowerCase().includes(t)) && (f.type === 'all' || (r.type || r.t?.code) === f.type);
      const certRows = (list, actions) => (list.length ? `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Person</th><th>Certificate</th><th>Issued</th><th>Expires</th><th>Status</th><th></th></tr></thead><tbody>
        ${list.map((c) => `<tr><td><b>${esc(c.name)}</b><small class="sub">${esc(c.employee_id || '')}</small></td><td>${certName(c)}</td><td class="nowrap">${c.issued_on ? dShort(c.issued_on) : '—'}</td>
          <td class="nowrap">${c.expires_on ? dShort(c.expires_on) : '<span class="muted">no expiry</span>'}</td><td>${certTag(c)}${c.source === 'self' ? ' <small class="muted">sent by staff</small>' : ''}</td>
          <td class="nowrap">${c.has_file ? `<button type="button" class="btn sm ghost" data-file="${esc(c.id)}">${icon('eye')}Copy</button>` : ''}${actions(c)}</td></tr>`).join('')}</tbody></table></div>`
        : '<div class="empty small"><p>Nothing here</p></div>');
      if (f.tab === 'expiring') box.innerHTML = certRows(exp.filter(okp), (c) => (D.can_edit ? ` <button type="button" class="btn sm" data-renew="${esc(c.id)}">Renewed…</button>` : ''));
      else if (f.tab === 'all') box.innerHTML = certRows(D.certificates.filter((c) => c.status !== 'pending' && okp(c)), (c) => (D.can_edit ? ` <button type="button" class="btn sm ghost" data-edit="${esc(c.id)}">Edit</button>` : ''));
      else if (f.tab === 'verify') box.innerHTML = certRows(pend, (c) => (D.can_edit ? ` <button type="button" class="btn sm primary" data-ver="${esc(c.id)}">Verify</button> <button type="button" class="btn sm" data-rej="${esc(c.id)}">Not accept…</button>` : ''));
      else if (f.tab === 'missing') {
        const list = missing.filter((m) => okp({ ...m.p, t: m.t }));
        box.innerHTML = list.length ? `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Person</th><th>Required certificate</th><th></th></tr></thead><tbody>
          ${list.map((m) => `<tr><td><b>${esc(m.p.name)}</b><small class="sub">${esc([m.p.employee_id, m.p.title].filter(Boolean).join(' · '))}</small></td><td>${esc(m.t.label)}</td>
            <td>${D.can_edit ? `<button type="button" class="btn sm" data-addfor="${esc(m.p.person_id)}" data-type="${esc(m.t.code)}">Add…</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
          <p class="muted small">Certificate types marked "required for all staff" (Certificate types tab) that the person does not hold, or that have expired.</p>`
          : '<div class="empty small"><p>Everyone holds the required certificates</p></div>';
      } else if (f.tab === 'trainings') {
        box.innerHTML = `${D.can_edit ? '<div class="btn-row"><button type="button" class="btn primary" data-tr="">+ New training session…</button></div>' : ''}
          ${D.trainings.length ? `<div class="table-wrap"><table class="data click"><thead><tr><th>Training</th><th>Date</th><th>Gives certificate</th><th class="num">Attended</th></tr></thead><tbody>
          ${D.trainings.map((x) => `<tr data-tr="${esc(x.id)}"><td><b>${esc(x.title)}</b><small class="sub">${esc([x.provider, x.location].filter(Boolean).join(' · '))}</small></td>
            <td class="nowrap">${dShort(x.from)}${x.to && x.to !== x.from ? ` – ${dShort(x.to)}` : ''}</td><td>${esc(typeOf(x.cert_type).label || '—')}</td>
            <td class="num">${x.attendees.filter((a) => a.status === 'attended').length} / ${x.attendees.length}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty small"><p>No training sessions yet</p></div>'}`;
      } else {
        box.innerHTML = `<div class="table-wrap"><table class="data"><thead><tr><th>Certificate type</th><th>Valid for</th><th>Required for all staff</th><th>Remind before</th><th></th></tr></thead><tbody>
          ${D.types.map((x) => `<tr class="${x.is_active ? '' : 'muted'}"><td><b>${esc(x.label)}</b>${x.is_active ? '' : ' <span class="tag xs">not used</span>'}</td><td>${x.validity_months ? `${x.validity_months} months` : 'no expiry'}</td>
            <td>${x.required_all ? '<span class="tag warn xs">Required</span>' : '—'}</td><td>${x.remind_days} days</td><td>${D.can_types ? `<button type="button" class="btn sm ghost" data-ctype="${esc(x.code)}">Edit</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
          ${D.can_types ? '<div class="btn-row"><button type="button" class="btn" data-ctype="">+ Add certificate type</button></div>' : ''}`;
      }
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; draw(); }));
      $('#tq', el)?.addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#tq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
      $('#tty', el)?.addEventListener('change', (e) => { f.type = e.target.value; draw(); });
      $('[data-add]', el)?.addEventListener('click', () => certWindow({}));
      $$('[data-addfor]', box).forEach((b) => b.addEventListener('click', () => certWindow({ person_id: b.dataset.addfor, type: b.dataset.type })));
      $$('[data-edit]', box).forEach((b) => b.addEventListener('click', () => certWindow(D.certificates.find((c) => c.id === b.dataset.edit))));
      $$('[data-renew]', box).forEach((b) => b.addEventListener('click', () => { const c = D.certificates.find((x) => x.id === b.dataset.renew); certWindow({ person_id: c.person_id, type: c.type, title: c.title, issuer: c.issuer }); }));
      $$('[data-file]', box).forEach((b) => b.addEventListener('click', () => showCertFile(b.dataset.file)));
      $$('[data-ver]', box).forEach((b) => b.addEventListener('click', async () => { try { await API.rpc('cms_cert_decide', { p_id: b.dataset.ver, p_action: 'verify', p_note: null }); toast('Certificate verified'); reload(); } catch (e) { toast(e.message, 'err'); } }));
      $$('[data-rej]', box).forEach((b) => b.addEventListener('click', async () => {
        const ok = await modal({ title: 'Not accept the certificate', ok: 'Not accept', danger: true, body: '<label class="fld"><span>Reason (the staff member sees it)</span><input name="note" required></label>',
          onOk: async (fm) => { if (!fm.note.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_cert_decide', { p_id: b.dataset.rej, p_action: 'reject', p_note: fm.note.value }); } });
        if (ok) { toast('Sent back to the staff member'); reload(); }
      }));
      $$('[data-tr]', box).forEach((b) => b.addEventListener('click', () => trainingWindow(b.dataset.tr)));
      $$('[data-ctype]', box).forEach((b) => b.addEventListener('click', () => typeWindow(b.dataset.ctype)));
      fitTables();
    };
    const certWindow = async (c) => {
      const doc = { v: null }; const edit = !!c.id;
      const ok = await modal({ title: edit ? `Certificate · ${c.name}` : 'Add certificate', ok: 'Save', wide: true,
        body: `<div class="grid-2 tight">
          <label class="fld"><span>Person</span><select name="person" ${edit ? 'disabled' : ''} required><option value="">Choose…</option>${D.people.map((p) => `<option value="${esc(p.person_id)}" ${p.person_id === c.person_id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
          <label class="fld"><span>Certificate type</span><select name="type" required><option value="">Choose…</option>${D.types.filter((x) => x.is_active || x.code === c.type).map((x) => `<option value="${esc(x.code)}" ${x.code === c.type ? 'selected' : ''}>${esc(x.label)}</option>`).join('')}</select></label>
          <label class="fld"><span>Title / course name</span><input name="title" value="${esc(c.title || '')}"></label><label class="fld"><span>Issued by</span><input name="issuer" value="${esc(c.issuer || '')}"></label>
          <label class="fld"><span>Certificate no.</span><input name="no" value="${esc(c.cert_no || '')}"></label><span></span>
          <label class="fld"><span>Issued on</span><input name="iss" type="date" value="${esc(c.issued_on || '')}"></label>
          <label class="fld"><span>Expires on</span><input name="exp" type="date" value="${esc(c.expires_on || '')}"><small class="muted">Leave empty to count from the type's validity.</small></label>
          ${fileField()}<label class="fld fld-2"><span>Note</span><input name="note" value="${esc(c.note || '')}"></label></div>`,
        onOpen: (w) => wireDoc(w, doc),
        onOk: async (fm) => { const pid = edit ? c.person_id : fm.person.value; if (!pid || !fm.type.value) throw new Error('Choose the person and the certificate type.');
          await API.rpc('cms_cert_save', { p: { id: c.id || null, person_id: pid, type: fm.type.value, title: fm.title.value, issuer: fm.issuer.value, cert_no: fm.no.value,
            issued_on: fm.iss.value || null, expires_on: fm.exp.value || null, file: doc.v, note: fm.note.value } }); } });
      if (ok) { toast('Certificate saved'); reload(); }
    };
    const trainingWindow = async (id) => {
      const x = D.trainings.find((y) => y.id === id) || { attendees: [] }; const inT = new Set(x.attendees.map((a) => a.person_id));
      const ok = await modal({ title: id ? `Training · ${x.title}` : 'New training session', ok: D.can_edit ? 'Save' : null, cancel: 'Close', wide: true,
        body: `<div class="grid-2 tight"><label class="fld fld-2"><span>Training</span><input name="title" required value="${esc(x.title || '')}" ${D.can_edit ? '' : 'disabled'}></label>
          <label class="fld"><span>Provider</span><input name="provider" value="${esc(x.provider || '')}"></label><label class="fld"><span>Location</span><input name="loc" value="${esc(x.location || '')}"></label>
          <label class="fld"><span>From</span><input name="from" type="date" required value="${esc(x.from || '')}"></label><label class="fld"><span>To</span><input name="to" type="date" value="${esc(x.to || '')}"></label>
          <label class="fld"><span>Hours</span><input name="hours" type="number" min="0" step="0.5" value="${esc(x.hours ?? '')}"></label><label class="fld"><span>Cost (RM)</span><input name="cost" data-money inputmode="decimal" value="${x.cost != null ? m2(x.cost) : ''}"></label>
          <label class="fld fld-2"><span>Gives this certificate when attended</span><select name="ct"><option value="">— none —</option>${D.types.filter((t) => t.is_active).map((t) => `<option value="${esc(t.code)}" ${t.code === x.cert_type ? 'selected' : ''}>${esc(t.label)}</option>`).join('')}</select></label></div>
          ${id ? `<h4 class="sec-h">Attendees</h4><div class="table-wrap"><table class="data compact"><tbody>${x.attendees.map((a) => `<tr><td>${esc(a.name)}</td><td>${D.can_edit ? `<select data-att="${esc(a.person_id)}">${['registered', 'attended', 'absent'].map((s) => `<option ${a.status === s ? 'selected' : ''}>${s}</option>`).join('')}</select>` : esc(a.status)}${a.certificate_id ? ' <span class="tag ok xs">certificate added</span>' : ''}</td></tr>`).join('') || '<tr><td class="muted">No one yet</td></tr>'}</tbody></table></div>` : ''}
          ${D.can_edit ? `<label class="fld"><span>Add people</span><select name="add" multiple size="6">${D.people.filter((p) => !inT.has(p.person_id)).map((p) => `<option value="${esc(p.person_id)}">${esc(p.name)}</option>`).join('')}</select><small class="muted">Hold Ctrl (or ⌘) to pick several.</small></label>` : ''}`,
        onOpen: (w) => $$('[data-att]', w).forEach((s) => s.addEventListener('change', async () => {
          try { await API.rpc('cms_training_attend', { p_training: id, p_person: s.dataset.att, p_status: s.value }); toast(s.value === 'attended' && x.cert_type ? 'Attended: certificate added' : 'Saved'); } catch (e) { toast(e.message, 'err'); } })),
        onOk: async (fm) => { if (!fm.title.value.trim() || !fm.from.value) throw new Error('Give the training name and date.');
          await API.rpc('cms_training_save', { p: { id: id || null, title: fm.title.value, provider: fm.provider.value, location: fm.loc.value, from: fm.from.value, to: fm.to.value || null,
            hours: fm.hours.value || null, cost: fm.cost.value ? mval(fm.cost.value) : null, cert_type: fm.ct.value || null, people: [...fm.add.selectedOptions].map((o) => o.value) } }); } });
      if (ok || id) reload();
    };
    const typeWindow = async (code) => {
      const x = D.types.find((y) => y.code === code) || { is_active: true, remind_days: 60, category: 'other' };
      const ok = await modal({ title: code ? `Certificate type · ${x.label}` : 'New certificate type', ok: 'Save',
        body: `<div class="grid-2 tight"><label class="fld fld-2"><span>Name</span><input name="label" required value="${esc(x.label || '')}"></label>
          <label class="fld"><span>Kind</span><select name="cat">${['first_aid', 'childcare', 'food', 'safety', 'licence', 'skills', 'other'].map((c) => `<option ${x.category === c ? 'selected' : ''}>${c}</option>`).join('')}</select></label>
          <label class="fld"><span>Valid for (months; empty = no expiry)</span><input name="months" type="number" min="1" value="${esc(x.validity_months ?? '')}"></label>
          <label class="fld"><span>Remind before expiry (days)</span><input name="remind" type="number" min="1" value="${esc(x.remind_days)}"></label>
          <div class="fld"><label class="chk"><input type="checkbox" name="req" ${x.required_all ? 'checked' : ''}> Required for all active staff</label><label class="chk"><input type="checkbox" name="act" ${x.is_active ? 'checked' : ''}> In use</label></div></div>`,
        onOk: async (fm) => { await API.rpc('cms_cert_type_save', { p: { code: code || null, label: fm.label.value, category: fm.cat.value, validity_months: fm.months.value || null,
          remind_days: fm.remind.value || 60, required_all: fm.req.checked, is_active: fm.act.checked } }); } });
      if (ok) { toast('Certificate type saved'); reload(); }
    };
    draw();
  }

  async function meCertsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="mcert-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_my_certs'); } catch (e) { $('#mcert-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const have = new Set(D.certificates.filter((c) => c.status === 'verified' && c.state !== 'expired').map((c) => c.type));
    const need = D.types.filter((t) => t.required && !have.has(t.code));
    $('#mcert-body', el).innerHTML = `
      ${need.length ? `<div class="warn-box">${icon('clock')}<div><b>Required, not on record:</b> ${need.map((t) => esc(t.label)).join(', ')}. Send a copy if you have it.</div></div>` : ''}
      <section class="card"><div class="card-head"><h3>My certificates</h3><button type="button" class="btn sm primary" id="mc-send">+ Send a certificate…</button></div>
        ${D.certificates.length ? D.certificates.map((c) => `<div class="me-item"><div>${certName(c)}<small class="sub">${c.issued_on ? `Issued ${dShort(c.issued_on)}` : ''}${c.expires_on ? ` · expires ${dShort(c.expires_on)}` : ''}${c.reject_reason ? ` · ${esc(c.reject_reason)}` : ''}</small></div>
          <div class="btn-row">${certTag(c)}${c.has_file ? `<button type="button" class="btn sm ghost" data-file="${esc(c.id)}">${icon('eye')}Copy</button>` : ''}</div></div>`).join('')
          : '<div class="empty small"><p>No certificates on record</p></div>'}</section>
      ${D.trainings.length ? `<section class="card"><div class="card-head"><h3>My training</h3></div>${D.trainings.map((x) => `<div class="me-item"><div><b>${esc(x.title)}</b><small class="sub">${dShort(x.from)}${x.provider ? ` · ${esc(x.provider)}` : ''}${x.hours ? ` · ${esc(String(x.hours))} h` : ''}</small></div><span class="tag ${x.status === 'attended' ? 'ok' : ''} xs">${esc(x.status)}</span></div>`).join('')}</section>` : ''}`;
    $$('[data-file]', el).forEach((b) => b.addEventListener('click', () => showCertFile(b.dataset.file)));
    $('#mc-send', el).addEventListener('click', async () => {
      const doc = { v: null };
      const ok = await modal({ title: 'Send a certificate to HR', ok: 'Send', wide: true,
        body: `<div class="grid-2 tight"><label class="fld fld-2"><span>Certificate type</span><select name="type" required><option value="">Choose…</option>${D.types.map((t) => `<option value="${esc(t.code)}">${esc(t.label)}</option>`).join('')}</select></label>
          <label class="fld"><span>Title / course name</span><input name="title"></label><label class="fld"><span>Issued by</span><input name="issuer"></label>
          <label class="fld"><span>Issued on</span><input name="iss" type="date"></label><label class="fld"><span>Expires on (if any)</span><input name="exp" type="date"></label>
          <label class="fld"><span>Certificate no.</span><input name="no"></label><span></span>${fileField('Photo or PDF of the certificate')}</div>
          <p class="muted small">HR checks it before it is added to your record.</p>`,
        onOpen: (w) => wireDoc(w, doc),
        onOk: async (fm) => { if (!fm.type.value) throw new Error('Choose the certificate type.'); if (!doc.v) throw new Error('Attach a photo or PDF of the certificate.');
          await API.rpc('cms_my_cert_send', { p: { type: fm.type.value, title: fm.title.value, issuer: fm.issuer.value, issued_on: fm.iss.value || null, expires_on: fm.exp.value || null, cert_no: fm.no.value, file: doc.v } }); } });
      if (ok) { toast('Sent to HR'); render(); }
    });
  }
  async function loadCertsPending() { try { state.certsPending = await API.rpc('cms_certs_pending'); drawBell(); } catch (e) { /* reminders only */ } }
  function certTasks() {
    const x = state.certsPending; const t = []; if (!x) return t;
    if (x.mine_expiring && selfOn('certs')) t.push({ ic: 'shield', tone: 'orange', title: `${num(x.mine_expiring)} of your certificates expiring`, sub: 'Renew and send the new copy', href: '#/me/certs' });
    if (x.hr_to_verify) t.push({ ic: 'shield', tone: 'blue', title: `${num(x.hr_to_verify)} certificate${x.hr_to_verify === 1 ? '' : 's'} to verify`, sub: 'Sent by staff', href: '#/training' });
    if (x.hr_expiring) t.push({ ic: 'shield', tone: 'rose', title: `${num(x.hr_expiring)} certificate${x.hr_expiring === 1 ? '' : 's'} expiring within 30 days`, sub: 'Training & Certificates', href: '#/training' });
    if (x.hr_missing) t.push({ ic: 'shield', tone: 'orange', title: `${num(x.hr_missing)} required certificate${x.hr_missing === 1 ? '' : 's'} missing`, sub: 'Required for all staff', href: '#/training' });
    return t;
  }

  // ================================================================ 5d · EMPLOYEE DOCUMENTS, HR LETTERS
  const DOC_TYPES = [['contract', 'Employment contract / LOEC'], ['ic', 'IC / passport copy'], ['certificate', 'Certificate / qualification'], ['letter', 'HR letter (signed copy)'],
    ['bank', 'Bank details'], ['medical', 'Medical'], ['resignation', 'Resignation letter'], ['other', 'Other']];
  const docTypeLbl = (t) => (DOC_TYPES.find((x) => x[0] === t) || [t, t])[1];
  async function openStored(path) {
    try {
      const { data, error } = await API.sb().storage.from('employee-documents').createSignedUrl(path, 300);
      if (error) throw error; window.open(data.signedUrl, '_blank', 'noopener');
    } catch (e) { toast(API.friendly(e), 'err'); }
  }
  async function documentsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="dc-body">${loading()}</div>`;
    let D; const load = async () => { D = await API.rpc('cms_documents', {}); D.people.forEach((r) => upKeys(r, 'name')); D.documents.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#dc-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const f = { q: '', type: 'all', old: false };
    const reload = async () => { const y = pageScroller().scrollTop; try { await load(); } catch (e) { toast(e.message, 'err'); } draw(); requestAnimationFrame(() => { pageScroller().scrollTop = y; }); };
    const draw = () => {
      const t = f.q.trim().toLowerCase();
      const list = D.documents.filter((d) => (f.old || d.current) && (f.type === 'all' || d.type === f.type) && (!t || `${d.name} ${d.employee_id || ''} ${d.label || ''} ${d.file_name || ''}`.toLowerCase().includes(t)));
      const lets = D.letters.filter((l) => l.status === 'issued' && (!t || `${l.name} ${l.title || ''}`.toLowerCase().includes(t)));
      $('#dc-body', el).innerHTML = `<section class="card"><div class="toolbar"><label class="search-in">${icon('search')}<input id="dq" type="search" placeholder="Name, Employee ID or document" value="${esc(f.q)}" aria-label="Search"></label>
          <select id="dty" aria-label="Type"><option value="all">All types</option>${DOC_TYPES.map(([k, l]) => `<option value="${k}" ${f.type === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
          <label class="chk"><input type="checkbox" id="dold" ${f.old ? 'checked' : ''}> Include replaced copies</label>
          ${D.can_edit ? '<button type="button" class="btn sm primary" data-up>+ Upload document…</button>' : ''}</div>
        <div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Person</th><th>Document</th><th>Date</th><th>Expires</th><th>Uploaded</th><th></th></tr></thead><tbody>
          ${list.map((d) => `<tr class="${d.current ? '' : 'muted'}"><td><b>${esc(d.name)}</b><small class="sub">${esc(d.employee_id || '')}</small></td>
            <td><b>${esc(d.label || d.file_name || '—')}</b><small class="sub">${esc(docTypeLbl(d.type))}${d.current ? '' : ' · replaced'}</small></td>
            <td class="nowrap">${d.date ? dShort(d.date) : '—'}</td><td class="nowrap">${d.expiry ? `${dShort(d.expiry)}${daysTo(d.expiry) < 0 ? ' <span class="tag bad xs">expired</span>' : ''}` : '—'}</td>
            <td class="nowrap">${dShort(d.uploaded_at)}</td>
            <td class="nowrap"><button type="button" class="btn sm ghost" data-open="${esc(d.path)}">${icon('eye')}Open</button>${D.can_edit && d.current ? ` <button type="button" class="btn sm ghost" data-rep="${esc(d.id)}">Replace…</button> <button type="button" class="btn sm ghost" data-rm="${esc(d.id)}">Remove…</button>` : ''}</td></tr>`).join('')
          || '<tr><td colspan="6"><div class="empty small"><p>No documents</p></div></td></tr>'}</tbody></table></div>
        ${lets.length ? `<h4 class="sec-h">HR letters issued from the CMS</h4><div class="table-wrap"><table class="data compact"><tbody>${lets.map((l) => `<tr><td><b>${esc(l.name)}</b></td><td>${esc(l.title || l.template)}</td><td class="nowrap">${dShort(l.issued_at)}</td><td><a class="btn sm ghost" href="#/letters?open=${esc(l.id)}">Open</a></td></tr>`).join('')}</tbody></table></div>` : ''}
        <p class="muted small">Files are kept in the employee documents store shared with MEG-EAF V2. Replacing keeps the older copy (tick "Include replaced copies" to see it); removing needs a reason and is logged.</p></section>`;
      $('#dq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#dq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
      $('#dty', el).addEventListener('change', (e) => { f.type = e.target.value; draw(); });
      $('#dold', el).addEventListener('change', (e) => { f.old = e.target.checked; draw(); });
      $$('[data-open]', el).forEach((b) => b.addEventListener('click', () => openStored(b.dataset.open)));
      $('[data-up]', el)?.addEventListener('click', () => uploadWindow({}));
      $$('[data-rep]', el).forEach((b) => b.addEventListener('click', () => { const d = D.documents.find((x) => x.id === b.dataset.rep); uploadWindow({ person_id: d.person_id, type: d.type, label: d.label, replaces: d.id }); }));
      $$('[data-rm]', el).forEach((b) => b.addEventListener('click', async () => {
        const ok = await modal({ title: 'Remove document', ok: 'Remove', danger: true, body: '<label class="fld"><span>Reason</span><input name="r" required></label>',
          onOk: async (fm) => { if (!fm.r.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_document_remove', { p_id: b.dataset.rm, p_reason: fm.r.value }); } });
        if (ok) { toast('Document removed'); reload(); }
      }));
      fitTables();
    };
    const uploadWindow = async (pre) => {
      const ok = await modal({ title: pre.replaces ? 'Replace document' : 'Upload document', ok: 'Upload', wide: true,
        body: `<div class="grid-2 tight"><label class="fld"><span>Person</span><select name="p" ${pre.person_id ? 'disabled' : ''} required><option value="">Choose…</option>${D.people.map((p) => `<option value="${esc(p.person_id)}" ${p.person_id === pre.person_id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
          <label class="fld"><span>Type</span><select name="t">${DOC_TYPES.map(([k, l]) => `<option value="${k}" ${pre.type === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
          <label class="fld fld-2"><span>Name of the document</span><input name="l" value="${esc(pre.label || '')}" placeholder="e.g. Letter of Offer and Employment (signed)"></label>
          <label class="fld"><span>Document date</span><input name="d" type="date"></label><label class="fld"><span>Expires (if any)</span><input name="x" type="date"></label>
          <label class="fld fld-2"><span>File (PDF or picture, 10 MB at most)</span><input name="f" type="file" accept="application/pdf,image/*" required></label>
          <label class="fld fld-2"><span>Note</span><input name="n"></label></div>`,
        onOk: async (fm) => {
          const pid = pre.person_id || fm.p.value; const file = fm.f.files[0];
          if (!pid) throw new Error('Choose the person.'); if (!file) throw new Error('Choose the file.'); if (file.size > 10 * 1024 * 1024) throw new Error('The file is larger than 10 MB.');
          const path = `${pid}/${Date.now()}_${file.name.replace(/[^A-Za-z0-9._-]+/g, '_')}`;
          const { error } = await API.sb().storage.from('employee-documents').upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
          if (error) throw new Error(API.friendly(error));
          await API.rpc('cms_document_add', { p: { person_id: pid, type: fm.t.value, label: fm.l.value || file.name, file_name: file.name, path, mime: file.type, size: file.size,
            date: fm.d.value || null, expiry: fm.x.value || null, note: fm.n.value, replaces: pre.replaces || null } });
        } });
      if (ok) { toast('Document uploaded'); reload(); }
    };
    draw();
  }

  // ---------------------------------------------------------------- HR letters centre
  // Letters: draft → submit → approve (Admin / Super Admin / Director, never the drafter) → issue (HR / Admin / Super Admin / Director).
  // Templates: text (with [b] [i] [u]) or a Word file whose {{placeholders}} are filled inside the .docx, keeping its layout.
  const LONG_KEYS = /(details|areas|objectives|description|expectations|summary|evidence|allegation|particulars|conditions|information|process|findings|correspondence|resources|targets|gaps|actions|instructions|basis|arrangements|considered)/;
  const tplKeys = (body) => [...new Set([...String(body || '').matchAll(/\{\{([a-z0-9_]+)\}\}/g)].map((m) => m[1]))];
  const fillTpl = (body, v) => String(body || '').replace(/\{\{([a-z0-9_]+)\}\}/g, (m, k) => (v[k] != null && String(v[k]).trim() !== '' ? String(v[k]) : m));
  const LETTERHEADS = { MEG: 'assets/letterheads/MEG.jpg', HD: 'assets/letterheads/HD.jpg', ABP: 'assets/letterheads/ABP.jpg', MEH: 'assets/letterheads/MEH.jpg' };
  const DOCX_MIME = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const longDate = (iso) => { const [y, m, d] = String(iso).split('-').map(Number); return y && m && d ? `${d} ${MONTHS[m - 1]} ${y}` : ''; };
  const TPL_ST = { draft: ['Draft', ''], pending: ['Waiting for approval', 'warn'], published: ['Published', 'ok'], rejected: ['Sent back', 'bad'], retired: ['Retired', ''] };
  const LET_ST = { draft: ['Draft', ''], pending_approval: ['Waiting for approval', 'warn'], approved: ['Approved · to issue', 'blue'], issued: ['Issued', 'ok'], void: ['Cancelled', 'bad'] };
  const KINDS = [['text', 'Text'], ['paragraph', 'Paragraph'], ['date', 'Date'], ['money', 'Money (RM)'], ['number', 'Number'], ['percentage', 'Percentage']];
  const SOURCES = [['manual', 'Typed in for each letter'], ['employee', 'From the person’s records'], ['calculation', 'Calculated']];
  function splitAddress(a) {
    const parts = String(a || '').replace(/\.$/, '').split(/\s*[,\n]\s*/).filter(Boolean); if (!parts.length) return {};
    const state = parts.length > 2 ? parts.pop() : ''; let pc = parts.findIndex((p) => /\b\d{5}\b/.test(p)); if (pc < 0) pc = parts.length - 1;
    const town = parts.splice(pc, 1)[0] || ''; const l1 = parts.slice(0, 2).join(', '); const l2 = parts.slice(2).join(', ');
    return { address_line1: l1, address_line2: l2, postcode_town: town, state };
  }
  // [b] [i] [u] → bold / italic / underline; an unfilled {{key}} shows as a red [Label]
  const richLine = (t, labelOf) => esc(t).replace(/\[(\/?)(b|i|u)\]/g, '<$1$2>')
    .replace(/\{\{([a-z0-9_]+)\}\}/g, (m, k) => `<mark class="lt-miss">[${esc(labelOf ? labelOf(k) : k.replace(/_/g, ' '))}]</mark>`);
  function letterSheet(text, co, coCode, labelOf) {
    const c = co || {}; const head = LETTERHEADS[coCode] || LETTERHEADS[c.code];
    const lines = String(text).split('\n').map((ln) => {
      const t = ln.trim(); if (!t) return '<div class="lt-gap"></div>';
      if (/^PRIVATE & CONFIDENTIAL$/i.test(t)) return `<p class="lt-conf">${esc(t)}</p>`;
      if (/^Subject:/i.test(t)) return `<p class="lt-subj">${richLine(t.replace(/^Subject:\s*/i, ''), labelOf)}</p>`;
      return `<p>${richLine(t, labelOf)}</p>`;
    }).join('');
    const top = head ? `<img class="lt-head" src="${esc(asset(head))}" alt="${esc(c.name || coCode || '')} letterhead">`
      : `<div class="doc-head">${c.logo ? `<img class="doc-logo" src="${esc(asset(c.logo))}" alt="">` : ''}<div class="doc-co"><div class="doc-co-name">${esc(c.name || '')}</div>
        <div>${esc([c.registration_no ? `(${c.registration_no})` : null, c.address].filter(Boolean).join(' · '))}</div></div></div>`;
    return `<section class="sheet letter">${top}<div class="lt-body">${lines}</div></section>`;
  }

  // ---- Word (.docx) tools: read, find & replace across styled runs, fill, preview (no document leaves the browser except to our storage)
  let libsP = null;
  const loadLib = (src) => new Promise((ok, no) => { const s = document.createElement('script'); s.src = asset(src); s.onload = ok; s.onerror = () => no(new Error('The Word tools could not be loaded — check the connection and try again.')); document.head.appendChild(s); });
  const wordLibs = () => libsP || (libsP = (async () => { if (!window.JSZip) await loadLib('vendor/jszip.min.js'); if (!window.docx) await loadLib('vendor/docx-preview.min.js'); })().catch((e) => { libsP = null; throw e; }));
  const WNS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const W = {
    parts: /^word\/(document|header\d*|footer\d*|footnotes|endnotes)\.xml$/,
    xml(t) { const d = new DOMParser().parseFromString(t, 'application/xml'); if (d.getElementsByTagName('parsererror').length) throw new Error('This Word file could not be read.'); return d; },
    paras: (d) => Array.from(d.getElementsByTagNameNS(WNS, 'p')),
    texts: (p) => Array.from(p.getElementsByTagNameNS(WNS, 't')),
    ptext: (p) => W.texts(p).map((n) => n.textContent).join(''),
    // replace character ranges of a paragraph, keeping each run's own style (Word often splits one word over several runs)
    splice(p, ranges) {
      const nodes = W.texts(p);
      for (const r of ranges.sort((a, b) => b.start - a.start)) {
        let off = 0; let put = false;
        for (const n of nodes) { const s = n.textContent; const stop = off + s.length;
          if (stop > r.start && off < r.end) { n.textContent = s.slice(0, Math.max(0, r.start - off)) + (put ? '' : r.text) + s.slice(Math.max(0, r.end - off)); n.setAttribute('xml:space', 'preserve'); put = true; }
          off = stop; }
      }
    },
    async zip(bytes) {
      await wordLibs();
      if (!bytes?.byteLength || bytes.byteLength > 10 * 1024 * 1024) throw new Error('Choose a Word .docx file of 10 MB or less.');
      let z; try { z = await window.JSZip.loadAsync(bytes); } catch (e) { throw new Error('This is not a Word .docx file (old .doc files: open in Word and “Save as” .docx).'); }
      if (!z.file('word/document.xml')) throw new Error('This is not a Word .docx file.');
      for (const name of Object.keys(z.files)) {
        if (/vbaProject|embeddings\/|afchunk|altchunk/i.test(name)) throw new Error('Remove macros, embedded files and embedded web content from the Word file first.');
        if (name.endsWith('.rels')) { const d = W.xml(await z.file(name).async('string')); if (Array.from(d.getElementsByTagName('Relationship')).some((r) => r.getAttribute('TargetMode') === 'External')) throw new Error('Remove external links and linked pictures from the Word file (insert pictures instead).'); }
      }
      return z;
    },
    async read(bytes) {
      const z = await W.zip(bytes); const out = [];
      const names = Object.keys(z.files).filter((n) => W.parts.test(n)).sort((a, b) => (a === 'word/document.xml' ? -1 : b === 'word/document.xml' ? 1 : a.localeCompare(b)));
      for (const n of names) { const d = W.xml(await z.file(n).async('string')); W.paras(d).forEach((p) => out.push(W.ptext(p))); }
      const text = out.join('\n'); if (!text.trim()) throw new Error('The Word file has no text.'); if (text.length > 100000) throw new Error('The Word file is too long (100,000 characters at most).');
      const broken = text.replace(/\{\{[a-z0-9_]+\}\}/g, '').match(/\{\{[^}]*\}\}/g);
      return { text, fields: tplKeys(text), broken: broken ? [...new Set(broken)] : [] };
    },
    async edit(bytes, fn) {
      const z = await W.zip(bytes); let count = 0;
      for (const n of Object.keys(z.files).filter((x) => W.parts.test(x))) {
        const d = W.xml(await z.file(n).async('string')); let changed = false;
        W.paras(d).forEach((p) => { const c = fn(p, W.ptext(p), d); if (c) { count += c; changed = true; } });
        if (changed) z.file(n, new XMLSerializer().serializeToString(d));
      }
      return { bytes: await z.generateAsync({ type: 'uint8array', mimeType: DOCX_MIME }), count };
    },
    // pairs: [{find, key}] — every occurrence of the phrase becomes {{key}}
    replace(bytes, pairs) {
      const list = pairs.filter((x) => x.find && x.key).sort((a, b) => b.find.length - a.find.length);
      return W.edit(bytes, (p, text) => {
        const used = []; const ranges = [];
        for (const x of list) { let i = 0; const hay = text.toLowerCase(); const needle = x.find.toLowerCase();
          while ((i = hay.indexOf(needle, i)) >= 0) { const e = i + needle.length;
            const inTag = /\{\{[a-z0-9_]*$/.test(text.slice(0, i)) && /^[a-z0-9_]*\}\}/.test(text.slice(e));
            if (!inTag && !used.some(([s, t]) => i < t && e > s)) { used.push([i, e]); ranges.push({ start: i, end: e, text: `{{${x.key}}}` }); }
            i = e; } }
        if (ranges.length) W.splice(p, ranges); return ranges.length;
      });
    },
    async fill(bytes, values, labelOf) {
      const r = await W.edit(bytes, (p, text, d) => {
        const ranges = [...text.matchAll(/\{\{([a-z0-9_]+)\}\}/g)].map((m) => { const v = values[m[1]]; return { start: m.index, end: m.index + m[0].length, text: v != null && String(v).trim() !== '' ? String(v) : `[${labelOf(m[1])}]` }; });
        if (!ranges.length) return 0; W.splice(p, ranges);
        // typed line breaks become Word line breaks
        W.texts(p).filter((n) => n.textContent.includes('\n')).forEach((n) => { const bits = n.textContent.split(/\r?\n/);
          bits.forEach((b, i) => { if (i) n.parentNode.insertBefore(d.createElementNS(WNS, 'w:br'), n); const t = n.cloneNode(false); t.textContent = b; t.setAttribute('xml:space', 'preserve'); n.parentNode.insertBefore(t, n); }); n.parentNode.removeChild(n); });
        return ranges.length;
      });
      return r.bytes;
    },
    // a plain-text template from the Word file: paragraphs as lines, bold / italic / underline as [b] [i] [u]
    async toText(bytes) {
      const z = await W.zip(bytes); const d = W.xml(await z.file('word/document.xml').async('string'));
      const on = (rPr, tag) => { const x = rPr && Array.from(rPr.childNodes).find((c) => c.localName === tag); if (!x) return false; const v = x.getAttributeNS(WNS, 'val') || x.getAttribute('w:val'); return !(v === '0' || v === 'false' || v === 'none'); };
      return W.paras(d).map((p) => {
        let out = ''; let cur = '';
        Array.from(p.getElementsByTagNameNS(WNS, 'r')).forEach((r) => { const rPr = Array.from(r.childNodes).find((c) => c.localName === 'rPr');
          const t = Array.from(r.getElementsByTagNameNS(WNS, 't')).map((n) => n.textContent).join(''); if (!t) return;
          const st = ['b', 'i', 'u'].filter((g) => on(rPr, g)).join('');
          if (st !== cur) { out += [...cur].reverse().map((g) => `[/${g}]`).join('') + [...st].map((g) => `[${g}]`).join(''); cur = st; }
          out += t; });
        return out + [...cur].reverse().map((g) => `[/${g}]`).join('');
      }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
    },
    // read-only preview in a sandboxed frame (no scripts, no network); unfilled [Label] and raw {{key}} are marked
    async render(bytes, host, opts = {}) {
      await wordLibs(); const box = document.createElement('div');
      await window.docx.renderAsync(bytes, box, box, { useBase64URL: true, renderAltChunks: false, renderComments: false, ignoreLastRenderedPageBreak: false });
      box.querySelectorAll('a').forEach((a) => a.removeAttribute('href'));
      const marks = opts.marks || []; const walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT); const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
      const re = new RegExp(`(\\{\\{[a-z0-9_]+\\}\\}${marks.length ? `|${marks.map((m) => m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')}` : ''})`, 'g');
      nodes.forEach((n) => { if (n.parentElement?.closest('style') || !re.test(n.textContent)) return; re.lastIndex = 0;
        const frag = document.createDocumentFragment(); let at = 0; n.textContent.replace(re, (m, g, i) => { frag.append(document.createTextNode(n.textContent.slice(at, i)));
          const mk = document.createElement('mark'); mk.textContent = m; mk.style.cssText = m.startsWith('{{') ? 'background:#dbeafe;color:#1e40af' : 'background:#fee2e2;color:#991b1b'; frag.append(mk); at = i + m.length; return m; });
        frag.append(document.createTextNode(n.textContent.slice(at))); n.replaceWith(frag); });
      if (opts.stamp) box.querySelectorAll('section.docx').forEach((s) => { const p = document.createElement('p'); p.textContent = opts.stamp; p.style.cssText = 'font:bold 11pt Arial;color:#a00;margin:0 0 6pt'; s.prepend(p); });
      const frame = document.createElement('iframe'); frame.className = 'lw-frame'; frame.title = 'Word letter preview'; frame.setAttribute('sandbox', 'allow-same-origin allow-modals');
      const fit = () => { for (const pg of frame.contentDocument?.querySelectorAll('section.docx') || []) pg.style.zoom = opts.zoom || Math.min(1, (frame.clientWidth - 20) / pg.offsetWidth); };
      frame.onload = () => { fit(); try { frame.style.height = `${Math.max(500, frame.contentDocument.body.scrollHeight + 20)}px`; } catch (e) { /* sizing only */ } };
      frame.srcdoc = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"><style>body{margin:0;background:#e5e7eb}.docx-wrapper{padding:8px!important;background:#e5e7eb!important}section.docx{margin:0 auto 10px!important}@media print{body,.docx-wrapper{background:#fff!important;padding:0!important}section.docx{zoom:1!important;box-shadow:none!important;margin:0!important}mark{background:none!important;color:inherit!important}}</style></head><body>${box.innerHTML}</body></html>`;
      host.replaceChildren(frame);
      return { frame, refit: fit, print: () => frame.contentWindow.print(), selection: () => { try { return String(frame.contentWindow.getSelection() || '').trim(); } catch (e) { return ''; } } };
    },
  };
  const srcBucket = () => API.sb().storage.from('hr-letter-sources');
  async function getDocx(path) { const { data, error } = await srcBucket().download(path); if (error) throw new Error(API.friendly(error)); return new Uint8Array(await data.arrayBuffer()); }
  async function putDocx(folder, bytes, name) {
    const path = `cms/${folder}/${name || (crypto.randomUUID ? crypto.randomUUID() : `${Date.now().toString(16).padStart(8, '0')}-0000-4000-8000-${Math.random().toString(16).slice(2, 14).padEnd(12, '0')}`)}.docx`;
    const { error } = await srcBucket().upload(path, new Blob([bytes], { type: DOCX_MIME }), { contentType: DOCX_MIME, upsert: false });
    if (error) throw new Error(API.friendly(error)); return path;
  }
  const saveBytes = (bytes, name) => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([bytes], { type: DOCX_MIME })); a.download = name; document.body.append(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1500); };
  const fileSafe = (s) => String(s || 'letter').replace(/[^A-Za-z0-9 ._-]+/g, '').trim().replace(/\s+/g, '-');

  const ask = (text, ok) => confirmBox(ok, esc(text), ok);
  async function lettersData(force) { if (force || !state.lettersData) state.lettersData = await API.rpc('cms_letters'); return state.lettersData; }
  async function loadLettersPending() { try { state.lettersPending = await API.rpc('cms_letters_pending'); drawBell(); } catch (e) { /* reminders only */ } }
  function letterTasks() {
    const x = state.lettersPending; const t = []; if (!x) return t;
    if (x.to_approve) t.push({ ic: 'file-check', tone: 'orange', title: `${num(x.to_approve)} HR letter${x.to_approve === 1 ? '' : 's'} to approve`, sub: 'Drafted by HR', href: '#/letters?tab=todo' });
    if (x.to_issue) t.push({ ic: 'file-check', tone: 'blue', title: `${num(x.to_issue)} approved letter${x.to_issue === 1 ? '' : 's'} to issue`, sub: 'HR Letters', href: '#/letters?tab=todo' });
    if (x.sent_back) t.push({ ic: 'file-check', tone: 'rose', title: `${num(x.sent_back)} of your letters sent back`, sub: 'See the reason and correct', href: '#/letters?tab=todo' });
    if (x.templates_to_review) t.push({ ic: 'file-check', tone: 'violet', title: `${num(x.templates_to_review)} letter template${x.templates_to_review === 1 ? '' : 's'} to review`, sub: 'New, changed or to retire', href: '#/letters?tab=templates' });
    return t;
  }

  // new or changed placeholder
  async function placeholderWindow(L, p, preKey) {
    const isNew = !p; let saved = null;
    const ok = await modal({ title: isNew ? 'New placeholder' : `Placeholder {{${p.key}}}`, ok: 'Save', wide: true,
      body: `<div class="grid-2 tight">
          <label class="fld"><span>Name used in templates</span><input name="key" ${isNew ? '' : 'disabled'} value="${esc(p?.key || preKey || '')}" placeholder="e.g. probation_months" pattern="[a-z][a-z0-9_]*" required><small class="muted">lower-case, numbers and _ · written as {{name}}</small></label>
          <label class="fld"><span>Label shown to HR</span><input name="label" required value="${esc(p?.label || '')}" placeholder="e.g. Probation period (months)"></label>
          <label class="fld"><span>Type</span><select name="kind">${KINDS.map(([k, l]) => `<option value="${k}" ${(p?.kind || 'text') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
          <label class="fld"><span>Filled</span><select name="source">${SOURCES.map(([k, l]) => `<option value="${k}" ${(p?.source || 'manual') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
          <label class="fld" data-srckey><span>Record field</span><input name="skey" value="${esc(p?.source_key || '')}" placeholder="e.g. confirmation_date"></label>
          <label class="fld"><span>Default value (optional)</span><input name="def" value="${esc(p?.default || '')}"></label>
          <label class="fld fld-2"><span>Help text (optional)</span><input name="desc" value="${esc(p && p.description !== p.label ? p.description || '' : '')}"></label>
          <div class="fld fld-2 chk-row"><label class="chk"><input type="checkbox" name="req" ${p?.required === false ? '' : 'checked'}> Must be filled before submitting</label>
            <label class="chk"><input type="checkbox" name="edit" ${p?.editable === false ? '' : 'checked'}> HR may change it in a letter</label>
            ${isNew ? '' : `<label class="chk"><input type="checkbox" name="act" ${p.active ? 'checked' : ''}> In use</label>`}</div>
          ${isNew ? '' : '<label class="fld fld-2"><span>Reason for the change</span><input name="why" required maxlength="300"></label>'}</div>`,
      onOpen: (w) => { const sync = () => { $('[data-srckey]', w).hidden = $('select[name=source]', w).value !== 'employee'; }; $('select[name=source]', w).addEventListener('change', sync); sync(); },
      onOk: async (f) => {
        const key = (isNew ? f.key.value : p.key).trim().toLowerCase();
        if (!/^[a-z][a-z0-9_]{0,79}$/.test(key)) throw new Error('The name uses lower-case letters, numbers and _, starting with a letter.');
        if (isNew && L.placeholders.some((x) => x.key === key)) throw new Error(`{{${key}}} already exists.`);
        if (!isNew && !f.why.value.trim()) throw new Error('Give the reason for the change.');
        saved = await API.rpc('cms_letter_placeholder_save', { p: { key, label: f.label.value.trim(), description: f.desc.value.trim(), kind: f.kind.value, source: f.source.value,
          source_key: f.source.value === 'employee' ? f.skey.value.trim() : '', default: f.def.value, required: f.req.checked, editable: f.edit.checked,
          active: isNew ? true : f.act.checked, revision: p?.revision || null, reason: isNew ? null : f.why.value.trim() } });
      } });
    if (ok) { toast(isNew ? `{{${saved}}} created` : 'Placeholder saved'); const fresh = await lettersData(true); L.placeholders = fresh.placeholders; }
    return ok ? saved : null;
  }
  const phOptions = (L, sel, blank = 'Choose…') => `<option value="">${blank}</option>${L.placeholders.filter((p) => p.active).map((p) => `<option value="${esc(p.key)}" ${p.key === sel ? 'selected' : ''}>${esc(p.label)} — {{${esc(p.key)}}}</option>`).join('')}<option value="__new">＋ New placeholder…</option>`;
  const typeList = (L) => L.templates.filter((t) => t.code === t.letter_type && t.status !== 'retired');
  const typeField = (L, sel, allowNew = true) => `<label class="fld"><span>Letter type</span><select name="ltype" required><option value="">Choose…</option>${typeList(L).map((t) => `<option value="${esc(t.code)}" ${t.code === sel ? 'selected' : ''}>${esc(t.title)} (${esc(t.code)})</option>`).join('')}${allowNew ? '<option value="__new">＋ A new letter type…</option>' : ''}</select></label>
      <div class="grid-2 tight" data-newtype hidden><label class="fld"><span>New type code</span><input name="ncode" maxlength="12" placeholder="e.g. LOA" style="text-transform:uppercase"></label><label class="fld"><span>New type name</span><input name="ntitle" placeholder="e.g. Letter of Appointment"></label></div>`;
  const companyField = (sel) => `<label class="fld"><span>Company</span><select name="co"><option value="">Any company</option>${window.CMS_COMPANIES.map((c) => `<option value="${esc(c.code)}" ${c.code === sel ? 'selected' : ''}>${esc(c.short)}</option>`).join('')}</select></label>`;
  const wireTypeField = (w) => { const s = $('select[name=ltype]', w); const box = $('[data-newtype]', w); if (!s || !box) return; const sync = () => { box.hidden = s.value !== '__new'; }; s.addEventListener('change', sync); sync(); };
  const readType = (f) => (f.ltype.value === '__new' ? { new_type: { code: f.ncode.value.trim().toUpperCase(), title: f.ntitle.value.trim() } } : { letter_type: f.ltype.value });

  // ================================================================ HR Letters page
  async function lettersPage(item, el) {
    const q = new URLSearchParams(location.hash.split('?')[1] || '');
    if (q.get('open')) { location.replace(`#/letters?ws=${encodeURIComponent(q.get('open'))}`); return; }
    if (q.get('ws')) return letterWorkspace(item, el, q);
    if (q.get('tpl')) return templateEditor(item, el, q);
    if (q.get('import')) return wordImport(item, el, q);
    document.body.classList.remove('doc-mode');
    el.innerHTML = `${pageHead(item)}<div id="lt-body">${loading()}</div>`;
    let L; const load = async () => { L = await lettersData(true); L.letters.forEach((r) => upKeys(r, 'name')); };
    try { await load(); } catch (e) { $('#lt-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const me = L.me; const todo = () => ({
      approve: L.can_approve ? L.letters.filter((l) => l.status === 'pending_approval' && l.created_by !== me) : [],
      issue: L.can_issue ? L.letters.filter((l) => l.status === 'approved') : [],
      back: L.letters.filter((l) => l.status === 'draft' && l.rejected && l.created_by === me),
      tpls: L.can_publish ? L.templates.filter((t) => t.status === 'pending' || t.pending?.submitted_at || t.retire_request) : [] });
    const T0 = todo(); const nTodo = T0.approve.length + T0.issue.length + T0.back.length + T0.tpls.length;
    const f = { tab: q.get('tab') || (nTodo ? 'todo' : 'issued'), q: '', retired: false };
    const reload = async () => { const y = pageScroller().scrollTop; try { await load(); loadLettersPending(); } catch (e) { toast(e.message, 'err'); } draw(); requestAnimationFrame(() => { pageScroller().scrollTop = y; }); };
    const tag = (m, s) => { const [l, c] = m[s] || [s, '']; return `<span class="tag ${c} xs">${esc(l)}</span>`; };
    const letterRows = (list, when) => (list.length ? `<div class="table-wrap fill"><table class="data freeze2 click"><thead><tr><th>Person</th><th>Letter</th><th>Status</th><th>${when}</th><th></th></tr></thead><tbody>
      ${list.map((l) => `<tr data-ws="${esc(l.id)}"><td><b>${esc(l.name)}</b><small class="sub">${esc(l.employee_id || '')}</small></td><td>${esc(l.title || l.template)}${l.format === 'docx' ? ' <span class="tag xs">Word</span>' : ''}</td>
        <td>${tag(LET_ST, l.status)}${l.rejected && l.status === 'draft' ? '<small class="sub bad-t">sent back</small>' : ''}</td>
        <td class="nowrap">${dShort(l.issued_at || l.approved_at || l.submitted_at || l.created_at)}<small class="sub">${esc(l.issued_by || l.approved_by_name || l.created_by_name || '')}</small></td>
        <td><button type="button" class="btn sm" data-ws="${esc(l.id)}">Open</button></td></tr>`).join('')}</tbody></table></div>` : '<div class="empty small"><p>Nothing here</p></div>');
    const draw = () => {
      const T = todo(); const t = f.q.trim().toLowerCase(); const m = (l) => !t || `${l.name} ${l.title || ''} ${l.employee_id || ''}`.toLowerCase().includes(t);
      const iss = L.letters.filter((l) => l.status === 'issued' && m(l)); const prog = L.letters.filter((l) => ['draft', 'pending_approval', 'approved'].includes(l.status) && m(l));
      const n = T.approve.length + T.issue.length + T.back.length + T.tpls.length;
      const TABS = [['todo', `To do <span>${n}</span>`], ['issued', `Issued <span>${iss.length}</span>`], ['progress', `In progress <span>${prog.length}</span>`], ['templates', `Templates <span>${L.templates.filter((x) => x.status !== 'retired').length}</span>`], ['placeholders', `Placeholders <span>${L.placeholders.filter((x) => x.active).length}</span>`]];
      $('#lt-body', el).innerHTML = `<section class="card"><div class="seg ss-tabs">${TABS.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
        <div class="toolbar"><label class="search-in">${icon('search')}<input id="lq" type="search" placeholder="${f.tab === 'placeholders' ? 'Placeholder name or label' : f.tab === 'templates' ? 'Template' : 'Name or letter'}" value="${esc(f.q)}" aria-label="Search"></label>
          ${f.tab === 'templates' ? `<label class="chk"><input type="checkbox" id="lret" ${f.retired ? 'checked' : ''}> Show retired</label>${L.can_change ? `<button type="button" class="btn sm" data-imp>${icon('plus')}Import from Word…</button><a class="btn sm" href="#/letters?tpl=new">+ New text template</a>` : ''}`
            : f.tab === 'placeholders' ? (L.can_placeholders ? '<button type="button" class="btn sm primary" data-phnew>+ New placeholder…</button>' : '')
            : L.can_edit ? '<a class="btn sm primary" href="#/letters?ws=new">+ New letter</a>' : ''}</div><div id="lt-tab"></div></section>
        <p class="muted small">HR drafts a letter and sends it for approval; Admin, Super Admin or a Director approves it (never the person who drafted it); then HR, Admin, Super Admin or a Director issues it. The approved wording is what gets issued, and every issued letter is kept in the person's records. New and changed templates need approval too, unless made by someone who can approve.</p>`;
      const box = $('#lt-tab', el);
      if (f.tab === 'todo') {
        const sec = (h, list, when) => (list.length ? `<h4 class="sec-h">${h} <span class="muted">${list.length}</span></h4>${letterRows(list.filter(m), when)}` : '');
        box.innerHTML = (sec('Waiting for your approval', T.approve, 'Sent') + sec('Approved — ready to issue', T.issue, 'Approved') + sec('Sent back to you', T.back, 'Drafted')
          + (T.tpls.length ? `<h4 class="sec-h">Templates to review <span class="muted">${T.tpls.length}</span></h4><div class="table-wrap"><table class="data compact"><tbody>${T.tpls.map((x) => `<tr><td><b>${esc(x.title)}</b> <small class="muted">${esc(x.code)}</small><small class="sub">${x.retire_request ? `Retire: ${esc(x.retire_request.reason)} · ${esc(x.retire_request.by_name || '')}` : x.pending?.submitted_at ? `Change: ${esc(x.pending.reason || '')} · ${esc(x.pending.by_name || '')}` : `New ${x.format === 'docx' ? 'Word' : 'text'} template · ${esc(x.created_by_name || '')}`}</small></td><td><button type="button" class="btn sm primary" data-review="${esc(x.code)}">Review…</button></td></tr>`).join('')}</tbody></table></div>` : ''))
          || '<div class="empty small"><p>Nothing waiting for you</p></div>';
      } else if (f.tab === 'issued') box.innerHTML = letterRows(iss, 'Issued');
      else if (f.tab === 'progress') box.innerHTML = letterRows(prog, 'Last step');
      else if (f.tab === 'templates') {
        const list = L.templates.filter((x) => (f.retired || x.status !== 'retired') && (!t || `${x.title} ${x.code} ${x.type_title}`.toLowerCase().includes(t)));
        const groups = new Map(); list.forEach((x) => { const k = x.letter_type; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(x); });
        box.innerHTML = groups.size ? `<div class="table-wrap fill"><table class="data"><thead><tr><th>Template</th><th>Status</th><th>In use</th><th class="num">Issued</th><th></th></tr></thead><tbody>
          ${[...groups.entries()].map(([k, xs]) => `<tr class="grp"><td colspan="5">${esc(xs[0].type_title)} <small class="muted">${esc(k)}</small></td></tr>${xs.map((x) => `<tr>
            <td><b>${esc(x.title)}</b> <small class="muted">${esc(x.code)}</small> ${x.format === 'docx' ? '<span class="tag xs">Word</span>' : '<span class="tag xs">Text</span>'}${x.company ? ` <span class="tag xs">${esc(coShort(x.company) || x.company)}</span>` : ''}
              <small class="sub">${tplKeys(x.body).length} field${tplKeys(x.body).length === 1 ? '' : 's'}${x.created_by_name ? ` · by ${esc(x.created_by_name)}` : ''}${x.reviewed_by_name ? ` · approved by ${esc(x.reviewed_by_name)}` : ''}</small></td>
            <td>${tag(TPL_ST, x.status)}${x.pending?.submitted_at ? '<small class="sub">change waiting for approval</small>' : x.pending ? `<small class="sub">${x.pending.rejected ? 'change sent back' : 'change in draft'}</small>` : ''}${x.retire_request ? '<small class="sub">retirement asked</small>' : ''}${x.status === 'rejected' && x.review_note ? `<small class="sub">${esc(x.review_note)}</small>` : ''}</td>
            <td>${x.status === 'published' ? (L.can_switch ? `<label class="switch" title="Switch on to use for letters"><input type="checkbox" data-on="${esc(x.code)}" ${x.active ? 'checked' : ''}><span></span></label>` : (x.active ? '<span class="tag ok xs">On</span>' : '<span class="tag xs">Off</span>')) : '—'}</td>
            <td class="num">${num(x.used || 0)}</td>
            <td class="nowrap">${x.status === 'published' && x.active && L.can_edit ? `<a class="btn sm" href="#/letters?ws=new&template=${encodeURIComponent(x.code)}">Use</a> ` : ''}
              ${L.can_publish && (x.status === 'pending' || x.pending?.submitted_at || x.retire_request) ? `<button type="button" class="btn sm primary" data-review="${esc(x.code)}">Review…</button> ` : ''}
              ${L.can_change && x.status !== 'retired' ? `<a class="btn sm ghost" href="#/letters?${x.format === 'docx' ? 'import' : 'tpl'}=${encodeURIComponent(x.code)}">Edit</a> ` : ''}
              <button type="button" class="btn sm ghost" data-hist="${esc(x.code)}">History</button>
              ${L.can_change && x.status !== 'retired' && !x.retire_request ? ` <button type="button" class="btn sm ghost" data-retire="${esc(x.code)}">Retire…</button>` : ''}</td></tr>`).join('')}`).join('')}</tbody></table></div>` : '<div class="empty small"><p>No templates</p></div>';
      } else {
        const list = L.placeholders.filter((p) => !t || `${p.key} ${p.label}`.toLowerCase().includes(t));
        box.innerHTML = `<div class="table-wrap fill"><table class="data freeze2"><thead><tr><th>Placeholder</th><th>Label</th><th>Type</th><th>Filled</th><th>Used in</th><th></th></tr></thead><tbody>
          ${list.map((p) => { const used = L.templates.filter((x) => x.status !== 'retired' && x.body.includes(`{{${p.key}}}`)).length;
            return `<tr class="${p.active ? '' : 'muted'}"><td><code>{{${esc(p.key)}}}</code>${p.protected ? ` <span class="lock-ic" title="Protected: filled from the Employee Master">${icon('lock')}</span>` : ''}${p.active ? '' : ' <span class="tag xs">off</span>'}</td>
              <td>${esc(p.label)}${p.required ? '' : ' <small class="muted">optional</small>'}</td><td>${esc((KINDS.find((k) => k[0] === p.kind) || [0, p.kind])[1])}</td>
              <td>${esc((SOURCES.find((k) => k[0] === p.source) || [0, p.source])[1])}${p.source_key ? `<small class="sub">${esc(p.source_key)}</small>` : ''}</td><td class="num">${used} template${used === 1 ? '' : 's'}</td>
              <td>${L.can_placeholders && !p.protected ? `<button type="button" class="btn sm ghost" data-ph="${esc(p.key)}">Edit…</button>` : ''}</td></tr>`; }).join('')}</tbody></table></div>`;
      }
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; f.q = ''; draw(); }));
      $('#lq', el).addEventListener('input', (e) => { f.q = e.target.value; draw(); const i = $('#lq', el); i.focus(); i.setSelectionRange(i.value.length, i.value.length); });
      $('#lret', el)?.addEventListener('change', (e) => { f.retired = e.target.checked; draw(); });
      $$('[data-ws]', box).forEach((b) => b.addEventListener('click', (e) => { e.stopPropagation(); location.hash = `#/letters?ws=${b.dataset.ws}`; }));
      $('[data-imp]', el)?.addEventListener('click', () => { location.hash = '#/letters?import=new'; });
      $('[data-phnew]', el)?.addEventListener('click', async () => { if (await placeholderWindow(L, null)) draw(); });
      $$('[data-ph]', box).forEach((b) => b.addEventListener('click', async () => { if (await placeholderWindow(L, L.placeholders.find((p) => p.key === b.dataset.ph))) draw(); }));
      $$('[data-on]', box).forEach((c) => c.addEventListener('change', async () => {
        try { await API.rpc('cms_letter_template_switch', { p_code: c.dataset.on, p_on: c.checked }); toast(`${c.dataset.on} switched ${c.checked ? 'on' : 'off'}`); reload(); }
        catch (e) { c.checked = !c.checked; toast(e.message, 'err'); } }));
      $$('[data-review]', box).forEach((b) => b.addEventListener('click', async () => { if (await reviewTemplate(L, L.templates.find((x) => x.code === b.dataset.review))) reload(); }));
      $$('[data-hist]', box).forEach((b) => b.addEventListener('click', () => templateHistory(L, b.dataset.hist)));
      $$('[data-retire]', box).forEach((b) => b.addEventListener('click', async () => {
        const x = L.templates.find((y) => y.code === b.dataset.retire); let out = null;
        const ok = await modal({ title: `Retire ${x.title} (${x.code})`, ok: L.can_publish ? 'Retire' : 'Ask to retire', danger: true,
          body: `<p class="muted small">${L.can_publish ? 'It stops being used for new letters; letters already issued are kept.' : 'Admin, Super Admin or a Director approves the retirement.'}</p><label class="fld"><span>Reason</span><input name="r" required></label>`,
          onOk: async (fm) => { if (!fm.r.value.trim()) throw new Error('Give the reason.'); out = await API.rpc('cms_letter_template_retire', { p_code: x.code, p_reason: fm.r.value.trim() }); } });
        if (ok) { toast(out === 'retired' ? 'Template retired' : 'Retirement sent for approval'); reload(); }
      }));
      fitTables();
    };
    draw();
  }

  async function templateHistory(L, code) {
    let H = []; try { H = await API.rpc('cms_letter_template_history', { p_code: code }); } catch (e) { toast(e.message, 'err'); return; }
    const x = L.templates.find((t) => t.code === code);
    await modal({ title: `History · ${x?.title || code}`, ok: '', cancel: 'Close', wide: true,
      body: H.length ? `<ul class="tl-list">${H.map((h) => `<li><b>${dShort(h.at)}</b> · ${esc(h.by || '')}${h.current ? ' <span class="tag ok xs">in use</span>' : ''}<small class="sub">${esc(h.reason || '')}</small>
        <details><summary class="small">Wording</summary><pre class="lt-pre">${esc(h.body)}</pre></details></li>`).join('')}</ul>` : '<p class="muted">No history yet.</p>', onOk: async () => {} });
  }

  async function reviewTemplate(L, x) {
    const what = x.retire_request ? 'retire' : x.pending?.submitted_at ? 'change' : 'new';
    const body = what === 'change' ? x.pending.body : x.body; const fmt = x.format;
    let back = false; let wv = null;
    const ok = await modal({ title: `${what === 'retire' ? 'Retire' : what === 'change' ? 'Changed template' : 'New template'} · ${x.title}`, ok: what === 'retire' ? 'Approve retirement' : 'Approve and publish', wide: true,
      body: `<p class="small">${what === 'retire' ? `<b>${esc(x.retire_request.by_name || '')}</b> asks to retire it: ${esc(x.retire_request.reason)}` : what === 'change' ? `<b>${esc(x.pending.by_name || '')}</b> changed it: ${esc(x.pending.reason || '')}. The current wording stays in use until you approve.` : `Made by <b>${esc(x.created_by_name || '')}</b> · ${fmt === 'docx' ? `Word file ${esc(x.file_name || '')}` : 'text template'}${x.company ? ` · ${esc(coShort(x.company) || x.company)}` : ''}`}</p>
        ${what === 'retire' ? '' : `<p class="muted small">Fields: ${tplKeys(body).map((k) => `<code>{{${esc(k)}}}</code>`).join(' ') || 'none'}</p><div id="rv-prev" class="lt-prev tall">${fmt === 'docx' ? loading() : letterSheet(body, null, x.company, (k) => (L.placeholders.find((p) => p.key === k) || {}).label || k)}</div>`}
        <label class="fld"><span>Note (needed when sending back)</span><input name="note" maxlength="300"></label>
        <div class="btn-row"><button type="button" class="btn danger" data-back>Send back</button></div>`,
      onOpen: async (w) => {
        $('[data-back]', w).addEventListener('click', async () => { const n = $('input[name=note]', w).value.trim(); if (!n) { toast('Write the reason in the note first.', 'err'); return; }
          try { await API.rpc('cms_letter_template_review', { p_code: x.code, p_approve: false, p_note: n }); back = true; toast('Sent back'); $('[data-x]', w).click(); } catch (e) { toast(e.message, 'err'); } });
        if (what !== 'retire' && fmt === 'docx') { try { wv = await W.render(await getDocx(what === 'change' ? x.pending.source_path : x.source_path), $('#rv-prev', w)); } catch (e) { $('#rv-prev', w).innerHTML = errorCard(e.message); } }
      },
      onOk: async (f) => { await API.rpc('cms_letter_template_review', { p_code: x.code, p_approve: true, p_note: f.note.value.trim() || null }); } });
    if (ok) toast(what === 'retire' ? 'Template retired' : 'Template published — switch it on to use it');
    return ok || back;
  }

  // ---------------------------------------------------------------- letter workspace (full page)
  async function letterWorkspace(item, el, q) {
    document.body.classList.remove('doc-mode');
    el.innerHTML = loading();
    let L; try { L = await lettersData(true); } catch (e) { el.innerHTML = errorCard(e.message); wireRetry(el); return; }
    const ph = new Map(L.placeholders.map((p) => [p.key, p])); const labelOf = (k) => ph.get(k)?.label || k.replace(/_/g, ' ');
    const id = q.get('ws') === 'new' ? null : q.get('ws'); const rec = id ? L.letters.find((x) => x.id === id) : null;
    if (id && !rec) { el.innerHTML = errorCard('This letter was not found, or you cannot see it.'); return; }
    const usable = L.templates.filter((t) => t.status === 'published' && t.active);
    const type = q.get('type');
    let code = rec?.template || q.get('template') || (type ? (usable.find((t) => t.code === type) || usable.find((t) => t.letter_type === type))?.code : '') || '';
    let personId = rec?.person_id || q.get('person') || '';
    const appraisal = rec?.appraisal_id || q.get('appraisal') || null;
    const vals = { ...(rec?.fields || {}) }; const status = rec?.status || 'new';
    const editable = (status === 'new' || status === 'draft') && L.can_edit;
    let ctx = null; let co = null; let coCode = null; let srcBytes = null; let srcFor = null; let view = null; let timer = null; let zoom = 'fit';
    const tpl = () => L.templates.find((t) => t.code === code); const person = () => L.people.find((p) => p.person_id === personId);
    const choices = L.templates.filter((t) => (t.status === 'published' && t.active) || t.code === code);
    if (type && !code) toast(`No ${type} template is switched on yet — switch one on under Templates.`, 'err');
    const banner = !rec ? '' : status === 'draft' && rec.rejected ? `<div class="note bad">${icon('help')}<div><b>Sent back by ${esc(rec.rejected.by || '')}</b> · ${dShort(rec.rejected.at)}<br>${esc(rec.rejected.reason)}</div></div>`
      : status === 'pending_approval' ? `<div class="note warn">${icon('clock')}<div><b>Waiting for approval</b> · sent ${dShort(rec.submitted_at)} by ${esc(rec.created_by_name || '')}${L.can_approve && rec.created_by === L.me ? '<br>You drafted it, so someone else must approve it.' : ''}</div></div>`
      : status === 'approved' ? `<div class="note ok">${icon('check-circle')}<div><b>Approved</b> by ${esc(rec.approved_by_name || '')} · ${dShort(rec.approved_at)} — ready to issue.</div></div>`
      : status === 'issued' ? `<div class="note ok">${icon('check-circle')}<div><b>Issued</b> ${dShort(rec.issued_at)} by ${esc(rec.issued_by || '')}${rec.approved_by_name ? ` · approved by ${esc(rec.approved_by_name)}` : ''}. Kept in ${esc(rec.name)}'s records.</div></div>`
      : status === 'void' ? `<div class="note bad">${icon('x')}<div><b>Cancelled</b>${rec.void_reason ? ` · ${esc(rec.void_reason)}` : ''}</div></div>` : '';
    el.innerHTML = `<div class="lw">
      <div class="lw-bar"><a class="btn ghost sm" href="#/letters">‹ HR Letters</a><div class="lw-title"><b>${rec ? esc(`${rec.title || rec.template} · ${rec.name}`) : 'New HR letter'}</b>${rec ? ` <span class="tag ${(LET_ST[status] || [])[1] || ''} xs">${esc((LET_ST[status] || [status])[0])}</span>` : ''}</div><div class="lw-acts" id="lw-acts"></div></div>
      ${banner}
      <div class="lw-grid">
        <section class="card lw-form">
          <div class="fld"><span>Person</span>${editable && !rec ? `<input id="lw-pq" type="search" placeholder="Type to find a name or Employee ID" aria-label="Find person">` : ''}
            <select id="lw-p" ${editable && !rec ? '' : 'disabled'}><option value="">Choose…</option>${L.people.map((p) => `<option value="${esc(p.person_id)}" ${p.person_id === personId ? 'selected' : ''}>${esc(p.name)} · ${esc(p.employee_id || 'no ID')}${p.status === 'former' ? ' (former)' : ''}</option>`).join('')}</select></div>
          <label class="fld"><span>Letter</span><select id="lw-t" ${editable ? '' : 'disabled'}><option value="">Choose…</option>${[...new Set(choices.map((t) => t.type_title))].map((g) => `<optgroup label="${esc(g)}">${choices.filter((t) => t.type_title === g).map((t) => `<option value="${esc(t.code)}" ${t.code === code ? 'selected' : ''}>${esc(t.title)}${t.format === 'docx' ? ' · Word' : ''}${t.company ? ` · ${esc(coShort(t.company) || t.company)}` : ''}</option>`).join('')}</optgroup>`).join('')}</select></label>
          ${!usable.length && editable ? '<p class="small bad-t">No template is switched on yet. Admin switches templates on under HR Letters › Templates.</p>' : ''}
          <div id="lw-fields"></div>
        </section>
        <section class="card lw-pv-card" id="lw-pv-card">
          <div class="lw-pv-bar"><b>Preview</b><span class="muted small" id="lw-pv-st"></span><span class="sp"></span>
            <select id="lw-zoom" aria-label="Zoom"><option value="fit">Fit width</option><option value="0.75">75%</option><option value="1">100%</option><option value="1.25">125%</option></select>
            <button type="button" class="btn sm ghost" id="lw-full">${icon('eye')}Full screen</button></div>
          <div class="lw-pv" id="lw-pv"></div>
        </section>
      </div></div>`;
    const pv = $('#lw-pv', el); const st = $('#lw-pv-st', el);
    const keys = () => tplKeys(tpl()?.body);
    const textNow = () => (status === 'new' || status === 'draft' ? fillTpl(tpl()?.body, vals) : rec.text || fillTpl(tpl()?.body, vals));
    const missing = () => tplKeys(textNow()).filter((k) => ph.get(k)?.required !== false);
    const applyZoom = () => {
      const s = $('.sheet', pv); if (s) s.style.zoom = zoom === 'fit' ? Math.max(0.35, Math.min(1.4, (pv.clientWidth - 24) / 794)) : zoom;
      if (view) { try { view.frame.contentDocument.querySelectorAll('section.docx').forEach((p) => { p.style.zoom = ''; p.style.zoom = zoom === 'fit' ? Math.max(0.35, Math.min(1.4, (view.frame.clientWidth - 24) / (p.offsetWidth || 794))) : zoom; });
        view.frame.style.height = `${Math.max(500, view.frame.contentDocument.body.scrollHeight + 20)}px`; } catch (e) { /* zoom only */ } } };
    const stamp = () => (status === 'issued' ? null : status === 'approved' ? 'APPROVED — NOT YET ISSUED' : missing().length ? 'DRAFT — INCOMPLETE' : 'DRAFT — NOT ISSUED');
    const preview = async () => {
      const t = tpl(); if (!t || !personId) { pv.innerHTML = '<div class="empty small"><p>Choose the person and the letter.</p></div>'; st.textContent = ''; return; }
      const miss = missing(); st.textContent = status === 'issued' ? 'as issued' : miss.length ? `${miss.length} field${miss.length === 1 ? '' : 's'} still to fill (red)` : 'all fields filled';
      if (t.format !== 'docx') { view = null; pv.innerHTML = `${stamp() ? `<div class="lw-stamp">${stamp()}</div>` : ''}${letterSheet(textNow(), co, coCode, labelOf)}`; requestAnimationFrame(applyZoom); return; }
      try {
        let bytes;
        if (status === 'issued' && rec.docx_path) bytes = await getDocx(rec.docx_path);
        else { const path = t.source_path; if (srcFor !== path) { pv.innerHTML = loading(); srcBytes = await getDocx(path); srcFor = path; } bytes = await W.fill(srcBytes, vals, labelOf); }
        view = await W.render(bytes, pv, { marks: missing().map((k) => `[${labelOf(k)}]`), stamp: stamp() }); view.frame.addEventListener('load', () => setTimeout(applyZoom, 30));
      } catch (e) { pv.innerHTML = errorCard(e.message); }
    };
    const later = () => { clearTimeout(timer); timer = setTimeout(preview, tpl()?.format === 'docx' ? 500 : 120); };
    const calc = () => { if (!('basic_increment' in vals) && !keys().includes('basic_increment')) return; const cur = mval(vals.current_basic); const inc = mval(vals.basic_increment);
      if (cur > 0 && !isNaN(inc) && String(vals.basic_increment ?? '').trim() !== '') { vals.basic_increment_pct = (inc / cur * 100).toFixed(2); vals.revised_basic = m2(cur + inc);
        ['basic_increment_pct', 'revised_basic'].forEach((k) => { const i = $(`[data-k="${k}"]`, el); if (i) i.value = vals[k]; }); } };
    const drawFields = () => {
      const box = $('#lw-fields', el); const t = tpl(); if (!t || !personId) { box.innerHTML = ''; return; }
      box.innerHTML = `<h4 class="sec-h">Letter fields</h4>${keys().map((k) => { const p = ph.get(k) || {}; const ro = !editable || p.protected || p.editable === false || p.source === 'calculation';
        const kind = p.kind || (LONG_KEYS.test(k) ? 'paragraph' : 'text'); const v = esc(vals[k] ?? '');
        const inp = kind === 'paragraph' || LONG_KEYS.test(k) ? `<textarea data-k="${k}" rows="3" ${ro ? 'readonly' : ''}>${v}</textarea>`
          : kind === 'date' ? `<span class="lw-dt"><input data-k="${k}" value="${v}" placeholder="e.g. 14 November 2026" ${ro ? 'readonly' : ''}>${ro ? '' : `<input type="date" data-pick="${k}" aria-label="Pick a date for ${esc(p.label || k)}">`}</span>`
          : `<input data-k="${k}" value="${v}" ${kind === 'money' ? 'data-money inputmode="decimal"' : kind === 'number' || kind === 'percentage' ? 'inputmode="decimal"' : ''} ${ro ? 'readonly' : ''}>`;
        return `<label class="fld ${ro ? 'ro' : ''}"><span>${esc(p.label || k.replace(/_/g, ' '))}${p.source === 'employee' || p.protected ? ' <small class="muted">from records</small>' : p.source === 'calculation' ? ' <small class="muted">calculated</small>' : p.required === false ? ' <small class="muted">optional</small>' : ''}</span>${inp}</label>`; }).join('')
        || '<p class="muted small">This letter has no fields to fill.</p>'}
        ${editable && ctx?._home_address ? '<button type="button" class="lnk small" data-addr>Use the saved home address again</button>' : ''}`;
      $$('[data-k]', box).forEach((i) => { i.addEventListener('input', () => { vals[i.dataset.k] = i.value; calc(); later(); }); i.addEventListener('focusout', () => { vals[i.dataset.k] = i.value; calc(); later(); }); });
      $$('[data-pick]', box).forEach((i) => i.addEventListener('change', () => { if (!i.value) return; const k = i.dataset.pick; vals[k] = longDate(i.value); $(`[data-k="${k}"]`, box).value = vals[k]; later(); }));
      $('[data-addr]', box)?.addEventListener('click', () => { Object.assign(vals, splitAddress(ctx._home_address)); drawFields(); later(); });
    };
    const loadCtx = async (fresh) => {
      if (!personId) { ctx = null; drawFields(); preview(); return; }
      try { ctx = await API.rpc('cms_letter_context', { p_person: personId }); } catch (e) { toast(e.message, 'err'); return; }
      co = ctx._company || null; coCode = person()?.company || co?.code || null;
      if (editable) {
        const auto = { ...ctx, ...splitAddress(ctx._home_address) };
        Object.entries(auto).forEach(([k, v]) => { if (!k.startsWith('_') && v != null && v !== '' && (fresh || vals[k] == null || vals[k] === '' || ph.get(k)?.protected)) vals[k] = v; });
        L.placeholders.forEach((p) => { if (p.default && (vals[p.key] == null || vals[p.key] === '')) vals[p.key] = p.default; });
        calc();
      }
      drawFields(); preview();
    };
    // actions
    const acts = [];
    if (editable) acts.push('<button type="button" class="btn" data-a="save">Save draft</button>', '<button type="button" class="btn primary" data-a="submit">Send for approval</button>');
    if (status === 'pending_approval' && L.can_approve && rec.created_by !== L.me) acts.push('<button type="button" class="btn danger" data-a="back">Send back…</button>', '<button type="button" class="btn primary" data-a="approve">Approve</button>');
    if (status === 'approved' && L.can_issue) acts.push('<button type="button" class="btn primary" data-a="issue">Issue letter…</button>');
    if (status === 'issued') { acts.push(`<button type="button" class="btn primary" data-a="print">${icon('download')}Print / PDF</button>`); if (rec.docx_path) acts.push('<button type="button" class="btn" data-a="word">Download Word</button>'); }
    if (rec && ['draft', 'pending_approval', 'approved', 'issued'].includes(status) && L.can_void) acts.push('<button type="button" class="btn ghost" data-a="void">Cancel letter…</button>');
    $('#lw-acts', el).innerHTML = acts.join('');
    const payload = (submit) => { const t = tpl(); return { id: rec?.id || null, person_id: personId, template: t.code, fields: vals, text: fillTpl(t.body, vals), company: co ? { ...co, logo: undefined } : null, appraisal_id: appraisal, submit }; };
    const need = () => { if (!personId || !tpl()) throw new Error('Choose the person and the letter.'); };
    const doIssue = async () => {
      const t = tpl(); let path = null;
      if (t.format === 'docx') { const src = await getDocx(t.source_path); const bytes = await W.fill(src, rec.fields || vals, labelOf); path = await putDocx('issued', bytes, rec.id); }
      await API.rpc('cms_letter_issue', { p_id: rec.id, p_docx_path: path });
    };
    $$('[data-a]', el).forEach((b) => b.addEventListener('click', async () => {
      const a = b.dataset.a;
      try {
        if (a === 'save') { need(); const nid = await API.rpc('cms_letter_save', { p: payload(false) }); toast('Draft saved'); state.lettersData = null; if (!rec) location.hash = `#/letters?ws=${nid}`; return; }
        if (a === 'submit') { need(); const m = missing(); if (m.length) throw new Error(`Fill in: ${m.map(labelOf).join(', ')}.`);
          if (!(await ask('Send this letter for approval? Admin, Super Admin or a Director approves it; you cannot change it while it waits.', 'Send for approval'))) return;
          const nid = await API.rpc('cms_letter_save', { p: payload(true) }); toast('Sent for approval'); state.lettersData = null; loadLettersPending(); location.hash = `#/letters?ws=${nid}`; return; }
        if (a === 'approve') { if (!(await ask('Approve this letter exactly as shown? It can then be issued.', 'Approve'))) return; await API.rpc('cms_letter_decide', { p_id: rec.id, p_approve: true, p_reason: null }); toast('Approved'); loadLettersPending(); render(); return; }
        if (a === 'back') { const ok = await modal({ title: 'Send back to the drafter', ok: 'Send back', danger: true, body: '<label class="fld"><span>What should be changed</span><input name="r" required maxlength="300"></label>',
          onOk: async (f) => { if (!f.r.value.trim()) throw new Error('Say what should be changed.'); await API.rpc('cms_letter_decide', { p_id: rec.id, p_approve: false, p_reason: f.r.value.trim() }); } });
          if (ok) { toast('Sent back'); loadLettersPending(); render(); } return; }
        if (a === 'issue') { if (!(await ask(`Issue this letter to ${rec.name}? It is then locked and kept in their records.`, 'Issue'))) return;
          b.disabled = true; await doIssue(); toast('Letter issued'); state.lettersData = null; loadLettersPending(); render(); return; }
        if (a === 'print') { if (tpl()?.format === 'docx' || rec.docx_path) { view?.print(); return; } docView(el, `${rec.title} · ${rec.name}`, [letterSheet(rec.text, co, coCode, labelOf)], () => render()); return; }
        if (a === 'word') { saveBytes(await getDocx(rec.docx_path), `${fileSafe(rec.title)}-${fileSafe(rec.name)}.docx`); return; }
        if (a === 'void') { const ok = await modal({ title: 'Cancel letter', ok: 'Cancel letter', danger: true, body: `<p class="muted small">${status === 'issued' ? 'The issued letter stays on record, marked as cancelled.' : 'The draft is closed.'}</p><label class="fld"><span>Reason</span><input name="r" required></label>`,
          onOk: async (f) => { if (!f.r.value.trim()) throw new Error('Give the reason.'); await API.rpc('cms_letter_void', { p_id: rec.id, p_reason: f.r.value.trim() }); } });
          if (ok) { toast('Letter cancelled'); state.lettersData = null; location.hash = '#/letters'; } }
      } catch (e) { b.disabled = false; toast(API.friendly ? API.friendly(e) : e.message, 'err'); }
    }));
    const pq = $('#lw-pq', el); const psel = $('#lw-p', el);
    pq?.addEventListener('input', () => { const t = pq.value.trim().toLowerCase(); let first = null; $$('option', psel).forEach((o) => { const hit = !o.value || !t || o.textContent.toLowerCase().includes(t); o.hidden = !hit; if (hit && o.value && !first) first = o; }); if (t && first && psel.value !== first.value) { psel.value = first.value; psel.dispatchEvent(new Event('change')); } });
    psel.addEventListener('change', () => { personId = psel.value; Object.keys(vals).forEach((k) => delete vals[k]); loadCtx(true); });
    $('#lw-t', el).addEventListener('change', (e) => { code = e.target.value; drawFields(); later(); });
    $('#lw-zoom', el).addEventListener('change', (e) => { zoom = e.target.value; applyZoom(); });
    $('#lw-full', el).addEventListener('click', () => { const c = $('#lw-pv-card', el); c.classList.toggle('lw-fullscreen'); $('#lw-full', el).lastChild.textContent = c.classList.contains('lw-fullscreen') ? 'Close full screen' : 'Full screen'; requestAnimationFrame(applyZoom); });
    window.addEventListener('resize', () => { if (zoom === 'fit') applyZoom(); });
    loadCtx(false);
  }

  // ---------------------------------------------------------------- text template editor
  async function templateEditor(item, el, q) {
    document.body.classList.remove('doc-mode');
    el.innerHTML = loading();
    let L; try { L = await lettersData(true); } catch (e) { el.innerHTML = errorCard(e.message); wireRetry(el); return; }
    const code = q.get('tpl'); const t = code === 'new' ? null : L.templates.find((x) => x.code === code);
    if (code !== 'new' && !t) { el.innerHTML = errorCard('Template not found.'); return; }
    if (t?.format === 'docx') { location.replace(`#/letters?import=${encodeURIComponent(t.code)}`); return; }
    const fromWord = q.get('from') === 'word' ? state.wordText : null; state.wordText = null;
    const pend = t?.pending && !t.pending.submitted_at ? t.pending : null;
    const body0 = fromWord?.body ?? pend?.body ?? t?.body ?? 'Date: {{letter_date}}\nPRIVATE & CONFIDENTIAL\n\nTo:\n{{employee_name}}\n{{address_line1}}\n{{address_line2}}\n{{postcode_town}}\n{{state}}\n\nDear {{employee_name}},\n\nSubject: \n\n\n\nYours faithfully,\nFor and on behalf of\n{{company_name}}\n\n\n{{authorized_signatory}}\n{{authorized_designation}}';
    const pub = t?.status === 'published';
    el.innerHTML = `<div class="lw">
      <div class="lw-bar"><a class="btn ghost sm" href="#/letters?tab=templates">‹ Templates</a><div class="lw-title"><b>${t ? `Edit · ${esc(t.title)}` : 'New text template'}</b>${t ? ` <small class="muted">${esc(t.code)}</small> <span class="tag ${TPL_ST[t.status][1]} xs">${TPL_ST[t.status][0]}</span>` : ''}</div>
        <div class="lw-acts"><button type="button" class="btn" data-a="draft">Save draft</button><button type="button" class="btn primary" data-a="submit">${L.can_publish ? 'Publish' : 'Send for approval'}</button></div></div>
      ${pub ? `<div class="note">${icon('help')}<div>This template is published${t.active ? ' and in use' : ''}. Your change ${L.can_publish ? 'takes effect when you publish it' : 'is approved by Admin, Super Admin or a Director'}; until then the current wording stays in use.${t.pending?.rejected ? `<br><b class="bad-t">Last change sent back:</b> ${esc(t.pending.rejected)}` : ''}</div></div>` : t?.status === 'rejected' && t.review_note ? `<div class="note bad">${icon('help')}<div><b>Sent back:</b> ${esc(t.review_note)}</div></div>` : ''}
      <form class="lw-grid" id="te-f" onsubmit="return false">
        <section class="card lw-form">
          <div class="grid-2 tight"><label class="fld fld-2"><span>Template title</span><input name="title" required value="${esc(fromWord?.title || pend?.title || t?.title || '')}" placeholder="e.g. Letter of Confirmation (teachers)"></label>
            ${t ? `<div class="fld"><span>Letter type</span><input disabled value="${esc(t.type_title)} (${esc(t.letter_type)})"></div>` : typeField(L, fromWord?.letter_type || q.get('type') || '')}
            ${companyField(fromWord?.company ?? t?.company ?? '')}</div>
          <div class="te-tools"><button type="button" class="btn sm" data-wrap="b" title="Bold"><b>B</b></button><button type="button" class="btn sm" data-wrap="i" title="Italic"><i>I</i></button><button type="button" class="btn sm" data-wrap="u" title="Underline"><u>U</u></button>
            <span class="sp"></span><select id="te-ph" aria-label="Placeholder to insert">${phOptions(L, '', 'Insert a placeholder…')}</select><button type="button" class="btn sm primary" data-ins>Insert</button></div>
          <textarea name="body" id="te-body" class="te-body" rows="26" spellcheck="true">${esc(body0)}</textarea>
          <p class="muted small">Put the cursor where a detail goes, pick the placeholder and press Insert — it is written as {{name}} and filled for each letter. Select words and press B, I or U for bold, italic or underline. A line starting “Subject:” is printed bold and underlined.</p>
          ${pub ? '<label class="fld"><span>Reason for the change</span><input name="why" maxlength="300" required></label>' : ''}
          <p class="small" id="te-unk"></p>
        </section>
        <section class="card lw-pv-card"><div class="lw-pv-bar"><b>Preview</b><span class="sp"></span><select id="te-person" aria-label="Preview for a person"><option value="">Preview with field names</option>${L.people.filter((p) => p.status !== 'former').map((p) => `<option value="${esc(p.person_id)}">${esc(p.name)}</option>`).join('')}</select></div><div class="lw-pv" id="te-pv"></div></section>
      </form></div>`;
    const f = $('#te-f', el); const ta = $('#te-body', el); wireTypeField(el);
    const labelOf = (k) => (L.placeholders.find((p) => p.key === k) || {}).label || k.replace(/_/g, ' ');
    let pv = {}; let pco = null; let pcode = null;
    const draw = () => { const unk = tplKeys(ta.value).filter((k) => !L.placeholders.some((p) => p.key === k && p.active));
      $('#te-unk', el).innerHTML = unk.length ? `<span class="bad-t">Not in the placeholder list:</span> ${unk.map((k) => `<code>{{${esc(k)}}}</code> <button type="button" class="lnk" data-mk="${esc(k)}">create</button>`).join(' ')}` : '';
      $$('[data-mk]', el).forEach((b) => b.addEventListener('click', async () => { if (await placeholderWindow(L, null, b.dataset.mk)) { $('#te-ph', el).innerHTML = phOptions(L, '', 'Insert a placeholder…'); draw(); } }));
      $('#te-pv', el).innerHTML = letterSheet(fillTpl(ta.value, pv), pco, pcode || f.co.value || t?.company || 'MEG', labelOf); };
    ta.addEventListener('input', draw);
    $$('[data-wrap]', el).forEach((b) => b.addEventListener('click', () => { const g = b.dataset.wrap; const s = ta.selectionStart; const e = ta.selectionEnd; ta.setRangeText(`[${g}]${ta.value.slice(s, e)}[/${g}]`, s, e, 'select'); ta.focus(); draw(); }));
    $('[data-ins]', el).addEventListener('click', async () => { let k = $('#te-ph', el).value; if (!k) { toast('Choose the placeholder first.', 'err'); return; }
      const s = ta.selectionStart; const e = ta.selectionEnd;
      if (k === '__new') { k = await placeholderWindow(L, null); $('#te-ph', el).innerHTML = phOptions(L, '', 'Insert a placeholder…'); if (!k) return; }
      ta.focus(); ta.setRangeText(`{{${k}}}`, s, e, 'end'); draw(); });
    $('#te-person', el).addEventListener('change', async (e) => { pv = {}; pco = null; pcode = null; const pid = e.target.value;
      if (pid) { try { const c = await API.rpc('cms_letter_context', { p_person: pid }); pv = { ...c, ...splitAddress(c._home_address) }; pco = c._company; pcode = (L.people.find((p) => p.person_id === pid) || {}).company; } catch (er) { toast(er.message, 'err'); } }
      draw(); });
    f.co.addEventListener('change', draw);
    $$('[data-a]', el).forEach((b) => b.addEventListener('click', async () => {
      const submit = b.dataset.a === 'submit';
      try {
        if (!f.title.value.trim()) throw new Error('Give the template a title.');
        if (!t && !f.ltype.value) throw new Error('Choose the letter type.');
        if (pub && !f.why.value.trim()) throw new Error('Give the reason for the change.');
        const unk = tplKeys(ta.value).filter((k) => !L.placeholders.some((p) => p.key === k && p.active)); if (unk.length) throw new Error(`Create these placeholders first: ${unk.join(', ')}.`);
        if (submit && !(await ask(L.can_publish ? 'Publish this template? Switch it on afterwards to use it for letters.' : 'Send this template for approval?', L.can_publish ? 'Publish' : 'Send'))) return;
        const c = await API.rpc('cms_letter_template_save', { p: { code: t?.code || null, ...(t ? {} : readType(f)), title: f.title.value.trim(), format: 'text', body: ta.value, company: f.co.value, reason: pub ? f.why.value.trim() : (fromWord ? 'Converted from a Word file' : null), submit } });
        toast(submit ? (L.can_publish ? `${c} published` : `${c} sent for approval`) : `${c} saved as a draft`); state.lettersData = null; loadLettersPending();
        location.hash = '#/letters?tab=templates';
      } catch (e) { toast(e.message, 'err'); }
    }));
    draw();
  }

  // ---------------------------------------------------------------- Word import / Word template editor
  async function wordImport(item, el, q) {
    document.body.classList.remove('doc-mode');
    el.innerHTML = loading();
    let L; try { L = await lettersData(true); } catch (e) { el.innerHTML = errorCard(e.message); wireRetry(el); return; }
    const code = q.get('import'); const t = code === 'new' ? null : L.templates.find((x) => x.code === code);
    if (code !== 'new' && !t) { el.innerHTML = errorCard('Template not found.'); return; }
    const pub = t?.status === 'published';
    const labelOf = (k) => (L.placeholders.find((p) => p.key === k) || {}).label || k.replace(/_/g, ' ');
    let bytes = null; let info = null; let fileName = t?.pending?.file_name || t?.file_name || ''; let view = null; let rows = []; let who = null; let changed = false;
    el.innerHTML = `<div class="lw">
      <div class="lw-bar"><a class="btn ghost sm" href="#/letters?tab=templates">‹ Templates</a><div class="lw-title"><b>${t ? `Edit Word template · ${esc(t.title)}` : 'Import a letter from Word'}</b>${t ? ` <small class="muted">${esc(t.code)}</small> <span class="tag ${TPL_ST[t.status][1]} xs">${TPL_ST[t.status][0]}</span>` : ''}</div>
        <div class="lw-acts"><button type="button" class="btn" data-a="draft">Save draft</button><button type="button" class="btn primary" data-a="submit">${L.can_publish ? 'Publish' : 'Send for approval'}</button></div></div>
      ${pub ? `<div class="note">${icon('help')}<div>This template is published. Your change ${L.can_publish ? 'takes effect when you publish it' : 'is approved by Admin, Super Admin or a Director'}; until then the current file stays in use.</div></div>` : ''}
      <form class="lw-grid" id="wi-f" onsubmit="return false">
        <section class="card lw-form">
          <h4 class="sec-h">1 · The Word file</h4>
          <label class="fld"><span>${t ? 'Replace with another Word file (optional)' : 'Word file (.docx, 10 MB at most)'}</span><input type="file" name="file" accept=".docx,${DOCX_MIME}" ${t ? '' : 'required'}></label>
          <div class="grid-2 tight"><label class="fld fld-2"><span>Template title</span><input name="title" required value="${esc(t?.pending?.title || t?.title || '')}" placeholder="e.g. Letter of Confirmation (Happy Dino)"></label>
            ${t ? `<div class="fld"><span>Letter type</span><input disabled value="${esc(t.type_title)} (${esc(t.letter_type)})"></div>` : typeField(L, q.get('type') || '')}${companyField(t?.company || '')}</div>
          <div id="wi-scan"></div>
          <div id="wi-manual"></div>
          ${pub ? '<label class="fld"><span>Reason for the change</span><input name="why" maxlength="300" required></label>' : ''}
          <fieldset class="fld"><legend>Save as</legend><label class="radio"><input type="radio" name="keep" value="word" checked> Keep the Word layout (recommended) — letters are filled inside this Word file</label>
            ${t ? '' : '<label class="radio"><input type="radio" name="keep" value="text"> Convert to a text template — bold, italic, underline and line breaks are kept; tables, pictures and page layout are not</label>'}</fieldset>
        </section>
        <section class="card lw-pv-card"><div class="lw-pv-bar"><b>Preview</b><span class="muted small" id="wi-st">blue = placeholder</span></div><div class="lw-pv" id="wi-pv"><div class="empty small"><p>${t ? 'Loading…' : 'Choose the Word file.'}</p></div></div></section>
      </form></div>`;
    const f = $('#wi-f', el); wireTypeField(el); const pv = $('#wi-pv', el);
    const show = async () => { try { view = await W.render(bytes, pv); } catch (e) { pv.innerHTML = errorCard(e.message); } };
    const drawManual = () => {
      const unk = info.fields.filter((k) => !L.placeholders.some((p) => p.key === k && p.active));
      $('#wi-manual', el).innerHTML = `<h4 class="sec-h">3 · Make a placeholder yourself</h4>
        <p class="muted small">Type (or select in the preview and press “Use selected text”) a word or phrase in the letter, then choose the placeholder it becomes. Every place it appears is changed.</p>
        <div class="wi-mk"><input id="wi-find" placeholder="Text in the letter, e.g. 1 November 2026"><button type="button" class="btn sm ghost" data-sel>Use selected text</button>
          <select id="wi-key">${phOptions(L, '')}</select><button type="button" class="btn sm primary" data-mkph>Make placeholder</button></div>
        <p class="small">Placeholders in this file: ${info.fields.length ? info.fields.map((k) => `<code class="${unk.includes(k) ? 'bad-t' : ''}">{{${esc(k)}}}</code>`).join(' ') : '<span class="muted">none yet</span>'}</p>
        ${unk.length ? `<p class="small bad-t">Not in the placeholder list: ${unk.map((k) => `<code>{{${esc(k)}}}</code> <button type="button" class="lnk" data-mk="${esc(k)}">create</button>`).join(' ')}</p>` : ''}
        ${info.broken.length ? `<p class="small bad-t">Placeholders written wrongly (use lower-case letters, numbers and _): ${info.broken.map(esc).join(', ')}</p>` : ''}`;
      $('[data-sel]', el).addEventListener('click', () => { const s = view?.selection(); if (!s) { toast('Select some words in the preview first.', 'err'); return; } $('#wi-find', el).value = s; });
      $('#wi-key', el).addEventListener('change', async (e) => { if (e.target.value === '__new') { const k = await placeholderWindow(L, null); drawManual(); if (k) $('#wi-key', el).value = k; } });
      $('[data-mkph]', el).addEventListener('click', async () => { const find = $('#wi-find', el).value.trim(); const key = $('#wi-key', el).value;
        if (!find || !key || key === '__new') { toast('Type the text and choose the placeholder.', 'err'); return; }
        try { const r = await W.replace(bytes, [{ find, key }]); if (!r.count) { toast('That text was not found in the letter (check spelling and spaces).', 'err'); return; }
          bytes = r.bytes; info = await W.read(bytes); changed = true; toast(`${r.count} place${r.count === 1 ? '' : 's'} changed to {{${key}}}`); $('#wi-find', el).value = ''; drawScan(); drawManual(); show(); } catch (e) { toast(e.message, 'err'); } });
      $$('[data-mk]', el).forEach((b) => b.addEventListener('click', async () => { if (await placeholderWindow(L, null, b.dataset.mk)) drawManual(); }));
    };
    // scan: who is it for, then their details and common patterns
    const findAll = (text, needle) => { const out = []; if (!needle || String(needle).trim().length < 2) return out; const h = text.toLowerCase(); const n = String(needle).toLowerCase(); let i = 0; while ((i = h.indexOf(n, i)) >= 0) { out.push(text.slice(i, i + n.length)); i += n.length; } return out; };
    const scan = (text, c) => {
      const out = new Map(); const add = (find, key, why) => { if (!find || out.has(find.toLowerCase()) || /^\{\{/.test(find)) return; out.set(find.toLowerCase(), { find, key, why, n: findAll(text, find).length, on: !!key }); };
      if (c) {
        const v = { ...c, ...splitAddress(c._home_address) };
        const money = (x) => { const n = mval(x); if (!n) return []; const s = m2(n); return [`RM ${s}`, `RM${s}`, s, n.toFixed(2), String(Math.round(n) === n ? n : n.toFixed(2))]; };
        const order = ['employee_name', 'employee_id', 'company_name', 'current_position', 'position', 'current_department', 'department', 'confirmation_date', 'current_probation_end_date', 'revised_probation_end_date', 'last_working_day', 'resignation_date',
          'current_manager', 'authorized_signatory', 'authorized_designation', 'address_line1', 'address_line2', 'postcode_town', 'state'];
        if (v._home_address && findAll(text, v._home_address).length) add(findAll(text, v._home_address)[0], 'address_line1', 'their home address');
        order.forEach((k) => { if (!v[k] || !L.placeholders.some((p) => p.key === k && p.active)) return; const hit = findAll(text, v[k])[0]; if (hit) add(hit, k, `their ${labelOf(k).toLowerCase()}`); });
        if (v.current_basic) { const hit = money(v.current_basic).map((s) => findAll(text, s)[0]).find(Boolean); if (hit) add(hit, 'current_basic', 'their basic salary'); }
      }
      window.CMS_COMPANIES.forEach((x) => { [x.name, x.name.replace('MyEden', 'Myeden')].forEach((nm) => { const hit = findAll(text, nm)[0]; if (hit) add(hit, 'company_name', 'a company name'); }); });
      const dates = [...text.matchAll(new RegExp(`\\b\\d{1,2}(?:st|nd|rd|th)?\\s+(?:${MONTHS.join('|')})\\s+\\d{4}\\b|\\b\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{4}\\b`, 'gi'))].map((m) => m[0]);
      dates.forEach((d, i) => add(d, i === 0 && /^\s*(date\s*:?)?\s*$/i.test(text.slice(Math.max(0, text.indexOf(d) - 12), text.indexOf(d)).split('\n').pop()) ? 'letter_date' : '', i === 0 ? 'a date (the first one is often the letter date)' : 'a date'));
      [...text.matchAll(/RM\s?\d[\d,]*(?:\.\d{2})?/g)].forEach((m) => add(m[0], '', 'an amount of money'));
      return [...out.values()];
    };
    const drawScan = () => {
      const people = L.people.map((p) => ({ p, s: (findAll(info.text, p.name).length ? 2 : 0) + (p.employee_id && findAll(info.text, p.employee_id).length ? 2 : 0) })).filter((x) => x.s).sort((a, b) => b.s - a.s).slice(0, 4);
      $('#wi-scan', el).innerHTML = `<h4 class="sec-h">2 · Turn the filled-in details into placeholders</h4>
        <div class="fld"><span>Who was this letter written for?</span>
          ${people.length ? people.map(({ p, s }) => `<label class="radio"><input type="radio" name="who" value="${esc(p.person_id)}" ${who === p.person_id ? 'checked' : ''}> ${esc(p.name)} · ${esc(p.employee_id || '')} <small class="muted">${s >= 4 ? 'name and ID found' : 'found in the letter'}</small></label>`).join('') : '<p class="muted small">No staff name or Employee ID was found in the letter.</p>'}
          <label class="radio"><input type="radio" name="who" value="__other" ${who && !people.some((x) => x.p.person_id === who) ? 'checked' : ''}> Someone else: <select id="wi-other"><option value="">Choose…</option>${L.people.map((p) => `<option value="${esc(p.person_id)}" ${p.person_id === who ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
          <label class="radio"><input type="radio" name="who" value="" ${who ? '' : 'checked'}> Nobody — only look for company names, dates and amounts</label></div>
        <div id="wi-rows">${rows.length ? `<div class="table-wrap"><table class="data compact"><thead><tr><th></th><th>Found in the letter</th><th>Becomes</th></tr></thead><tbody>
          ${rows.map((r, i) => `<tr><td><input type="checkbox" data-on="${i}" ${r.on ? 'checked' : ''} aria-label="Convert"></td><td><b>${esc(r.find)}</b>${r.n > 1 ? ` <small class="muted">×${r.n}</small>` : ''}<small class="sub">${esc(r.why)}</small></td><td><select data-key="${i}">${phOptions(L, r.key)}</select></td></tr>`).join('')}</tbody></table></div>
          <div class="btn-row"><button type="button" class="btn primary sm" data-conv>Convert the ticked items</button></div>` : '<p class="muted small">Nothing left to convert automatically. Use “Make a placeholder yourself” for anything else.</p>'}</div>`;
      const pick = async () => { const v = $('input[name=who]:checked', el)?.value; who = v === '__other' ? $('#wi-other', el).value || null : v || null; let c = null;
        if (who) { try { c = await API.rpc('cms_letter_context', { p_person: who }); } catch (e) { toast(e.message, 'err'); } }
        rows = scan(info.text, c); drawScan(); };
      $$('input[name=who]', el).forEach((r) => r.addEventListener('change', pick)); $('#wi-other', el).addEventListener('change', () => { $('input[name=who][value="__other"]', el).checked = true; pick(); });
      $$('[data-on]', el).forEach((c) => c.addEventListener('change', () => { rows[c.dataset.on].on = c.checked; }));
      $$('[data-key]', el).forEach((s) => s.addEventListener('change', async () => { const i = s.dataset.key; if (s.value === '__new') { const k = await placeholderWindow(L, null); rows[i].key = k || ''; drawScan(); drawManual(); return; } rows[i].key = s.value; rows[i].on = !!s.value; $(`[data-on="${i}"]`, el).checked = rows[i].on; }));
      $('[data-conv]', el)?.addEventListener('click', async () => { const sel = rows.filter((r) => r.on); if (sel.some((r) => !r.key)) { toast('Choose the placeholder for every ticked item.', 'err'); return; } if (!sel.length) { toast('Tick at least one item.', 'err'); return; }
        try { const r = await W.replace(bytes, sel); bytes = r.bytes; info = await W.read(bytes); changed = true; toast(`${r.count} place${r.count === 1 ? '' : 's'} converted`); rows = rows.filter((x) => !x.on); drawScan(); drawManual(); show(); } catch (e) { toast(e.message, 'err'); } });
    };
    const loadBytes = async (b, name) => { bytes = b; info = await W.read(bytes); fileName = name || fileName;
      if (!f.title.value.trim() && name) f.title.value = name.replace(/\.docx$/i, '').replace(/[_-]+/g, ' ');
      who = null; rows = scan(info.text, null); const ppl = L.people.map((p) => ({ p, s: (findAll(info.text, p.name).length ? 2 : 0) + (p.employee_id && findAll(info.text, p.employee_id).length ? 2 : 0) })).filter((x) => x.s).sort((a, b2) => b2.s - a.s);
      drawScan(); drawManual(); await show();
      if (ppl.length) { $(`input[name=who][value="${ppl[0].p.person_id}"]`, el).checked = true; $(`input[name=who][value="${ppl[0].p.person_id}"]`, el).dispatchEvent(new Event('change')); } };
    f.file.addEventListener('change', async () => { const file = f.file.files[0]; if (!file) return;
      try { if (!/\.docx$/i.test(file.name)) throw new Error('Choose a Word .docx file (old .doc files: open in Word and “Save as” .docx).'); await loadBytes(new Uint8Array(await file.arrayBuffer()), file.name); changed = true; }
      catch (e) { f.file.value = ''; toast(e.message, 'err'); } });
    if (t) { try { await loadBytes(await getDocx(t.pending?.source_path || t.source_path), t.pending?.file_name || t.file_name); } catch (e) { pv.innerHTML = errorCard(e.message); } }
    $$('[data-a]', el).forEach((b) => b.addEventListener('click', async () => {
      const submit = b.dataset.a === 'submit';
      try {
        if (!bytes) throw new Error('Choose the Word file first.');
        if (!f.title.value.trim()) throw new Error('Give the template a title.');
        if (!t && !f.ltype.value) throw new Error('Choose the letter type.');
        if (pub && !f.why.value.trim()) throw new Error('Give the reason for the change.');
        if (info.broken.length) throw new Error(`Fix the placeholders written wrongly: ${info.broken.join(', ')}.`);
        const unk = info.fields.filter((k) => !L.placeholders.some((p) => p.key === k && p.active)); if (unk.length) throw new Error(`Create these placeholders first: ${unk.join(', ')}.`);
        if ($('input[name=keep]:checked', el)?.value === 'text') { state.wordText = { body: await W.toText(bytes), title: f.title.value.trim(), letter_type: f.ltype.value === '__new' ? '' : f.ltype.value, company: f.co.value }; location.hash = '#/letters?tpl=new&from=word'; return; }
        if (!info.fields.length && !(await ask('This letter has no placeholders yet, so every letter would be identical. Save anyway?', 'Save anyway'))) return;
        if (submit && !(await ask(L.can_publish ? 'Publish this Word template? Switch it on afterwards to use it for letters.' : 'Send this Word template for approval?', L.can_publish ? 'Publish' : 'Send'))) return;
        b.disabled = true;
        const path = !t || changed ? await putDocx('templates', bytes) : (t.pending?.source_path || t.source_path);
        const c = await API.rpc('cms_letter_template_save', { p: { code: t?.code || null, ...(t ? {} : readType(f)), title: f.title.value.trim(), format: 'docx', body: info.text, company: f.co.value,
          source_path: path, file_name: fileName, reason: pub ? f.why.value.trim() : 'Imported from Word', submit } });
        toast(submit ? (L.can_publish ? `${c} published` : `${c} sent for approval`) : `${c} saved as a draft`); state.lettersData = null; loadLettersPending();
        location.hash = '#/letters?tab=templates';
      } catch (e) { b.disabled = false; toast(e.message, 'err'); }
    }));
  }

  // ================================================================ 5e · REPORTS & ANALYTICS
  // Charts are inline SVG: one y-axis, thin bars with a 2px gap, rounded data ends, a legend for 2+ series, hover tooltips,
  // and a table view under every chart. Company colours follow the company (never its rank).
  const VZ_CO = ['MEG', 'MEH', 'HD', 'ABP'];
  const vzColor = (key, keys) => { const i = VZ_CO.indexOf(key); return i >= 0 ? `var(--vz-${i + 1})` : `var(--vz-${Math.min(4, keys.indexOf(key) + 1)})`; };
  const niceMax = (v) => { if (!(v > 0)) return 1; const p = 10 ** Math.floor(Math.log10(v)); const m = v / p; return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p; };
  const ymLabel = (ym) => { const [y, m] = ym.split('-').map(Number); return `${MONTHS[m - 1].slice(0, 3)} ${String(y).slice(2)}`; };
  const compact = (v) => (Math.abs(v) >= 1e6 ? `${(v / 1e6).toFixed(1)}m` : Math.abs(v) >= 1e4 ? `${Math.round(v / 1e3)}k` : Math.abs(v) >= 1e3 ? `${(v / 1e3).toFixed(1)}k` : String(Math.round(v * 10) / 10));
  // stacked / single vertical bars: cats = labels, series = [{key, label, values[]}]
  function vzBars({ cats, series, fmt = num, h = 240, colors }) {
    const W = Math.max(900, cats.length * 46 + 60); const L = 48; const B = 26; const T = 10; const ih = h - B - T; const iw = W - L - 8;
    const tot = cats.map((_, i) => series.reduce((a, s) => a + (s.values[i] || 0), 0)); const int = fmt === num;
    const max = int ? Math.max(4, Math.ceil(niceMax(Math.max(...tot, 0)) / 4) * 4) : niceMax(Math.max(...tot, 0));
    const bw = Math.min(34, iw / cats.length - 8); const step = iw / cats.length; const every = Math.ceil(cats.length / 14);
    const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * max);
    let svg = `<svg class="vz-svg" viewBox="0 0 ${W} ${h}" role="img" preserveAspectRatio="xMinYMin meet">`;
    ticks.forEach((t) => { const y = T + ih - (t / max) * ih; svg += `<line class="vz-grid" x1="${L}" x2="${W - 8}" y1="${y}" y2="${y}"/><text class="vz-tick" x="${L - 6}" y="${y + 4}" text-anchor="end">${esc(compact(t))}</text>`; });
    cats.forEach((c, i) => {
      const x = L + i * step + (step - bw) / 2; let y0 = T + ih; const segs = series.map((s) => ({ s, v: s.values[i] || 0 })).filter((z) => z.v > 0);
      segs.forEach(({ s, v }, k) => { const hh = (v / max) * ih; const top = k === segs.length - 1; const y = y0 - hh; const gap = k ? 2 : 0;
        const rh = Math.max(0, hh - gap); const r = top ? Math.min(4, rh / 2, bw / 2) : 0;
        const d = r ? `M${x},${y0 - gap} V${y + r} Q${x},${y} ${x + r},${y} H${x + bw - r} Q${x + bw},${y} ${x + bw},${y + r} V${y0 - gap} Z` : `M${x},${y0 - gap} V${y} H${x + bw} V${y0 - gap} Z`;
        svg += `<path class="vz-mark" d="${d}" fill="${colors ? colors(s.key) : 'var(--vz-1)'}" data-tip="${esc(`${c}|${s.label}|${fmt(v)}|${series.length > 1 ? fmt(tot[i]) : ''}`)}" tabindex="0"/>`; y0 = y; });
      if (i % every === 0 || i === cats.length - 1) svg += `<text class="vz-tick" x="${L + i * step + step / 2}" y="${h - 8}" text-anchor="middle">${esc(c)}</text>`;
    });
    svg += `<line class="vz-axis" x1="${L}" x2="${W - 8}" y1="${T + ih}" y2="${T + ih}"/></svg>`;
    const legend = series.length > 1 ? `<div class="vz-legend">${series.map((s) => `<span><i style="background:${colors ? colors(s.key) : 'var(--vz-1)'}"></i>${esc(s.label)}</span>`).join('')}</div>` : '';
    const table = `<details class="vz-table"><summary>Table</summary><div class="table-wrap"><table class="data compact"><thead><tr><th></th>${series.map((s) => `<th class="num">${esc(s.label)}</th>`).join('')}${series.length > 1 ? '<th class="num">Total</th>' : ''}</tr></thead><tbody>
      ${cats.map((c, i) => `<tr><td>${esc(c)}</td>${series.map((s) => `<td class="num">${fmt(s.values[i] || 0)}</td>`).join('')}${series.length > 1 ? `<td class="num"><b>${fmt(tot[i])}</b></td>` : ''}</tr>`).join('')}</tbody></table></div></details>`;
    return `${legend}<div class="vz-wrap"><div class="vz-scroll">${svg}</div><div class="vz-tip" hidden></div></div>${table}`;
  }
  // horizontal bars with the value written at the end of each bar
  function vzHBars(rows, fmt = num, color = 'var(--vz-1)') {
    if (!rows.length) return '<div class="empty small"><p>No data</p></div>';
    const max = Math.max(...rows.map((r) => r.value), 1);
    return `<ul class="vz-hbars">${rows.map((r) => `<li data-tip="${esc(`${r.label}||${fmt(r.value)}${r.note ? ` · ${r.note}` : ''}|`)}" tabindex="0"><span class="vz-hl">${esc(r.label)}</span><span class="vz-ht"><i style="width:${r.value > 0 ? Math.max(1.5, (r.value / max) * 100) : 0}%;background:${r.color || color}"></i><b>${fmt(r.value)}</b>${r.note ? `<small>${esc(r.note)}</small>` : ''}</span></li>`).join('')}</ul>`;
  }
  function wireTips(root) {
    $$('.vz-wrap, .vz-hbars', root).forEach((wrap) => {
      const host = wrap.classList.contains('vz-wrap') ? wrap : wrap.parentElement; let tip = $('.vz-tip', host);
      if (!tip) { tip = document.createElement('div'); tip.className = 'vz-tip'; tip.hidden = true; host.style.position = 'relative'; host.appendChild(tip); }
      const show = (el, ev) => { const [cat, ser, val, tot] = el.dataset.tip.split('|'); tip.replaceChildren();
        const b = document.createElement('b'); b.textContent = val; const s1 = document.createElement('span'); s1.textContent = ser ? `${ser} · ${cat}` : cat; tip.append(b, s1);
        if (tot) { const s2 = document.createElement('small'); s2.textContent = `Total ${tot}`; tip.append(s2); }
        tip.hidden = false; const hr = host.getBoundingClientRect(); const r = el.getBoundingClientRect();
        const x = (ev && ev.clientX ? ev.clientX : r.left + r.width / 2) - hr.left; const y = r.top - hr.top;
        tip.style.left = `${Math.min(Math.max(8, x - tip.offsetWidth / 2), hr.width - tip.offsetWidth - 8)}px`; tip.style.top = `${Math.max(0, y - tip.offsetHeight - 8)}px`; };
      $$('[data-tip]', wrap).forEach((el) => { el.addEventListener('pointermove', (e) => show(el, e)); el.addEventListener('focus', () => show(el)); el.addEventListener('pointerleave', () => { tip.hidden = true; }); el.addEventListener('blur', () => { tip.hidden = true; }); });
    });
  }

  async function reportsPage(item, el) {
    el.innerHTML = `${pageHead(item)}<div id="rp-body">${loading()}</div>`;
    let D; try { D = await API.rpc('cms_reports'); } catch (e) { $('#rp-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const today = D.today; const curY = Number(today.slice(0, 4));
    const coName = (c) => coShort(c) || (D.companies.find((x) => x.code === c) || {}).name || c || 'Not set';
    const used = [...new Set([...D.people.map((p) => p.co), ...D.payroll.map((p) => p.co), ...D.claims.map((c) => c.co)].filter(Boolean))].sort((a, b) => (VZ_CO.indexOf(a) + 1 || 99) - (VZ_CO.indexOf(b) + 1 || 99));
    const colors = (k) => vzColor(k, used);
    const years = []; for (let y = Math.min(...D.people.map((p) => Number(String(p.s || today).slice(0, 4))), curY); y <= curY; y += 1) years.push(y);
    const f = { tab: new URLSearchParams(location.hash.split('?')[1] || '').get('tab') || 'people', co: 'all', range: '12m' };
    const lastDay = (ym) => { const [y, m] = ym.split('-').map(Number); return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10); };
    const monthsIn = () => {
      let a; let b;
      if (f.range === '12m') { const [y, m] = today.split('-').map(Number); b = `${y}-${String(m).padStart(2, '0')}`; const d = new Date(Date.UTC(y, m - 12, 1)); a = d.toISOString().slice(0, 7); }
      else { a = `${f.range}-01`; b = Number(f.range) === curY ? today.slice(0, 7) : `${f.range}-12`; }
      const out = []; let [y, m] = a.split('-').map(Number); const [by, bm] = b.split('-').map(Number);
      while (y < by || (y === by && m <= bm)) { out.push(`${y}-${String(m).padStart(2, '0')}`); m += 1; if (m > 12) { m = 1; y += 1; } }
      return out;
    };
    const coOk = (c) => f.co === 'all' || c === f.co;
    const activeAt = (p, d) => p.s && p.s <= d && (!p.e || p.e >= d);
    const monthsBetween = (a, b) => { const x = new Date(a); const y = new Date(b); return (y.getUTCFullYear() - x.getUTCFullYear()) * 12 + (y.getUTCMonth() - x.getUTCMonth()) + (y.getUTCDate() >= x.getUTCDate() ? 0 : -1); };
    const BANDS = [['Under 3 months', 0, 3], ['3–6 months', 3, 6], ['6–12 months', 6, 12], ['1–2 years', 12, 24], ['2–5 years', 24, 60], ['5 years or more', 60, 9999]];
    const band = (mo) => (BANDS.find(([, a, b]) => mo >= a && mo < b) || BANDS[0])[0];
    const pct = (v) => `${(Math.round(v * 10) / 10).toFixed(1)}%`;
    const kpi = (lbl, val, sub, tone = '') => `<div class="rp-kpi ${tone}"><span>${esc(lbl)}</span><b>${val}</b>${sub ? `<small>${sub}</small>` : ''}</div>`;
    const csvBtn = (name) => (D.can_export ? `<button type="button" class="btn sm ghost" data-csv="${esc(name)}">${icon('download')}CSV</button>` : '');
    const CSV = {};
    const toCsv = (rows) => rows.map((r) => r.map((v) => { const s = v == null ? '' : String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; }).join(',')).join('\n');
    const rangeTxt = () => (f.range === '12m' ? 'last 12 months' : String(f.range));

    function peopleTab(box) {
      const P = D.people.filter((p) => coOk(p.co)); const M = monthsIn(); const ends = M.map((m) => (m === today.slice(0, 7) ? today : lastDay(m)));
      const from = `${M[0]}-01`; const to = ends[ends.length - 1];
      const cos = used.filter((c) => f.co === 'all' || c === f.co);
      const series = cos.map((c) => ({ key: c, label: coName(c), values: ends.map((d) => P.filter((p) => p.co === c && activeAt(p, d)).length) }));
      const hc = ends.map((d) => P.filter((p) => activeAt(p, d)).length); const avg = hc.reduce((a, b) => a + b, 0) / (hc.length || 1);
      const joined = P.filter((p) => p.s && p.s >= from && p.s <= to); const left = P.filter((p) => p.e && p.e >= from && p.e <= to);
      const now = P.filter((p) => activeAt(p, today)); const ten = now.map((p) => monthsBetween(p.s, today)); const avgTen = ten.length ? ten.reduce((a, b) => a + b, 0) / ten.length : 0;
      const dept = {}; now.forEach((p) => { const k = p.dept || 'Not set'; dept[k] = (dept[k] || 0) + 1; });
      const gender = { M: 0, F: 0, '?': 0 }; now.forEach((p) => { gender[p.g === 'M' || p.g === 'F' ? p.g : '?'] += 1; });
      const tb = {}; now.forEach((p) => { const b = band(monthsBetween(p.s, today)); tb[b] = (tb[b] || 0) + 1; });
      CSV.headcount = [['Month', ...series.map((s) => s.label), 'Total'], ...M.map((m, i) => [m, ...series.map((s) => s.values[i]), hc[i]])];
      CSV.staff = [['Name', 'Employee ID', 'Company', 'Department', 'Position', 'Started', 'Months in service'], ...now.map((p) => [p.name || '', p.eid || '', coName(p.co), p.dept || '', p.pos || '', p.s, monthsBetween(p.s, today)])];
      box.innerHTML = `<div class="rp-kpis">${kpi('Staff now', num(now.length), f.co === 'all' ? cos.map((c) => `${esc(coName(c))} ${now.filter((p) => p.co === c).length}`).join(' · ') : '')}
          ${kpi(`Joined · ${rangeTxt()}`, num(joined.length))}${kpi(`Left · ${rangeTxt()}`, num(left.length))}
          ${kpi('Turnover', pct(avg ? (left.length / avg) * 100 : 0), `${left.length} left ÷ ${avg.toFixed(1)} average staff`)}${kpi('Average service (staff now)', `${(avgTen / 12).toFixed(1)} yrs`, `${Math.round(avgTen)} months`)}</div>
        <section class="card"><div class="card-head"><h3>${icon('users')}Headcount at the end of each month</h3>${csvBtn('headcount')}</div>${vzBars({ cats: M.map(ymLabel), series, colors })}
          <p class="muted small">Counted from each person's start date and last working day (Employee Master and payroll). The current month counts today.</p></section>
        <div class="rp-2"><section class="card"><div class="card-head"><h3>${icon('building')}Staff now by department</h3></div>${vzHBars(Object.entries(dept).sort((a, b) => b[1] - a[1]).map(([k, v]) => ({ label: k, value: v })))}</section>
          <section class="card"><div class="card-head"><h3>${icon('clock')}Staff now by length of service</h3></div>${vzHBars(BANDS.map(([b]) => ({ label: b, value: tb[b] || 0 })))}
            <h4 class="sec-h">Gender</h4>${vzHBars([{ label: 'Female', value: gender.F }, { label: 'Male', value: gender.M }, ...(gender['?'] ? [{ label: 'Not recorded', value: gender['?'] }] : [])])}</section></div>
        ${D.can_names ? `<details class="card rp-list"><summary><b>Staff now (${now.length})</b> ${csvBtn('staff')}</summary><div class="table-wrap"><table class="data compact"><thead><tr><th>Name</th><th>Company</th><th>Department</th><th>Started</th><th class="num">Service</th></tr></thead><tbody>
          ${now.sort((a, b) => a.s.localeCompare(b.s)).map((p) => `<tr><td><b>${esc(p.name || '')}</b><small class="sub">${esc(p.eid || '')}</small></td><td>${esc(coName(p.co))}</td><td>${esc(p.dept || '—')}</td><td class="nowrap">${dShort(p.s)}</td><td class="num">${(monthsBetween(p.s, today) / 12).toFixed(1)} yrs</td></tr>`).join('')}</tbody></table></div></details>` : ''}`;
    }

    function turnoverTab(box) {
      const P = D.people.filter((p) => coOk(p.co)); const M = monthsIn(); const from = `${M[0]}-01`; const to = M[M.length - 1] === today.slice(0, 7) ? today : lastDay(M[M.length - 1]);
      const cos = used.filter((c) => f.co === 'all' || c === f.co);
      const left = P.filter((p) => p.e && p.e >= from && p.e <= to);
      const series = cos.map((c) => ({ key: c, label: coName(c), values: M.map((m) => left.filter((p) => p.co === c && p.e.slice(0, 7) === m).length) }));
      const tb = {}; left.forEach((p) => { const b = band(monthsBetween(p.s, p.e)); tb[b] = (tb[b] || 0) + 1; });
      const rs = {}; left.forEach((p) => { const k = p.r ? p.r.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase()) : 'Not recorded'; rs[k] = (rs[k] || 0) + 1; });
      const yrs = years.map((y) => { const a = `${y}-01-01`; const b = y === curY ? today : `${y}-12-31`;
        const ms = []; for (let m = 1; m <= (y === curY ? Number(today.slice(5, 7)) : 12); m += 1) ms.push(m === Number(today.slice(5, 7)) && y === curY ? today : lastDay(`${y}-${String(m).padStart(2, '0')}`));
        const avg = ms.reduce((s, d) => s + P.filter((p) => activeAt(p, d)).length, 0) / (ms.length || 1);
        const j = P.filter((p) => p.s >= a && p.s <= b).length; const l = P.filter((p) => p.e && p.e >= a && p.e <= b).length; const early = P.filter((p) => p.e && p.e >= a && p.e <= b && monthsBetween(p.s, p.e) < 3).length;
        return { y, start: P.filter((p) => activeAt(p, `${y - 1}-12-31`)).length, j, l, end: P.filter((p) => activeAt(p, b)).length, avg, rate: avg ? (l / avg) * 100 : 0, early }; });
      const noReason = left.filter((p) => !p.r).length;
      CSV.leavers = [['Name', 'Employee ID', 'Company', 'Department', 'Position', 'Started', 'Last day', 'Months in service', 'Reason'], ...left.map((p) => [p.name || '', p.eid || '', coName(p.co), p.dept || '', p.pos || '', p.s, p.e, monthsBetween(p.s, p.e), p.r || ''])];
      CSV.years = [['Year', 'Staff at start', 'Joined', 'Left', 'Staff at end', 'Average staff', 'Turnover %', 'Left within 3 months'], ...yrs.map((r) => [r.y, r.start, r.j, r.l, r.end, r.avg.toFixed(1), r.rate.toFixed(1), r.early])];
      box.innerHTML = `<section class="card"><div class="card-head"><h3>${icon('trend')}People who left, by month</h3>${csvBtn('leavers')}</div>${vzBars({ cats: M.map(ymLabel), series, colors })}</section>
        <div class="rp-2"><section class="card"><div class="card-head"><h3>${icon('clock')}How long leavers stayed · ${esc(rangeTxt())}</h3></div>${vzHBars(BANDS.map(([b]) => ({ label: b, value: tb[b] || 0 })))}</section>
          <section class="card"><div class="card-head"><h3>${icon('list')}Why they left · ${esc(rangeTxt())}</h3></div>${vzHBars(Object.entries(rs).sort((a, b) => b[1] - a[1]).map(([k, v]) => ({ label: k, value: v, color: k === 'Not recorded' ? 'var(--line)' : undefined })))}
            ${noReason ? `<p class="muted small">${noReason} leaver${noReason === 1 ? ' has' : 's have'} no leaving reason yet — add it on <a class="link" href="#/people/former">Former Staff</a>.</p>` : ''}</section></div>
        <section class="card"><div class="card-head"><h3>${icon('chart')}Turnover by year</h3>${csvBtn('years')}</div><div class="table-wrap"><table class="data"><thead><tr><th>Year</th><th class="num">Staff at start</th><th class="num">Joined</th><th class="num">Left</th><th class="num">Staff at end</th><th class="num">Turnover</th><th class="num">Left within 3 months</th></tr></thead><tbody>
          ${yrs.map((r) => `<tr><td><b>${r.y}</b>${r.y === curY ? ' <small class="muted">so far</small>' : ''}</td><td class="num">${r.start}</td><td class="num">${r.j}</td><td class="num">${r.l}</td><td class="num">${r.end}</td><td class="num"><b>${pct(r.rate)}</b></td><td class="num">${r.early}</td></tr>`).join('')}</tbody></table></div>
          <p class="muted small">Turnover = people who left in the year ÷ the average number of staff at the end of each month.</p></section>
        ${D.can_names && left.length ? `<details class="card rp-list"><summary><b>Leavers · ${esc(rangeTxt())} (${left.length})</b></summary><div class="table-wrap"><table class="data compact"><thead><tr><th>Name</th><th>Company</th><th>Position</th><th>Last day</th><th class="num">Stayed</th><th>Reason</th></tr></thead><tbody>
          ${left.sort((a, b) => b.e.localeCompare(a.e)).map((p) => `<tr><td><b>${esc(p.name || '')}</b><small class="sub">${esc(p.eid || '')}</small></td><td>${esc(coName(p.co))}</td><td>${esc(p.pos || '—')}</td><td class="nowrap">${dShort(p.e)}</td><td class="num">${monthsBetween(p.s, p.e)} mo</td><td>${esc(p.r || '—')}</td></tr>`).join('')}</tbody></table></div></details>` : ''}`;
    }

    function payrollTab(box) {
      const M = monthsIn(); const R = D.payroll.filter((r) => coOk(r.co) && M.includes(String(r.period).slice(0, 7)));
      const months = M.filter((m) => R.some((r) => String(r.period).slice(0, 7) === m));
      if (!months.length) { box.innerHTML = `<section class="card"><div class="empty"><p>No payroll months in ${esc(rangeTxt())}</p><small class="muted">Payroll in the CMS starts from the months imported into MyPayroll.</small></div></section>`; return; }
      const cost = (r) => Number(r.gross) + Number(r.epf) + Number(r.socso) + Number(r.eis);
      const cos = used.filter((c) => R.some((r) => r.co === c));
      const at = (m, c) => R.filter((r) => String(r.period).slice(0, 7) === m && (!c || r.co === c));
      const series = cos.map((c) => ({ key: c, label: coName(c), values: months.map((m) => at(m, c).reduce((a, r) => a + cost(r), 0)) }));
      const rows = months.map((m) => { const xs = at(m); const s = (k) => xs.reduce((a, r) => a + Number(r[k]), 0);
        return { m, n: s('n'), gross: s('gross'), epf: s('epf'), socso: s('socso'), eis: s('eis'), reimb: s('reimb'), cost: xs.reduce((a, r) => a + cost(r), 0), draft: xs.some((r) => r.status !== 'finalised') }; });
      const fin = rows.filter((r) => !r.draft); const T = (k, list = rows) => list.reduce((a, r) => a + r[k], 0);
      CSV.payroll = [['Month', 'Status', 'People paid', 'Gross (RM)', 'EPF employer', 'SOCSO employer', 'EIS employer', 'Employer cost (RM)', 'Reimbursements'], ...rows.map((r) => [r.m, r.draft ? 'draft' : 'finalised', r.n, r.gross.toFixed(2), r.epf.toFixed(2), r.socso.toFixed(2), r.eis.toFixed(2), r.cost.toFixed(2), r.reimb.toFixed(2)])];
      box.innerHTML = `<div class="rp-kpis">${kpi('Employer cost · finalised months', `${money(T('cost', fin))}`, `${fin.length} month${fin.length === 1 ? '' : 's'}${rows.length > fin.length ? ` · ${rows.length - fin.length} draft not counted` : ''}`)}
          ${kpi('Average per month', `${money(fin.length ? T('cost', fin) / fin.length : 0)}`)}${kpi('Average cost per person paid', `${money(T('n', fin) ? T('cost', fin) / T('n', fin) : 0)}`, 'per month')}
          ${kpi('Employer EPF + SOCSO + EIS', `${money(T('epf', fin) + T('socso', fin) + T('eis', fin))}`, 'finalised months')}</div>
        <section class="card"><div class="card-head"><h3>${icon('wallet')}Employer cost by month (RM)</h3>${csvBtn('payroll')}</div>${vzBars({ cats: months.map((m) => `${ymLabel(m)}${rows.find((r) => r.m === m).draft ? '*' : ''}`), series, colors, fmt: (v) => money(v) })}
          <p class="muted small">Employer cost = gross pay + employer EPF, SOCSO and EIS, by the company that pays. * = month still in draft. Claims reimbursed through payroll are listed separately below and are not in the cost.</p></section>
        <section class="card"><div class="card-head"><h3>${icon('list')}Payroll by month</h3></div><div class="table-wrap"><table class="data"><thead><tr><th>Month</th><th class="num">People paid</th><th class="num">Gross</th><th class="num">EPF (employer)</th><th class="num">SOCSO (employer)</th><th class="num">EIS (employer)</th><th class="num">Employer cost</th><th class="num">Reimbursed</th></tr></thead><tbody>
          ${rows.map((r) => `<tr class="${r.draft ? 'dim' : ''}"><td><b>${esc(ymLabel(r.m))}</b>${r.draft ? ' <span class="tag warn xs">draft</span>' : ''}</td><td class="num">${r.n}</td><td class="num">${m2(r.gross)}</td><td class="num">${m2(r.epf)}</td><td class="num">${m2(r.socso)}</td><td class="num">${m2(r.eis)}</td><td class="num"><b>${m2(r.cost)}</b></td><td class="num">${m2(r.reimb)}</td></tr>`).join('')}
          <tr class="tot"><td><b>Finalised total</b></td><td class="num">${T('n', fin)}</td><td class="num">${m2(T('gross', fin))}</td><td class="num">${m2(T('epf', fin))}</td><td class="num">${m2(T('socso', fin))}</td><td class="num">${m2(T('eis', fin))}</td><td class="num"><b>${m2(T('cost', fin))}</b></td><td class="num">${m2(T('reimb', fin))}</td></tr></tbody></table></div></section>`;
    }

    function claimsTab(box) {
      const M = monthsIn(); const from = `${M[0]}-01`; const to = lastDay(M[M.length - 1]);
      const C = D.claims.filter((c) => coOk(c.co) && c.sub && c.sub >= from && c.sub <= to);
      if (!D.claims.length) { box.innerHTML = '<section class="card"><div class="empty"><p>No claims you can view</p></div></section>'; return; }
      const FORM = (c) => (c.form === 'tec' || c.form === 'tec-v2' ? 'tec' : c.form); const FL = { scf: 'Staff claims (SCF)', mtcf: 'Mileage (MTCF)', tec: 'Teacher tuition (TEC)', prfaf: 'Purchase & funding (PRFAF)' };
      const rm = C.filter((c) => c.unit === 'RM' && c.stage !== 'disapproved'); const ot = C.filter((c) => c.form === 'otcf' && c.stage !== 'disapproved');
      const forms = Object.keys(FL).filter((k) => rm.some((c) => FORM(c) === k));
      const formColor = (k) => `var(--vz-${forms.indexOf(k) + 1})`;
      const series = forms.map((k) => ({ key: k, label: FL[k], values: M.map((m) => rm.filter((c) => FORM(c) === k && c.sub.slice(0, 7) === m).reduce((a, c) => a + Number(c.amt || 0), 0)) }));
      const sum = (xs) => xs.reduce((a, c) => a + Number(c.amt || 0), 0);
      const ST = [['approval', 'Waiting for approval'], ['processing', 'Ready to process'], ['payment', 'Waiting for payment'], ['paid', 'Paid'], ['closed', 'Closed'], ['disapproved', 'Disapproved']];
      const all = C.filter((c) => c.unit === 'RM'); const waiting = rm.filter((c) => ['approval', 'processing', 'payment'].includes(c.stage));
      const byCo = used.filter((c) => f.co === 'all' || c === f.co).map((c) => ({ label: coName(c), value: sum(rm.filter((x) => x.co === c)), color: colors(c) })).filter((r) => r.value > 0);
      CSV.claims = [['Form', 'Company', 'Submitted', 'Amount', 'Unit', 'Stage', 'Paid on'], ...C.map((c) => [c.label, c.co ? coName(c.co) : '', c.sub, c.amt, c.unit, c.stage, c.paid || ''])];
      box.innerHTML = `<div class="rp-kpis">${kpi(`Claimed · ${rangeTxt()}`, `${money(sum(rm))}`, `${rm.length} claim${rm.length === 1 ? '' : 's'} (not counting disapproved)`)}${kpi('Paid', `${money(sum(rm.filter((c) => c.stage === 'paid')))}`)}
          ${kpi('Still open', `${money(sum(waiting))}`, `${waiting.length} waiting for approval, processing or payment`, waiting.length ? 'warn' : '')}${ot.length ? kpi('Overtime claimed', `${num(Math.round(ot.reduce((a, c) => a + Number(c.amt || 0), 0) * 10) / 10)} hrs`, `${ot.length} OTCF claim${ot.length === 1 ? '' : 's'}`) : ''}</div>
        <section class="card"><div class="card-head"><h3>${icon('file-check')}Claims by month submitted (RM)</h3>${csvBtn('claims')}</div>${forms.length ? vzBars({ cats: M.map(ymLabel), series, colors: formColor, fmt: (v) => money(v) }) : '<div class="empty small"><p>No RM claims in this period</p></div>'}
          <p class="muted small">Only the claim forms you are allowed to see are counted. Overtime is in hours, so it is shown on its own.</p></section>
        <div class="rp-2"><section class="card"><div class="card-head"><h3>${icon('building')}Claimed by company (RM)</h3></div>${vzHBars(byCo, (v) => money(v))}</section>
          <section class="card"><div class="card-head"><h3>${icon('list')}Where the claims are</h3></div><div class="table-wrap"><table class="data compact"><thead><tr><th>Stage</th><th class="num">Claims</th><th class="num">RM</th>${ot.length ? '<th class="num">OT hours</th>' : ''}</tr></thead><tbody>
            ${ST.map(([k, l]) => { const xs = all.filter((c) => c.stage === k); const os = C.filter((c) => c.form === 'otcf' && c.stage === k); return xs.length || os.length ? `<tr><td>${esc(l)}</td><td class="num">${xs.length + os.length}</td><td class="num">${m2(sum(xs))}</td>${ot.length ? `<td class="num">${num(Math.round(os.reduce((a, c) => a + Number(c.amt || 0), 0) * 10) / 10)}</td>` : ''}</tr>` : ''; }).join('')}</tbody></table></div>
            <p class="muted small">Open: <a class="link" href="#/forms/scf">Staff Claims</a> · <a class="link" href="#/forms/mtcf">Mileage</a> · <a class="link" href="#/forms/tec">Tuition</a> · <a class="link" href="#/overtime">Overtime</a></p></section></div>`;
    }

    const draw = () => {
      const TABS = [['people', 'Headcount'], ['turnover', 'Turnover'], ...(D.can_pay ? [['payroll', 'Payroll cost']] : []), ['claims', 'Claims']];
      if (!TABS.some(([k]) => k === f.tab)) f.tab = 'people';
      $('#rp-body', el).innerHTML = `<div class="rp-filters card"><div class="seg ss-tabs">${TABS.map(([k, l]) => `<button type="button" data-tab="${k}" class="${f.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
          <span class="sp"></span><label class="rp-f"><span>Company</span><select id="rp-co"><option value="all">All companies</option>${used.map((c) => `<option value="${esc(c)}" ${f.co === c ? 'selected' : ''}>${esc(coName(c))}</option>`).join('')}</select></label>
          <label class="rp-f"><span>Period</span><select id="rp-range"><option value="12m">Last 12 months</option>${years.slice().reverse().map((y) => `<option value="${y}" ${String(f.range) === String(y) ? 'selected' : ''}>${y}${y === curY ? ' (so far)' : ''}</option>`).join('')}</select></label></div>
        <div id="rp-tab" class="rp-tab viz-root"></div>`;
      const box = $('#rp-tab', el);
      ({ people: peopleTab, turnover: turnoverTab, payroll: payrollTab, claims: claimsTab })[f.tab](box);
      $$('[data-tab]', el).forEach((b) => b.addEventListener('click', () => { f.tab = b.dataset.tab; draw(); }));
      $('#rp-co', el).addEventListener('change', (e) => { f.co = e.target.value; draw(); });
      $('#rp-range', el).addEventListener('change', (e) => { f.range = e.target.value; draw(); });
      $$('[data-csv]', el).forEach((b) => b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); const k = b.dataset.csv;
        download(`MyEden-${k}-${f.co === 'all' ? 'all' : f.co}-${f.range}.csv`, new Blob([`﻿${toCsv(CSV[k] || [])}`], { type: 'text/csv;charset=utf-8' })); }));
      wireTips(box); fitTables();
    };
    draw();
  }

  // ================================================================ PHASE 6 · MYPAYROLL PAGES INSIDE THE CMS
  // The MyPayroll V2.0 page code (payroll/js) runs here unchanged on the same database, with the CMS sign-in, the CMS look and
  // the CMS permissions: each page says which permission lets a person change things on it.
  window.cmsToast = (m, tone) => toast(m, tone);
  const MYP_PAGES = {
    'settings/org': { file: 'modules/org.js', edit: () => can('payroll.settings', 'E') },
    'settings/lists': { file: 'modules/lists.js', edit: () => can('payroll.settings', 'E') },
    'settings/payment-types': { file: 'modules/paymenttypes.js', edit: () => can('payroll.settings', 'E') },
    'settings/statutory': { file: 'modules/statutory.js', edit: () => can('payroll.settings', 'E') },
    'settings/holidays': { file: 'modules/holidays.js', edit: () => can('payroll.settings', 'E') },
    'settings/policies': { file: 'modules/policies.js', edit: () => can('payroll.settings', 'E') },
    'people/ids': { file: 'modules/eid.js', edit: () => can('people.eid') },
    'people/import': { file: 'modules/import.js', edit: () => isSuper() },
    leave: { file: 'modules/leave.js', edit: () => can('leave', 'E') },
    'leave/balances': { file: 'modules/balances.js', edit: () => can('leave', 'E') },
    'leave/audit': { file: 'modules/leaveaudit.js', edit: () => can('leave', 'E') },
    'leave/al-calculator': { file: 'modules/alcalc.js', edit: () => can('leave', 'E') },
    'leave/kpi': { file: 'modules/kpi.js', edit: () => can('leave', 'E') },
    'leave/year-end': { file: 'modules/yearclose.js', edit: () => can('leave', 'E') },
    'leave/import': { file: 'modules/leaveimportpage.js', edit: () => isSuper() },
    time: { file: 'modules/overtime.js', edit: () => can('payroll', 'E') },
    payroll: { file: 'modules/payroll.js', edit: () => can('payroll.prepare'),
      can: (roles) => (String(roles?.[0] || '').startsWith('payroll.') ? can(roles[0]) : roles?.length === 1 && roles[0] === 'admin' ? can('payroll.settings', 'E') : can('payroll.prepare')) },
    'time/part-time': { file: 'modules/parttime.js', edit: () => can('payroll', 'E') },
  };
  let mypCss = null;
  const mypStyles = () => mypCss || (mypCss = new Promise((ok) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = asset(`payroll/payroll.css?v=${encodeURIComponent(window.CMS_VERSION || '')}`); l.onload = ok; l.onerror = ok; document.head.appendChild(l); }));
  async function mypPage(item, el) {
    const P = MYP_PAGES[item.route];
    el.innerHTML = `${pageHead(item)}<div class="myp" id="myp-root">${loading()}</div>`;
    const root = $('#myp-root', el);
    let mod; try { await mypStyles(); mod = await import(asset(`payroll/js/${P.file}?v=${encodeURIComponent(window.CMS_VERSION || '')}`)); }
    catch (e) { root.innerHTML = errorCard(`This page could not be loaded (${e.message}). Check the connection and reload.`); return; }
    const me = { user_id: state.access?.user_id, email: state.access?.email, display_name: state.access?.name, role: P.edit() ? 'admin' : 'viewer', status: 'active' };
    const ctx = { sb: API.sb(), can: (roles) => (P.can ? P.can(roles) : P.edit()), VERSION: window.CMS_VERSION, me, modules: {}, async reloadModules() {}, session: null, brand: [], refreshBrand: async () => {} };
    try { ctx.session = await API.session(); const { data } = await API.sb().from('eppd_policies').select('value').eq('key', 'modules').maybeSingle(); ctx.modules = data?.value || {}; } catch (e) { /* optional modules stay off */ }
    root.innerHTML = '';
    // links inside MyPayroll pages that point at its own employee pages go to the CMS people pages
    root.addEventListener('click', (e) => { const a = e.target.closest('a[href^="#/employees"]'); if (!a) return; e.preventDefault(); location.hash = '#/people'; });
    const q = Object.fromEntries(new URLSearchParams(location.hash.split('?')[1] || ''));
    const pm = location.hash.match(/^#\/payroll\/(\d{4}-\d{2})(?:-\d{2})?(?:[?]|$)/);
    try { await mod.render(root, ctx, pm ? { period: pm[1] } : {}, q); }
    catch (e) { root.innerHTML = errorCard(e.message); }
  }

  // ================================================================ module placeholder pages
  function modulePage(item, el) {
    const plan = item.plan || []; const base = item.source && window.CMS_SOURCES[item.source]; const url = base && item.myp ? `${base}#/${item.myp}` : base;
    el.innerHTML = `${pageHead(item)}
      <section class="card coming"><div class="coming-art">${icon(item.icon || item.groupIcon || 'sparkle')}</div>
        <div><h3>${item.myp ? `Runs in ${esc(item.source)} until ${esc(window.CMS_PHASES[6])}` : `Arrives in ${esc(window.CMS_PHASES[item.phase] || 'a later phase')}`}</h3>
        <p>${item.myp ? `<b>${esc(item.source)}</b> works on the same data as the CMS, so nothing is entered twice. In Phase 6 this page is rebuilt inside the CMS; until then open it with the button below. Your access follows your CMS Payroll permission.`
          : item.source ? `Until then, keep using <b>${esc(item.source)}</b>. Its data moves into the CMS when this module goes live, so nothing is retyped.` : 'This module is new in the CMS.'}</p>
        ${plan.length ? `<ul class="plan">${plan.map((p) => `<li>${esc(p)}</li>`).join('')}</ul>` : ''}
        ${url ? `<div class="btn-row"><a class="btn primary" href="${esc(url)}" target="_blank" rel="noopener">${icon('plug')}Open ${esc(item.source)}</a></div>` : ''}</div></section>`;
  }

  function noAccessPage(el) {
    el.innerHTML = `<section class="card coming"><div class="coming-art">${icon('lock')}</div><div><h3>You do not have access to this page</h3><p>Ask an Admin or Super Admin to give you access.</p><div class="btn-row"><a class="btn primary" href="#/dashboard">Back to the dashboard</a></div></div></section>`;
  }

  const LIVE = {
    dashboard: dashboardPage, people: peoplePage, 'people/former': peoplePage, org: orgPage, 'admin/companies': orgPage, approvals: approvalsPage,
    'payroll/companies': payingPage, 'payroll/increments': incrementsPage,
    applications: applicationsPage, interviews: applicationsPage, jd: jdPage, positions: jdPage, onboarding: onboardingPage, handbook: handbookPage, hrlaw: hrlawPage,
    'admin/roles': rolesPage, 'admin/audit': auditPage, 'admin/export': exportPage,
    careers: careersPage, documents: documentsPage, letters: lettersPage, reports: reportsPage, ...Object.fromEntries(Object.keys(MYP_PAGES).map((r) => [r, mypPage])), training: trainingPage, 'me/certs': meCertsPage, performance: appraisalsPage, 'me/appraisal': meAppraisalPage, me: meHomePage, 'me/leave': meLeavePage, 'leave/requests': leaveRequestsPage, 'me/items': meItemsPage, 'me/claims': meClaimsPage, 'me/handbook': meHandbookPage, assets: itemsPage, 'me/profile': meProfilePage, 'me/payslips': mePayslipsPage, 'me/salary': meSalaryPage, 'people/selfservice': selfServicePage,
    overtime: claimsPage, 'forms/scf': claimsPage, 'forms/mtcf': claimsPage, 'forms/tec': claimsPage, 'forms/prfaf': claimsPage,
  };

  // ---------------------------------------------------------------- frozen headers on long lists
  // A list fills the screen below the top bar and scrolls inside its own box, so its search, tabs and column
  // headings stay in view. Scrolling down first moves the page title away, then scrolls the rows.
  const pageScroller = () => document.scrollingElement || document.documentElement;
  const topbarH = () => ($('.topbar')?.offsetHeight || 0);
  function fitTables() {
    const tb = topbarH();
    $$('#page .table-wrap.fill').forEach((w) => {
      const card = w.closest('.card') || w.parentElement;
      const inCard = w.getBoundingClientRect().top - card.getBoundingClientRect().top;
      w.style.maxHeight = `${Math.max(260, window.innerHeight - tb - inCard - 14)}px`;
      const t = $('table', w); const first = t && $('thead th', t);
      if (t && first) t.style.setProperty('--c2', `${first.offsetWidth}px`);
      if (!w.dataset.wheel) {
        w.dataset.wheel = '1';
        w.addEventListener('wheel', (e) => {
          if (e.deltaY <= 0 || e.ctrlKey) return;
          const sc = pageScroller(); const gap = (w.closest('.card') || w).getBoundingClientRect().top - topbarH() - 8;
          if (gap > 1 && sc.scrollTop + window.innerHeight < sc.scrollHeight - 1) { e.preventDefault(); sc.scrollBy(0, Math.min(e.deltaY, gap)); }
        }, { passive: false });
      }
    });
  }
  let fitQueued = false;
  const queueFit = () => { if (fitQueued) return; fitQueued = true; requestAnimationFrame(() => { fitQueued = false; fitTables(); }); };
  window.addEventListener('resize', queueFit);
  new MutationObserver(queueFit).observe(document.body, { childList: true, subtree: true });

  async function render() {
    if (!state.access || !$('#page')) return;
    const id = ++state.renderId;
    let r = (location.hash.replace(/^#\/?/, '').split('?')[0]) || 'dashboard';
    if (/^payroll\/\d{4}-\d{2}(-\d{2})?$/.test(r)) r = 'payroll';   // a payroll month opens inside Monthly Payroll
    const item = PAGES.get(r === 'dashboard' && !canRoute('dashboard') ? homeRoute() : r) || PAGES.get(homeRoute());
    state.route = item.route;
    const g = groupOf(item.route); if (g && !state.open.has(g)) { state.open.add(g); store.set('openGroups', [...state.open]); }
    drawSidebar();
    const page = $('#page');
    const holder = document.createElement('div'); holder.className = 'page-in';
    page.replaceChildren(holder);
    page.classList.remove('enter'); void page.offsetWidth; page.classList.add('enter');
    document.title = `${item.label} · MyEden Group CMS V1.0`;
    window.scrollTo(0, 0);
    if (!canRoute(item.route) || (item.route === 'admin/export' && !isSuper())) { noAccessPage(holder); return; }
    try { await (LIVE[item.route] || modulePage)(item, holder); }
    catch (e) { if (id === state.renderId) { holder.innerHTML = errorCard(e.message); wireRetry(holder); } }
  }

  // live clock on the dashboard
  setInterval(() => { const d = new Date(); const t = $('#h-time'); if (t) { t.textContent = fmtTime(d); $('#h-date').textContent = fmtDate(d); } }, 15000);

  // ================================================================ sign-in screens
  const BRAND_CHIPS = ['People', 'Recruitment', 'Payroll', 'Forms &amp; Claims'];
  function authShell(title, sub, inner) {
    document.body.innerHTML = `<div class="auth2">
      <aside class="auth-brand">
        <span class="ab-blob g" aria-hidden="true"></span><span class="ab-blob o" aria-hidden="true"></span>
        <div class="ab-top">${logo3d('lg')}<div class="ab-name"><b>MyEden Group</b><span>CMS V1.0</span></div></div>
        <div class="ab-mid"><h2>One Group.<br>One Platform.</h2>
          <p>Every person, from application to offboarding: people, recruitment, payroll, forms and claims in one place.</p>
          <div class="ab-chips">${BRAND_CHIPS.map((c) => `<span>${c}</span>`).join('')}</div></div>
        <div class="ab-foot">MyEden Group · MyEden Edu Hub · Happy Dino · Aborne Project</div>
      </aside>
      <main class="auth-main"><div class="auth-box">
        <h1>${esc(title)}</h1>${sub ? `<p class="auth-sub">${sub}</p>` : ''}
        ${inner}
        <button type="button" class="btn ghost block auth-install" data-install hidden>${icon('download')} Install MyEden CMS app</button>
        <p class="auth-foot">${esc(window.CMS_VERSION)}</p></div></main></div>`;
    wireInstall();
    const logo = $('.logo3d'); logo?.addEventListener('click', () => { logo.classList.remove('flip'); void logo.offsetWidth; logo.classList.add('flip'); });
    $$('[data-eye]').forEach((b) => b.addEventListener('click', () => {
      const inp = b.parentElement.querySelector('input'); const show = inp.type === 'password';
      inp.type = show ? 'text' : 'password';
      b.innerHTML = icon(show ? 'eye-off' : 'eye'); b.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
      b.setAttribute('aria-pressed', String(show));
    }));
  }
  // an input inside the brand-ring box; password boxes get a show / hide button
  const ringField = (label, name, type, ac, ic, value = '', ph = '') => `<label class="fld"><span>${label}</span>
    <span class="ring">${icon(ic, 'ring-ic')}<input type="${type}" name="${name}" autocomplete="${ac}" value="${esc(value)}" ${ph ? `placeholder="${esc(ph)}"` : ''} required>${type === 'password' ? `<button type="button" class="eye" data-eye aria-label="Show password" aria-pressed="false">${icon('eye')}</button>` : ''}</span></label>`;

  function loginScreen(msg) {
    authShell('Welcome back', 'Sign in with your MEG-EAF V2 / MEG-FORMS account.', `<form class="auth-form" id="login" novalidate>
        ${ringField('Email', 'email', 'email', 'username', 'mail', '', 'name@myeden.com.my')}
        ${ringField('Password', 'password', 'password', 'current-password', 'lock')}
        <div class="auth-row"><button type="button" class="lnk" id="forgot">Forgot password?</button></div>
        <p class="form-err" ${msg ? '' : 'hidden'}>${esc(msg || '')}</p>
        <button type="submit" class="btn primary block">Sign in</button></form>`);
    const f = $('#login'); const err = $('.form-err', f);
    setTimeout(() => f.email.focus(), 50);
    f.addEventListener('submit', async (e) => {
      e.preventDefault(); err.hidden = true;
      if (!f.email.value.trim() || !f.password.value) { err.textContent = 'Enter your email and password.'; err.hidden = false; return; }
      const b = $('button[type=submit]', f); b.disabled = true; b.classList.add('busy'); b.textContent = 'Signing in…';
      try { await API.signIn(f.email.value.trim(), f.password.value); justSignedIn = true; await start(); }
      catch (x) { err.textContent = x.message; err.hidden = false; b.disabled = false; b.classList.remove('busy'); b.textContent = 'Sign in'; }
    });
    $('#forgot').addEventListener('click', () => forgotScreen(f.email.value.trim()));
  }

  function forgotScreen(email) {
    authShell('Reset your password', 'Enter your email and we will send a link to set a new password.', `<form class="auth-form" id="forgot-f" novalidate>
        ${ringField('Email', 'email', 'email', 'username', 'mail', email || '', 'name@myeden.com.my')}
        <p class="form-err" hidden></p><p class="form-ok" hidden></p>
        <button type="submit" class="btn primary block">Send reset link</button>
        <div class="auth-row center"><button type="button" class="lnk" id="back">Back to sign in</button></div></form>`);
    const f = $('#forgot-f');
    setTimeout(() => f.email.focus(), 50);
    $('#back').addEventListener('click', () => loginScreen());
    f.addEventListener('submit', async (e) => {
      e.preventDefault(); const err = $('.form-err', f); const ok = $('.form-ok', f); err.hidden = true; ok.hidden = true;
      if (!f.email.value.trim()) { err.textContent = 'Enter your email.'; err.hidden = false; return; }
      const b = $('button[type=submit]', f); b.disabled = true;
      try { await API.sendReset(f.email.value.trim()); ok.textContent = 'If this email has a login, a reset link is on its way. Check your inbox (and spam).'; ok.hidden = false; }
      catch (x) { err.textContent = x.message; err.hidden = false; } finally { b.disabled = false; }
    });
  }

  function newPasswordScreen() {
    authShell('Set a new password', 'Use at least 8 characters.', `<form class="auth-form" id="np" novalidate>
        ${ringField('New password', 'p1', 'password', 'new-password', 'lock')}
        ${ringField('Type it again', 'p2', 'password', 'new-password', 'lock')}
        <p class="form-err" hidden></p>
        <button type="submit" class="btn primary block">Save password</button></form>`);
    const f = $('#np');
    setTimeout(() => f.p1.focus(), 50);
    f.addEventListener('submit', async (e) => {
      e.preventDefault(); const err = $('.form-err', f); err.hidden = true;
      if (f.p1.value.length < 8) { err.textContent = 'Use at least 8 characters.'; err.hidden = false; return; }
      if (f.p1.value !== f.p2.value) { err.textContent = 'The two passwords are different.'; err.hidden = false; return; }
      try { await API.setPassword(f.p1.value); recovering = false; toast('Password saved'); history.replaceState(null, '', location.pathname); justSignedIn = true; await start(); }
      catch (x) { err.textContent = x.message; err.hidden = false; }
    });
  }

  function noRoleScreen() {
    const a = state.access;
    authShell('No access yet', '', `<div class="auth-form">
        <div class="noaccess">${icon('lock')}<div><b>${esc(a.email)}</b><p>You are signed in, but this login has no CMS role yet. A Super Admin can grant one in Users, Roles &amp; Access.</p></div></div>
        <button type="button" class="btn ghost block" id="so">Sign out</button></div>`);
    $('#so').addEventListener('click', signOut);
  }

  async function signOut() {
    await API.signOut(); state.access = null; state.dash = null; state.people = null; state.org = null; loginScreen();
  }

  // ================================================================ start
  let justSignedIn = false; let recovering = false;
  async function start() {
    let session;
    try { session = await API.session(); }
    catch (e) { authShell('Something went wrong', '', `<div class="auth-form"><p class="form-err">${esc(e.message)}</p><button type="button" class="btn primary block" id="rl">Reload</button></div>`); $('#rl').addEventListener('click', () => location.reload()); return; }
    if (recovering) { newPasswordScreen(); return; }
    if (!session) { loginScreen(); return; }
    if (!state.access) authShell('Opening the CMS…', '', loading('Checking your access…'));
    try { state.access = upUser(await API.rpc('cms_my_access')); }
    catch (e) { loginScreen(e.message); return; }
    const fresh = justSignedIn;
    if (justSignedIn) { justSignedIn = false; API.rpc('cms_note_sign_in').catch(() => {}); }
    try { state.self = state.access ? await API.rpc('cms_my_self') : null; } catch (e) { state.self = null; }
    if (!state.access || (!state.access.roles.length && !hasSelf())) { noRoleScreen(); return; }
    const cur = location.hash.replace(/^#\/?/, '').split('?')[0] || 'dashboard';
    if (fresh && !canRoute(cur)) history.replaceState(null, '', `${location.pathname}${location.search}#/${homeRoute()}`);   // signed in somewhere this login cannot open
    buildShell(); render(); loadIncrSummary(); loadRecruitSummary(); loadSelfPending(); loadItemsPending(); loadLeavePending(); loadApprPending(); loadCertsPending(); loadLettersPending(); drawBell();
    if (canRoute('dashboard') && (location.hash.replace(/^#\/?/, '').split('?')[0] || 'dashboard') !== 'dashboard') API.rpc('cms_dashboard').then((d) => { state.dash = d; drawBell(); }).catch(() => {});
  }

  const boot = () => {
    if (/type=recovery/.test(location.hash)) recovering = true;
    try {
      API.onAuth((event) => {
        if (event === 'PASSWORD_RECOVERY') { recovering = true; newPasswordScreen(); }
        else if (event === 'SIGNED_OUT' && state.access) { state.access = null; loginScreen('You have been signed out.'); }
      });
    } catch (e) { /* start() reports it */ }
    start();
  };
  // the app files are loaded after the page itself (latest-version loader), so the page may already be ready
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
  window.addEventListener('hashchange', () => { if (/access_token|type=recovery/.test(location.hash)) return; render(); });
})();
