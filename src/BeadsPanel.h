// BeadsPanel — the docked NSView that hosts the bundled beads-viewer
// plus our native board/issues/detail views inside one WKWebView.
//
// Layout (Phase 2):
//
//   [toolbar: proj | [View ▼] | ⌕ search… | ⟳ | 📁 | ⋯ ]    — 28pt
//   ─────────────────────────────────────────────────────
//   [WKWebView — fills; URL varies by view mode]
//   ─────────────────────────────────────────────────────
//   [status-row: project · issues(open/blocked/closed)]     — 18pt
//
// View modes map to URLs inside the nppbeads:// origin:
//   Dashboard  → index.html#/
//   Issues     → index.html#/issues
//   Graph      → index.html#/graph
//   Board      → app/board.html   (our own native-rendered kanban)
//
// The Rich viewer's own header + mobile-nav are hidden via CSS injection
// (WKUserScript) so our toolbar is the sole navigation surface.
//
// Theme follows macOS system appearance — we override
// `viewDidChangeEffectiveAppearance` and evaluateJavaScript into both
// the Rich viewer (flips `dark` class on <html>, writes localStorage)
// and our own app views (sets [data-theme]).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class BeadsProject;
@class JsonlDataSource;
@class BeadsWatcher;

NS_ASSUME_NONNULL_BEGIN

// Available view surfaces. Indices used as NSPopUpButton tags.
typedef NS_ENUM(NSInteger, BeadsViewMode) {
    BeadsViewModeDashboard = 0,   // Rich viewer — dashboard
    BeadsViewModeIssues    = 1,   // Rich viewer — issues list
    BeadsViewModeInsights  = 2,   // Rich viewer — insights (top-rank / cycles / etc.)
    BeadsViewModeGraph     = 3,   // Rich viewer — force-directed graph
    BeadsViewModeBoard     = 4,   // Native kanban
    BeadsViewModeActivity  = 5,   // Native activity feed (Phase 6)
};

// User-selectable theme override. Default is Auto (track macOS appearance).
typedef NS_ENUM(NSInteger, BeadsThemePref) {
    BeadsThemePrefAuto  = 0,
    BeadsThemePrefLight = 1,
    BeadsThemePrefDark  = 2,
};

@interface BeadsPanel : NSView <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSSearchFieldDelegate>

// Absolute path to the plugin's `resources/` directory. Must be set via
// the designated init — the panel uses it to `loadFileURL` during init.
@property (nonatomic, copy, readonly) NSString *resourcesDir;
@property (nonatomic, strong, nullable) BeadsProject *project;

// Called by the "Hide panel" context menu item. NppBeads.mm owns
// the dock/float state, so the panel just asks it to hide.
@property (nonatomic, copy, nullable) void (^hideHandler)(void);

// Fires whenever the panel's bound project changes — including via the
// in-app project switcher chip in the toolbar. Hosts that surround the
// panel with chrome (e.g. the standalone Beads.app's window controller,
// which puts the project name in the window title) set this to reflect
// the change. Optional: callers that don't set it see no behaviour
// change. The plugin (NppBeads.mm) doesn't surround the panel with a
// project-aware host, so it leaves this handler unset.
@property (nonatomic, copy, nullable) void (^projectDidChangeHandler)(BeadsProject * _Nullable project);

// Whether the "Hide panel" item appears in the overflow / context
// menu. Default YES (plugin shell — the docked panel must be
// dismissable from inside it). The standalone app shell sets this to
// NO since the panel IS the window's only content; "hiding" it would
// leave a blank window. Standalone users dismiss via ⌘W / the red
// traffic light, which is the natural Mac convention.
//
// Setting this rebuilds the panel's context menu in place; no need
// to retain any reference to the prior menu.
@property (nonatomic, assign) BOOL showsHidePanelMenuItem;

- (instancetype)initWithFrame:(NSRect)frame
                 resourcesDir:(NSString *)resourcesDir NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;

// Bind to a .beads/ project (or nil to clear). Triggers viewer reload.
// When `project` is non-nil, its projectRoot is prepended to the
// persisted `NppBeadsRecentProjectRoots` MRU list so it appears in the
// project-switcher dropdown on next launch.
- (void)bindProject:(nullable BeadsProject *)project;

// Reread JSONL from disk and ask the viewer to rehydrate.
- (void)reloadData;

// Reset to Dashboard + clear search before the panel becomes visible.
// Called by NppBeads.mm on each show transition so re-opening doesn't
// inherit whatever view/search state the user was last in.
- (void)prepareForShow;

// Open the .beads/ directory in Finder (menu action).
- (void)openBeadsDirInFinder:(nullable id)sender;

// Phase 4: NppBeads.mm calls this on every NPPN_BUFFERACTIVATED so we
// accumulate the set of file paths the user has touched this session.
// The project-switcher dropdown walks UP from each to surface candidate
// projects without needing a filesystem tree scan. No-op on nil/empty.
- (void)noteFileActivated:(nullable NSString *)filePath;

// Phase 5: programmatically open the Board view's detail modal on a
// specific bead id. Switches the view popup to Board, waits for the
// viewer load if needed, then evaluates window.__nppApp.openBeadModalById.
- (void)showBeadDetail:(NSString *)beadId;

// Phase 5: open the Board view's "New issue" modal with an optional
// prefilled title string (from the editor selection). Same view-switch
// + post-load handshake as showBeadDetail:.
- (void)showCreateIssueWithTitle:(nullable NSString *)title;

@end

NS_ASSUME_NONNULL_END
