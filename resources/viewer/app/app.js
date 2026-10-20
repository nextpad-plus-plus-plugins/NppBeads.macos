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

  App.load = function (jsonl) {
    App.beads = parseJsonl(jsonl);
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
