// Facet filters shared by the Activity and Graph views: Type / Priority /
// Status / Assignee dropdowns plus the Blocked (All · Ready · Blocked) and
// Blocking (All · Blockers) segmented controls. Each view supplies how to
// read its own issue records; the controls, their wording and their
// semantics are identical in both. Styles live in facets.css (.npp-facets).
//
//   const f = NppFacets.create({
//     container,                     // controls are appended here, in order
//     beads: () => [...],            // records the menus list values from
//     typeOf, priorityOf, statusOf, assigneeOf,   // record → value
//     blockingState: (b) => ({ blockers, blocking }),  // open counts
//     typeLabel, statusLabel,        // value → menu label
//     onChange,                      // any facet changed
//     epics: {                       // optional — adds a leading Epic menu
//       list: () => [{ id, label }], //   epics to offer, in menu order
//       of:   (b) => [epicId, ...],  //   epics a record belongs to
//     },
//   });
//   f.passes(b)   f.active()   f.set({ status: [...], blocked: 'ready' })

(function () {
  'use strict';

  const NO_ASSIGNEE = '__unassigned__';
  const TYPE_ORDER   = ['epic', 'feature', 'task', 'bug', 'chore', 'decision'];
  // bd's built-in statuses (`bd statuses`, bd 1.3). The Status menu always
  // lists all of them; custom statuses found in the data are appended.
  const STATUS_ORDER = ['open', 'in_progress', 'blocked', 'deferred', 'closed',
                        'pinned', 'hooked'];
  const PRIO_ORDER   = ['0', '1', '2', '3', '4'];

  function create(opts) {
    const container = opts.container;
    const sets = {
      epic:     new Set(),   // epic ids; a record passes if it is in any
      type:     new Set(),
      priority: new Set(),
      status:   new Set(),
      assignee: new Set(),   // assignee names; NO_ASSIGNEE = unassigned
    };
    // Blocking state, as in `bd ready`: only blockers that aren't closed count.
    //   blocked  'all' | 'ready' (no open blockers) | 'blocked' (≥1 open blocker)
    //   blocking 'all' | 'blockers' (not closed and holding up ≥1 open issue)
    let blockedMode  = 'all';
    let blockingMode = 'all';
    const syncers = [];

    const valueOf = {
      type:     (b) => opts.typeOf(b) || 'task',
      priority: (b) => { const p = opts.priorityOf(b); return p == null ? null : String(p); },
      status:   (b) => opts.statusOf(b) || '',
      assignee: (b) => opts.assigneeOf(b) || NO_ASSIGNEE,
    };

    function active() {
      return sets.epic.size > 0 ||
             sets.type.size > 0 || sets.priority.size > 0 || sets.status.size > 0 ||
             sets.assignee.size > 0 || blockedMode !== 'all' || blockingMode !== 'all';
    }

    function passes(b) {
      if (sets.epic.size && !opts.epics.of(b).some(id => sets.epic.has(id))) return false;
      for (const key of ['type', 'priority', 'status', 'assignee']) {
        const set = sets[key];
        if (!set.size) continue;
        const v = valueOf[key](b);
        if (v == null || !set.has(v)) return false;
      }
      if (blockedMode !== 'all' || blockingMode !== 'all') {
        const s = opts.blockingState(b);
        if (blockedMode === 'ready'   && s.blockers > 0) return false;
        if (blockedMode === 'blocked' && s.blockers === 0) return false;
        if (blockingMode === 'blockers' &&
            (opts.statusOf(b) === 'closed' || s.blocking === 0)) return false;
      }
      return true;
    }

    // Values the menus list: the canonical order filtered to what the data
    // uses (Status always lists every built-in), unknown values appended
    // alphabetically, assignees by name with "(unassigned)" first.
    function presentValues(key) {
      if (key === 'epic') return opts.epics.list().map(e => e.id);
      const present = new Set();
      for (const b of (opts.beads() || [])) {
        const v = valueOf[key](b);
        if (v != null && v !== '') present.add(v);
      }
      if (key === 'assignee') {
        const names = [...present].filter(v => v !== NO_ASSIGNEE).sort();
        return present.has(NO_ASSIGNEE) ? [NO_ASSIGNEE].concat(names) : names;
      }
      const order = key === 'type' ? TYPE_ORDER : key === 'priority' ? PRIO_ORDER : STATUS_ORDER;
      const inOrder = key === 'status' ? order.slice() : order.filter(v => present.has(v));
      const extras  = [...present].filter(v => order.indexOf(v) === -1).sort();
      return inOrder.concat(extras);
    }

    function closeAllMenus() {
      for (const m of container.querySelectorAll('.filter-menu')) m.hidden = true;
      for (const f of container.querySelectorAll('.filter.is-open')) f.classList.remove('is-open');
    }

    // One facet dropdown: a button + a checkbox menu populated on open
    // (so it reflects the current data and filter state each time).
    function buildFilter(name, key, labelFn, menuClass) {
      const set = sets[key];
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
      syncers.push(syncBtn);

      const menu = document.createElement('div');
      menu.className = 'filter-menu' + (menuClass ? ' ' + menuClass : '');
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
          opts.onChange();
        });
        allRow.appendChild(allCb);
        allRow.appendChild(document.createTextNode('All'));
        menu.appendChild(allRow);

        for (const v of presentValues(key)) {
          const row = document.createElement('label');
          row.className = 'filter-opt';
          const cb = document.createElement('input');
          cb.type = 'checkbox';
          cb.checked = set.has(v);
          cb.addEventListener('change', () => {
            if (cb.checked) set.add(v); else set.delete(v);
            allCb.checked = set.size === 0;
            syncBtn();
            opts.onChange();
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

    // A small All / … segmented control. options: [[value, label, tooltip]].
    function buildSegmented(name, options, get, setMode) {
      const wrap = document.createElement('div');
      wrap.className = 'seg';
      wrap.setAttribute('role', 'group');
      wrap.setAttribute('aria-label', name);
      const buttons = [];
      function sync() {
        for (const b of buttons) {
          const on = b.dataset.value === get();
          b.classList.toggle('is-active', on);
          b.setAttribute('aria-pressed', on ? 'true' : 'false');
        }
      }
      for (const [value, label, tip] of options) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'seg-btn';
        b.dataset.value = value;
        b.textContent = label;
        b.title = name + ': ' + tip;
        b.addEventListener('click', () => {
          if (get() === value) return;
          setMode(value);
          sync();
          opts.onChange();
        });
        buttons.push(b);
        wrap.appendChild(b);
      }
      sync();
      syncers.push(sync);
      return wrap;
    }

    if (opts.epics) {
      container.appendChild(buildFilter('Epic', 'epic', (v) => {
        const e = opts.epics.list().find(x => x.id === v);
        return e ? e.label : v;
      }, 'is-wide'));
    }
    container.appendChild(buildFilter('Type', 'type',
      (v) => opts.typeLabel(v)));
    container.appendChild(buildFilter('Priority', 'priority',
      (v) => 'P' + v));
    container.appendChild(buildFilter('Status', 'status',
      (v) => opts.statusLabel(v)));
    container.appendChild(buildFilter('Assignee', 'assignee',
      (v) => v === NO_ASSIGNEE ? '(unassigned)' : v));

    container.appendChild(buildSegmented('Blocked', [
      ['all',     'All',     'Show all issues'],
      ['ready',   'Ready',   'No open blockers'],
      ['blocked', 'Blocked', 'Waiting on at least one open blocker'],
    ], () => blockedMode, (v) => { blockedMode = v; }));
    container.appendChild(buildSegmented('Blocking', [
      ['all',      'All',      'Show all issues'],
      ['blockers', 'Blockers', 'Open issues that other open issues are waiting on'],
    ], () => blockingMode, (v) => { blockingMode = v; }));

    // Click anywhere outside an open filter closes it.
    document.addEventListener('click', (e) => {
      if (!e.target.closest || !e.target.closest('.filter')) closeAllMenus();
    });

    // Replace the whole facet state (unnamed facets reset to "all") and
    // refresh the controls. Does not call onChange — the caller re-renders.
    function set(spec) {
      spec = spec || {};
      for (const key of ['epic', 'type', 'priority', 'status', 'assignee']) {
        sets[key].clear();
        for (const v of (spec[key] || [])) sets[key].add(String(v));
      }
      blockedMode  = ['ready', 'blocked'].indexOf(spec.blocked) !== -1 ? spec.blocked : 'all';
      blockingMode = spec.blocking === 'blockers' ? 'blockers' : 'all';
      closeAllMenus();
      for (const s of syncers) s();
    }

    return { passes, active, set };
  }

  window.NppFacets = { create, NO_ASSIGNEE };
})();
