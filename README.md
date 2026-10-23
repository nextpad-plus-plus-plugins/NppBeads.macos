# NppBeads — Beads panel for Notepad++ (macOS)

A dockable side panel that embeds the
[Beads](https://github.com/steveyegge/beads) issue-graph viewer inside
[Notepad++ for macOS](https://github.com/notepad-plus-plus-mac/notepad-plus-plus-macos).

Works **purely from `.beads/issues.jsonl`** — no Dolt server, no `bd`
binary required for read-mode. All viewer assets are bundled; no external
fetches, fully offline.


![beads-screenshot](screenshot.png) *Beads Plugin*

![beads-screenshot2](screenshot-app.png) *Beads macOS App - open multiple instances to view multiple projects*

## What you get (v0.1 — Phase 1)

- Auto-detects `.beads/` by walking up from the active file's directory
- Reads `issues.jsonl`, synthesizes a SQLite DB in-memory via `sql.js`
- Embeds the [dicklesworthstone beads-viewer](https://github.com/Dicklesworthstone/beads_viewer)
  (GPL) — Dashboard, Issues, Insights, Graph with live PageRank /
  betweenness / k-core computed client-side on the dependency graph
- File-watcher with content-gated debounce — updates reflect writes from
  `bd` or agents
- Panel context menu: reveal `.beads/`, reload viewer, copy diagnostics,
  show JSONL head

## Install (development)

```bash
cd /path/to/nppPluginsMacOS/NppBeads
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
make install   # → ~/.notepad++/plugins/NppBeads/
```

Restart Notepad++. Open any file inside a repo that contains a `.beads/`
directory, then **Plugins ▸ NppBeads ▸ Show Beads panel** (⌘⌥⇧B).

## Architecture

```
NppBeads panel
 ├── Title bar + status bar   (Cocoa NSView)
 ├── WKWebView                (serves nppbeads:// via WKURLSchemeHandler)
 │    └── bundled beads-viewer + bridge.js (JSONL → sql.js synthesis)
 └── Data layer
      ├── JsonlDataSource      (.beads/issues.jsonl reader + counts)
      ├── BeadsProjectScanner  (walk-up auto-detect)
      └── BeadsWatcher         (dispatch_source_t VNODE, debounced)
```

All file loads go through `nppbeads://` (custom `WKURLSchemeHandler`)
instead of `file://`, which fixes WebKit's file-origin quirks that
otherwise break ES-module dynamic imports and `WebAssembly.instantiateStreaming`.

## Licenses

- NppBeads itself: GPL-2.0-or-later (same as Notepad++)
- Bundled [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer): GPL
- Phase 2+ will include code ported from
  [jdillon/vscode-beads](https://github.com/jdillon/vscode-beads)
  (Apache-2.0, attributed in per-file headers)

## Roadmap

- **v0.1 — Phase 1 (shipped)** — JSONL read-only, viewer embedded
- **v0.2 — Phase 2** — Native Kanban board, panel toolbar with view
  switcher + search + dark-mode, header consolidation
- **v0.3 — Phase 3** — `bd` CLI integration, write path (create /
  update / close / dep add/remove), real-time polling
- **v0.4 — Phase 4** — Native details view with inline edit, markdown,
  dependency manager
- **v0.5 — Phase 5** — Bead-ID CodeLens in open documents, tab
  color-coding by open-issue density
