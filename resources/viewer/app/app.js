// NppBeads — shared helpers for the native-rendered side (board / issues /
// detail). Runs in every app/*.html page. Keep this small and
// dependency-free. No framework.
//
// Data source: we rely on `window.__nppBeadsPreloadedJsonl` (injected via
// WKUserScript at document-start by BeadsPanel._installJsonlUserScript).
// Native calls `window.__nppApp.reload(jsonl)` when the JSONL on disk
// changes.
//
// Theme: BeadsPanel sets `document.documentElement.dataset.theme =
// 'dark'|'light'` via evaluateJavaScript when macOS system theme changes.
//
// Search: BeadsPanel sets `window.__nppApp.filter = { query: '...' }` and
// calls `window.__nppApp.applyFilter()`. Each view wires its own render.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';
  if (window.__nppApp) return;

  const App = window.__nppApp = {
    beads: [],
    filter: { query: '' },
    theme: document.documentElement.dataset.theme || 'dark',
    log(...a)  { try { console.log('[NppBeads/app]', ...a); } catch {} },
    warn(...a) { try { console.warn('[NppBeads/app]', ...a); } catch {} },
  };

  // ── Bead normalization ──────────────────────────────────────────────
  // Both JSONL and bd --json produce slightly different shapes. Normalize
  // once here so every view works off the same object structure.
  function normalizeBead(r) {
    if (!r || typeof r !== 'object') return null;
    // source_repo: bd stores "." for issues native to the current repo;
    // anything else is a cross-repo import worth showing as a chip. Empty
    // string / null / undefined → no chip.
    let sourceRepo = null;
    if (typeof r.source_repo === 'string') {
      const sr = r.source_repo.trim();
      if (sr && sr !== '.') sourceRepo = sr;
    }
    const out = {
      id:          String(r.id || ''),
      title:       String(r.title || ''),
      description: String(r.description || ''),
      status:      String(r.status || 'open'),
      priority:    (typeof r.priority === 'number') ? r.priority : null,
      type:        String(r.issue_type || r.type || 'task'),
      assignee:    r.assignee || r.created_by || null,
      // The real assignee only (no created_by fallback) — for filtering.
      assignedTo:  r.assignee || null,
      labels:      Array.isArray(r.labels) ? r.labels
                   : (typeof r.labels === 'string' && r.labels.length)
                      ? r.labels.split(',').map(s => s.trim()).filter(Boolean)
                      : [],
      sourceRepo:  sourceRepo,
      createdAt:   r.created_at || null,
      updatedAt:   r.updated_at || null,
      closedAt:    r.closed_at || null,
      deps:        Array.isArray(r.dependencies) ? r.dependencies : [],
      // Phase 6 — comments are only present on `bd show` output; bd export
      // (JSONL) omits them. The Board pulls full record via fetchBead
      // when the detail modal opens.
      comments:    Array.isArray(r.comments) ? r.comments : [],
    };
    return out;
  }

  // Phase 6 — render a markdown string to sanitized HTML. Falls back to
  // plain text (with newlines → <br>) when marked/DOMPurify aren't
  // loaded (e.g. first-ever run before vendor scripts settle). Never
  // returns unsanitized HTML — we route every path through DOMPurify
  // when available.
  App.renderMarkdown = function (text) {
    const s = (typeof text === 'string') ? text : '';
    if (!s) return '';
    try {
      if (typeof window.marked !== 'undefined' &&
          typeof window.DOMPurify !== 'undefined') {
        const raw = window.marked.parse(s, { breaks: true, gfm: true });
        return window.DOMPurify.sanitize(raw, {
          // Allow basic formatting + links + images. No scripts.
          ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'code', 'pre',
                         'a', 'ul', 'ol', 'li', 'blockquote', 'hr',
                         'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                         'table', 'thead', 'tbody', 'tr', 'th', 'td',
                         'img', 'del', 'span'],
          ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'class'],
          ALLOW_DATA_ATTR: false,
        });
      }
    } catch (e) { /* fall through to plain-text fallback */ }
    // Plain-text fallback — escape + turn newlines into <br>.
    const esc = s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return esc.replace(/\n/g, '<br>');
  };

  // Extract a displayable timestamp from a bd comment/issue record.
  App.fmtTime = function (ts) {
    if (!ts) return '';
    try {
      const d = new Date(ts);
      if (Number.isNaN(d.getTime())) return String(ts);
      const now = new Date();
      const sameDay = d.toDateString() === now.toDateString();
      const h = String(d.getHours()).padStart(2, '0');
      const m = String(d.getMinutes()).padStart(2, '0');
      if (sameDay) return h + ':' + m;
      const y = d.getFullYear();
      const mo = String(d.getMonth() + 1).padStart(2, '0');
      const dy = String(d.getDate()).padStart(2, '0');
      return y + '-' + mo + '-' + dy + ' ' + h + ':' + m;
    } catch (e) { return String(ts); }
  };

  // Format a source_repo value for display — if it looks like a path,
  // use the last component; otherwise show the string as-is.
  App.sourceRepoLabel = function (sr) {
    if (!sr) return '';
    if (sr.indexOf('/') === -1) return sr;
    const parts = sr.split('/').filter(Boolean);
    return parts[parts.length - 1] || sr;
  };

  // ── Dep types ───────────────────────────────────────────────────────
  // The 10 bd dep types, split by whether they gate status propagation.
  // Used by the Phase 3.5 dep manager (new-issue + detail-modal) for the
  // dropdown next to the chip input. `blocks` is the UI default because
  // it's by far the most common and the one that drives bd ready.
  App.depTypes = [
    { value: 'blocks',             label: 'blocks',             group: 'blocking' },
    { value: 'parent-child',       label: 'parent-child',       group: 'blocking' },
    { value: 'conditional-blocks', label: 'conditional-blocks', group: 'blocking' },
    { value: 'waits-for',          label: 'waits-for',          group: 'blocking' },
    { value: 'related',            label: 'related',            group: 'non-blocking' },
    { value: 'tracks',             label: 'tracks',             group: 'non-blocking' },
    { value: 'discovered-from',    label: 'discovered-from',    group: 'non-blocking' },
    { value: 'caused-by',          label: 'caused-by',          group: 'non-blocking' },
    { value: 'validates',          label: 'validates',          group: 'non-blocking' },
    { value: 'supersedes',         label: 'supersedes',         group: 'non-blocking' },
  ];

  // Build a <select> of the 10 dep types, grouped by blocking/non-blocking.
  // Used in both the new-issue modal and the detail-modal dep editor.
  App.buildDepTypeSelect = function (current) {
    const sel = document.createElement('select');
    sel.className = 'dep-type-select';
    const groups = { blocking: 'Blocking', 'non-blocking': 'Non-blocking' };
    for (const key of Object.keys(groups)) {
      const og = document.createElement('optgroup');
      og.label = groups[key];
      for (const t of App.depTypes) {
        if (t.group !== key) continue;
        const o = document.createElement('option');
        o.value = t.value;
        o.textContent = t.label;
        if (t.value === (current || 'blocks')) o.selected = true;
        og.appendChild(o);
      }
      sel.appendChild(og);
    }
    return sel;
  };

  function parseJsonl(text) {
    const out = [];
    if (!text) return out;
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      if (!t) continue;
      try {
        const o = JSON.parse(t);
        const b = normalizeBead(o);
        if (b && b.id) out.push(b);
      } catch (e) {
        // merge-conflict markers, partial lines — skip quietly
      }
    }
    return out;
  }

  // Both directions of every dependency edge, per bead. bd export stores
  // an edge only on the dependent's record (issue_id), so a bead's own
  // `deps` never lists the issues that depend on IT — reading `deps`
  // alone made "Blocks" come out empty. Map id → { up, down }:
  //   up   — edges where this bead is the dependent  (it depends on …)
  //   down — edges where this bead is the dependency (… depend on it)
  // Each edge: { id (the other bead), type, dependent, dependency }.
  function buildDepIndex(beads) {
    const index = new Map();
    const seen = new Set();
    const slot = (id) => {
      let s = index.get(id);
      if (!s) { s = { up: [], down: [] }; index.set(id, s); }
      return s;
    };
    for (const b of beads) {
      for (const d of (b.deps || [])) {
        if (!d || !d.issue_id || !d.depends_on_id) continue;
        const type = d.type || d.dependency_type || 'blocks';
        const key = d.issue_id + '\u0000' + d.depends_on_id + '\u0000' + type;
        if (seen.has(key)) continue;
        seen.add(key);
        const edge = { type, dependent: d.issue_id, dependency: d.depends_on_id };
        slot(d.issue_id).up.push(Object.assign({ id: d.depends_on_id }, edge));
        slot(d.depends_on_id).down.push(Object.assign({ id: d.issue_id }, edge));
      }
    }
    return index;
  }

  App.depsOf = function (id) {
    return (App.depIndex && App.depIndex.get(id)) || { up: [], down: [] };
  };

  // Blocking state from `blocks` edges, following `bd ready`: only a
  // blocker that is not closed counts.
  //   openBlockers — not-closed issues this bead waits on
  //   openBlocking — not-closed issues waiting on this bead
  App.blockingState = function (id) {
    const byId = App.beadById;
    const live = (otherId) => {
      const o = byId && byId.get(otherId);
      return !!o && o.status !== 'closed';
    };
    const deps = App.depsOf(id);
    return {
      openBlockers: deps.up.filter(e => e.type === 'blocks' && live(e.id)).map(e => e.id),
      openBlocking: deps.down.filter(e => e.type === 'blocks' && live(e.id)).map(e => e.id),
    };
  };

  // What closing `id` would free up, over `blocks` edges, by the rules of
  // the graph engine's whatIfClose: an issue is freed once every one of
  // its open blockers is done, and freed issues are assumed done in turn.
  //   direct  — issues that become ready as soon as `id` is closed
  //   cascade — everything freed down the chain (includes direct)
  //   waiting — open issues waiting on `id` that stay blocked, each with
  //             the other open blockers still in the way
  App.whatIfClose = function (id) {
    const byId = App.beadById;
    const isOpen = (x) => { const b = byId && byId.get(x); return !!b && b.status !== 'closed'; };
    const openBlockersOf = (x) => App.depsOf(x).up
      .filter(e => e.type === 'blocks' && isOpen(e.id)).map(e => e.id);
    const openDependentsOf = (x) => [...new Set(App.depsOf(x).down
      .filter(e => e.type === 'blocks' && isOpen(e.id)).map(e => e.id))];

    const done = new Set([id]);
    const freedBy = (x) => openDependentsOf(x)
      .filter(d => !done.has(d) && openBlockersOf(d).every(b => done.has(b)));

    const direct = freedBy(id);
    const cascade = direct.slice();
    for (const d of direct) done.add(d);
    for (let i = 0; i < cascade.length; i++) {
      for (const d of freedBy(cascade[i])) {
        done.add(d);
        cascade.push(d);
      }
    }
    const waiting = openDependentsOf(id)
      .filter(d => direct.indexOf(d) === -1)
      .map(d => ({ id: d, others: openBlockersOf(d).filter(b => b !== id) }));
    return { direct, cascade, waiting };
  };

  // Graph metrics from the WASM engine the Graph view uses (vendor/
  // bv_graph.js), over `blocks` edges oriented dependent → dependency
  // like graph.js. Resolves to Map id → { pagerank, betweenness,
  // criticalDepth }, or null when the engine can't load. Cached until
  // the next App.load.
  // One shared load: concurrent init() calls would each instantiate the
  // module and swap its memory out from under graphs already built.
  let wasmLoad = null;
  App.ensureGraphMetrics = async function () {
    if (App.graphMetrics) return App.graphMetrics;
    const beads = App.beads;
    try {
      if (!wasmLoad) {
        wasmLoad = import('../vendor/bv_graph.js')
          .then(mod => mod.default().then(() => mod));
        wasmLoad.catch(() => { wasmLoad = null; });
      }
      const wasmModule = await wasmLoad;
      const edges = [];
      for (const [id, d] of (App.depIndex || new Map())) {
        for (const e of d.up) if (e.type === 'blocks') edges.push([id, e.id]);
      }
      const g = wasmModule.DiGraph.withCapacity(beads.length, edges.length);
      try {
        for (const b of beads) g.addNode(b.id);
        for (const [from, to] of edges) {
          const fi = g.nodeIdx(from), ti = g.nodeIdx(to);
          if (fi !== undefined && ti !== undefined) g.addEdge(fi, ti);
        }
        const n = g.nodeCount();
        const pagerank    = g.pagerankDefault();
        const betweenness = n > 500 ? g.betweennessApprox(Math.min(100, n)) : g.betweenness();
        const heights     = g.criticalPathHeights();
        const out = new Map();
        for (const b of beads) {
          const i = g.nodeIdx(b.id);
          if (i === undefined) continue;
          out.set(b.id, {
            pagerank:      pagerank ? pagerank[i] : null,
            betweenness:   betweenness ? betweenness[i] : null,
            criticalDepth: heights ? heights[i] : null,
          });
        }
        // A reload may have replaced the data while we were computing.
        if (App.beads === beads) App.graphMetrics = out;
        return out;
      } finally {
        g.free();
      }
    } catch (e) {
      App.warn('graph metrics unavailable:', e);
      return null;
    }
  };

  App.load = function (jsonl) {
    App.beads = parseJsonl(jsonl);
    App.beadById = new Map(App.beads.map(b => [b.id, b]));
    App.depIndex = buildDepIndex(App.beads);
    App.graphMetrics = null;   // recomputed on demand for the new data
    App.log('loaded ' + App.beads.length + ' beads');
    if (typeof App.onDataLoaded === 'function') App.onDataLoaded();
  };

  App.reload = function (jsonl) {
    App.load(jsonl);
    if (typeof App.onRefresh === 'function') App.onRefresh();
  };

  App.setFilter = function (f) {
    App.filter = Object.assign({ query: '' }, f || {});
    if (typeof App.applyFilter === 'function') App.applyFilter();
  };

  App.setTheme = function (theme) {
    App.theme = theme === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = App.theme;
  };

  // Case-insensitive match over id/title/description/labels/assignee.
  App.matchesQuery = function (bead, query) {
    if (!query) return true;
    const q = query.toLowerCase();
    if (bead.id.toLowerCase().includes(q)) return true;
    if (bead.title.toLowerCase().includes(q)) return true;
    if (bead.description.toLowerCase().includes(q)) return true;
    if (bead.assignee && bead.assignee.toLowerCase().includes(q)) return true;
    for (const l of bead.labels) if (l.toLowerCase().includes(q)) return true;
    return false;
  };

  // ── UI presentation helpers (icon glyphs, label colors, etc.) ───────
  // Label auto-coloring — same trick vscode-beads uses: hash label text
  // to a stable HSL. Keeps lightness high so text reads on any theme.
  App.labelColor = function (label) {
    let h = 0;
    for (let i = 0; i < label.length; i++) {
      h = ((h << 5) - h + label.charCodeAt(i)) | 0;
    }
    const hue = Math.abs(h) % 360;
    return `hsl(${hue}, 55%, 45%)`;
  };

  // Tiny icon helper (SVG glyphs rendered inline). Keep the set small to
  // avoid adding a font or icon pack.
  App.typeIcon = function (type) {
    const t = String(type || '').toLowerCase();
    const icons = {
      bug:     '🪲',
      feature: '✨',
      task:    '✓',
      epic:    '⬢',
      chore:   '•',
    };
    return icons[t] || icons.task;
  };

  App.statusColor = function (status) {
    switch (status) {
      case 'open':        return { fg: '#0369a1', bg: '#e0f2fe', label: 'Open' };
      case 'in_progress': return { fg: '#b45309', bg: '#fef3c7', label: 'In Progress' };
      case 'blocked':     return { fg: '#b91c1c', bg: '#fee2e2', label: 'Blocked' };
      case 'closed':      return { fg: '#4b5563', bg: '#e5e7eb', label: 'Closed' };
      case 'deferred':    return { fg: '#6d28d9', bg: '#ede9fe', label: 'Deferred' };
      case 'pinned':      return { fg: '#9d174d', bg: '#fce7f3', label: 'Pinned' };
      case 'hooked':      return { fg: '#0f766e', bg: '#ccfbf1', label: 'Hooked' };
      default:            return { fg: '#374151', bg: '#f3f4f6', label: status || '' };
    }
  };

  App.priorityBadge = function (p) {
    if (p === null || p === undefined) return '';
    // Beads priority is 0..4 (0 = critical, 4 = trivial) per upstream.
    const labels = ['P0', 'P1', 'P2', 'P3', 'P4'];
    const colors = ['#dc2626', '#ea580c', '#ca8a04', '#2563eb', '#6b7280'];
    if (p < 0 || p > 4) return '';
    return {
      label: labels[p],
      color: colors[p],
    };
  };

  // ── Native bridge ───────────────────────────────────────────────────
  App.postNative = function (msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.beadsBridge) {
        window.webkit.messageHandlers.beadsBridge.postMessage(msg);
        return true;
      }
    } catch (e) { App.warn('bridge post failed:', e); }
    return false;
  };

  // ── Kick-off ────────────────────────────────────────────────────────
  // Each view sets App.onDataLoaded then we fire.
  document.addEventListener('DOMContentLoaded', function () {
    const pre = window.__nppBeadsPreloadedJsonl;
    if (typeof pre === 'string') App.load(pre);
    if (typeof App.onDataLoaded === 'function') App.onDataLoaded();
  });
})();
