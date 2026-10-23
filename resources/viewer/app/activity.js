// Beads Activity view — Phase 6, restructured.
//
// Issues grouped by Epic. Each group is an epic header row (collapsible)
// followed by the epic's descendants as an indented tree (parent-child
// deps). Issues with no epic anywhere up their parent chain land in a
// distinct "Not in any epic" group. Groups and rows are ordered by most
// recent activity (updated_at DESC) so the view still reads as "what
// moved lately". Every row shows the issue type.
//
// Clicking a row (or its Open button) opens the shared view/edit modal
// from detail.js right here — no hop to the Board view. Hovering a row
// still expands the inline preview (description + facts).
//
// Data source: window.__nppApp.beads (parsed from JSONL). The modal does
// its own fetchBead for comments.

(function () {
  'use strict';
  const App = window.__nppApp;
  if (!App) { console.warn('[Activity] __nppApp missing'); return; }

  const listEl = document.getElementById('activity-list');
  const sumEl  = document.getElementById('activity-summary');
  const ctrlEl = document.getElementById('activity-controls');

  const NO_EPIC = '__no_epic__';
  const ROW_CAP = 200;   // render cap — agents can create 10k+ beads

  // ── View-local facet filters + expand/collapse-all ──────────────────
  // These live only in this view (the search box drives App.filter.query
  // separately). A bead must pass ALL active facets AND the search query
  // to be shown. An empty facet set means "all".
  const typeFilter   = new Set();
  const prioFilter   = new Set();
  const statusFilter = new Set();

  const TYPE_ORDER   = ['epic', 'feature', 'task', 'bug', 'chore', 'decision'];
  const STATUS_ORDER = ['open', 'in_progress', 'blocked', 'deferred', 'closed'];
  const PRIO_ORDER   = ['0', '1', '2', '3', '4'];

  let expandAllBox = null;   // the master expand/collapse checkbox
  let shownGroups  = [];     // {id, collapsed} for each group in the last render

  function filtersActive() {
    const q = (App.filter && App.filter.query) ? App.filter.query : '';
    return !!q || typeFilter.size > 0 || prioFilter.size > 0 || statusFilter.size > 0;
  }
  function passesFacets(b) {
    if (typeFilter.size && !typeFilter.has(b.type || 'task')) return false;
    if (prioFilter.size && (b.priority == null || !prioFilter.has(String(b.priority)))) return false;
    if (statusFilter.size && !statusFilter.has(b.status || '')) return false;
    return true;
  }

  // Distinct facet values actually present in the data, in canonical
  // order (unknown values appended alphabetically) — so each menu lists
  // exactly the types/priorities/statuses this project uses.
  function presentValues(kind) {
    const present = new Set();
    for (const b of (App.beads || [])) {
      if (kind === 'types')      present.add(b.type || 'task');
      else if (kind === 'prios') { if (b.priority != null) present.add(String(b.priority)); }
      else if (kind === 'stats') { if (b.status) present.add(b.status); }
    }
    const order = kind === 'types' ? TYPE_ORDER : kind === 'prios' ? PRIO_ORDER : STATUS_ORDER;
    const inOrder = order.filter(v => present.has(v));
    const extras  = [...present].filter(v => order.indexOf(v) === -1).sort();
    return inOrder.concat(extras);
  }

  function closeAllMenus() {
    if (!ctrlEl) return;
    for (const m of ctrlEl.querySelectorAll('.filter-menu')) m.hidden = true;
    for (const f of ctrlEl.querySelectorAll('.filter.is-open')) f.classList.remove('is-open');
  }

  // One facet dropdown: a button + a checkbox menu populated on open
  // (so it reflects the current data and filter state each time).
  function buildFilter(name, set, kind, labelFn) {
    const wrap = document.createElement('div');
    wrap.className = 'filter';

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'filter-btn';
    function syncBtn() {
      btn.textContent = name + (set.size ? ' (' + set.size + ')' : '') + ' ▾';
      btn.classList.toggle('is-active', set.size > 0);
    }
    syncBtn();

    const menu = document.createElement('div');
    menu.className = 'filter-menu';
    menu.hidden = true;
    menu.addEventListener('click', (e) => e.stopPropagation());

    function populate() {
      menu.innerHTML = '';
      const allRow = document.createElement('label');
      allRow.className = 'filter-opt filter-all';
      const allCb = document.createElement('input');
      allCb.type = 'checkbox';
      allCb.checked = set.size === 0;
      allCb.addEventListener('change', () => {
        set.clear();
        syncBtn();
        populate();
        render();
      });
      allRow.appendChild(allCb);
      allRow.appendChild(document.createTextNode('All'));
      menu.appendChild(allRow);

      for (const v of presentValues(kind)) {
        const row = document.createElement('label');
        row.className = 'filter-opt';
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = set.has(v);
        cb.addEventListener('change', () => {
          if (cb.checked) set.add(v); else set.delete(v);
          allCb.checked = set.size === 0;
          syncBtn();
          render();
        });
        const lab = document.createElement('span');
        lab.className = 'filter-opt-label';
        lab.textContent = labelFn(v);
        row.appendChild(cb);
        row.appendChild(lab);
        menu.appendChild(row);
      }
    }

    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const willOpen = menu.hidden;
      closeAllMenus();
      if (willOpen) { populate(); menu.hidden = false; wrap.classList.add('is-open'); }
    });

    wrap.appendChild(btn);
    wrap.appendChild(menu);
    return wrap;
  }

  function onExpandAll() {
    const expand = expandAllBox.checked;
    for (const g of shownGroups) toggles[g.id] = !expand;
    saveToggles(toggles);
    render();
  }

  function syncExpandBox() {
    if (!expandAllBox) return;
    if (!shownGroups.length) {
      expandAllBox.checked = false;
      expandAllBox.indeterminate = false;
      expandAllBox.disabled = true;
      return;
    }
    expandAllBox.disabled = false;
    let anyCollapsed = false, anyExpanded = false;
    for (const g of shownGroups) {
      if (g.collapsed) anyCollapsed = true; else anyExpanded = true;
    }
    expandAllBox.checked = !anyCollapsed;                 // all expanded
    expandAllBox.indeterminate = anyCollapsed && anyExpanded;
  }

  function buildControls() {
    if (!ctrlEl) return;
    ctrlEl.innerHTML = '';

    const expandLbl = document.createElement('label');
    expandLbl.className = 'activity-expand';
    expandLbl.title = 'Expand or collapse every epic';
    expandAllBox = document.createElement('input');
    expandAllBox.type = 'checkbox';
    expandAllBox.addEventListener('change', onExpandAll);
    expandLbl.appendChild(expandAllBox);
    expandLbl.appendChild(document.createTextNode('Expand all'));
    ctrlEl.appendChild(expandLbl);

    ctrlEl.appendChild(buildFilter('Type',     typeFilter,   'types',
      (v) => App.typeIcon(v) + ' ' + v));
    ctrlEl.appendChild(buildFilter('Priority', prioFilter,   'prios',
      (v) => 'P' + v));
    ctrlEl.appendChild(buildFilter('Status',   statusFilter, 'stats',
      (v) => App.statusColor(v).label));

    // Rightmost: same New-issue entry point as the Board (shared modal
    // in detail.js). No optimistic hook — the native re-push after the
    // create refreshes the feed.
    const newBtn = document.createElement('button');
    newBtn.type = 'button';
    newBtn.id = 'new-issue-btn';
    newBtn.className = 'new-issue-btn';
    newBtn.title = 'Create a new issue (bd create)';
    newBtn.textContent = '+ New issue';
    newBtn.addEventListener('click', () => App.openNewIssueModal());
    ctrlEl.appendChild(newBtn);

    // Click anywhere outside an open filter closes it.
    document.addEventListener('click', (e) => {
      if (!e.target.closest('.filter')) closeAllMenus();
    });
  }

  // ── Collapse state ──────────────────────────────────────────────────
  // Explicit user toggles persist per group id. Groups without a stored
  // choice default to collapsed when the epic is closed, expanded
  // otherwise.
  const COLLAPSED_KEY = 'nppbeads.activity.collapsed.v2';
  function loadToggles() {
    try {
      const raw = localStorage.getItem(COLLAPSED_KEY);
      const obj = raw ? JSON.parse(raw) : null;
      return (obj && typeof obj === 'object') ? obj : {};
    } catch { return {}; }
  }
  function saveToggles(t) {
    try { localStorage.setItem(COLLAPSED_KEY, JSON.stringify(t)); } catch {}
  }
  const toggles = loadToggles();
  function isCollapsed(groupId, epic) {
    if (Object.prototype.hasOwnProperty.call(toggles, groupId)) return !!toggles[groupId];
    return !!(epic && epic.status === 'closed');
  }

  // ── Hierarchy ───────────────────────────────────────────────────────
  function recency(b) { return String(b.updatedAt || b.createdAt || ''); }
  function byRecency(a, b) { return recency(b).localeCompare(recency(a)); }

  // parent-child deps: {issue_id: child, depends_on_id: parent}. bd may
  // embed the edge on either side's record, so read both directions.
  function buildParentMap(beads, byId) {
    const parentOf = new Map();
    for (const b of beads) {
      for (const d of (b.deps || [])) {
        if (!d) continue;
        const kind = d.dependency_type || d.type || 'blocks';
        if (kind !== 'parent-child') continue;
        const child = d.issue_id, parent = d.depends_on_id;
        if (!child || !parent || child === parent) continue;
        if (!byId.has(child) || !byId.has(parent)) continue;
        if (!parentOf.has(child)) parentOf.set(child, parent);
      }
    }
    return parentOf;
  }

  // Top-most epic in the ancestor chain (cycle-safe), or null.
  function groupEpicFor(id, parentOf, byId) {
    let top = null;
    const seen = new Set([id]);
    let cur = parentOf.get(id);
    while (cur && !seen.has(cur)) {
      seen.add(cur);
      const b = byId.get(cur);
      if (b && b.type === 'epic') top = cur;
      cur = parentOf.get(cur);
    }
    return top;
  }

  // Returns [{ id, epic|null, members: [beads], latest }] sorted by recency.
  function buildGroups(beads) {
    const byId = new Map(beads.map(b => [b.id, b]));
    const parentOf = buildParentMap(beads, byId);
    const groups = new Map();
    function group(key, epic) {
      let g = groups.get(key);
      if (!g) { g = { id: key, epic, members: [], latest: '' }; groups.set(key, g); }
      return g;
    }
    for (const b of beads) {
      let key, epic = null;
      if (b.type === 'epic' && !groupEpicFor(b.id, parentOf, byId)) {
        key = b.id; epic = b;              // top-level epic = its own group
      } else {
        const top = groupEpicFor(b.id, parentOf, byId);
        if (top) { key = top; epic = byId.get(top); }
        else      { key = NO_EPIC; }
      }
      const g = group(key, epic);
      if (epic !== b) g.members.push(b);
      if (recency(b) > g.latest) g.latest = recency(b);
    }
    const out = [...groups.values()];
    out.sort((a, b) => b.latest.localeCompare(a.latest));
    return { groups: out, parentOf, byId };
  }

  // Tree of a group's members: a member nests under its parent when the
  // parent is also a member of the same group, else at the group root.
  function buildTree(g, parentOf) {
    const memberIds = new Set(g.members.map(b => b.id));
    const children = new Map();   // parent id (or '') → [beads]
    for (const b of g.members) {
      const p = parentOf.get(b.id);
      const key = (p && memberIds.has(p)) ? p : '';
      if (!children.has(key)) children.set(key, []);
      children.get(key).push(b);
    }
    for (const arr of children.values()) arr.sort(byRecency);
    return children;
  }

  // ── Render ──────────────────────────────────────────────────────────
  function render() {
    listEl.innerHTML = '';
    const beads = (App.beads || []).slice();
    if (beads.length === 0) {
      listEl.appendChild(emptyNote('No issues in this project yet.'));
      sumEl.textContent = '';
      shownGroups = [];
      syncExpandBox();
      return;
    }

    const q = (App.filter && App.filter.query) ? App.filter.query : '';
    const active = filtersActive();
    const matches = (b) => (!q || App.matchesQuery(b, q)) && passesFacets(b);
    const { groups, parentOf } = buildGroups(beads);

    const shown = [];
    let rows = 0, shownIssues = 0, capped = false;
    let epicCount = 0, noEpicCount = 0;

    for (const g of groups) {
      if (g.epic) epicCount++; else noEpicCount = g.members.length;
      const children = buildTree(g, parentOf);

      // Visibility under search: a node is visible when it matches or
      // any descendant does. Precompute per node.
      const visible = new Map();
      function computeVisible(parentKey) {
        let any = false;
        for (const b of (children.get(parentKey) || [])) {
          const self = matches(b);
          const sub = computeVisible(b.id);
          visible.set(b.id, self || sub);
          if (self || sub) any = true;
        }
        return any;
      }
      const anyChild = computeVisible('');
      const epicMatches = g.epic ? matches(g.epic) : false;
      if (active && !anyChild && !epicMatches) continue;
      if (!g.epic && !g.members.length) continue;

      const collapsed = isCollapsed(g.id, g.epic);
      if (rows >= ROW_CAP) { capped = true; break; }
      const groupEl = buildGroup(g, collapsed, epicMatches, active);
      listEl.appendChild(groupEl);
      shown.push({ id: g.id, collapsed });
      rows++;
      if (g.epic && (epicMatches || !active)) shownIssues++;
      if (collapsed) continue;

      // Depth-first emit of visible rows into the group body. Each row
      // knows whether it is the last visible sibling so the tree
      // connector can draw └ instead of ├.
      const body = groupEl.querySelector('.activity-group-body');
      const stack = [];
      const push = (parentKey, depth) => {
        const arr = (children.get(parentKey) || []).filter(b => visible.get(b.id));
        for (let i = arr.length - 1; i >= 0; i--) {
          stack.push({ b: arr[i], depth, last: i === arr.length - 1 });
        }
      };
      push('', 0);
      while (stack.length) {
        const { b, depth, last } = stack.pop();
        if (rows >= ROW_CAP) { capped = true; break; }
        body.appendChild(buildRow(b, depth, last, parentOf, matches(b)));
        rows++;
        if (matches(b)) shownIssues++;
        push(b.id, depth + 1);
      }
      if (capped) break;
      if (active && epicMatches && !anyChild && g.members.length) {
        body.appendChild(emptyNote(g.members.length + ' item' +
          (g.members.length === 1 ? '' : 's') + ' hidden by filters', 1));
      }
    }

    if (capped) {
      listEl.appendChild(emptyNote('… list capped at ' + ROW_CAP +
        ' rows (use search to narrow)'));
    }
    if (rows === 0 && active) {
      listEl.appendChild(emptyNote('No issues match the current filters.'));
    }

    shownGroups = shown;
    syncExpandBox();

    const total = beads.length;
    let summary = total + ' issue' + (total === 1 ? '' : 's') +
      ' · ' + epicCount + ' epic' + (epicCount === 1 ? '' : 's') +
      ' · ' + noEpicCount + ' not in any epic';
    if (active) summary += ' · ' + shownIssues + ' match';
    sumEl.textContent = summary;
  }

  function emptyNote(text, indent) {
    const n = document.createElement('div');
    n.className = 'activity-empty';
    if (indent) n.classList.add('is-inline');
    n.textContent = text;
    return n;
  }

  function typePill(type) {
    const t = document.createElement('span');
    t.className = 'pill pill-type activity-type';
    t.textContent = App.typeIcon(type) + ' ' + (type || 'task');
    t.title = 'type: ' + (type || 'task');
    return t;
  }

  function statusPill(b) {
    const s = App.statusColor(b.status);
    const status = document.createElement('span');
    status.className = 'pill';
    status.style.background = s.bg;
    status.style.color      = s.fg;
    status.textContent = s.label;
    return status;
  }

  function openButton(id) {
    const openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.className = 'activity-open-btn';
    openBtn.textContent = 'Open';
    openBtn.title = 'View / edit ' + id;
    openBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      App.openBeadModal(id);
    });
    return openBtn;
  }

  // Row click → modal, unless the click hit a control or the user was
  // selecting text (ids are selectable for copying).
  function onRowClick(id, e) {
    if (e.target.closest('button, a, input, select, textarea')) return;
    const sel = window.getSelection && window.getSelection();
    if (sel && String(sel).length) return;
    App.openBeadModal(id);
  }

  // Group = header row (the epic, or the "no epic" bucket) + a body
  // holding the member rows as an indented tree. Caret toggles the
  // body; clicking anywhere else on an epic header (or its Open button)
  // opens the epic in the edit modal, same as any other row.
  function buildGroup(g, collapsed, epicMatches, active) {
    const row = document.createElement('div');
    row.className = 'activity-group' + (g.epic ? '' : ' is-no-epic') +
                    (collapsed ? ' is-collapsed' : '');
    if (g.epic) row.dataset.beadId = g.epic.id;

    const main = document.createElement('div');
    main.className = 'activity-group-main';

    const caret = document.createElement('button');
    caret.type = 'button';
    caret.className = 'activity-caret';
    caret.title = collapsed ? 'Expand' : 'Collapse';
    caret.setAttribute('aria-label', caret.title);
    caret.innerHTML = '<svg width="10" height="10" viewBox="0 0 10 10">' +
      '<path d="M2 3 L5 7 L8 3" fill="none" stroke="currentColor" ' +
      'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    caret.addEventListener('click', (e) => {
      e.stopPropagation();
      toggles[g.id] = !collapsed;
      saveToggles(toggles);
      render();
    });
    main.appendChild(caret);

    if (g.epic) {
      main.appendChild(typePill('epic'));
      const idEl = document.createElement('span');
      idEl.className = 'activity-id';
      idEl.textContent = g.epic.id;
      idEl.title = g.epic.id;
      main.appendChild(idEl);
      const titleEl = document.createElement('div');
      titleEl.className = 'activity-title-cell activity-group-title';
      titleEl.textContent = g.epic.title || '(no title)';
      titleEl.title = g.epic.title || '';
      if (active && !epicMatches) titleEl.classList.add('is-context');
      main.appendChild(titleEl);
    } else {
      const badge = document.createElement('span');
      badge.className = 'pill pill-type activity-type activity-no-epic-pill';
      badge.textContent = '⊘ no epic';
      main.appendChild(badge);
      const titleEl = document.createElement('div');
      titleEl.className = 'activity-title-cell activity-group-title';
      titleEl.textContent = 'Not in any epic';
      main.appendChild(titleEl);
    }

    const metaEl = document.createElement('div');
    metaEl.className = 'activity-meta';
    const count = document.createElement('span');
    count.className = 'activity-count';
    count.textContent = g.members.length + ' item' + (g.members.length === 1 ? '' : 's');
    metaEl.appendChild(count);
    if (g.epic) {
      metaEl.appendChild(statusPill(g.epic));
      const p = App.priorityBadge(g.epic.priority);
      if (p) {
        const pEl = document.createElement('span');
        pEl.className = 'pill';
        pEl.style.background = p.color;
        pEl.style.color = '#fff';
        pEl.textContent = p.label;
        metaEl.appendChild(pEl);
      }
    }
    const when = document.createElement('span');
    when.className = 'activity-time';
    when.textContent = App.fmtTime(g.latest);
    when.title = g.latest;
    metaEl.appendChild(when);
    if (g.epic) metaEl.appendChild(openButton(g.epic.id));
    main.appendChild(metaEl);
    row.appendChild(main);

    if (g.epic) {
      // Epic header behaves like an issue row: click → modal.
      main.addEventListener('click', (e) => onRowClick(g.epic.id, e));
      row.appendChild(buildPreview(g.epic, null));
    } else {
      main.addEventListener('click', (e) => {
        if (e.target.closest('button, a')) return;
        toggles[g.id] = !collapsed;
        saveToggles(toggles);
        render();
      });
    }

    const body = document.createElement('div');
    body.className = 'activity-group-body';
    row.appendChild(body);
    return row;
  }

  function buildRow(b, depth, isLast, parentOf, isMatch) {
    const row = document.createElement('div');
    row.className = 'activity-row';
    row.dataset.beadId = b.id;
    row.style.setProperty('--depth', String(depth));
    if (!isMatch) row.classList.add('is-context');
    if (isLast) row.classList.add('is-last');   // tree connector draws └

    const main = document.createElement('div');
    main.className = 'activity-row-main';

    const lead = document.createElement('div');
    lead.className = 'activity-lead';
    lead.appendChild(typePill(b.type));
    const idEl = document.createElement('span');
    idEl.className = 'activity-id';
    idEl.textContent = b.id;
    idEl.title = b.id;   // tooltip lets user see full id even when narrow
    lead.appendChild(idEl);
    main.appendChild(lead);

    const titleEl = document.createElement('div');
    titleEl.className = 'activity-title-cell';
    titleEl.textContent = b.title || '(no title)';
    titleEl.title = b.title || '';
    main.appendChild(titleEl);

    const metaEl = document.createElement('div');
    metaEl.className = 'activity-meta';
    metaEl.appendChild(statusPill(b));

    const p = App.priorityBadge(b.priority);
    if (p) {
      const pEl = document.createElement('span');
      pEl.className = 'pill';
      pEl.style.background = p.color;
      pEl.style.color = '#fff';
      pEl.textContent = p.label;
      metaEl.appendChild(pEl);
    }

    if (b.assignee) {
      const aEl = document.createElement('span');
      aEl.className = 'activity-assignee';
      aEl.textContent = '@' + b.assignee;
      metaEl.appendChild(aEl);
    }

    const when = document.createElement('span');
    when.className = 'activity-time';
    when.textContent = App.fmtTime(b.updatedAt || b.createdAt);
    when.title = b.updatedAt || b.createdAt || '';
    metaEl.appendChild(when);

    metaEl.appendChild(openButton(b.id));
    main.appendChild(metaEl);
    row.appendChild(main);
    row.addEventListener('click', (e) => onRowClick(b.id, e));

    // Hover preview — pre-rendered so there's no lag on first hover.
    row.appendChild(buildPreview(b, parentOf));
    return row;
  }

  function buildPreview(b, parentOf) {
    const wrap = document.createElement('div');
    wrap.className = 'activity-preview';

    // Description — truncated to keep the expanded row bounded.
    const descRaw = (typeof b.description === 'string') ? b.description : '';
    if (descRaw.trim().length) {
      const body = document.createElement('div');
      body.className = 'activity-preview-body';
      const shortTxt = descRaw.length > 600 ? descRaw.slice(0, 600) + '…' : descRaw;
      // Preview stays plain-text so the row layout can't be broken by
      // someone pasting raw HTML inside a description. Whitespace is
      // preserved via CSS `white-space: pre-wrap` — keeps bullet lists
      // and indented code legible without running our markdown renderer
      // (which would style too heavily for a compact preview).
      body.textContent = shortTxt;
      if (descRaw.length > 600) body.classList.add('is-truncated');
      wrap.appendChild(body);
    } else {
      const empty = document.createElement('p');
      empty.className = 'activity-preview-empty';
      empty.textContent = '(no description)';
      wrap.appendChild(empty);
    }

    // Facts row — quick overview of type, parent, label count, dep counts.
    const facts = document.createElement('div');
    facts.className = 'activity-preview-facts';

    function addFact(key, val) {
      if (val === null || val === undefined || val === '') return;
      const f = document.createElement('span');
      const k = document.createElement('span');
      k.className = 'fact-key';
      k.textContent = key + ':';
      const v = document.createElement('span');
      v.className = 'fact-val';
      v.textContent = ' ' + val;
      f.appendChild(k);
      f.appendChild(v);
      facts.appendChild(f);
    }

    addFact('type', b.type || null);
    if (parentOf && parentOf.has(b.id)) addFact('parent', parentOf.get(b.id));
    if (b.labels && b.labels.length) {
      addFact('labels', b.labels.slice(0, 6).join(', ') +
        (b.labels.length > 6 ? ` (+${b.labels.length - 6})` : ''));
    }

    // Dep counts — deps is the raw `dependencies` array from the JSONL
    // record (we normalize to .deps in app.js). Each entry has
    // issue_id / depends_on_id / type.
    const deps = Array.isArray(b.deps) ? b.deps : [];
    let blockedByN = 0, blocksN = 0;
    for (const d of deps) {
      if (!d) continue;
      const kind = d.dependency_type || d.type || 'blocks';
      if (kind !== 'blocks') continue;
      if (d.issue_id === b.id)           blockedByN++;
      else if (d.depends_on_id === b.id) blocksN++;
    }
    if (blockedByN) addFact('blocked by', blockedByN);
    if (blocksN)    addFact('blocks',     blocksN);

    if (b.sourceRepo) addFact('source', App.sourceRepoLabel(b.sourceRepo));

    wrap.appendChild(facts);
    return wrap;
  }

  buildControls();

  App.onDataLoaded = render;
  App.onRefresh    = render;
  App.applyFilter  = render;

  if (App.beads && App.beads.length) render();
})();
