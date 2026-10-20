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
  const canRoute = (route) => can(moduleOf(route), 'V');
  const isSuper = () => !!state.access?.is_super_admin;

  // ---------------------------------------------------------------- small helpers
  const initials = (n) => String(n || '?').trim().split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase() || '?';
  const num = (n) => (n === null || n === undefined || n === '') ? '—' : Number(n).toLocaleString('en-MY');
  const money = (n) => 'RM ' + Number(n || 0).toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
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
  const roleName = (code) => ({ super_admin: 'Super Admin', admin: 'Admin', hr: 'HR', payroll: 'Payroll', finance: 'Finance', approver: 'Approver', director: 'CEO / Director', payroll_viewer: 'Account / Payroll Viewer', staff: 'Staff' }[code] || code);
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
  function logo3d(size = 'md') {
    const layers = Array.from({ length: 9 }, (_, i) => `<img src="assets/logos/myeden-mark.png" alt="" style="--z:${(i - 4) * 1.6}px" class="${i === 8 ? 'front' : i === 0 ? 'back' : 'edge'}">`).join('');
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
    if (!d) return [];
    const t = [];
    const bs = d.claims_by_stage || {};
    if (d.claims_pending && can('approvals')) t.push({ ic: 'file-check', tone: 'orange', title: `${num(d.claims_pending)} claims waiting`, sub: [bs.approval && `${bs.approval} to approve`, bs.processing && `${bs.processing} to process`, bs.payment && `${bs.payment} to pay`].filter(Boolean).join(' · ') + ` · ${money(d.claims_pending_amount)}`, href: '#/approvals' });
    if (d.applications_pending && can('recruitment')) t.push({ ic: 'search-user', tone: 'blue', title: `${num(d.applications_pending)} applications not yet processed`, sub: 'Office Use and decision in MEG-EAF V2', href: window.CMS_SOURCES['MEG-EAF V2'], ext: true, src: 'MEG-EAF V2' });
    if (d.handbook_outstanding && can('handbook')) t.push({ ic: 'shield', tone: 'violet', title: `${num(d.handbook_outstanding)} handbook acknowledgements outstanding`, sub: 'Assigned or viewed, not yet acknowledged', href: window.CMS_SOURCES['MEG-EAF V2'], ext: true, src: 'MEG-EAF V2' });
    if (can('admin.roles') && d.logins - d.logins_with_role > 0) t.push({ ic: 'lock', tone: 'teal', title: `${num(d.logins - d.logins_with_role)} logins have no CMS role yet`, sub: 'Review the suggested roles and accept or skip', href: '#/admin/roles' });
    if (can('admin.roles', 'E') && d.logins_unlinked > 0) t.push({ ic: 'users', tone: 'rose', title: `${num(d.logins_unlinked)} logins are not linked to a person`, sub: 'Link each login to its Employee Master record', href: '#/admin/roles?tab=logins' });
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
        <div class="pop-wrap"><button type="button" class="user-btn" aria-haspopup="true"><span class="avatar">${esc(initials(a.name))}</span><span class="who"><b>${esc(a.name || '')}</b><small>${esc(top ? top.name : 'No role')}</small></span>${icon('chevron', 'chev down')}</button>
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
    const inst = $('[data-install]');
    if (inst) {
      inst.hidden = !installPrompt;
      inst.addEventListener('click', async () => { if (!installPrompt) return; closePops(); installPrompt.prompt(); await installPrompt.userChoice; installPrompt = null; inst.hidden = true; });
    }
    drawBell();
  }
  // install as an app (Chrome / Edge / Android): the browser offers it; the user menu shows "Install app" while it can
  let installPrompt = null;
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); installPrompt = e; const b = document.querySelector('[data-install]'); if (b) b.hidden = false; });
  window.addEventListener('appinstalled', () => { installPrompt = null; const b = document.querySelector('[data-install]'); if (b) b.hidden = true; toast('MyEden Group CMS installed'); });
  if ('serviceWorker' in navigator) window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
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
    return `<div class="crumbs"><a href="#/dashboard">Dashboard</a>${item.group ? ` / <span>${esc(item.group)}</span>` : ''} / <span>${esc(item.label)}</span></div>
      <div class="page-head"><div><h1>${esc(item.label)}</h1><p>${esc(item.desc || '')}</p></div><div class="ph-tags">${extra}${item.source ? `<span class="tag src">${icon('plug')}Now in ${esc(item.source)}</span>` : ''}${live ? '<span class="tag live">Live</span>' : phaseTag(item.phase)}</div></div>`;
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
          <div class="cos">${window.CMS_COMPANIES.map((c) => `<div class="co"><span class="co-logo"><img src="${c.logo}" alt="${esc(c.short)} logo"></span><div><b>${esc(c.short)}</b><small>${num(byEmp[c.code] || 0)} employed · ${num(byPay[c.code] || 0)} paid</small></div></div>`).join('')}</div></section>
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
              <label class="fld"><span>Salary paid by this company (RM)</span><input type="number" name="amt" min="0" step="0.01" required placeholder="0.00"></label>
              ${statBoxes({})}
              <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300" placeholder="e.g. teaches 2 days a week at Edu Hub"></label>`,
            onOk: async (f) => { if (!f.co.value || !f.m.value || f.amt.value === '') throw new Error('Choose the company and month, and enter the salary.');
              await API.rpc('cms_pay_add_company', { p_employment: empId, p_company: f.co.value, p_from: `${f.m.value}-01`, p_salary: Number(f.amt.value), p_pay_basis: f.basis.value, p_statutory: statOf(f), p_note: f.note.value || null }); } });
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
              <div class="grid-2 tight"><label class="fld"><span>New salary (RM)</span><input type="number" name="amt" min="0" step="0.01" required value="${r.current_salary ?? ''}"></label>
              <label class="fld"><span>From payroll month</span><input type="month" name="m" required value="${monthNow()}"></label></div>
              <p class="muted small" data-diff></p>
              <label class="fld"><span>Reason</span><select name="reason"><option>Annual increment</option><option>Confirmation increment</option><option>Promotion</option><option>Merit increment</option><option>Adjustment</option></select></label>
              <label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
            onOpen: (w) => { const f = $('form', w); const upd = () => { const d = Number(f.amt.value) - Number(r.current_salary || 0); $('[data-diff]', w).textContent = f.amt.value ? `Change: ${d < 0 ? '−' : '+'}${money(Math.abs(d))}${r.current_salary ? ` (${(d / r.current_salary * 100).toFixed(1)}%)` : ''}` : ''; }; f.amt.addEventListener('input', upd); upd(); setTimeout(() => f.amt.select(), 30); },
            onOk: async (f) => { if (!f.amt.value || !f.m.value) throw new Error('Enter the new salary and the month.');
              await API.rpc('cms_record_increment', { p_employment: r.employment_id, p_from: `${f.m.value}-01`, p_salary: Number(f.amt.value), p_reason: f.reason.value, p_note: f.note.value || null }); } });
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
          <td class="nowrap">${confCell(r)}</td><td class="nowrap">${salaryTxt(r.current_salary, r.pay_basis)}</td><td class="nowrap">${changeTxt(r)}</td>
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
    try { [rows] = await Promise.all([loadPeople(), loadOrg(), can('payroll.increments') ? loadIncrSummary() : null]); state.people = rows; }
    catch (e) { $('#people-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const editable = can('people', 'E'); const payView = can('payroll.paying');
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
        <div class="table-wrap fill"><table class="data freeze2" id="ptable"><thead><tr><th>Employee ID</th><th>Name</th><th>Employer</th><th>Paid by</th><th>Centre</th><th>Title</th><th>Status</th><th>Start</th><th>Confirmation</th>${can('payroll.increments') ? '<th>Next review</th>' : ''}<th>Notice until</th><th>Last working day</th></tr></thead><tbody></tbody></table></div>
        <p class="muted small" id="pcount"></p>
        <p class="muted small">Employer is the company on the contract (Employee Master). “Paid by” is the paying company for payroll; “same” means the employer pays; two companies means joint payment, main company first. The previous ID is shown under the Employee ID.${clickable ? ` Click a row to see${can('payroll.paying', 'E') ? ' and change' : ''} the paying companies${editable ? ' and centre' : ''}.` : ''} Confirmation, notice, last working day, leaving reason and rehire eligibility come from payroll; notice is counted from the resignation letter by the notice-period policy unless HR set an agreed date. IC, bank and salary details are not shown here.</p>
      </section>`;
    const incCol = can('payroll.increments'); const incBy = new Map((state.incr || []).map((x) => [x.person_id, x]));
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
        <td class="nowrap">${lastDayCell(r)}</td></tr>`).join('')
        : `<tr><td colspan="${incCol ? 12 : 11}"><div class="empty small"><p>No one matches</p><span>Try another status or clear the search.</span></div></td></tr>`;
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
      <div class="cos big">${active.map((c) => `<section class="card co"><span class="co-logo lg">${c.logo ? `<img src="${esc(c.logo)}" alt="${esc(c.short_name)} logo">` : icon('building')}</span>
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
    if (typeof v === 'number' && /amount|total|subtotal|pay|rate|price|claim/i.test(k)) return Number(v).toLocaleString('en-MY', { maximumFractionDigits: 2 });
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
                  : paid ? `<p><span class="st st-paid">Paid</span> ${row.payment_done_at ? dtShort(row.payment_done_at) : ''}${row.payment_done_by_name ? ` · ${esc(row.payment_done_by_name)}` : ''}</p>${d.can_edit ? '<button type="button" class="btn sm ghost" data-act="unpay">Undo payment</button>' : ''}`
                  : row.processing_eligible ? (d.can_edit ? `<p class="muted small">${row.fully_processed ? 'Processing is complete.' : 'Tip: finish the processing checklist first.'}</p><button type="button" class="btn sm primary" data-act="pay">Mark as paid</button>` : '<p class="muted small">Waiting for Finance.</p>')
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
      <div class="tabs" role="tablist">${[['logins', 'Logins'], ['grid', 'Roles & permissions'], ['rules', 'Position rules']].map(([k, l]) => `<button type="button" role="tab" data-tab="${k}" class="${tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <div id="roles-body">${loading()}</div>`;
    let users, matrix;
    try { [users, matrix] = await Promise.all([API.rpc('cms_users'), API.rpc('cms_roles_matrix'), loadOrg()]); users.forEach(upUser); }
    catch (e) { $('#roles-body', el).innerHTML = errorCard(e.message); wireRetry(el); return; }
    const body = $('#roles-body', el);
    const sup = isSuper(); const canLink = can('admin.roles', 'E');
    const filter = { q: '', show: 'all' };
    const reload = async () => { [users, matrix] = await Promise.all([API.rpc('cms_users'), API.rpc('cms_roles_matrix')]); users.forEach(upUser); draw(); };

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
          <p class="muted small">${sup ? 'Accept a suggestion with one click, or add any role. Suggestions come from MEG-EAF V2 and MEG-FORMS permissions and from the person’s JD position; nothing is granted until you accept it.' : 'Only a Super Admin can grant or remove roles.'}</p>
          <div class="ulist">${list.map((u) => `
            <article class="urow" data-u="${esc(u.id)}">
              <div class="u-main"><span class="avatar ${u.roles.length ? '' : 'off'}">${esc(initials(u.name))}</span>
                <div class="u-id"><b>${esc(u.name)}</b><small>${esc(u.email)} · last sign-in ${ago(u.last_sign_in_at)}${u.profile_status === 'pending' ? ' · <span class="st st-onboarding">pending</span>' : ''}</small>
                  <div class="u-person">${u.person ? `${icon('users')}<span>${esc(u.person.name)} · ${esc(u.person.employee_id || 'no ID')} · ${esc(coShort(u.person.company_code))}${u.person.title ? ' · ' + esc(u.person.title) : ''}</span>${canLink ? '<button type="button" class="lnk" data-act="unlink">Unlink</button>' : ''}`
                    : u.suggested_person ? `${icon('users')}<span class="muted">Same email as ${esc(u.suggested_person.name)} (${esc(u.suggested_person.employee_id || 'no ID')})</span>${canLink ? '<button type="button" class="lnk" data-act="link-sugg">Link</button>' : ''}`
                    : `<span class="muted">Not linked to a person</span>${canLink ? '<button type="button" class="lnk" data-act="link">Link to person…</button>' : ''}`}</div></div></div>
              <div class="u-roles">${u.roles.map((r) => `<span class="role-chip r-${esc(r.code)}" title="${esc(r.note || '')}">${esc(roleName(r.code))}<em>${esc(scopeTxt(r.companies))}</em>${sup ? `<button type="button" data-act="revoke" data-role="${esc(r.code)}" aria-label="Remove ${esc(roleName(r.code))}">${icon('x')}</button>` : ''}</span>`).join('') || '<span class="muted small">No CMS role · cannot use the CMS</span>'}
                ${sup ? `<button type="button" class="btn sm ghost" data-act="add">${icon('plus')}Add role</button>` : ''}</div>
              ${u.suggestions.length ? `<div class="u-sugg"><span class="lbl">${icon('sparkle')}Suggested</span>${u.suggestions.map((s, i) => `<span class="sugg"><span><b>${esc(roleName(s.role))}</b> · ${esc(scopeTxt(s.companies))}<small>${esc(s.reason)}</small></span>${sup ? `<button type="button" class="btn sm primary" data-act="accept" data-i="${i}">Accept</button>` : ''}</span>`).join('')}</div>` : ''}
            </article>`).join('') || '<div class="empty small"><p>No logins match</p></div>'}</div>
        </section>`;
    }

    function drawGrid() {
      const roles = matrix.roles; const mods = matrix.modules; let grp = '';
      return `<section class="card"><div class="card-head"><h3>${icon('lock')}Who can do what</h3><span class="muted small">V view · C create · E edit · A approve · D delete · X export</span></div>
        <p class="muted small">${sup ? 'Click a cell to change it. Super Admin always has everything. Every change is logged.' : 'Only a Super Admin can change permissions.'}</p>
        <div class="table-wrap fill"><table class="grid perm-grid freeze1"><thead><tr><th>Module</th>${roles.map((r) => `<th title="${esc(r.description)}">${esc(r.name)}<small>${r.users} ${r.users === 1 ? 'user' : 'users'}</small></th>`).join('')}</tr></thead><tbody>
        ${mods.map((m) => { const head = m.grp !== grp ? `<tr class="grp"><td colspan="${roles.length + 1}">${esc(m.grp)}</td></tr>` : ''; grp = m.grp;
          return `${head}<tr><td>${esc(m.label)} ${m.phase === 0 ? '<span class="tag live xs">Live</span>' : `<span class="tag phase p${m.phase} xs">P${m.phase}</span>`}</td>${roles.map((r) => {
            const a = matrix.permissions[r.code]?.[m.code] || '';
            return `<td><button type="button" class="pcell ${a ? 'on' : ''}" data-role="${esc(r.code)}" data-mod="${esc(m.code)}" ${sup && r.code !== 'super_admin' ? '' : 'disabled'} aria-label="${esc(r.name)} · ${esc(m.label)}: ${a || 'none'}">${a ? 'VCEADX'.split('').filter((x) => a.includes(x)).map((x) => `<i>${x}</i>`).join('') : '·'}</button></td>`; }).join('')}</tr>`; }).join('')}
        </tbody></table></div></section>
        <section class="card"><div class="card-head"><h3>${icon('shield')}Roles</h3></div>
          <ul class="role-desc">${roles.map((r) => `<li><span class="role-chip r-${esc(r.code)}">${esc(r.name)}</span><span>${esc(r.description)}</span>${r.phase > 0 ? `<span class="tag phase p${r.phase}">used from ${esc(window.CMS_PHASES[r.phase])}</span>` : ''}</li>`).join('')}</ul></section>`;
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
      body.innerHTML = tab === 'grid' ? drawGrid() : tab === 'rules' ? drawRules() : drawLogins();
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
        const opts = matrix.roles.filter((r) => !u.roles.some((x) => x.code === r.code));
        await modal({
          title: `Add a role · ${u.name}`,
          body: `<label class="fld"><span>Role</span><select name="role">${opts.map((r) => `<option value="${esc(r.code)}">${esc(r.name)}</option>`).join('')}</select></label>
            <p class="muted small" id="role-desc">${esc(opts[0]?.description || '')}</p>
            ${companyPicker()}<label class="fld"><span>Note (optional)</span><input name="note" maxlength="300"></label>`,
          ok: 'Grant role',
          onOk: async (form) => { if (!form.role.value) throw new Error('This login already holds every role.'); await grant(u, form.role.value, form.role.value === 'super_admin' ? null : readScope(form), form.note.value); },
        });
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
      const L = [['V', 'View'], ['C', 'Create'], ['E', 'Edit'], ['A', 'Approve'], ['D', 'Delete'], ['X', 'Export']];
      await modal({
        title: `${r.name} · ${m.label}`,
        body: `<div class="checks big">${L.map(([k, l]) => `<label><input type="checkbox" name="a" value="${k}" ${cur.includes(k) ? 'checked' : ''}> <b>${k}</b> ${l}</label>`).join('')}</div>
          <p class="muted small">Any action also needs View, which is added automatically. People holding this role see the change on their next page load.</p>`,
        onOk: async (form) => {
          const v = $$('input[name=a]:checked', form).map((x) => x.value).join('');
          const saved = await API.rpc('cms_set_permission', { p_role: role, p_module: mod, p_actions: v });
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

  // ================================================================ module placeholder pages
  function modulePage(item, el) {
    const plan = item.plan || []; const base = item.source && window.CMS_SOURCES[item.source]; const url = base && item.myp ? `${base}#/${item.myp}` : base;
    el.innerHTML = `${pageHead(item)}
      <section class="card coming"><div class="coming-art">${icon(item.icon || item.groupIcon || 'sparkle')}</div>
        <div><h3>Arrives in ${esc(window.CMS_PHASES[item.phase] || 'a later phase')}</h3>
        <p>${item.source ? `Until then, keep using <b>${esc(item.source)}</b>. Its data moves into the CMS when this module goes live, so nothing is retyped.` : 'This module is new in the CMS.'}</p>
        ${plan.length ? `<ul class="plan">${plan.map((p) => `<li>${esc(p)}</li>`).join('')}</ul>` : ''}
        ${url ? `<div class="btn-row"><a class="btn primary" href="${esc(url)}" target="_blank" rel="noopener">${icon('plug')}Open ${esc(item.source)}</a></div>` : ''}</div></section>`;
  }

  function noAccessPage(el) {
    el.innerHTML = `<section class="card coming"><div class="coming-art">${icon('lock')}</div><div><h3>You do not have access to this page</h3><p>Ask a Super Admin to add it to one of your roles.</p><div class="btn-row"><a class="btn primary" href="#/dashboard">Back to the dashboard</a></div></div></section>`;
  }

  const LIVE = {
    dashboard: dashboardPage, people: peoplePage, 'people/former': peoplePage, org: orgPage, 'admin/companies': orgPage, approvals: approvalsPage,
    'payroll/companies': payingPage, 'payroll/increments': incrementsPage,
    'admin/roles': rolesPage, 'admin/audit': auditPage, 'admin/export': exportPage,
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
    const r = (location.hash.replace(/^#\/?/, '').split('?')[0]) || 'dashboard';
    const item = PAGES.get(r) || PAGES.get('dashboard');
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
        <p class="auth-foot">${esc(window.CMS_VERSION)}</p></div></main></div>`;
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
    if (justSignedIn) { justSignedIn = false; API.rpc('cms_note_sign_in').catch(() => {}); }
    if (!state.access || !state.access.roles.length) { noRoleScreen(); return; }
    buildShell(); render(); loadIncrSummary();
    if ((location.hash.replace(/^#\/?/, '').split('?')[0] || 'dashboard') !== 'dashboard') API.rpc('cms_dashboard').then((d) => { state.dash = d; drawBell(); }).catch(() => {});
  }

  document.addEventListener('DOMContentLoaded', () => {
    if (/type=recovery/.test(location.hash)) recovering = true;
    try {
      API.onAuth((event) => {
        if (event === 'PASSWORD_RECOVERY') { recovering = true; newPasswordScreen(); }
        else if (event === 'SIGNED_OUT' && state.access) { state.access = null; loginScreen('You have been signed out.'); }
      });
    } catch (e) { /* start() reports it */ }
    start();
  });
  window.addEventListener('hashchange', () => { if (/access_token|type=recovery/.test(location.hash)) return; render(); });
})();
