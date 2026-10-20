// NppBeads — JSONL→sql.js synthesis shim.
//
// The bundled dicklesworthstone viewer expects to fetch ./beads.sqlite3
// (full Dolt-backed DB). In the lightweight / JSONL-only code path we
// don't have one. Instead the native plugin hands us the contents of
// .beads/issues.jsonl over a WKScriptMessageHandler bridge, we build an
// in-memory SQLite via sql.js, export it to bytes, and return those
// bytes when the viewer's loadDatabase() eventually calls fetch().
//
// Runs at document-start (injected via a <script> tag above every other
// script tag in index.html) so window.fetch is patched BEFORE viewer.js
// tries to use it.

(function () {
  'use strict';

  if (window.__nppBeads) return;
  const NPP = window.__nppBeads = {
    version: 17,  // bump on every bridge.js edit to confirm the page
                  // picked up the latest file (stale WebKit cache check).
    mode: 'jsonl',
    // Prefer the synchronously-preloaded JSONL (injected by BeadsPanel
    // via WKUserScript at document-start) — this removes the IPC race
    // entirely. Fall back to null → async pull.
    jsonl: (typeof window.__nppBeadsPreloadedJsonl === 'string')
             ? window.__nppBeadsPreloadedJsonl : null,
    pendingJsonlResolvers: [],
    dbBytesPromise: null,
    log(...args) { try { console.log('[NppBeads]', ...args); } catch {} },
    warn(...args) { try { console.warn('[NppBeads]', ...args); } catch {} },
    err(...args)  { try { console.error('[NppBeads]', ...args); } catch {} },
  };

  // Capture console output into a rolling buffer so our native diagnostic
  // button can surface what the page logged (the WKWebView inspector
  // isn't always accessible in production builds).
  window.__nppConsoleTail = [];
  (function () {
    function wrap(level, orig) {
      return function () {
        try {
          const parts = [];
          for (let i = 0; i < arguments.length; i++) {
            const a = arguments[i];
            if (a && a.stack) parts.push(String(a.stack));
            else if (typeof a === 'object') { try { parts.push(JSON.stringify(a)); } catch { parts.push(String(a)); } }
            else parts.push(String(a));
          }
          window.__nppConsoleTail.push('[' + level + '] ' + parts.join(' '));
          if (window.__nppConsoleTail.length > 200) window.__nppConsoleTail.shift();
        } catch {}
        return orig.apply(console, arguments);
      };
    }
    if (console.log)   console.log   = wrap('log',   console.log);
    if (console.warn)  console.warn  = wrap('warn',  console.warn);
    if (console.error) console.error = wrap('error', console.error);
    window.addEventListener('error', function (ev) {
      try {
        window.__nppConsoleTail.push('[uncaught] ' +
          (ev.message || '') + ' @ ' + (ev.filename || '?') + ':' + (ev.lineno || '?'));
      } catch {}
    });
    window.addEventListener('unhandledrejection', function (ev) {
      try {
        const r = ev.reason;
        window.__nppConsoleTail.push('[unhandledrejection] ' +
          (r && (r.stack || r.message) ? (r.stack || r.message) : String(r)));
      } catch {}
    });
  })();

  // ── Native bridge ────────────────────────────────────────────────────
  // beadsBridge is installed by BeadsPanel.mm (WKScriptMessageHandler).
  // On the native side we reply by evaluateJavaScript'ing a call to
  // window.__nppBeads.receiveJsonl(jsonText) / .receiveError(msg).
  function postNative(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.beadsBridge) {
        window.webkit.messageHandlers.beadsBridge.postMessage(msg);
        return true;
      }
    } catch (e) { NPP.err('bridge post failed:', e); }
    return false;
  }

  NPP.receiveJsonl = function (text) {
    NPP.jsonl = text || '';
    const queued = NPP.pendingJsonlResolvers.splice(0);
    queued.forEach((resolve) => resolve(NPP.jsonl));
  };
  NPP.receiveError = function (msg) {
    NPP.err('native error:', msg);
    const queued = NPP.pendingJsonlResolvers.splice(0);
    queued.forEach((resolve) => resolve(''));  // empty DB
  };

  function requestJsonl() {
    if (NPP.jsonl !== null) {
      NPP.log('requestJsonl: immediate (len=' + NPP.jsonl.length + ')');
      return Promise.resolve(NPP.jsonl);
    }
    NPP.log('requestJsonl: waiting for native push...');
    return new Promise((resolve) => {
      NPP.pendingJsonlResolvers.push(resolve);
      const ok = postNative({ type: 'getJsonl' });
      NPP.log('requestJsonl: postNative returned ' + ok);
    });
  }

  // ── JSONL parser (robust against partial-line truncation) ────────────
  function parseJsonl(text) {
    const out = [];
    if (!text) return out;
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i].trim();
      if (!raw) continue;
      try { out.push(JSON.parse(raw)); }
      catch (e) { NPP.warn(`line ${i + 1} JSON parse failed:`, e.message); }
    }
    return out;
  }

  // ── Schema + synthesis ──────────────────────────────────────────────
  //
  // Mirrors the real Dolt export: tables `issues`, `dependencies`,
  // `export_meta`, FTS5 virtual table `issues_fts`, and a view
  // `issue_overview_mv` that the viewer SELECTs from everywhere.
  //
  // Computed in JS (no WASM): blocks_count, depends_on_count,
  // triage_score (very rough), critical_path_depth (0 placeholder).
  // Core schema — MUST succeed on every sql.js build.
  const SCHEMA_SQL = `
    CREATE TABLE issues (
      id TEXT PRIMARY KEY,
      title TEXT,
      description TEXT,
      status TEXT,
      priority INTEGER,
      issue_type TEXT,
      assignee TEXT,
      labels TEXT,
      created_at TEXT,
      updated_at TEXT,
      closed_at TEXT,
      close_reason TEXT,
      compaction_level INTEGER DEFAULT 0,
      original_size INTEGER DEFAULT 0,
      created_by TEXT,
      acceptance_criteria TEXT,
      design TEXT,
      notes TEXT,
      estimated_hours REAL,
      actual_hours REAL
    );
    CREATE TABLE dependencies (
      issue_id TEXT,
      depends_on_id TEXT,
      type TEXT,
      created_at TEXT,
      created_by TEXT
    );
    CREATE INDEX idx_dep_issue    ON dependencies(issue_id);
    CREATE INDEX idx_dep_depends  ON dependencies(depends_on_id);
    CREATE TABLE export_meta (key TEXT PRIMARY KEY, value TEXT);
  `;

  // FTS5 virtual table — may be missing from this sql-wasm build. We
  // try it in its own step; if it fails we fall back to a plain-LIKE
  // shim table below (empty, but the viewer's search queries won't
  // crash when they SELECT FROM issues_fts).
  const FTS_SCHEMA_SQL = `
    CREATE VIRTUAL TABLE issues_fts USING fts5(
      id UNINDEXED, title, description,
      content='issues', content_rowid='rowid'
    );
  `;
  const FTS_FALLBACK_SQL = `
    CREATE TABLE issues_fts (id TEXT, title TEXT, description TEXT);
  `;

  // After inserting issues, the viewer wants a view with computed
  // aggregate columns. We materialize by embedding a subquery — sql.js
  // supports views fine.
  // Mirror the upstream `bv --export-pages` schema for `issue_overview_mv`
  // (see beads_viewer/pkg/export/sqlite_schema.go). Upstream makes it a
  // real TABLE populated once at export; we make it a VIEW over `issues`
  // + a stub `issue_metrics` table so the zero defaults (COALESCE) fall
  // out of the join. Graph metrics (pagerank/betweenness/critical_path/
  // triage) are 0 because Phase 1 doesn't run the graph engine — the
  // viewer's WHERE col > 0 queries return empty rather than erroring.
  const METRICS_STUB_SQL = `
    CREATE TABLE IF NOT EXISTS issue_metrics (
      issue_id TEXT PRIMARY KEY,
      pagerank REAL DEFAULT 0,
      betweenness REAL DEFAULT 0,
      critical_path_depth INTEGER DEFAULT 0,
      triage_score REAL DEFAULT 0,
      blocks_count INTEGER DEFAULT 0,
      blocked_by_count INTEGER DEFAULT 0
    );
  `;

  const VIEW_SQL = `
    CREATE VIEW issue_overview_mv AS
    SELECT
      i.id, i.title, i.description, i.status, i.priority, i.issue_type,
      i.assignee, i.labels, i.created_at, i.updated_at, i.closed_at,
      COALESCE(m.pagerank,             0) AS pagerank,
      COALESCE(m.betweenness,          0) AS betweenness,
      COALESCE(m.critical_path_depth,  0) AS critical_path_depth,
      COALESCE(m.triage_score,
        CASE i.status WHEN 'open'        THEN 100
                      WHEN 'in_progress' THEN 80
                      WHEN 'blocked'     THEN 40
                      WHEN 'closed'      THEN 0
                      ELSE 50 END)          AS triage_score,
      COALESCE(m.blocks_count,
        (SELECT COUNT(*) FROM dependencies d
          WHERE d.depends_on_id = i.id AND (d.type = 'blocks' OR d.type = '')))
                                            AS blocks_count,
      COALESCE(m.blocked_by_count,
        (SELECT COUNT(*) FROM dependencies d
          WHERE d.issue_id = i.id AND (d.type = 'blocks' OR d.type = '')))
                                            AS blocked_by_count,
      -- Upstream aliases for the same counts (viewer uses both names).
      COALESCE(m.blocked_by_count,
        (SELECT COUNT(*) FROM dependencies d
          WHERE d.issue_id = i.id AND (d.type = 'blocks' OR d.type = '')))
                                            AS blocker_count,
      COALESCE(m.blocks_count,
        (SELECT COUNT(*) FROM dependencies d
          WHERE d.depends_on_id = i.id AND (d.type = 'blocks' OR d.type = '')))
                                            AS dependent_count,
      COALESCE(m.critical_path_depth,  0) AS critical_depth,
      0 AS in_cycle,
      0 AS comment_count,
      (SELECT GROUP_CONCAT(issue_id) FROM (
        SELECT issue_id FROM dependencies
        WHERE depends_on_id = i.id AND (type = 'blocks' OR type = '')
        ORDER BY issue_id))                 AS blocks_ids,
      (SELECT GROUP_CONCAT(depends_on_id) FROM (
        SELECT depends_on_id FROM dependencies
        WHERE issue_id = i.id AND (type = 'blocks' OR type = '')
        ORDER BY depends_on_id))            AS blocked_by_ids
    FROM issues i
    LEFT JOIN issue_metrics m ON i.id = m.issue_id;
  `;

  async function synthesizeDB() {
    try {
      return await _synthesizeDBInner();
    } catch (e) {
      NPP.err('synthesizeDB threw:', (e && e.stack) || e);
      throw e;
    }
  }

  async function _synthesizeDBInner() {
    NPP.log('synthesizing DB from JSONL...');

    // 1) Pull JSONL from native.
    const jsonlText = await requestJsonl();
    const issues = parseJsonl(jsonlText);
    NPP.log(`parsed ${issues.length} issue records`);

    // 2) Load sql.js from the bundled vendor copy. Use the viewer's own
    //    initSqlJs if already installed (viewer.js creates it on demand);
    //    otherwise pull vendor/sql-wasm.js ourselves.
    NPP.log('step: call __nppSqlJs');
    // Use the preloaded sql-wasm.js (stashed as window.__nppSqlJs by
    // index.html BEFORE viewer.js clobbers window.initSqlJs).
    const sqlJs = window.__nppSqlJs || window.initSqlJs;
    if (typeof sqlJs !== 'function') {
      throw new Error('sql-wasm.js not loaded (expected window.__nppSqlJs)');
    }
    const SQL = await sqlJs({
      locateFile: (f) => './vendor/' + f,
    });

    NPP.log('step: create Database');
    const db = new SQL.Database();
    NPP.log('step: schema (core)');
    db.run(SCHEMA_SQL);
    NPP.log('step: schema (fts5 try)');
    let ftsEnabled = false;
    try {
      db.run(FTS_SCHEMA_SQL);
      ftsEnabled = true;
      NPP.log('step: fts5 enabled');
    } catch (e) {
      NPP.warn('fts5 unavailable in this sql-wasm build:', e && e.message);
      try { db.run(FTS_FALLBACK_SQL); }
      catch (e2) { NPP.err('fts5 fallback failed:', e2 && e2.message); }
    }

    // 3) Insert issues + dependencies.
    NPP.log('step: prepare inserts');
    const insIssue = db.prepare(
      "INSERT OR REPLACE INTO issues " +
      "(id,title,description,status,priority,issue_type,assignee,labels," +
      "created_at,updated_at,closed_at,close_reason,compaction_level," +
      "original_size,created_by,acceptance_criteria,design,notes," +
      "estimated_hours,actual_hours) " +
      "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    );
    const insDep = db.prepare(
      "INSERT INTO dependencies (issue_id,depends_on_id,type,created_at,created_by) " +
      "VALUES (?,?,?,?,?)"
    );

    NPP.log('step: insert ' + issues.length + ' issues');
    db.run('BEGIN');
    let insertedIssues = 0, insertedDeps = 0, skipped = 0;
    try {
      for (let i = 0; i < issues.length; i++) {
        const r = issues[i];
        const labels = Array.isArray(r.labels)
          ? r.labels.join(',')
          : (typeof r.labels === 'string' ? r.labels : null);
        try {
          insIssue.run([
            r.id || null,
            r.title || null,
            r.description || null,
            r.status || null,
            (typeof r.priority === 'number') ? r.priority : null,
            r.issue_type || null,
            r.assignee || null,
            labels,
            r.created_at || null,
            r.updated_at || null,
            r.closed_at || null,
            r.close_reason || null,
            (typeof r.compaction_level === 'number') ? r.compaction_level : 0,
            (typeof r.original_size    === 'number') ? r.original_size    : 0,
            r.created_by || null,
            r.acceptance_criteria || null,
            r.design || null,
            r.notes || null,
            (typeof r.estimated_hours === 'number') ? r.estimated_hours : null,
            (typeof r.actual_hours    === 'number') ? r.actual_hours    : null,
          ]);
          insertedIssues++;
        } catch (e) {
          skipped++;
          if (skipped < 3) NPP.err('issue insert failed idx=' + i + ' id=' + r.id, e && e.message);
        }
        const deps = Array.isArray(r.dependencies) ? r.dependencies : [];
        for (const d of deps) {
          try {
            insDep.run([
              d.issue_id || r.id || null,
              d.depends_on_id || null,
              d.type || 'blocks',
              d.created_at || null,
              d.created_by || null,
            ]);
            insertedDeps++;
          } catch (e) {
            if (insertedDeps < 3) NPP.err('dep insert failed', e && e.message);
          }
        }
      }
      db.run('COMMIT');
      NPP.log('step: committed (issues=' + insertedIssues + ', deps=' + insertedDeps + ', skipped=' + skipped + ')');
    } catch (e) {
      NPP.err('transaction failed:', e && e.message);
      try { db.run('ROLLBACK'); } catch {}
    } finally {
      try { insIssue.free(); } catch {}
      try { insDep.free(); }   catch {}
    }

    // 4) Populate FTS from the issues table.
    //
    // issues_fts was created with content='issues' (external-content
    // FTS5). The canonical population command for this configuration
    // is `INSERT INTO issues_fts(issues_fts) VALUES('rebuild')` —
    // a special form that rebuilds the FTS index from the content
    // table. The direct `INSERT INTO issues_fts(rowid,...) SELECT ...`
    // pattern silently leaves the index empty in some sql-wasm builds
    // (observed: Issues view searches return 0 results even though bd
    // shows matching issues). We try the rebuild first and keep the
    // direct INSERT as a belt-and-suspenders fallback.
    NPP.log('step: populate FTS');
    if (ftsEnabled) {
      let populated = false;
      try {
        db.run("INSERT INTO issues_fts(issues_fts) VALUES('rebuild');");
        populated = true;
      } catch (e1) {
        NPP.warn('FTS rebuild failed, trying direct INSERT:', e1 && e1.message);
      }
      if (!populated) {
        try {
          db.run("INSERT INTO issues_fts(rowid,id,title,description) " +
                 "SELECT rowid,id,title,description FROM issues;");
        } catch (e2) {
          NPP.warn('FTS populate failed:', e2 && e2.message);
        }
      }
    }

    // 5) Create the view the viewer selects from (1:1 with upstream).
    NPP.log('step: create metrics stub + view');
    db.run(METRICS_STUB_SQL);
    db.run(VIEW_SQL);

    // 6) Export metadata — viewer surfaces these on the dashboard.
    NPP.log('step: insert export_meta');
    const metaRows = [
      ['source',         'npp-beads-jsonl'],
      ['issue_count',    String(insertedIssues)],
      ['generated_at',   new Date().toISOString()],
      ['viewer_version', 'npp-beads-v1.0.0'],
      ['schema_version', '1'],
    ];
    const insMeta = db.prepare("INSERT OR REPLACE INTO export_meta(key,value) VALUES (?,?)");
    metaRows.forEach((r) => insMeta.run(r));
    insMeta.free();

    NPP.log('step: export');
    const bytes = db.export();
    db.close();
    NPP.log('synthesized DB: ' + bytes.byteLength + ' bytes');
    return bytes;
  }

  function getDbBytes() {
    if (!NPP.dbBytesPromise) NPP.dbBytesPromise = synthesizeDB();
    return NPP.dbBytesPromise;
  }

  // Allow native-initiated refresh (file changed → rebuild DB from new JSONL).
  NPP.reloadJsonl = function (text) {
    NPP.jsonl = text || '';
    NPP.dbBytesPromise = null;
    // Re-dispatch a custom event so the viewer can re-init itself.
    try { window.dispatchEvent(new Event('npp-beads:jsonl-reloaded')); } catch {}
  };

  // ── fetch monkey-patch ───────────────────────────────────────────────
  // Must happen before viewer.js starts. viewer.js calls:
  //   fetch('./beads.sqlite3.config.json')   [optional]
  //   fetch('./beads.sqlite3')               [required]
  //   fetch('./data/beads.sqlite3')          [fallback]
  //   fetch('./chunks/NNNNN.bin')            [only when config.chunked=true]
  const origFetch = window.fetch.bind(window);

  function normalize(urlLike) {
    try { return new URL(urlLike, window.location.href).pathname; }
    catch { return String(urlLike || ''); }
  }

  async function dbResponse() {
    const bytes = await getDbBytes();
    // Uint8Array can back a Response body directly.
    return new Response(bytes, {
      status: 200,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': String(bytes.byteLength),
      },
    });
  }

  function jsonResponse(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Load a same-origin resource via XHR — reliable across WKWebView's
  // file:// quirks — and wrap the bytes in a Response with an explicit
  // Content-Type. This is how we defeat "instantiateStreaming rejects
  // because mime isn't application/wasm" on file://.
  function xhrResponse(url, contentType) {
    return new Promise((resolve, reject) => {
      try {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.responseType = 'arraybuffer';
        xhr.onload = () => {
          // file:// returns status 0 on success in WebKit.
          if (xhr.status === 200 || xhr.status === 0) {
            resolve(new Response(xhr.response, {
              status: 200,
              headers: {
                'Content-Type': contentType,
                'Content-Length': String(xhr.response && xhr.response.byteLength || 0),
              },
            }));
          } else {
            reject(new Error('xhr status ' + xhr.status));
          }
        };
        xhr.onerror = () => reject(new Error('xhr error for ' + url));
        xhr.send();
      } catch (e) { reject(e); }
    });
  }

  window.fetch = function patchedFetch(input, init) {
    // fetch() accepts strings, URL objects, and Request objects. We need
    // to handle all three — bv_graph.js passes a URL instance.
    let urlStr = '';
    if (typeof input === 'string') {
        urlStr = input;
    } else if (input && typeof input.href === 'string') {
        urlStr = input.href;           // URL object
    } else if (input && typeof input.url === 'string') {
        urlStr = input.url;            // Request object
    } else if (input != null) {
        urlStr = String(input);
    }
    const p = normalize(urlStr);
    NPP.log('fetch: ' + urlStr);

    // .wasm no longer needs a JS-side intercept: the nppbeads:// scheme
    // handler serves wasm files with the correct application/wasm MIME,
    // so instantiateStreaming works natively. Left the preloaded bytes
    // available on __nppBeadsWasmBytesMap as a belt-and-suspenders
    // fallback in case any other script wants them directly.

    // Config file: always claim "not chunked, no hash" — viewer tolerates
    // config.chunked=false and an absent hash (no OPFS caching).
    if (p.endsWith('/beads.sqlite3.config.json')) {
      return Promise.resolve(jsonResponse({ chunked: false, hash: null }));
    }
    // Main DB — and the ./data/beads.sqlite3 fallback path.
    if (p.endsWith('/beads.sqlite3') || p.endsWith('/data/beads.sqlite3')) {
      return dbResponse();
    }
    // sql-wasm.wasm is preloaded as Uint8Array at document-start and
    // passed to sql.js via { wasmBinary } — so fetch for it should never
    // fire. If it does (e.g. someone imports sql.js elsewhere), fall
    // through to the native fetch.
    // Optional JSON data files the viewer sometimes pokes at. Empty {} is
    // a safe answer — viewer treats them as absent.
    if (p.endsWith('/data/meta.json') ||
        p.endsWith('/data/history.json') ||
        p.endsWith('/data/triage.json') ||
        p.endsWith('/data/project_health.json') ||
        p.endsWith('/data/graph_layout.json')) {
      return Promise.resolve(jsonResponse({}));
    }
    return origFetch(input, init);
  };

  // ── Request/response bridge for write operations ──────────────────
  // JS calls window.__nppBridge.call('updateBead', {id,status,...}) and
  // awaits a Promise. Native-side BeadsPanel posts back via
  // window.__nppBridge.resolve(reqId, payload) which fulfills the
  // matching pending Promise. This is how Phase 3 CRUD flows: UI
  // applies optimistic state, calls __nppBridge, rolls back on failure.
  const pending = new Map();
  let   reqSeq  = 0;
  window.__nppBridge = {
    /** Returns a Promise<{ok, bead?, error?, errorKind?, blockers?}>. */
    call(type, payload) {
      if (!window.webkit || !window.webkit.messageHandlers ||
          !window.webkit.messageHandlers.beadsBridge) {
        return Promise.reject(new Error('native bridge unavailable'));
      }
      const reqId = 'r' + (++reqSeq) + '_' + Date.now().toString(36);
      const msg = Object.assign({ type, reqId }, payload || {});
      return new Promise((resolve, reject) => {
        // 15s timeout: if native doesn't resolve (crash, etc.) we reject
        // rather than leave the UI frozen.
        const timer = setTimeout(() => {
          pending.delete(reqId);
          reject(new Error('bridge timeout (' + type + ')'));
        }, 15000);
        pending.set(reqId, { resolve, reject, timer });
        try {
          window.webkit.messageHandlers.beadsBridge.postMessage(msg);
        } catch (e) {
          clearTimeout(timer);
          pending.delete(reqId);
          reject(e);
        }
      });
    },
    /** Native calls this via evaluateJavaScript. Shape: { ok, bead?, ... }. */
    resolve(reqId, payload) {
      const p = pending.get(reqId);
      if (!p) { NPP.warn('stray resolve for ' + reqId); return; }
      pending.delete(reqId);
      clearTimeout(p.timer);
      p.resolve(payload || {});
    },
  };

  NPP.log('bridge.js active — mode=' + NPP.mode);

  // ── ⌘+ / ⌘- / ⌘0 zoom shortcuts ─────────────────────────────────────
  // Captures the standard browser zoom keystrokes and routes them to
  // the native side (BeadsPanel._adjustPageZoomBy: / _setPageZoom:).
  // WKWebView's pageZoom is the actual zoom — we just relay intent.
  //
  // Uses `capture` + preventDefault so the webview's own handlers don't
  // react first. Skipped when the user is typing in an editable field
  // (otherwise ⌘- / ⌘= inside a textarea would be stolen).
  window.addEventListener('keydown', function (e) {
    if (!e.metaKey) return;
    const target = e.target;
    const tag = target && target.tagName;
    const editable = (target && target.isContentEditable) ||
                     tag === 'INPUT' || tag === 'TEXTAREA';
    if (editable) return;

    let kind = null;
    // `=` is the unshifted key on a US keyboard where Shift+= gives `+`.
    // Both should count as "zoom in" to match browser convention.
    if (e.key === '=' || e.key === '+') kind = 'zoomIn';
    else if (e.key === '-' || e.key === '_') kind = 'zoomOut';
    else if (e.key === '0')                  kind = 'zoomReset';
    if (!kind) return;

    e.preventDefault();
    e.stopPropagation();
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.beadsBridge) {
        window.webkit.messageHandlers.beadsBridge.postMessage({ type: kind });
      }
    } catch (err) { NPP.warn('zoom bridge post failed:', err); }
  }, true /* capture phase */);

  // ── Native-facing helpers that reach into the Rich viewer's Alpine
  //    root. All guard against Alpine not being loaded (our own app/
  //    pages have no Alpine, so these are safe no-ops there). We use
  //    the public Alpine.$data(el) API — stable across Alpine v3.x —
  //    rather than poking at _x_dataStack directly. ─────────────────
  function richApp() {
    try {
      if (!window.Alpine || typeof window.Alpine.$data !== 'function') return null;
      const el = document.querySelector('[x-data]');
      if (!el) return null;
      return window.Alpine.$data(el);
    } catch (e) { NPP.warn('richApp failed:', e); return null; }
  }

  // Called by BeadsPanel._pushSearchQuery when the toolbar search is
  // typed in while on the Rich Issues view. Sets searchQuery on the
  // Alpine beadsApp root and triggers loadIssues(). Diagnostic log
  // lets us trace via ctxCopyDiagnostics' __nppConsoleTail whether the
  // bridge actually reached this function (helpful when Issues search
  // appears to do nothing).
  window.__nppRichSearch = function (q) {
    const query = (q || '').trim();
    const app = richApp();
    if (!app) {
      NPP.warn('__nppRichSearch called but Alpine root not ready; q="' + query + '"');
      return false;
    }
    NPP.log('__nppRichSearch q="' + query + '" (view=' + (app.view || '?') +
            ', hasLoad=' + (typeof app.loadIssues === 'function') + ')');
    app.searchQuery = query;
    app.page = 1;
    if (typeof app.loadIssues === 'function') {
      try { app.loadIssues(); }
      catch (e) { NPP.warn('loadIssues failed:', e && e.message); }
    }
    return true;
  };

  // Called by BeadsPanel.viewDidMoveToWindow (detach/dock transitions)
  // and prepareForShow (fresh open). Clears any zombie state — the
  // graph detail panel especially likes to get stuck visible after a
  // reparent because its enter/leave transitions don't complete when
  // the hosting window changes.
  window.__nppClearTransientState = function () {
    const app = richApp();
    if (!app) return false;
    try {
      if (app.graphDetailNode !== undefined) app.graphDetailNode = null;
      if (app.selectedIssue   !== undefined) app.selectedIssue   = null;
    } catch (e) { NPP.warn('clearTransient failed:', e); }
    return true;
  };
})();
