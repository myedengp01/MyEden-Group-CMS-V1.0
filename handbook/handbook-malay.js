(function () {
  'use strict';
  var data = null, map = {}, loadGeneration = 0;
  var resources = {'MYEDEN-EMPLOYEE-HANDBOOK':{version:'2.0',stem:'myeden-v2.0-ms',clauses:216,tables:26},'HAPPY-DINO-EMPLOYEE-HANDBOOK':{version:'1.0',stem:'happy-dino-v1.0-ms',clauses:142,tables:47},'ABORNE-EMPLOYEE-HANDBOOK':{version:'1.0',stem:'aborne-v1.0-ms',clauses:142,tables:11}};
  function norm(s) { return String(s || '').replace(/\s+/g, ' ').trim().toLowerCase(); }
  async function readResource(code) {
    var resource = resources[code || 'MYEDEN-EMPLOYEE-HANDBOOK'];
    if (!resource) throw new Error('Unsupported handbook translation.');
    var response = await fetch('handbook-data/' + resource.stem + '-approved.json?v=20261012-ms3', {cache:'no-store'});
    if (!response.ok) throw new Error('Bahasa Malaysia translation could not be loaded.');
    var manifest = await response.json();
    var chunks = await Promise.all(manifest.files.map(async function (path) {
      if (!path.startsWith(resource.stem + '/') || !/\/chapter-\d{2}\.json$/.test(path)) throw new Error('Invalid translation chapter.');
      var r = await fetch('handbook-data/' + path + '?v=20261012-ms3', {cache:'no-store'});
      if (!r.ok) throw new Error('Bahasa Malaysia chapter could not be loaded.');
      return r.json();
    }));
    return Object.assign({}, manifest, {blocks:chunks.flatMap(function(c){return c.blocks;}),clauses:chunks.flatMap(function(c){return c.clauses;}),paragraphs:Object.assign.apply(Object,[{}].concat(chunks.map(function(c){return c.paragraphs;})))});
  }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function blocksHtml(blocks) {
    var out = '', list = [], type;
    function flush() { if (!list.length) return; var tag = type === 'numbered' ? 'ol' : 'ul'; out += '<' + tag + '>' + list.map(function (t) { return '<li>' + esc(t) + '</li>'; }).join('') + '</' + tag + '>'; list = []; }
    (blocks || []).forEach(function (b) {
      if (b.type === 'bullet' || b.type === 'numbered') { if (type !== b.type) flush(); type = b.type; list.push(b.text); return; }
      flush();
      if (b.type === 'table') {
        out += '<div style="overflow:auto"><table class="doc-table">';
        b.rows.forEach(function (row, ri) { out += '<tr>'; row.forEach(function (cell) {
          var tag = ri === 0 && b.rows.length > 1 ? 'th' : 'td';
          var align = {left:'left',center:'center',right:'right',both:'justify'}[cell.align] || 'left';
          out += '<' + tag + ' colspan="' + Number(cell.span || 1) + '" style="text-align:' + align + '">' + esc(cell.text).replace(/\n/g,'<br>') + '</' + tag + '>';
        }); out += '</tr>'; }); out += '</table></div>';
      } else if (b.type === 'heading1') out += '<h2 class="chapter">' + esc(b.text) + '</h2>';
      else if (b.type === 'clause_heading') out += '<h3 class="clause-title">' + esc(b.text) + '</h3>';
      else out += '<p>' + esc(b.text).replace(/\n/g,'<br>') + '</p>';
    }); flush(); return out;
  }
  async function load(handbook, english, englishMap) {
    var generation = ++loadGeneration;
    data = null; map = {};
    var button = document.getElementById('malayTopBtn');
    if (button) button.classList.add('hidden');
    var resource = handbook && resources[handbook.handbook_code];
    if (!resource || String(handbook.version || '').replace(/^v/i,'') !== resource.version) return;
    try {
      var loaded = await readResource(handbook.handbook_code);
      if (generation !== loadGeneration) return;
      if (loaded.approval_status !== 'approved' || loaded.handbook_code !== handbook.handbook_code || loaded.clause_count !== resource.clauses || loaded.table_count !== resource.tables) throw new Error('Invalid approved translation resource.');
      var titles = {};
      loaded.clauses.forEach(function (c) { titles[norm(c.source_chapter) + '|' + norm(c.source_title)] = c; });
      Object.keys(englishMap).forEach(function (key) {
        var entry = englishMap[key];
        var match = titles[norm(entry.chapter.title) + '|' + norm(entry.clause.title)];
        if (match) map[key] = match;
      });
      data = loaded;
      if (button) button.classList.remove('hidden');
    } catch (error) {
      console.error(error);
      if (button) { button.classList.remove('hidden'); button.title = 'Translation unavailable. Reload to retry.'; }
    }
  }
  function show(key) {
    var c = map[key]; if (!c) return;
    var english = window.CLAUSE_MAP[key].clause;
    window.openDialog('Bahasa Malaysia · ' + english.title,
      '<div class="refbox"><b>English governing version</b><br><br>' + esc(window.plainClause(english)).replace(/\n/g,'<br>') + '</div>' +
      '<div lang="ms" class="clause-body"><h4>' + esc(c.title) + '</h4>' + blocksHtml(c.blocks) + '</div>');
  }
  function decorate() {
    if (!data) return;
    document.querySelectorAll('#doc .clause').forEach(function (section) {
      var key = section.dataset.key, tools = section.querySelector('.tools');
      if (!map[key] || !tools || tools.querySelector('.malay-clause-button')) return;
      var button = document.createElement('button'); button.className = 'iconbtn malay-clause-button'; button.type = 'button'; button.textContent = 'BM'; button.title = 'Approved Bahasa Malaysia translation'; button.onclick = function () { show(key); }; tools.appendChild(button);
    });
    // Individual paragraph/list-item reference buttons, including preface material.
    document.querySelectorAll('#doc .clause-body p,#doc .clause-body li,#doc .preface p,#doc .preface li').forEach(function (p) {
      if (p.querySelector('.malay-paragraph-button') || p.querySelector('input,button,canvas')) return;
      var english = p.textContent, malay = data.paragraphs[norm(english)] || data.paragraphs[norm(english).replace(/^•\s*/, '')];
      if (!malay) return;
      var button = document.createElement('button'); button.type = 'button'; button.className = 'iconbtn malay-paragraph-button no-print'; button.textContent = 'BM'; button.title = 'Translate this paragraph into Bahasa Malaysia'; button.style.marginLeft = '8px';
      button.onclick = function () { window.openDialog('Bahasa Malaysia', '<div class="refbox">' + esc(english) + '</div><div lang="ms">' + esc(malay).replace(/\n/g,'<br>') + '</div>'); }; p.appendChild(button);
    });
  }
  function openFull() {
    if (!data) { alert('Bahasa Malaysia translation is unavailable. Please reload to retry.'); return; }
    var query = {'HAPPY-DINO-EMPLOYEE-HANDBOOK':'?handbook=happy-dino','ABORNE-EMPLOYEE-HANDBOOK':'?handbook=aborne'}[data.handbook_code] || '';
    window.open('handbook-ms.html' + query, '_blank', 'noopener');
  }
  window.HandbookMalay = {load:load, decorate:decorate, show:show, openFull:openFull, blocksHtml:blocksHtml,readResource:readResource};
})();