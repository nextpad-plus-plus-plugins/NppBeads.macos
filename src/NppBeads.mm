// NppBeads — Notepad++ macOS plugin that wraps the bundled
// dicklesworthstone/beads_viewer inside a docked WKWebView. Auto-detects
// `.beads/` directories from the active file path, reads issues.jsonl,
// and synthesizes a sql.js-compatible SQLite DB on-the-fly (via bridge.js
// — no external fetches, all assets bundled).
//
// Phase 1 scope: JSONL data path, auto-detect, file watcher, status bar,
// Show/Hide panel + Refresh menu items + toolbar icon.

#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <string>

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"
#import "BeadIdIndicator.h"

// ─────────────────────────────────────────────────────────────────────────
//  Plugin identity + menu slots
// ─────────────────────────────────────────────────────────────────────────
static const char *PLUGIN_NAME = "NppBeads";

enum CmdIdx {
    kCmdShowPanel        = 0,
    kCmdReload           = 1,
    kCmdOpenDir          = 2,
    kCmdSep1             = 3,
    kCmdJumpToBead       = 4,   // Phase 5
    kCmdCopyBeadId       = 5,   // Phase 5
    kCmdCreateFromSel    = 6,   // Phase 5
    kCmdSep2             = 7,
    kCmdAbout            = 8,
    kCmdCount            = 9,
};

static FuncItem   sFuncItem[kCmdCount];
static NppData    sNpp;

// ─────────────────────────────────────────────────────────────────────────
//  Plugin state
// ─────────────────────────────────────────────────────────────────────────
static BeadsPanel *sPanel          = nil;
static uint64_t    g_panelHandle   = 0;
static NSPanel    *g_floatingPanel = nil;
static bool        sPanelVisible   = false;
static std::string sResourcesDir;
static BeadsProject *sCurrentProject = nil;
static BeadIdIndicator *sIndicator = nil;   // Phase 5 editor bead-id painter

// ─────────────────────────────────────────────────────────────────────────
//  Forward decls
// ─────────────────────────────────────────────────────────────────────────
static void cmdTogglePanel();
static void cmdReload();
static void cmdOpenDir();
static void cmdAbout();
static void cmdJumpToBead();
static void cmdCopyBeadId();
static void cmdCreateFromSelection();
static void ensurePanel();
static NSPanel *ensureFloatingPanel();
static BOOL panelIsShown();
static void rescanProjectFromCurrentBuffer();
static uintptr_t currentScintillaHandle();
static NSString * _Nullable beadIdAtCurrentCaret();
static NSString * _Nullable currentSelectionText();

static inline intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return sNpp._sendMessage(sNpp._nppHandle, msg, w, l);
}

