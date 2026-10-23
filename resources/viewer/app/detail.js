// Shared issue detail / edit modal — used by the Board AND Activity
// views (and any future view). Loads after app.js, before the view
// script. Exposes on window.__nppApp:
//   App.openBeadModal(id)      open the view/edit modal for a bead
//   App.closeBeadModal()
//   App.openBeadModalById(id)  alias used by the native entry points
//   App.el / App.findBead / App.showToast / App.refreshDepSuggestions
// Hooks a view may set:
//   App.onBeadDeleted(id)      called after a successful delete so the
//                              view can drop any optimistic state.
// Requires marked + DOMPurify (App.renderMarkdown) and a
// <datalist id="dep-suggest"> in the host page for dep autocomplete.
// ─────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  const App = window.__nppApp;
  if (!App) { console.error('[Detail] app.js not loaded'); return; }
  // Find the original JSONL record for a bead id (has the full
  // description, dependencies, timestamps) — App.beads only has the
  // normalized subset, but the raw deps are on `.deps`.
  function findBead(id) {
    return App.beads.find(b => b.id === id) || null;
  }

  function el(tag, attrs, ...children) {
    const n = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'class') n.className = attrs[k];
      else if (k === 'style') n.setAttribute('style', attrs[k]);
      else if (k.startsWith('on') && typeof attrs[k] === 'function')
        n.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
      else if (attrs[k] != null) n.setAttribute(k, attrs[k]);
    }
    for (const c of children) {
      if (c == null || c === false) continue;
      n.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return n;
  }

  function fmtTime(iso) {
    if (!iso) return null;
    try {
      const d = new Date(iso);
      if (isNaN(d.getTime())) return iso;
      return d.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
    } catch { return iso; }
  }

  function openBeadModal(id) {
    const b = findBead(id);
    closeBeadModal();

    const overlay = el('div', {
      class: 'modal-overlay',
      onclick: (e) => { if (e.target === overlay) closeBeadModal(); },
    });
    overlay.id = 'bead-modal';

    if (!b) {
      overlay.appendChild(el('div', { class: 'modal-card' },
        el('div', { class: 'modal-hdr' },
          el('span', { class: 'modal-id' }, id),
          el('button', {
            class: 'modal-close',
            'aria-label': 'Close',
            onclick: closeBeadModal,
          }, '×'),
        ),
        el('div', { class: 'modal-body' },
          el('p', { class: 'modal-missing' }, 'Issue not found in current project data.'),
        ),
      ));
      document.body.appendChild(overlay);
      return;
    }

    const card = el('div', { class: 'modal-card modal-edit' });

    // Header: type icon + id + close button
    const hdr = el('div', { class: 'modal-hdr' });
    hdr.appendChild(el('span', { class: 'modal-type' }, App.typeIcon(b.type)));
    hdr.appendChild(el('span', { class: 'modal-id' }, b.id));
    const closeBtn = el('button', {
      class: 'modal-close',
      'aria-label': 'Close',
      onclick: closeBeadModal,
    }, '×');
    hdr.appendChild(closeBtn);
    card.appendChild(hdr);

    // Editable body (no <form> — we post per-field on Save).
    const body = el('div', { class: 'modal-body' });

    // Title (editable)
    const titleInput = el('input', {
      type: 'text',
      class: 'edit-title',
      value: b.title || '',
      placeholder: 'Title',
    });
    body.appendChild(el('label', { class: 'field' },
      el('span', { class: 'field-label' }, 'Title'),
      titleInput));

    // Status / priority / type / assignee on one row
    const statusSel = makeSelect('status', [
      ['open',        'Open'],
      ['in_progress', 'In Progress'],
      ['blocked',     'Blocked'],
      ['deferred',    'Deferred'],
      ['closed',      'Closed'],
    ], b.status);
    const prioSel = makeSelect('priority', [
      ['0', 'P0 — critical'],
      ['1', 'P1 — high'],
      ['2', 'P2 — normal'],
      ['3', 'P3 — low'],
      ['4', 'P4 — trivial'],
    ], String(b.priority == null ? 2 : b.priority));
    const typeSel = makeSelect('issueType', [
      ['task', 'task'], ['bug', 'bug'], ['feature', 'feature'],
      ['epic', 'epic'], ['chore', 'chore'], ['decision', 'decision'],
    ], b.type || 'task');
    const assigneeInput = el('input', {
      type: 'text', class: 'edit-assignee',
      value: b.assignee || '', placeholder: '@user',
    });
    const metaRow = el('div', { class: 'field-row' });
    metaRow.appendChild(wrapField('Status',   statusSel));
    metaRow.appendChild(wrapField('Priority', prioSel));
    metaRow.appendChild(wrapField('Type',     typeSel));
    metaRow.appendChild(wrapField('Assignee', assigneeInput));
    body.appendChild(metaRow);

    // Labels (comma-separated)
    const labelsInput = el('input', {
      type: 'text',
      class: 'edit-labels',
      value: (b.labels || []).join(', '),
      placeholder: 'comma, separated, labels',
    });
    body.appendChild(wrapField('Labels', labelsInput));

    // Description — Raw (textarea) | Markdown (rendered preview) toggle.
    // Opens in Markdown when there is something to read, Raw otherwise.
    const descInput = el('textarea', {
      class: 'edit-desc', rows: '8', placeholder: 'Markdown description…',
    });
    descInput.value = b.description || '';
    body.appendChild(mdField('Description', descInput, {
      initial: descInput.value.trim() ? 'markdown' : 'raw',
    }));

    // Dependencies — editable in Phase 3.5. We keep a persistent
    // container and re-render it after every dep op so the modal
    // reflects the new state immediately (the Board refresh also fires
    // via _broadcastDataChanged, but that updates App.beads; the open
    // modal doesn't re-open on its own).
    const depContainer = el('div', { class: 'modal-dep-editor' });
    body.appendChild(depContainer);
    renderDepEditor(depContainer, b.id);

    // Phase 6 — comments thread. JSONL export doesn't carry comments,
    // so we fire a fetchBead bridge call and render them when it
    // resolves. While pending, a subtle placeholder stops the section
    // from flickering empty→populated. The add-comment form is always
    // present so the user can start typing before fetch resolves.
    const commentsContainer = el('div', { class: 'modal-comments' });
    body.appendChild(commentsContainer);
    renderComments(commentsContainer, b.id, { loading: true });
    if (window.__nppBridge) {
      window.__nppBridge.call('fetchBead', { id: b.id })
        .then((resp) => {
          if (resp && resp.ok && resp.bead) {
            renderComments(commentsContainer, b.id, {
              loading: false,
              comments: Array.isArray(resp.bead.comments) ? resp.bead.comments : [],
            });
          } else {
            renderComments(commentsContainer, b.id, {
              loading: false,
              error: (resp && resp.error) || 'could not load comments',
            });
          }
        })
        .catch((err) => {
          renderComments(commentsContainer, b.id, {
            loading: false,
            error: (err && err.message) || String(err),
          });
        });
    } else {
      renderComments(commentsContainer, b.id,
        { loading: false, error: 'bridge unavailable' });
    }

    // Timestamps
    const ts = el('div', { class: 'modal-ts' });
    const pairs = [
      ['created',  fmtTime(b.createdAt)],
      ['updated',  fmtTime(b.updatedAt)],
      ['closed',   fmtTime(b.closedAt)],
    ];
    for (const [k, v] of pairs) if (v) {
      const row = el('div', { class: 'ts-row' });
      row.appendChild(el('span', { class: 'ts-k' }, k));
      row.appendChild(el('span', { class: 'ts-v' }, v));
      ts.appendChild(row);
    }
    body.appendChild(ts);

    // Action bar: status line + close/reopen/claim + delete + cancel/save.
    const actions = el('div', { class: 'modal-actions' });
    const statusLine = el('span', { class: 'form-status' });
    actions.appendChild(statusLine);

    const isClosed = b.status === 'closed';
    const toggleLabel = isClosed ? 'Reopen' : 'Close';
    const toggleBtn = el('button', {
      type: 'button', class: 'btn btn-secondary edit-toggle-close',
    }, toggleLabel);
    toggleBtn.addEventListener('click', () => {
      if (isClosed) doReopen(b, statusLine, toggleBtn);
      else          doClose(b,  statusLine, toggleBtn);
    });
    actions.appendChild(toggleBtn);

    const claimBtn = el('button', {
      type: 'button', class: 'btn btn-secondary edit-claim',
    }, 'Claim');
    claimBtn.addEventListener('click', () => doClaim(b, statusLine, claimBtn));
    actions.appendChild(claimBtn);

    // Phase 3.5 — destructive delete, kept last in the secondary row
    // and styled .btn-danger so it's obviously different from the
    // non-destructive ones. Confirm dialog lists any issues that
    // depend on this one (dep-sweep warning).
    const deleteBtn = el('button', {
      type: 'button', class: 'btn btn-danger edit-delete',
    }, 'Delete');
    deleteBtn.addEventListener('click', () => doDelete(b, statusLine, deleteBtn));
    actions.appendChild(deleteBtn);

    actions.appendChild(el('button', {
      type: 'button', class: 'btn btn-secondary',
      onclick: closeBeadModal,
    }, 'Cancel'));

    const saveBtn = el('button', {
      type: 'button', class: 'btn btn-primary edit-save',
    }, 'Save');
    saveBtn.addEventListener('click', async () => {
      const nextAssignee = assigneeInput.value.trim();
      const origAssignee = (b.assignee || '').trim();
      // Phase 3.5 — when the user clears a previously-set assignee, the
      // diffPatch would put assignee="" into the update, but bd treats
      // empty --assignee as "no change". We detect the clear here and
      // route it to the dedicated unassignBead bridge instead, BEFORE
      // the regular update so we don't send a stale assignee in the
      // same flight. bd serializes writes per-project (the plugin
      // awaits each call), so ordering is preserved.
      const clearingAssignee = origAssignee.length > 0 && nextAssignee.length === 0;
      const patch = diffBeadPatch(b, {
        title:       titleInput.value.trim(),
        status:      statusSel.value,
        priority:    parseInt(prioSel.value, 10),
        issueType:   typeSel.value,
        // Don't include the empty assignee in the patch — unassign
        // handles it separately below.
        assignee:    clearingAssignee ? origAssignee : nextAssignee,
        labels:      labelsInput.value.split(',').map(s => s.trim()).filter(Boolean),
        description: descInput.value,
      });
      if (!patch && !clearingAssignee) {
        statusLine.textContent = 'no changes';
        statusLine.classList.remove('is-error');
        return;
      }
      saveBtn.disabled = true;
      statusLine.classList.remove('is-error');
      statusLine.textContent = 'Saving…';
      if (!window.__nppBridge) {
        statusLine.textContent = 'native bridge unavailable';
        statusLine.classList.add('is-error');
        saveBtn.disabled = false;
        return;
      }
      try {
        if (clearingAssignee) {
          const r = await window.__nppBridge.call('unassignBead', { id: b.id });
          if (!r.ok) {
            statusLine.textContent = r.error || 'unassign failed';
            statusLine.classList.add('is-error');
            saveBtn.disabled = false;
            return;
          }
        }
        if (patch) {
          const resp = await window.__nppBridge.call('updateBead',
            Object.assign({ id: b.id }, patch));
          if (!resp.ok) {
            statusLine.textContent = resp.error || 'update failed';
            statusLine.classList.add('is-error');
            saveBtn.disabled = false;
            return;
          }
        }
        showToast(b.id + ' updated');
        closeBeadModal();
      } catch (err) {
        statusLine.textContent = (err && err.message) || String(err);
        statusLine.classList.add('is-error');
        saveBtn.disabled = false;
      }
    });
    actions.appendChild(saveBtn);

    body.appendChild(actions);
    card.appendChild(body);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    // Esc to close. Autofocus title — typical for a detail-edit flow.
    document.addEventListener('keydown', escCloser);
    setTimeout(() => { titleInput.focus(); titleInput.select(); }, 0);
  }

  // ── Helpers for the edit modal ──────────────────────────────────────
  function makeSelect(name, options, current) {
    const sel = el('select', { name });
    for (const [val, lbl] of options) {
      const opt = document.createElement('option');
      opt.value = val;
      opt.textContent = lbl;
      if (String(val) === String(current)) opt.selected = true;
      sel.appendChild(opt);
    }
    return sel;
  }
  function wrapField(label, input) {
    return el('label', { class: 'field' },
      el('span', { class: 'field-label' }, label),
      input);
  }

  // A markdown-capable textarea field with a Raw | Markdown segmented
  // toggle in its label row. Raw shows the textarea; Markdown hides it
  // and shows the rendered (sanitized) preview of its current value.
  // The textarea stays in the DOM in both modes so Save/Submit always
  // read the same element. A <div> wrapper (not <label>) so clicks on
  // the toggle don't refocus the textarea.
  function mdField(label, textarea, opts) {
    const preview = el('div', { class: 'md-body md-preview' });
    const rawBtn = el('button', {
      type: 'button', class: 'mode-btn', role: 'tab', 'data-mode': 'raw',
      title: 'Edit the Markdown source',
    }, 'Raw');
    const mdBtn = el('button', {
      type: 'button', class: 'mode-btn', role: 'tab', 'data-mode': 'markdown',
      title: 'Preview the rendered Markdown',
    }, 'Markdown');
    const toggle = el('div', { class: 'mode-toggle md-mode', role: 'tablist' },
      rawBtn, mdBtn);
    const head = el('div', { class: 'field-label md-field-label' },
      el('span', null, label), toggle);
    const wrap = el('div', { class: 'field md-field' }, head, textarea, preview);

    function setMode(mode) {
      const md = mode === 'markdown';
      rawBtn.setAttribute('aria-selected', md ? 'false' : 'true');
      mdBtn.setAttribute('aria-selected',  md ? 'true'  : 'false');
      if (md) {
        const src = textarea.value;
        preview.innerHTML = src.trim()
          ? App.renderMarkdown(src)
          : '<p class="md-empty">Nothing to preview yet.</p>';
      }
      textarea.style.display = md ? 'none' : '';
      preview.style.display  = md ? '' : 'none';
      if (!md && opts && opts.focusOnRaw !== false && document.contains(textarea)) {
        textarea.focus();
      }
    }
    rawBtn.addEventListener('click', () => setMode('raw'));
    mdBtn.addEventListener('click',  () => setMode('markdown'));
    // First call runs before the field is attached — no focus side effect.
    setMode((opts && opts.initial) || 'raw');
    return wrap;
  }

  // Build a minimal patch by comparing form values to the bead's current
  // state. Only keys that differ are sent — avoids pointless writes and
  // lets bd skip the "status unchanged" path, which triggers no git
  // activity on a save-without-changes.
  function diffBeadPatch(orig, next) {
    const out = {};
    if (next.title && next.title !== (orig.title || '')) out.title = next.title;
    if (next.status && next.status !== orig.status)      out.status = next.status;
    const origPrio = orig.priority == null ? null : Number(orig.priority);
    if (!Number.isNaN(next.priority) && next.priority !== origPrio) out.priority = next.priority;
    if (next.issueType && next.issueType !== (orig.type || 'task')) out.issueType = next.issueType;
    const origAssignee = orig.assignee || '';
    if (next.assignee !== origAssignee) out.assignee = next.assignee;
    const origLabels = (orig.labels || []).slice().sort().join(',');
    const nextLabels = (next.labels || []).slice().sort().join(',');
    if (origLabels !== nextLabels) {
      // bd has separate add / remove lists — compute delta.
      const origSet = new Set(orig.labels || []);
      const nextSet = new Set(next.labels || []);
      const add = [...nextSet].filter(l => !origSet.has(l));
      const rm  = [...origSet].filter(l => !nextSet.has(l));
      if (add.length) out.addLabels    = add;
      if (rm.length)  out.removeLabels = rm;
    }
    if ((next.description || '') !== (orig.description || '')) {
      out.description = next.description || '';
    }
    return Object.keys(out).length ? out : null;
  }

  function doClose(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Closing…';
    if (!window.__nppBridge) { statusLine.textContent = 'bridge unavailable'; return; }
    window.__nppBridge.call('closeBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' closed'); closeBeadModal(); }
        else if (resp.errorKind === 3 /* BlockedByDeps */ && resp.blockers) {
          if (confirm('This issue has open blockers: ' + resp.blockers.join(', ') +
                      '. Close anyway (force)?')) {
            statusLine.textContent = 'Closing (force)…';
            window.__nppBridge.call('closeBead', { id: bead.id, force: true })
              .then((r2) => {
                if (r2.ok) { showToast(bead.id + ' closed (force)'); closeBeadModal(); }
                else { statusLine.textContent = r2.error || 'force close failed';
                       statusLine.classList.add('is-error'); btn.disabled = false; }
              });
          } else { btn.disabled = false; statusLine.textContent = ''; }
        } else {
          statusLine.textContent = resp.error || 'close failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }
  function doReopen(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Reopening…';
    if (!window.__nppBridge) return;
    window.__nppBridge.call('reopenBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' reopened'); closeBeadModal(); }
        else {
          statusLine.textContent = resp.error || 'reopen failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }
  function doClaim(bead, statusLine, btn) {
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Claiming…';
    if (!window.__nppBridge) return;
    window.__nppBridge.call('claimBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) { showToast(bead.id + ' claimed'); closeBeadModal(); }
        else {
          statusLine.textContent = resp.error || 'claim failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      });
  }

  // Phase 3.5 — permanent delete. Dep-sweep warning lists every issue
  // that currently depends on this one so the user sees which edges
  // will go dangling. bd handles the cleanup itself (deletes dangling
  // dependency rows when the target issue is deleted).
  function doDelete(bead, statusLine, btn) {
    if (!window.__nppBridge) {
      statusLine.textContent = 'bridge unavailable';
      statusLine.classList.add('is-error');
      return;
    }
    const dependents = App.beads
      .filter(x => (x.deps || []).some(d =>
        d.depends_on_id === bead.id && x.id !== bead.id))
      .map(x => x.id);
    let prompt = 'Permanently delete ' + bead.id + ' (' +
                 (bead.title || 'no title').slice(0, 60) + ')?';
    if (dependents.length) {
      prompt += '\n\n⚠ ' + dependents.length + ' issue' +
                (dependents.length === 1 ? '' : 's') +
                ' depend' + (dependents.length === 1 ? 's' : '') +
                ' on this: ' + dependents.slice(0, 8).join(', ') +
                (dependents.length > 8 ? ', …' : '') +
                '. Their dependency edges will be dropped.';
    }
    prompt += '\n\nThis cannot be undone.';
    if (!confirm(prompt)) return;
    btn.disabled = true;
    statusLine.classList.remove('is-error');
    statusLine.textContent = 'Deleting…';
    window.__nppBridge.call('deleteBead', { id: bead.id })
      .then((resp) => {
        if (resp.ok) {
          showToast(bead.id + ' deleted');
          // Let the hosting view drop any optimistic state for this id
          // (the Board keeps a status override map) before the native
          // _broadcastDataChanged lands.
          if (typeof App.onBeadDeleted === 'function') App.onBeadDeleted(bead.id);
          closeBeadModal();
        } else {
          statusLine.textContent = resp.error || 'delete failed';
          statusLine.classList.add('is-error');
          btn.disabled = false;
        }
      }).catch((err) => {
        statusLine.textContent = (err && err.message) || String(err);
        statusLine.classList.add('is-error');
        btn.disabled = false;
      });
  }

  // Populate the shared dep-suggest datalist from the current bead list.
  // Called by both the new-issue modal and the detail-modal dep editor
  // before they show chip-inputs that reference list="dep-suggest".
  function refreshDepSuggestions() {
    const dl = document.getElementById('dep-suggest');
    if (!dl) return;
    dl.innerHTML = '';
    const cap = Math.min(App.beads.length, 500);
    for (let i = 0; i < cap; i++) {
      const bd = App.beads[i];
      const opt = document.createElement('option');
      opt.value = bd.id;
      opt.label = bd.title || '';
      dl.appendChild(opt);
    }
  }

  // Phase 3.5 — render / re-render the editable dep section inside the
  // detail modal. Rebuilds in place after every dep op so the chips
  // reflect the live bead state without re-opening the modal.
  function renderDepEditor(container, beadId) {
    refreshDepSuggestions();
    container.innerHTML = '';
    const b = findBead(beadId);
    if (!b) {
      container.appendChild(el('p', { class: 'modal-missing' },
        'Bead not found in current data — refresh to reload.'));
      return;
    }

    container.appendChild(el('h4', { class: 'modal-dep-hdr' }, 'Dependencies'));
    const statusLine = el('span', { class: 'form-status dep-status-line' });
    container.appendChild(statusLine);

    // Partition existing deps by direction.
    const blockedBy = [];  // this issue depends on these
    const blocks    = [];  // these issues depend on this issue
    for (const d of (b.deps || [])) {
      const row = {
        id:    d.depends_on_id || d.issue_id,
        type:  d.type || 'blocks',
        dependent:  d.issue_id,
        dependency: d.depends_on_id,
      };
      if (d.issue_id === b.id)      blockedBy.push(row);
      else if (d.depends_on_id === b.id) blocks.push(row);
    }

    // Direction: "upstream" means new chips become our blockers
    //            (depAdd where dependent=us, dependency=chip)
    //            "downstream" means new chips become our dependents
    //            (depAdd where dependent=chip, dependency=us)
    buildDepGroup(container, {
      label:     'Blocked by',
      hint:      'upstream — this issue depends on:',
      existing:  blockedBy,
      beadId:    b.id,
      direction: 'upstream',
      statusLine,
      onChanged: () => renderDepEditor(container, beadId),
    });
    buildDepGroup(container, {
      label:     'Blocks',
      hint:      'downstream — these depend on this issue:',
      existing:  blocks,
      beadId:    b.id,
      direction: 'downstream',
      statusLine,
      onChanged: () => renderDepEditor(container, beadId),
    });
  }

  function buildDepGroup(container, opts) {
    const wrap = el('div', { class: 'dep-group' });
    const hdr  = el('div', { class: 'dep-group-hdr' });
    hdr.appendChild(el('span', { class: 'dep-group-label' }, opts.label));
    hdr.appendChild(el('span', { class: 'dep-group-hint hint' }, opts.hint));
    wrap.appendChild(hdr);

    const listRow = el('div', { class: 'dep-chip-list' });
    if (!opts.existing.length) {
      listRow.appendChild(el('span', { class: 'dep-empty' }, 'none'));
    } else {
      for (const x of opts.existing) listRow.appendChild(
        buildExistingDepChip(x, opts));
    }
    wrap.appendChild(listRow);

    // Add-row: input + type picker
    const addRow = el('div', { class: 'chip-input-row dep-add-row' });
    const inp = el('input', {
      type: 'text',
      placeholder: 'bd-… ↵',
      list: 'dep-suggest',
      autocomplete: 'off',
    });
    const typeSel = App.buildDepTypeSelect('blocks');
    addRow.appendChild(inp);
    addRow.appendChild(typeSel);
    wrap.appendChild(addRow);

    async function submitAdd() {
      const raw = inp.value.trim().replace(/,$/, '');
      if (!raw) return;
      if (raw === opts.beadId) {
        opts.statusLine.textContent = 'An issue cannot depend on itself.';
        opts.statusLine.classList.add('is-error');
        return;
      }
      const type = typeSel.value || 'blocks';
      // Direction maps to bd's (dependent, dependency) order.
      const dependent  = opts.direction === 'upstream' ? opts.beadId : raw;
      const dependency = opts.direction === 'upstream' ? raw         : opts.beadId;
      inp.disabled = true; typeSel.disabled = true;
      opts.statusLine.classList.remove('is-error');
      opts.statusLine.textContent = 'Adding dep…';
      try {
        const r = await window.__nppBridge.call('depAdd',
          { dependent, dependency, depType: type });
        if (r.ok) {
          inp.value = '';
          opts.statusLine.textContent = '';
          opts.onChanged();   // re-render container
        } else {
          opts.statusLine.textContent = r.error || 'dep add failed';
          opts.statusLine.classList.add('is-error');
        }
      } catch (e) {
        opts.statusLine.textContent = (e && e.message) || String(e);
        opts.statusLine.classList.add('is-error');
      } finally {
        inp.disabled = false; typeSel.disabled = false;
      }
    }

    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ',' || e.key === 'Tab') {
        e.preventDefault(); submitAdd();
      }
    });
    // change fires when the datalist picks a value without Enter
    inp.addEventListener('change', submitAdd);

    container.appendChild(wrap);
  }

  // Phase 6 — render / re-render the comments thread for a bead inside
  // the detail modal. Works off an options bag:
  //   { loading: true }                         → spinner + form
  //   { loading: false, comments: [...] }       → thread + form
  //   { loading: false, error: 'msg' }          → error notice + form
  // The add-comment form is always there so users can start typing
  // before fetchBead returns.
  function renderComments(container, beadId, opts) {
    container.innerHTML = '';
    container.appendChild(el('h4', { class: 'modal-comments-hdr' }, 'Comments'));

    const statusLine = el('span',
      { class: 'form-status comments-status-line' });
    container.appendChild(statusLine);

    const thread = el('div', { class: 'comments-thread' });
    container.appendChild(thread);

    if (opts.loading) {
      thread.appendChild(el('p', { class: 'comments-loading' },
        'Loading comments…'));
    } else if (opts.error) {
      thread.appendChild(el('p', { class: 'comments-error' },
        'Error loading comments: ' + opts.error));
    } else {
      const cs = opts.comments || [];
      if (cs.length === 0) {
        thread.appendChild(el('p', { class: 'comments-empty' },
          'No comments yet.'));
      } else {
        // Render each comment. bd's field set isn't stable across
        // versions — read every plausible name and fall back cleanly.
        for (const c of cs) {
          thread.appendChild(renderSingleComment(c));
        }
      }
    }

    // Add-comment form — textarea + Submit. Cmd+Enter submits. Empty
    // body is rejected client-side (bd also rejects).
    const form = el('div', { class: 'comments-add' });
    const ta = el('textarea', {
      class: 'comments-add-body',
      rows: '3',
      placeholder: 'Add a comment (Markdown, ⌘↵ to submit)…',
    });
    const submit = el('button', {
      type: 'button', class: 'btn btn-primary comments-add-submit',
    }, 'Comment');
    form.appendChild(mdField('New comment', ta, { initial: 'raw' }));
    form.appendChild(submit);
    container.appendChild(form);

    async function doSubmit() {
      const body = ta.value.trim();
      if (!body) {
        statusLine.textContent = 'Empty comment — type something first.';
        statusLine.classList.add('is-error');
        ta.focus();
        return;
      }
      if (!window.__nppBridge) {
        statusLine.textContent = 'bridge unavailable';
        statusLine.classList.add('is-error');
        return;
      }
      submit.disabled = true;
      ta.disabled = true;
      statusLine.classList.remove('is-error');
      statusLine.textContent = 'Posting…';
      try {
        const r = await window.__nppBridge.call('addComment',
          { id: beadId, body });
        if (r && r.ok) {
          ta.value = '';
          statusLine.textContent = '';
          // Re-fetch and re-render with the new comment included.
          try {
            const r2 = await window.__nppBridge.call('fetchBead', { id: beadId });
            renderComments(container, beadId, {
              loading: false,
              comments: (r2 && r2.ok && r2.bead && Array.isArray(r2.bead.comments))
                ? r2.bead.comments : [],
            });
          } catch (e) {
            // Best-effort: if refetch fails, the comment still posted.
            // Next re-open of the modal will show it.
            renderComments(container, beadId,
              { loading: false, error: 'refetch failed — reopen modal to see it' });
          }
        } else {
          statusLine.textContent = (r && r.error) || 'post failed';
          statusLine.classList.add('is-error');
        }
      } catch (e) {
        statusLine.textContent = (e && e.message) || String(e);
        statusLine.classList.add('is-error');
      } finally {
        submit.disabled = false;
        ta.disabled = false;
      }
    }

    submit.addEventListener('click', doSubmit);
    ta.addEventListener('keydown', (e) => {
      // Cmd+Enter (macOS) or Ctrl+Enter (cross-platform safety)
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault();
        doSubmit();
      }
    });
  }

  function renderSingleComment(c) {
    const row = el('div', { class: 'comment-row' });
    // Author / timestamp header — bd's field names vary; probe a few.
    const author = c.author || c.created_by || c.user || c.actor || '';
    const ts     = c.created_at || c.timestamp || c.createdAt || '';
    const body   = (typeof c.body === 'string' && c.body) ? c.body
                 : (typeof c.text === 'string' && c.text) ? c.text
                 : (typeof c.content === 'string' && c.content) ? c.content
                 : '';

    const hdr = el('div', { class: 'comment-hdr' });
    if (author) hdr.appendChild(el('span',
      { class: 'comment-author' }, '@' + author));
    if (ts) hdr.appendChild(el('span',
      { class: 'comment-ts' }, App.fmtTime(ts)));
    row.appendChild(hdr);

    const bodyEl = document.createElement('div');
    bodyEl.className = 'md-body comment-body';
    bodyEl.innerHTML = App.renderMarkdown(body);
    row.appendChild(bodyEl);

    return row;
  }

  function buildExistingDepChip(d, opts) {
    const target = findBead(d.id);
    const chip = el('span', {
      class: 'chip chip-existing',
      title: (target ? target.title : d.id) + '  ·  type: ' + d.type,
      'data-id': d.id,
      'data-type': d.type,
    });
    // Clickable bead id → jump to that bead's modal
    const link = el('a', {
      class: 'dep-chip-id',
      href: '#',
      onclick: (e) => { e.preventDefault(); openBeadModal(d.id); },
    }, d.id);
    chip.appendChild(link);
    if (d.type !== 'blocks') {
      const tag = el('span', { class: 'chip-type-tag' }, d.type);
      chip.appendChild(tag);
    }
    const rm = el('button', {
      type: 'button', class: 'chip-rm',
      'aria-label': 'Remove ' + d.id,
    }, '×');
    rm.addEventListener('click', async () => {
      rm.disabled = true;
      opts.statusLine.classList.remove('is-error');
      opts.statusLine.textContent = 'Removing dep…';
      try {
        const r = await window.__nppBridge.call('depRemove', {
          dependent:  d.dependent,
          dependency: d.dependency,
        });
        if (r.ok) {
          opts.statusLine.textContent = '';
          opts.onChanged();
        } else {
          opts.statusLine.textContent = r.error || 'dep remove failed';
          opts.statusLine.classList.add('is-error');
          rm.disabled = false;
        }
      } catch (e) {
        opts.statusLine.textContent = (e && e.message) || String(e);
        opts.statusLine.classList.add('is-error');
        rm.disabled = false;
      }
    });
    chip.appendChild(rm);
    return chip;
  }

  function escCloser(e) { if (e.key === 'Escape') closeBeadModal(); }

  function closeBeadModal() {
    const m = document.getElementById('bead-modal');
    if (m) m.remove();
    document.removeEventListener('keydown', escCloser);
  }

  // ── Toast ───────────────────────────────────────────────────────────
  let toastTimer = null;
  function showToast(text) {
    let el = document.getElementById('toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'toast';
      el.className = 'toast';
      document.body.appendChild(el);
    }
    el.textContent = text;
    el.classList.add('toast-visible');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      el.classList.remove('toast-visible');
    }, 3500);
  }

  // ── New issue modal (shared) ────────────────────────────────────────
  // Lived in board.js/board.html until 0.9.7; moved here so the Activity
  // view (and any future view) gets the same entry point. Markup is an
  // HTML string rather than a <template> so host pages don't each have
  // to carry a copy.
  const NEW_ISSUE_HTML = `
    <div class="modal-overlay" id="new-issue-overlay">
      <div class="modal-card new-issue-modal" role="dialog" aria-label="New issue">
        <div class="modal-hdr">
          <span class="modal-title">New issue</span>
          <button class="modal-close" type="button" aria-label="Close">×</button>
        </div>
        <form class="new-issue-form" novalidate>
          <label class="field">
            <span class="field-label">Title <span class="req">*</span></span>
            <input type="text" name="title" required autocomplete="off"
                   placeholder="Short summary of the issue">
          </label>
          <div class="field-row">
            <label class="field">
              <span class="field-label">Type</span>
              <select name="issueType">
                <option value="task">task</option>
                <option value="bug">bug</option>
                <option value="feature">feature</option>
                <option value="epic">epic</option>
                <option value="chore">chore</option>
                <option value="decision">decision</option>
              </select>
            </label>
            <label class="field">
              <span class="field-label">Priority</span>
              <select name="priority">
                <option value="0">P0 — critical</option>
                <option value="1">P1 — high</option>
                <option value="2" selected>P2 — normal</option>
                <option value="3">P3 — low</option>
                <option value="4">P4 — trivial</option>
              </select>
            </label>
          </div>
          <div class="field-row">
            <label class="field">
              <span class="field-label">Epic <span class="hint">(parent)</span></span>
              <select name="epic">
                <option value="" selected>— none —</option>
              </select>
            </label>
            <label class="field">
              <span class="field-label">Labels <span class="hint">(comma-separated)</span></span>
              <input type="text" name="labels" autocomplete="off" placeholder="backend, api">
            </label>
          </div>
          <div class="field-row">
            <label class="field">
              <span class="field-label">Blocked by <span class="hint">(upstream deps)</span></span>
              <div class="chip-input" data-role="blockers">
                <div class="chip-list" data-role="chips"></div>
                <div class="chip-input-row">
                  <input type="text" name="blockerInput" list="dep-suggest"
                         autocomplete="off" placeholder="bd-… ↵">
                  <span class="chip-input-type" data-role="type-slot"></span>
                </div>
              </div>
            </label>
            <label class="field">
              <span class="field-label">Blocks <span class="hint">(downstream deps)</span></span>
              <div class="chip-input" data-role="blocks">
                <div class="chip-list" data-role="chips"></div>
                <div class="chip-input-row">
                  <input type="text" name="blocksInput" list="dep-suggest"
                         autocomplete="off" placeholder="bd-… ↵">
                  <span class="chip-input-type" data-role="type-slot"></span>
                </div>
              </div>
            </label>
          </div>
          <label class="field">
            <span class="field-label">Description <span class="hint">(Markdown)</span></span>
            <textarea name="description" rows="5"
                      placeholder="Context, acceptance criteria, etc."></textarea>
          </label>
          <div class="modal-actions">
            <span class="form-status"></span>
            <button type="button" class="btn btn-secondary new-issue-cancel">Cancel</button>
            <button type="submit" class="btn btn-primary new-issue-submit">Create</button>
          </div>
        </form>
      </div>
    </div>`;

  // opts.onCreated(id) — optional hook a view sets so it can register
  // optimistic state (the Board pre-seeds its 'open' column override).
  function openNewIssueModal(opts) {
    opts = opts || {};
    closeNewIssueModal();
    document.body.insertAdjacentHTML('beforeend', NEW_ISSUE_HTML);

    const overlay  = document.getElementById('new-issue-overlay');
    const form     = overlay.querySelector('.new-issue-form');
    const closeBtn = overlay.querySelector('.modal-close');
    const cancel   = overlay.querySelector('.new-issue-cancel');
    const submit   = overlay.querySelector('.new-issue-submit');
    const statusEl = overlay.querySelector('.form-status');
    const titleEl  = overlay.querySelector('input[name="title"]');

    // Epic selector — every epic in the current data set, open ones
    // first. Picking one links the new issue as its child (parent-child
    // dep: new issue depends_on the epic) right after the create.
    const epicSel = overlay.querySelector('select[name="epic"]');
    const epics = (App.beads || [])
      .filter(b => b.type === 'epic')
      .sort((a, b) =>
        ((a.status === 'closed') - (b.status === 'closed')) ||
        String(a.title || a.id).localeCompare(String(b.title || b.id)));
    for (const ep of epics) {
      const o = document.createElement('option');
      o.value = ep.id;
      o.textContent = ep.id + ' — ' + (ep.title || 'no title').slice(0, 60) +
                      (ep.status === 'closed' ? ' (closed)' : '');
      epicSel.appendChild(o);
    }

    // Dep chip-inputs: one for "Blocked by" (upstream), one for "Blocks"
    // (downstream). The shared <datalist id="dep-suggest"> lives in the
    // permanent body of each host page.
    refreshDepSuggestions();

    // Wires a chip-input region. Returns an object with `values()` that
    // yields [{id, type}, …] so the caller can build per-chip dep writes.
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
      const epicId = (data.get('epic') || '').toString();
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
        //   Epic pick:       newId depends on epicId (type parent-child)
        //   Blocked-by chip: newId depends on chipId (chipId blocks newId)
        //   Blocks     chip: chipId depends on newId (newId blocks chipId)
        const totalDeps = (epicId ? 1 : 0) +
                          blockerEntries.length + blocksEntries.length;
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
          if (epicId) await postDep(newId, epicId, 'parent-child');
          for (const e of blockerEntries) await postDep(newId, e.id, e.type);
          for (const e of blocksEntries)  await postDep(e.id, newId, e.type);
        }
        if (failed.length) {
          showToast(newId + ' created; some deps failed: ' + failed.join('; '));
        } else if (epicId && !blockerEntries.length && !blocksEntries.length) {
          showToast(newId + ' created in epic ' + epicId);
        } else if (totalDeps) {
          showToast(newId + ' created with ' + totalDeps + ' dep' +
                    (totalDeps > 1 ? 's' : ''));
        } else {
          showToast(newId + ' created');
        }
        if (typeof opts.onCreated === 'function') opts.onCreated(newId);
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

  // ── Exports ─────────────────────────────────────────────────────────
  App.el                    = el;
  App.findBead              = findBead;
  App.showToast             = showToast;
  App.openBeadModal         = openBeadModal;
  App.closeBeadModal        = closeBeadModal;
  App.refreshDepSuggestions = refreshDepSuggestions;
  App.openNewIssueModal     = openNewIssueModal;
  App.openBeadModalById = function (id) {
    if (typeof id !== 'string' || !id) return;
    openBeadModal(id);
  };
})();
