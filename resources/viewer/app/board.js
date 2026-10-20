// Board view — status-based kanban. Columns: Open, In Progress,
// Blocked, Closed. DnD between columns. Closed is collapsed by default
// (matches vscode-beads UX). Optimistic status overrides for instant
// feedback; real persistence wires in Phase 3.
//
// Ported in spirit from jdillon/vscode-beads/src/webview/views/
// KanbanBoard.tsx (Apache-2.0) — de-Reacted to vanilla JS.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const App = window.__nppApp;
  if (!App) { console.error('[Board] app.js not loaded'); return; }

  const COLUMNS = [
    { status: 'open',        label: 'Open'         },
    { status: 'in_progress', label: 'In Progress'  },
    { status: 'blocked',     label: 'Blocked'      },
    { status: 'closed',      label: 'Closed'       },
  ];

  // Optimistic status overrides: instant visual response to a drop,
  // cleared once the real data catches up (native re-push). A Map here
  // vs object so keys can be arbitrary strings with no prototype
  // pollution.
  const optimistic = new Map();

  // ── Status mode ─────────────────────────────────────────────────────
  // 'raw'       — group by the stored `status` field (what bd wrote).
  // 'effective' — promote open/in_progress issues that have at least one
  //               non-closed `blocks` dependency into the Blocked column
  //               (matches what `bd ready` / `bd status` consider blocked).
  // The raw `status` field is never rewritten by bd just because a dep
  // opened — the graph-based blocked state is computed on the fly. This
  // toggle surfaces that distinction without changing any data.
  const MODE_KEY = 'nppbeads.board.statusMode';
  function loadMode() {
    try {
      const v = localStorage.getItem(MODE_KEY);
      return v === 'effective' ? 'effective' : 'raw';
    } catch { return 'raw'; }
  }
  function saveMode(m) {
    try { localStorage.setItem(MODE_KEY, m); } catch {}
  }
  let statusMode = loadMode();

  function hasOpenBlocker(bead) {
    if (!bead || !bead.deps || !bead.deps.length) return false;
    for (const d of bead.deps) {
      const kind = d.dependency_type || d.type || 'blocks';
      if (kind !== 'blocks') continue;
      // bd embeds the target's current status on each dep entry, so we
      // can decide without a cross-lookup. Treat an absent status as
      // 'open' — a conservative default so an export without statuses
      // still surfaces blockage rather than silently hiding it.
      const s = d.status || 'open';
      if (s !== 'closed') return true;
    }
    return false;
  }

  // Persisted column collapse state (per-browser-tab; survives reload).
  const COLLAPSED_KEY = 'nppbeads.board.collapsed';
  function loadCollapsed() {
    try {
      const raw = localStorage.getItem(COLLAPSED_KEY);
      if (!raw) return new Set(['closed']);  // sensible default
      const arr = JSON.parse(raw);
      return new Set(Array.isArray(arr) ? arr : ['closed']);
    } catch { return new Set(['closed']); }
  }
  function saveCollapsed(set) {
    try { localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...set])); }
    catch {}
  }
  const collapsed = loadCollapsed();

  const boardEl    = document.getElementById('board');
  const cardTpl    = document.getElementById('card-tpl');
  const colTpl     = document.getElementById('col-tpl');

  function effectiveStatus(b) {
    const ov = optimistic.get(b.id);
    const base = ov || b.status;
    if (statusMode !== 'effective') return base;
    if ((base === 'open' || base === 'in_progress') && hasOpenBlocker(b)) {
      return 'blocked';
    }
    return base;
  }

  function groupByStatus(beads) {
    const out = { open: [], in_progress: [], blocked: [], closed: [] };
    for (const b of beads) {
      if (!App.matchesQuery(b, App.filter.query)) continue;
      const s = effectiveStatus(b);
      if (out[s]) out[s].push(b);
    }
    // Within each column, sort: priority asc (P0 first), then updated desc.
    for (const s of Object.keys(out)) {
      out[s].sort((a, b) => {
        const pa = a.priority ?? 99, pb = b.priority ?? 99;
        if (pa !== pb) return pa - pb;
        return String(b.updatedAt || '').localeCompare(String(a.updatedAt || ''));
      });
    }
    return out;
  }

  // ── DnD handlers ────────────────────────────────────────────────────
  // Drag-guard: when a card is being dragged, we must NOT re-render
  // the board out from under the user's cursor — the DOM node being
  // dragged would get replaced and the drag would die. The live-sync
  // poll (Phase 4) and the watcher fire refreshes independently of DnD,
  // so we defer them until dragend. See App.onRefresh below.
  let isDraggingCard = false;
  let pendingRefresh = false;
  let dragWatchdog   = null;  // safety: fire a reset if dragend is missed

  function _beginDragGuard() {
    isDraggingCard = true;
    if (dragWatchdog) clearTimeout(dragWatchdog);
    // 8s is plenty — DnD on macOS rarely exceeds 2-3s. If we hit the
    // watchdog, the user probably dropped outside the window and the
    // browser swallowed the dragend. We release the guard so the next
    // refresh isn't stuck forever.
    dragWatchdog = setTimeout(() => {
      dragWatchdog   = null;
      isDraggingCard = false;
      _flushDeferredRefresh();
    }, 8000);
  }
  function _endDragGuard() {
    isDraggingCard = false;
    if (dragWatchdog) { clearTimeout(dragWatchdog); dragWatchdog = null; }
    _flushDeferredRefresh();
  }
  function _flushDeferredRefresh() {
    if (!pendingRefresh) return;
    pendingRefresh = false;
    _runRefresh();
  }

  function onDragStart(e) {
    const id = e.currentTarget.dataset.beadId;
    if (!id) return;
    e.dataTransfer.setData('text/plain', id);
    e.dataTransfer.effectAllowed = 'move';
    e.currentTarget.classList.add('card-dragging');
    _beginDragGuard();
  }
  function onDragEnd(e) {
    e.currentTarget.classList.remove('card-dragging');
    _endDragGuard();
  }
  function onDragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    const col = e.currentTarget;
    col.classList.add('col-drag-over');
  }
  function onDragLeave(e) {
    e.currentTarget.classList.remove('col-drag-over');
  }
  function onDrop(e) {
    e.preventDefault();
    const col = e.currentTarget;
    col.classList.remove('col-drag-over');
    const newStatus = col.dataset.status;
    const beadId = e.dataTransfer.getData('text/plain');
    if (!beadId || !newStatus) return;

    const bead = App.beads.find(b => b.id === beadId);
    if (!bead) return;
    const oldStatus = effectiveStatus(bead);
    if (oldStatus === newStatus) return;

    // Optimistic move — render instantly; then ask native to persist.
    optimistic.set(beadId, newStatus);
    render();

    // No bridge / no bd backend → stay optimistic + show a hint.
    if (!window.__nppBridge) {
      showToast('Moved ' + bead.id + ' (ephemeral — no bridge)');
      return;
    }
    window.__nppBridge.call('updateBead', {
      id: beadId,
      status: newStatus,
    }).then((resp) => {
      if (resp.ok) {
        // Real data will arrive via onRefresh broadcast from native;
        // optimistic.delete in onRefresh handles cleanup.
        showToast(bead.id + ' → ' + App.statusColor(newStatus).label);
      } else {
        // Roll back the optimistic move.
        optimistic.delete(beadId);
        render();
        const msg = resp.error || 'update failed';
        if (resp.errorKind === 1 /* ReadOnly */) {
          showToast('Install `bd` to enable editing');
        } else {
          showToast(bead.id + ' · ' + msg);
        }
      }
    }).catch((err) => {
      optimistic.delete(beadId);
      render();
      showToast(bead.id + ' · ' + (err.message || err));
    });
  }

  // ── Toggle column collapse ──────────────────────────────────────────
  function onToggleCol(e) {
    const col = e.currentTarget.closest('.col');
    const s = col.dataset.status;
    if (collapsed.has(s)) collapsed.delete(s); else collapsed.add(s);
    saveCollapsed(collapsed);
    render();
  }

  // ── Card click: show in-place detail modal ─────────────────────────
  // No navigation — all the bead's info is shown in an overlay directly
  // on the Board. Click outside or press Esc to close. Dependency chips
  // are clickable and open the linked bead in the same modal.
  function onCardClick(e) {
    if (e.target.closest('.card-id')) return;  // let the <a> handle it
    const id = e.currentTarget.dataset.beadId;
    if (!id) return;
    openBeadModal(id);
  }

  // The detail/edit modal + its helpers live in detail.js (shared with
  // the Activity view). Alias what this file still uses.
  const el                    = App.el;
  const findBead              = App.findBead;
  const showToast             = App.showToast;
  const openBeadModal         = App.openBeadModal;
  const refreshDepSuggestions = App.refreshDepSuggestions;
  // After a delete from the modal, drop any optimistic column override
  // so the next render doesn't flash the deleted card.
  App.onBeadDeleted = (id) => { optimistic.delete(id); };


  // ── Render ──────────────────────────────────────────────────────────
  function buildCard(b) {
    const node = cardTpl.content.firstElementChild.cloneNode(true);
    node.dataset.beadId = b.id;
    node.querySelector('.card-type').textContent = App.typeIcon(b.type);
    node.querySelector('.card-type').title = b.type;
    const idA = node.querySelector('.card-id');
    idA.textContent = b.id;
    idA.href = '#/issue/' + encodeURIComponent(b.id);

    const title = node.querySelector('.card-title');
    title.textContent = b.title || '(no title)';
    title.title = b.title || '';

    const meta = node.querySelector('.card-meta');
    meta.innerHTML = '';

    const p = App.priorityBadge(b.priority);
    if (p) {
      const sp = document.createElement('span');
      sp.className = 'pill';
      sp.style.background = p.color;
      sp.style.color = '#fff';
      sp.textContent = p.label;
      meta.appendChild(sp);
    }
    if (b.assignee) {
      const sp = document.createElement('span');
      sp.className = 'meta-assignee';
      sp.textContent = '@' + b.assignee;
      meta.appendChild(sp);
    }
    if (b.sourceRepo) {
      const sp = document.createElement('span');
      sp.className = 'pill pill-source-repo';
      sp.textContent = App.sourceRepoLabel(b.sourceRepo);
      sp.title = 'source: ' + b.sourceRepo;   // full path on hover
      meta.appendChild(sp);
    }
    const labelsToShow = b.labels.slice(0, 3);
    for (const l of labelsToShow) {
      const sp = document.createElement('span');
      sp.className = 'pill pill-label';
      sp.style.borderColor = App.labelColor(l);
      sp.style.color       = App.labelColor(l);
      sp.textContent = l;
      meta.appendChild(sp);
    }
    if (b.labels.length > labelsToShow.length) {
      const sp = document.createElement('span');
      sp.className = 'meta-more';
      sp.textContent = '+' + (b.labels.length - labelsToShow.length);
      meta.appendChild(sp);
    }

    node.addEventListener('dragstart', onDragStart);
    node.addEventListener('dragend',   onDragEnd);
    node.addEventListener('click',     onCardClick);
    return node;
  }

  function buildColumn(cfg, items, unfilteredCount) {
    const node = colTpl.content.firstElementChild.cloneNode(true);
    node.dataset.status = cfg.status;
    node.classList.add('col-' + cfg.status);
    if (collapsed.has(cfg.status)) node.classList.add('is-collapsed');

    node.querySelector('.col-title').textContent = cfg.label;
    const countEl = node.querySelector('.col-count');
    if (App.filter.query && unfilteredCount !== items.length) {
      countEl.textContent = items.length + '/' + unfilteredCount;
    } else {
      countEl.textContent = String(items.length);
    }

    node.querySelector('.col-hdr').addEventListener('click', onToggleCol);
    node.addEventListener('dragover',  onDragOver);
    node.addEventListener('dragleave', onDragLeave);
    node.addEventListener('drop',      onDrop);

    const body = node.querySelector('.col-body');
    if (items.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'col-empty';
      empty.textContent = App.filter.query && unfilteredCount > 0
        ? 'no match (' + unfilteredCount + ' filtered)'
        : 'no items';
      body.appendChild(empty);
    } else {
      // Cap rendering at 200 cards/col — agents can spam create, and
      // rendering 10k nodes kills scroll perf. Users can search to
      // narrow.
      const cap = Math.min(items.length, 200);
      for (let i = 0; i < cap; i++) body.appendChild(buildCard(items[i]));
      if (cap < items.length) {
        const more = document.createElement('div');
        more.className = 'col-empty';
        more.textContent = '… +' + (items.length - cap) + ' more (use search)';
        body.appendChild(more);
      }
    }
    return node;
  }

  function unfilteredCounts() {
    const out = { open: 0, in_progress: 0, blocked: 0, closed: 0 };
    for (const b of App.beads) {
      const s = effectiveStatus(b);
      if (out.hasOwnProperty(s)) out[s]++;
    }
    return out;
  }

  function render() {
    const grouped   = groupByStatus(App.beads);
    const unCounts  = unfilteredCounts();
    boardEl.innerHTML = '';
    for (const cfg of COLUMNS) {
      const items = grouped[cfg.status] || [];
      boardEl.appendChild(buildColumn(cfg, items, unCounts[cfg.status]));
    }
  }


  // ── New issue modal ─────────────────────────────────────────────────
  // Tiny inline form that posts `createBead` through the native bridge.
  // Kept self-contained so the Board view doesn't need to know about the
  // Rich/Issues views (they can grow their own entry points later).
  function openNewIssueModal() {
    closeNewIssueModal();
    const tpl = document.getElementById('new-issue-tpl');
    if (!tpl) return;
    const frag = tpl.content.firstElementChild.cloneNode(true);
    document.body.appendChild(frag);

    const overlay  = document.getElementById('new-issue-overlay');
    const form     = overlay.querySelector('.new-issue-form');
    const closeBtn = overlay.querySelector('.modal-close');
    const cancel   = overlay.querySelector('.new-issue-cancel');
    const submit   = overlay.querySelector('.new-issue-submit');
    const statusEl = overlay.querySelector('.form-status');
    const titleEl  = overlay.querySelector('input[name="title"]');

    // Dep chip-inputs: one for "Blocked by" (upstream), one for "Blocks"
    // (downstream). The shared <datalist id="dep-suggest"> lives in the
    // permanent body (board.html) so the detail-modal dep editor can use
    // the same autocomplete pool without re-defining it.
    refreshDepSuggestions();

    // Wires a chip-input region. Returns an object with `values()` that
    // yields [{id, type}, …] so the caller can build per-chip dep writes.
    //
    // If the region has a <span data-role="type-slot"></span> we mount a
    // dep-type <select> into it — chips created while the select shows
    // "blocks" record type=blocks, chips created while it shows
    // "parent-child" record type=parent-child, etc. Chip type is locked
    // at add time (visible in the chip's little tag suffix).
    function wireChipInput(containerRole) {
      const root = overlay.querySelector('[data-role="' + containerRole + '"]');
      const list = root.querySelector('.chip-list');
      const inp  = root.querySelector('input');
      const slot = root.querySelector('[data-role="type-slot"]');
      let typeSel = null;
      if (slot && typeof App.buildDepTypeSelect === 'function') {
        typeSel = App.buildDepTypeSelect('blocks');
        slot.appendChild(typeSel);
      }
      const entries = new Map();   // id → type
      function addChip(id) {
        id = String(id || '').trim();
        if (!id || entries.has(id)) return;
        const type = typeSel ? typeSel.value : 'blocks';
        entries.set(id, type);
        const bead = App.beads.find(b => b.id === id);
        const chip = document.createElement('span');
        chip.className = 'chip';
        chip.dataset.id = id;
        chip.dataset.type = type;
        chip.title = (bead ? bead.title : id) + '  ·  type: ' + type;
        chip.textContent = id;
        if (type !== 'blocks') {
          // Visually distinguish non-default types so the user can see
          // at a glance which chips will create which kind of dep.
          const tag = document.createElement('span');
          tag.className = 'chip-type-tag';
          tag.textContent = type;
          chip.appendChild(tag);
        }
        const rm = document.createElement('button');
        rm.type = 'button';
        rm.className = 'chip-rm';
        rm.textContent = '×';
        rm.setAttribute('aria-label', 'Remove ' + id);
        rm.addEventListener('click', () => { entries.delete(id); chip.remove(); });
        chip.appendChild(rm);
        list.appendChild(chip);
      }
      inp.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ',' || e.key === 'Tab') {
          const v = inp.value.trim().replace(/,$/, '');
          if (v) { e.preventDefault(); addChip(v); inp.value = ''; }
        } else if (e.key === 'Backspace' && !inp.value) {
          const chips = list.querySelectorAll('.chip');
          if (chips.length) {
            const last = chips[chips.length - 1];
            entries.delete(last.dataset.id);
            last.remove();
          }
        }
      });
      inp.addEventListener('change', () => {
        const v = inp.value.trim();
        if (v) { addChip(v); inp.value = ''; }
      });
      return {
        values() {
          const out = [];
          for (const [id, type] of entries) out.push({ id, type });
          return out;
        },
      };
    }
    const blockerInput = wireChipInput('blockers');
    const blocksInput  = wireChipInput('blocks');

    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) closeNewIssueModal();
    });
    closeBtn.addEventListener('click', closeNewIssueModal);
    cancel.addEventListener('click', closeNewIssueModal);
    document.addEventListener('keydown', newIssueEscHandler);

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const title = titleEl.value.trim();
      if (!title) {
        statusEl.textContent = 'Title is required';
        statusEl.classList.add('is-error');
        titleEl.focus();
        return;
      }
      const data = new FormData(form);
      const labelsRaw = (data.get('labels') || '').toString();
      const labels = labelsRaw.split(',').map(s => s.trim()).filter(Boolean);
      const payload = {
        title,
        issueType:   (data.get('issueType') || 'task').toString(),
        priority:    parseInt(data.get('priority'), 10),
        description: (data.get('description') || '').toString(),
        labels,
      };
      submit.disabled = true;
      statusEl.classList.remove('is-error');
      statusEl.textContent = 'Creating…';

      if (!window.__nppBridge) {
        statusEl.textContent = 'native bridge unavailable';
        statusEl.classList.add('is-error');
        submit.disabled = false;
        return;
      }
      const blockerEntries = blockerInput.values();   // blocking the new issue
      const blocksEntries  = blocksInput.values();    // new issue blocks these
      window.__nppBridge.call('createBead', payload).then(async (resp) => {
        if (!resp.ok) {
          statusEl.textContent = resp.error || 'create failed';
          statusEl.classList.add('is-error');
          submit.disabled = false;
          return;
        }
        const newId = resp.bead && resp.bead.id;
        if (!newId) {
          showToast('issue created');
          closeNewIssueModal();
          return;
        }
        // Sequential dep writes — bd's embedded dolt backend can deadlock
        // on concurrent writes within the same project. Each dep is:
        //   Blocked-by chip: newId depends on chipId   (chipId blocks newId)
        //   Blocks      chip: chipId depends on newId  (newId blocks chipId)
        // Each chip now carries its own dep type (Phase 3.5).
        const totalDeps = blockerEntries.length + blocksEntries.length;
        const failed = [];
        async function postDep(dependent, dependency, depType) {
          try {
            const r = await window.__nppBridge.call('depAdd', {
              dependent, dependency, depType: depType || 'blocks',
            });
            if (!r.ok) failed.push(dependent + '←' + dependency +
                                   ' (' + (r.error || 'failed') + ')');
          } catch (e) {
            failed.push(dependent + '←' + dependency +
                        ' (' + ((e && e.message) || e) + ')');
          }
        }
        if (totalDeps) {
          statusEl.textContent = 'linking ' + totalDeps + ' dep' +
                                 (totalDeps > 1 ? 's' : '') + '…';
          for (const e of blockerEntries) await postDep(newId, e.id, e.type);
          for (const e of blocksEntries)  await postDep(e.id, newId, e.type);
        }
        if (failed.length) {
          showToast(newId + ' created; some deps failed: ' + failed.join('; '));
        } else if (totalDeps) {
          showToast(newId + ' created with ' + totalDeps + ' dep' +
                    (totalDeps > 1 ? 's' : ''));
        } else {
          showToast(newId + ' created');
        }
        optimistic.set(newId, 'open');
        closeNewIssueModal();
      }).catch((err) => {
        statusEl.textContent = (err && err.message) || String(err);
        statusEl.classList.add('is-error');
        submit.disabled = false;
      });
    });

    // Focus the title field and let the user start typing immediately.
    setTimeout(() => titleEl.focus(), 0);
  }
  function closeNewIssueModal() {
    const overlay = document.getElementById('new-issue-overlay');
    if (overlay) overlay.remove();
    document.removeEventListener('keydown', newIssueEscHandler);
  }
  function newIssueEscHandler(e) {
    if (e.key === 'Escape') closeNewIssueModal();
  }
  (function wireNewIssueButton() {
    const btn = document.getElementById('new-issue-btn');
    if (btn) btn.addEventListener('click', openNewIssueModal);
  })();

  // ── Mode toggle wiring ──────────────────────────────────────────────
  function syncModeButtons() {
    const btns = document.querySelectorAll('#board-hdr .mode-btn');
    btns.forEach((b) => {
      const selected = b.dataset.mode === statusMode;
      b.setAttribute('aria-selected', selected ? 'true' : 'false');
    });
  }
  function onModeClick(e) {
    const m = e.currentTarget.dataset.mode;
    if (!m || m === statusMode) return;
    statusMode = m;
    saveMode(m);
    syncModeButtons();
    render();
  }
  function wireModeToggle() {
    const btns = document.querySelectorAll('#board-hdr .mode-btn');
    btns.forEach((b) => b.addEventListener('click', onModeClick));
    syncModeButtons();
  }
  wireModeToggle();

  // ── App wiring ──────────────────────────────────────────────────────
  App.onDataLoaded = render;

  // The actual refresh body, extracted so the drag-guard can defer +
  // replay it without duplicating logic.
  function _runRefresh() {
    // Real data arrived — drop every optimistic override, then render.
    // In Effective mode, if a card's computed state differs from the
    // column the user dragged it to, surface a toast so the snap-back
    // doesn't look like a silent no-op. We stash overrides before
    // clearing so the render-after-refresh shows truth, not stale
    // guesses.
    const prevOverrides = new Map(optimistic);
    optimistic.clear();
    if (statusMode === 'effective') {
      for (const [id, ov] of prevOverrides) {
        const b = App.beads.find(x => x.id === id);
        if (!b) continue;
        const eff = effectiveStatus(b);
        if (eff !== ov) {
          showToast(b.id + ' · shown in ' + App.statusColor(eff).label +
                    ' (has open blockers)');
          break;  // one toast per refresh is enough
        }
      }
    }
    render();
  }

  App.onRefresh = function () {
    if (isDraggingCard) {
      // Defer; dragend will flush. Swallow newer refreshes until then —
      // one final render after the drag is enough.
      pendingRefresh = true;
      return;
    }
    _runRefresh();
  };

  // ── Phase 5 — programmatic entry points from the native editor hooks ──
  // NppBeads.mm fires these after the user triggers
  //   Plugins → NppBeads → Jump to bead under caret (⌘⌥⇧J)
  //   Plugins → NppBeads → Create issue from selection (⌘⌥⇧N)
  // Either the panel was already on Board (JS runs immediately) or the
  // view was switched and this runs inside didFinishNavigation's
  // pending-JS hook. On first-open the JS may beat __nppApp — native
  // stashes `window.__nppBeadsPendingModalId` / `.pendingCreateTitle`
  // and we drain those here. App.openBeadModalById is provided by
  // detail.js.

  App.openNewIssueWithTitle = function (title) {
    openNewIssueModal();
    // Prefill on next tick — openNewIssueModal appends the template,
    // the title input is queryable immediately but we defer to be safe
    // with any Alpine/transition timing (there's no Alpine here but
    // this matches the pattern used for autofocus).
    setTimeout(function () {
      const overlay = document.getElementById('new-issue-overlay');
      if (!overlay) return;
      const input = overlay.querySelector('input[name="title"]');
      if (input && typeof title === 'string' && title.length) {
        input.value = title;
        // Move caret to end for easy editing
        input.setSelectionRange(title.length, title.length);
        input.focus();
      }
    }, 0);
  };

  // Drain any pending directives that native set before we loaded.
  (function drainPending() {
    if (typeof window.__nppBeadsPendingModalId === 'string') {
      const id = window.__nppBeadsPendingModalId;
      delete window.__nppBeadsPendingModalId;
      App.openBeadModalById(id);
    }
    if (typeof window.__nppBeadsPendingCreateTitle === 'string') {
      const title = window.__nppBeadsPendingCreateTitle;
      delete window.__nppBeadsPendingCreateTitle;
      App.openNewIssueWithTitle(title);
    }
  })();
  App.applyFilter  = render;

  // Initial render if data already present (app.js fires DOMContentLoaded
  // listener earlier in same file, but this view may register later).
  if (App.beads.length) render();
})();