// Full path of the currently-active buffer (UTF-8). Empty string when
// no file is open OR when the message is not supported.
static std::string currentFullPath() {
    // MAX_PATH on the Windows API is 260; the host honours that.
    char buf[2048] = {0};
    npp(NPPM_GETFULLCURRENTPATH, (uintptr_t)sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

// ─────────────────────────────────────────────────────────────────────────
//  Resources dir (sibling of the dylib)
// ─────────────────────────────────────────────────────────────────────────
static std::string resolveResourcesDir() {
    Dl_info info = {};
    if (dladdr((const void *)&resolveResourcesDir, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        auto slash = p.rfind('/');
        if (slash != std::string::npos) return p.substr(0, slash) + "/resources";
    }
    return "";
}

// ─────────────────────────────────────────────────────────────────────────
//  Panel hosting (docked preferred, NSPanel fallback for older hosts)
// ─────────────────────────────────────────────────────────────────────────
static void ensurePanel() {
    if (sPanel) return;
    @autoreleasepool {
        NSString *res = [NSString stringWithUTF8String:sResourcesDir.c_str()];
        sPanel = [[BeadsPanel alloc] initWithFrame:NSMakeRect(0, 0, 520, 720)
                                      resourcesDir:res];
        // Let the panel's "Hide panel" context menu item drive the same
        // dock/float hide logic that the menu toggle uses.
        sPanel.hideHandler = ^{
            if (sPanelVisible) cmdTogglePanel();
        };
    }
}

static NSPanel *ensureFloatingPanel() {
    if (g_floatingPanel) return g_floatingPanel;
    ensurePanel();
    @autoreleasepool {
        NSRect frame = NSMakeRect(120, 120, 520, 720);
        NSUInteger mask = NSWindowStyleMaskTitled    |
                          NSWindowStyleMaskClosable  |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskUtilityWindow;
        g_floatingPanel = [[NSPanel alloc] initWithContentRect:frame
                                                      styleMask:mask
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        g_floatingPanel.title              = @"NppBeads";
        g_floatingPanel.hidesOnDeactivate  = NO;
        g_floatingPanel.releasedWhenClosed = NO;
        g_floatingPanel.level              = NSNormalWindowLevel;
        sPanel.frame = ((NSView *)g_floatingPanel.contentView).bounds;
        sPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [g_floatingPanel.contentView addSubview:sPanel];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
                       object:g_floatingPanel
                        queue:nil
                   usingBlock:^(NSNotification *n) {
                       sPanelVisible = false;
                       npp(NPPM_SETMENUITEMCHECK,
                           (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID, 0);
                   }];
    }
    return g_floatingPanel;
}

static BOOL panelIsShown() {
    if (g_panelHandle > 0) {
        return sPanel && sPanel.window && sPanel.superview;
    }
    if (g_floatingPanel) return g_floatingPanel.isVisible;
    return NO;
}

// ─────────────────────────────────────────────────────────────────────────
//  Project detection
// ─────────────────────────────────────────────────────────────────────────
//
// Phase 4 semantics: the active buffer is an *auto-detect* source only.
// It can switch us TO a matching project, but activating a file that has
// no .beads/ ancestor must NOT clear a project the user has bound
// (either implicitly from a previous file or explicitly via the
// switcher). Same for closing the last file — we stay on whatever is
// currently bound. Users clear with "Unbind current project" in the
// switcher menu.
// Always-on path accumulator for the switcher's discovery. Runs whenever
// sPanel exists, even if the panel is hidden — otherwise a user who has
// worked on N files before ever showing the panel would have only the
// currently-active file in the dropdown's known-paths pool.
static void notePathActivated() {
    if (!sPanel) return;
    std::string path = currentFullPath();
    if (path.empty()) return;
    [sPanel noteFileActivated:[NSString stringWithUTF8String:path.c_str()]];
}

static void rescanProjectFromCurrentBuffer() {
    if (!sPanel) return;
    std::string path = currentFullPath();

    // Defence-in-depth against a reproducible crash: when the user opens a
    // `.beads/` internal file directly (most commonly the project's
    // issues.jsonl, which on large repos runs into the 10+ MB / thousands-
    // of-issues range), DO NOT treat that as "switch the panel to this
    // project". The auto-rebind path here is expensive — probe, poll
    // reinit, 11 MB JSONL escape-and-inject via jsStringLiteral, WKWebView
    // reload, sql.js rebuild — and when it races the SCN_PAINTED /
    // SCN_UPDATEUI storm that scrolling a multi-MB file generates across
    // every loaded plugin, something downstream throws (ViewBridge
    // collapse, plugin-side NSException) and abort()s the host from
    // NSApplication.run. Five crash reproductions with the same signature.
    //
    // The user already has a switcher menu item for "I want to look at
    // this project" — auto-binding on a raw data-file click is the wrong
    // affordance anyway. Matching the indicator-skip heuristic keeps this
    // simple: if the buffer path contains `/.beads/`, we leave the panel's
    // current binding alone. Normal code files (any path outside any
    // project's .beads/) still auto-rebind exactly as before.
    if (!path.empty() && path.find("/.beads/") != std::string::npos) {
        return;
    }

    NSString *nsPath = path.empty() ? nil : [NSString stringWithUTF8String:path.c_str()];
    BeadsProject *proj = [BeadsProjectScanner findProjectFromPath:nsPath];

    if (!proj) {
        // No .beads/ above this file. LEAVE the current binding alone.
        // This is the "survive no-file-open + survive scratch-file edit"
        // invariant. Nothing to do.
        return;
    }

    // Same project we already point at — noop. Rebinding would nuke the
    // viewer's scroll/search state. IMPORTANT: we compare against the
    // panel's live `self.project`, not a cached ivar here. The switcher
    // can change the panel's project without going through this path,
    // so a stale cache would cause us to skip a legitimate auto-rebind
    // (user picks project B via switcher, then activates a file in A —
    // A should win, but cache=A would tell us "already there").
    if (sPanel.project && sPanel.project.beadsDir.length &&
        [proj.beadsDir isEqualToString:sPanel.project.beadsDir]) {
        return;
    }

    sCurrentProject = proj;
    [sPanel bindProject:proj];
}

// ─────────────────────────────────────────────────────────────────────────
//  Menu commands
// ─────────────────────────────────────────────────────────────────────────
// NPPM_DMM_SETPANELINFO (host ≥ 1.1.0) — not yet present in this repo's
// bundled NppPluginInterfaceMac.h; local copy matches the host header. On
// older hosts the message returns 0 and is simply ignored.
#ifndef NPPM_DMM_SETPANELINFO
typedef struct NppPanelInfo {
    const char *moduleName;   /* plugin folder/module name */
    int32_t     cmdIndex;     /* FuncItem index of the show/toggle command */
} NppPanelInfo;
#define NPPM_DMM_SETPANELINFO (NPPMSG + 505)
#endif

static void cmdTogglePanel() {
    ensurePanel();

    if (g_panelHandle == 0 && g_floatingPanel == nil) {
        intptr_t h = sNpp._sendMessage(sNpp._nppHandle,
                                       NPPM_DMM_REGISTERPANEL,
                                       (uintptr_t)(__bridge void *)sPanel,
                                       (intptr_t)"NppBeads");
        if (h > 0) g_panelHandle = (uint64_t)h;
        else        ensureFloatingPanel();
        if (g_panelHandle) {
            // Declare restore metadata so a panel visible at quit reopens at
            // the next launch via "Show Beads panel" (kCmdShowPanel — this
            // toggle itself, a plain show/hide).
            NppPanelInfo info;
            info.moduleName = "NppBeads";
            info.cmdIndex   = kCmdShowPanel;
            sNpp._sendMessage(sNpp._nppHandle, NPPM_DMM_SETPANELINFO,
                              (uintptr_t)g_panelHandle, (intptr_t)&info);
        }
    }

    BOOL currentlyShown = panelIsShown();
    BOOL target         = !currentlyShown;
    sPanelVisible       = target;
    npp(NPPM_SETMENUITEMCHECK,
        (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID, target ? 1 : 0);

    if (target) {
        // Reset view + clear search so re-open feels fresh rather than
        // resuming stale state. Must happen BEFORE rescan (rescan may
        // trigger a reload that would race with the prepare).
        [sPanel prepareForShow];
        if (g_panelHandle > 0) {
            sNpp._sendMessage(sNpp._nppHandle, NPPM_DMM_SHOWPANEL,
                              (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderFront:nil];
        }
        rescanProjectFromCurrentBuffer();
    } else {
        if (g_panelHandle > 0) {
            sNpp._sendMessage(sNpp._nppHandle, NPPM_DMM_HIDEPANEL,
                              (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderOut:nil];
        }
    }
}

static void cmdReload() {
    if (!sPanel) { cmdTogglePanel(); return; }
    [sPanel reloadData];
}

static void cmdOpenDir() {
    if (!sPanel) return;
    [sPanel openBeadsDirInFinder:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Phase 5 — editor integration helpers
// ─────────────────────────────────────────────────────────────────────────

// Should the BeadIdIndicator scan the currently-active editor buffer?
//
// Skip when the buffer is itself a Beads-internal file. Two reasons:
//   1. issues.jsonl contains literal `bd-XXX` strings on every line as
//      part of its data; coloring all of them is visual noise (the
//      whole file IS bead data, not references TO beads), and on a
//      large file (340+ KB observed) it can produce thousands of
//      indicator paints per scan.
//   2. SCI_INDICATORFILLRANGE causes Scintilla to fire SCN_MODIFIED
//      with SC_MOD_CHANGEINDICATOR which the host forwards to all
//      plugins. On big files this generates a sustained storm of
//      cross-plugin notifications which may agitate other plugins
//      into raising NSException (we've seen two crashes with this
//      exact reproduction — JSONL inside .beads/ open + browsed +
//      panel active).
//
// Match path == bound project's jsonl exactly OR any path containing
// "/.beads/" anywhere (covers any unbound project's data files too).
static BOOL shouldRunIndicatorOnCurrentBuffer() {
    std::string path = currentFullPath();
    if (path.empty()) return YES;
    if (path.find("/.beads/") != std::string::npos) return NO;
    if (sCurrentProject && sCurrentProject.jsonlPath.length) {
        const char *jsonlC = [sCurrentProject.jsonlPath fileSystemRepresentation];
        if (jsonlC && path == jsonlC) return NO;
    }
    return YES;
}

// Resolve the scintilla handle that corresponds to the currently-focused
// editor view. NPPM_GETCURRENTSCINTILLA returns 0 (main) or 1 (sub).
static uintptr_t currentScintillaHandle() {
    int viewId = 0;
    (void)sNpp._sendMessage(sNpp._nppHandle, NPPM_GETCURRENTSCINTILLA, 0,
                            (intptr_t)&viewId);
    if (viewId == 0) return sNpp._scintillaMainHandle;
    if (viewId == 1) return sNpp._scintillaSecondHandle;
    return sNpp._scintillaMainHandle;
}

// Query the indicator cache for a bead id at the current caret position.
// Falls back to scanning an immediate ±64-byte window around the caret
// if the cache is stale or empty (e.g. first activation, or user clicked
// an area outside the scanned window and the debounce hasn't fired yet).
static NSString * _Nullable beadIdAtCurrentCaret() {
    if (!sIndicator) return nil;
    uintptr_t h = currentScintillaHandle();
    if (h == 0) return nil;
    intptr_t caret = sNpp._sendMessage(h, SCI_GETCURRENTPOS, 0, 0);
    NSString *id_ = [sIndicator beadIdAtPosition:caret];
    if (id_.length) return id_;

    // Fallback — scan a tiny window around the caret directly. Bead ids
    // are at most ~20 chars so ±64 bytes is plenty.
    intptr_t start = MAX((intptr_t)0, caret - 64);
    intptr_t end   = MIN(sNpp._sendMessage(h, SCI_GETLENGTH, 0, 0),
                         caret + 64);
    if (end <= start) return nil;
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)(end - start)];
    char *out = (char *)buf.mutableBytes;
    for (intptr_t i = 0; i < end - start; i++) {
        out[i] = (char)sNpp._sendMessage(h, SCI_GETCHARAT,
                                          (uintptr_t)(start + i), 0);
    }
    NSString *window = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    if (!window.length) return nil;

    NSString *prefix = sIndicator.prefix ?: @"bd-";
    // Build the same regex the indicator uses, restricted to this window.
    NSString *pattern = [NSString stringWithFormat:@"\\b%@[a-z0-9]+(\\.\\d+)*\\b",
                         [NSRegularExpression escapedPatternForString:prefix]];
    NSRegularExpression *rx = [NSRegularExpression
        regularExpressionWithPattern:pattern options:0 error:nil];
    if (!rx) return nil;

    // caret in byte-space maps to a UTF-16 offset in `window` — conversion
    // is identity for ASCII, but we're conservative and convert by
    // re-encoding the slice up to the caret.
    intptr_t caretOffset = caret - start;
    intptr_t caretByteOffset = caretOffset;  // within the window
    NSData *lead = [buf subdataWithRange:NSMakeRange(0, (NSUInteger)caretByteOffset)];
    NSString *leadStr = [[NSString alloc] initWithData:lead encoding:NSUTF8StringEncoding];
    NSUInteger caretChar = leadStr.length;

    __block NSString *best = nil;
    [rx enumerateMatchesInString:window options:0
                           range:NSMakeRange(0, window.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (!m) return;
        NSRange r = m.range;
        if (caretChar >= r.location && caretChar <= r.location + r.length) {
            best = [window substringWithRange:r];
            *stop = YES;
        }
    }];
    return best;
}

// UTF-8 text of the current editor selection (or empty when none). Caps
// at 4 KB so we don't round-trip a whole file via the bridge.
static NSString * _Nullable currentSelectionText() {
    uintptr_t h = currentScintillaHandle();
    if (h == 0) return nil;
    intptr_t selStart = sNpp._sendMessage(h, SCI_GETSELECTIONSTART, 0, 0);
    intptr_t selEnd   = sNpp._sendMessage(h, SCI_GETSELECTIONEND, 0, 0);
    if (selEnd <= selStart) return nil;
    intptr_t len = selEnd - selStart;
    if (len > 4096) len = 4096;
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)len];
    char *out = (char *)buf.mutableBytes;
    for (intptr_t i = 0; i < len; i++) {
        out[i] = (char)sNpp._sendMessage(h, SCI_GETCHARAT,
                                          (uintptr_t)(selStart + i), 0);
    }
    NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    // Normalize: trim + collapse internal whitespace to single spaces so
    // a multi-line selection becomes a one-line title candidate.
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    NSRegularExpression *wsRx = [NSRegularExpression
        regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    s = [wsRx stringByReplacingMatchesInString:s options:0
                                          range:NSMakeRange(0, s.length)
                                   withTemplate:@" "];
    return s;
}

static void cmdJumpToBead() {
    NSString *bid = beadIdAtCurrentCaret();
    if (!bid.length) { NSBeep(); return; }
    ensurePanel();
    if (!sPanelVisible) cmdTogglePanel();
    [sPanel showBeadDetail:bid];
}

static void cmdCopyBeadId() {
    NSString *bid = beadIdAtCurrentCaret();
    if (!bid.length) { NSBeep(); return; }
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:bid forType:NSPasteboardTypeString];
}

static void cmdCreateFromSelection() {
    NSString *sel = currentSelectionText();
    ensurePanel();
    if (!sPanelVisible) cmdTogglePanel();
    [sPanel showCreateIssueWithTitle:sel];
}

static void cmdAbout() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"NppBeads — Beads viewer panel";
        a.informativeText =
            @"Embeds the dicklesworthstone beads_viewer inside a dockable\n"
             "Notepad++ side panel. Auto-detects .beads/ above the active file\n"
             "and reads issues.jsonl. No external fetches — fully offline.\n\n"
             "Phase 1: JSONL data path only. SQLite/Dolt path comes in Phase 3.\n\n"
             "Beads project: https://github.com/gastownhall/beads\n"
             "Viewer: https://github.com/dicklesworthstone/beads_viewer";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Plugin exports
// ─────────────────────────────────────────────────────────────────────────
static void installShortcut(ShortcutKey *out, char base) {
    out->_isCtrl  = true;   // ⌘
    out->_isAlt   = true;   // ⌥
    out->_isShift = true;   // ⇧
    out->_key     = (UCHAR)base;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    sNpp = data;
    sResourcesDir = resolveResourcesDir();

    // Phase 5 — one indicator instance is enough. It switches its active
    // scintilla handle per NPPN_BUFFERACTIVATED, so two-view setups work
    // with a single painter.
    sIndicator = [[BeadIdIndicator alloc]
                   initWithSendMessage:(BeadIdSendMessageFn)sNpp._sendMessage];

    memset(sFuncItem, 0, sizeof(sFuncItem));
    auto setItem = [&](int idx, const char *name, PFUNCPLUGINCMD fn) {
        strlcpy(sFuncItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        sFuncItem[idx]._pFunc      = fn;
        sFuncItem[idx]._init2Check = false;
        sFuncItem[idx]._pShKey     = nullptr;
    };
    setItem(kCmdShowPanel,     "Show Beads panel", cmdTogglePanel);
    setItem(kCmdReload,        "Reload issues",    cmdReload);
    setItem(kCmdOpenDir,       "Reveal .beads/ in Finder", cmdOpenDir);
    sFuncItem[kCmdSep1]._itemName[0] = '\0';
    sFuncItem[kCmdSep1]._pFunc       = nullptr;
    setItem(kCmdJumpToBead,    "Jump to bead under caret",    cmdJumpToBead);
    setItem(kCmdCopyBeadId,    "Copy bead id under caret",    cmdCopyBeadId);
    setItem(kCmdCreateFromSel, "Create issue from selection", cmdCreateFromSelection);
    sFuncItem[kCmdSep2]._itemName[0] = '\0';
    sFuncItem[kCmdSep2]._pFunc       = nullptr;
    setItem(kCmdAbout,         "About NppBeads",    cmdAbout);

    static ShortcutKey scShow, scReload, scJump, scCreate;
    installShortcut(&scShow,   'B');
    installShortcut(&scReload, 'R');
    installShortcut(&scJump,   'J');    // ⌘⌥⇧J — jump to bead under caret
    installShortcut(&scCreate, 'N');    // ⌘⌥⇧N — new issue from selection
    sFuncItem[kCmdShowPanel]._pShKey     = &scShow;
    sFuncItem[kCmdReload]._pShKey        = &scReload;
    sFuncItem[kCmdJumpToBead]._pShKey    = &scJump;
    sFuncItem[kCmdCreateFromSel]._pShKey = &scCreate;
    // Copy-bead-id intentionally has no shortcut — not worth burning one,
    // and ⌘C in the editor is always just copy-selection.
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = kCmdCount;
    return sFuncItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION:
            sNpp._sendMessage(sNpp._nppHandle,
                              NPPM_ADDTOOLBARICON_FORDARKMODE,
                              (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID,
                              (intptr_t)"toolbar.png");
            break;
        case NPPN_READY:
            // Defer panel construction until the user asks for it; but if
            // we were asked to auto-show in the future, this is where.
            break;
        case NPPN_BUFFERACTIVATED:
        case NPPN_FILEOPENED:
            // Always feed the switcher's discovery pool — even when the
            // panel is hidden — so first-show doesn't start from an
            // empty seen-paths set.
            notePathActivated();
            if (sPanelVisible) rescanProjectFromCurrentBuffer();
            // Phase 5 — retarget the indicator at the now-active editor
            // and repaint. Also fires when the user splits a view.
            // Skip the rescan when the new buffer is a .beads/ internal
            // file (see shouldRunIndicatorOnCurrentBuffer for why) but
            // still update the handle so subsequent buffer switches
            // back to a code file work without a stale handle.
            if (sIndicator) {
                sIndicator.scintillaHandle = currentScintillaHandle();
                if (shouldRunIndicatorOnCurrentBuffer()) {
                    [sIndicator rescanNow];
                } else {
                    NSLog(@"[NppBeads] indicator paused — current buffer is "
                          @"a .beads/ internal file");
                }
            }
            break;
        // Phase 5 — forwarded Scintilla notifications. BeadIdIndicator
        // debounces internally (150 ms coalesce), so we don't filter
        // further beyond cheap guards.
        //   SCN_MODIFIED  — insert/delete/undo/redo (host filter)
        //   SCN_UPDATEUI  — caret move, style change; fires on typing
        //   SCN_PAINTED   — catches mouse-wheel scrolls that don't fire
        //                    UPDATEUI
        case SCN_MODIFIED:
        case SCN_UPDATEUI:
        case SCN_PAINTED:
            if (sIndicator && sIndicator.scintillaHandle != 0 &&
                shouldRunIndicatorOnCurrentBuffer()) {
                [sIndicator scheduleRescan];
            }
            break;
        case NPPN_SHUTDOWN:
            if (sIndicator) {
                [sIndicator clearAll];
                sIndicator = nil;
            }
            if (g_panelHandle > 0) {
                sNpp._sendMessage(sNpp._nppHandle,
                                  NPPM_DMM_UNREGISTERPANEL,
                                  (uintptr_t)g_panelHandle, 0);
                g_panelHandle = 0;
            }
            if (g_floatingPanel) {
                [g_floatingPanel close];
                g_floatingPanel = nil;
            }
            sPanel           = nil;
            sCurrentProject  = nil;
            break;
        default: break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
