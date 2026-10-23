#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"
#import "JsonlDataSource.h"
#import "BeadsWatcher.h"
#import "BeadsSchemeHandler.h"
#import "BeadsDataSource.h"
#import "BdCommandRunner.h"
#import "BdDataSource.h"
#import "BeadsPoll.h"
#import "BdEventsTail.h"

// ─────────────────────────────────────────────────────────────────────────
//  Small helper: escape a string for embedding inside a JS string literal.
//  bridge.js receives the raw JSONL via evaluateJavaScript; without escaping
//  any backslash, quote, newline, or U+2028/U+2029 in user data could
//  break the JS parse.
// ─────────────────────────────────────────────────────────────────────────
static NSString *jsStringLiteral(NSString *input) {
    if (!input) return @"\"\"";
    NSMutableString *out = [NSMutableString stringWithCapacity:input.length + 32];
    [out appendString:@"\""];
    NSUInteger n = input.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [input characterAtIndex:i];
        switch (c) {
            case '\\': [out appendString:@"\\\\"]; break;
            case '"':  [out appendString:@"\\\""]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            case 0x2028: [out appendString:@"\\u2028"]; break;
            case 0x2029: [out appendString:@"\\u2029"]; break;
            default:
                if (c < 0x20) {
                    [out appendFormat:@"\\u%04x", (unsigned)c];
                } else {
                    [out appendFormat:@"%C", c];
                }
        }
    }
    [out appendString:@"\""];
    return out;
}

// Persistent MRU of project root paths driving the switcher dropdown.
// Capped at 10 entries.
static NSString * const kBeadsRecentProjectsKey = @"NppBeadsRecentProjectRoots";
static const NSUInteger kBeadsRecentProjectsCap = 10;

// Phase 3.5 — projects where the user has opted INTO bd auto-push.
// Absence = sandbox ON (default, auto-push disabled). Presence of a
// project's standardized root = sandbox OFF for that project. Stored as
// an array because NSSet isn't plist-native.
static NSString * const kBeadsAutoPushProjectsKey = @"NppBeadsAutoPushProjects";

// Phase 6 — per-project "last Activity view visit" timestamp. Drives the
// status-bar "N new" badge: count issues with updated_at > lastVisit.
// Dict of { standardized projectRoot : ISO-8601 string }.
static NSString * const kBeadsLastVisitKey = @"NppBeadsLastActivityVisit";

// Option B (⌘+/⌘-/⌘0): persistent per-user page-zoom for the WKWebView.
// Defaults to 0.8 (20% smaller than upstream) so Dashboard / Insights
// fit a reasonable panel width without the user having to re-drag the
// dock divider. User-adjustable via Cmd+/-/0 shortcuts captured by a
// keydown listener inside bridge.js (posts zoomIn/zoomOut/zoomReset
// bridge messages back to us).
static NSString * const kBeadsPanelZoomKey = @"NppBeadsPanelZoom";
static const CGFloat kBeadsZoomDefault = 0.80;
static const CGFloat kBeadsZoomMin     = 0.50;
static const CGFloat kBeadsZoomMax     = 2.00;
static const CGFloat kBeadsZoomStep    = 0.10;

@implementation BeadsPanel {
    WKWebView          *_webView;
    NSButton           *_projectChip;    // borderless button; click → switcher menu
    NSPopUpButton      *_viewModePopup;
    NSSearchField      *_searchField;
    NSButton           *_themeButton;
    NSButton           *_refreshButton;
    NSButton           *_openDirButton;
    NSButton           *_menuButton;
    NSTextField        *_statusLabel;
    NSView             *_titleBar;
    NSView             *_statusBar;

    // Session-scoped set of file paths activated via NPPN_BUFFERACTIVATED.
    // Feeds the switcher's "discover projects from files I've touched"
    // path. Standardized paths (-stringByStandardizingPath).
    NSMutableSet<NSString *> *_seenFilePaths;

    JsonlDataSource          *_ds;          // kept — bridge.js still uses rawText preload
    BeadsWatcher             *_watcher;
    BeadsSchemeHandler       *_schemeHandler;
    // Phase 3: active data source for all CRUD from webview bridges.
    // `_bdRunner` is non-nil when bd is installed + project is usable.
    // `_activeDataSource` points at BdDataSource then, else at _ds (JSONL).
    BdCommandRunner          *_bdRunner;
    id<BeadsDataSource>       _activeDataSource;
    BeadsPoll                *_poll;            // active only when bd backend is active
    BdEventsTail             *_tail;            // events-feed live sync (bd >= 1.3);
                                                // mutually exclusive with _poll

    BeadsViewMode       _viewMode;
    BeadsThemePref      _themePref;
    NSString           *_lastSearchQuery;

    BOOL                _viewerLoaded;   // DOM ready
    BOOL                _pendingReload;  // a reload was requested before DOM ready
    NSString           *_pendingPostLoadJS;  // fire-once JS to run after didFinishNavigation
    NSString           *_lastLoadError;  // human-readable load failure (for diagnostics)
    NSUInteger          _loadCount;      // # of _loadViewer calls (reload-loop diag)
    NSUInteger          _reloadDataCount;
    NSUInteger          _watcherFireCount;
    NSUInteger          _jsonlBytesLastSeen;  // skip reload if file unchanged
}

@synthesize resourcesDir = _resourcesDir;

- (instancetype)initWithFrame:(NSRect)frame
                 resourcesDir:(NSString *)resourcesDir {
    if (!(self = [super initWithFrame:frame])) return nil;
    _resourcesDir = [resourcesDir copy];
    _ds      = [[JsonlDataSource alloc] init];
    _watcher = [[BeadsWatcher alloc] init];
    _seenFilePaths = [NSMutableSet setWithCapacity:32];
    // Default ON — matches the long-standing plugin behavior. The
    // standalone shell flips it OFF after init.
    _showsHidePanelMenuItem = YES;

    __weak typeof(self) weakSelf = self;
    _watcher.onChange = ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_watcherFireCount++;
        NSLog(@"[NppBeads] watcher fired (%lu)", (unsigned long)s->_watcherFireCount);
        [s reloadData];
    };

    _viewMode = BeadsViewModeDashboard;
    _lastSearchQuery = @"";
    _themePref = (BeadsThemePref)[[NSUserDefaults standardUserDefaults]
        integerForKey:@"NppBeadsThemePref"];  // defaults to Auto (0)

    [self _buildUI];
    [self _refreshThemeButton];
    [self _loadViewer];
    [self _refreshStatusBar];
    return self;
}

// ─────────────────────────────────────────────────────────────────────────
//  UI construction
// ─────────────────────────────────────────────────────────────────────────
- (void)_buildUI {
    self.wantsLayer = YES;
    self.menu = [self _buildContextMenu];

    // ── Toolbar row ────────────────────────────────────────────────
    _titleBar = [[NSView alloc] init];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    _titleBar.wantsLayer = YES;
    [self addSubview:_titleBar];

    // Project chip — borderless button that doubles as the project label
    // AND the switcher dropdown trigger (click → menu of recents +
    // Open / Clear). Middle-truncated so long paths still show both ends.
    //
    // NOTE: we put the ▾ chevron directly in the title string (not as an
    // NSImage with imagePosition=NSImageRight) — NSButton with
    // bordered=NO + SF-Symbol image has had rendering quirks across
    // macOS versions where the image silently doesn't draw. A glyph in
    // the title is deterministic, matches the text color automatically,
    // and doesn't need NSImageSymbolConfiguration plumbing.
    _projectChip = [[NSButton alloc] init];
    _projectChip.translatesAutoresizingMaskIntoConstraints = NO;
    _projectChip.bezelStyle    = NSBezelStyleRegularSquare;
    _projectChip.bordered      = NO;
    _projectChip.font          = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _projectChip.contentTintColor = [NSColor secondaryLabelColor];
    _projectChip.alignment     = NSTextAlignmentLeft;
    _projectChip.imagePosition = NSNoImage;
    _projectChip.title         = @"(no project) ▾";
    _projectChip.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _projectChip.cell.controlSize   = NSControlSizeSmall;
    _projectChip.target = self;
    _projectChip.action = @selector(_didTapProjectChip:);
    [_projectChip setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_projectChip setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_titleBar addSubview:_projectChip];

    // View-mode popup — compact, 4 options.
    _viewModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _viewModePopup.translatesAutoresizingMaskIntoConstraints = NO;
    _viewModePopup.bezelStyle = NSBezelStyleRounded;
    _viewModePopup.controlSize = NSControlSizeSmall;
    _viewModePopup.font = [NSFont systemFontOfSize:11];
    [_viewModePopup addItemWithTitle:@"Dashboard"]; [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeDashboard];
    [_viewModePopup addItemWithTitle:@"Issues"];    [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeIssues];
    [_viewModePopup addItemWithTitle:@"Insights"];  [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeInsights];
    [_viewModePopup addItemWithTitle:@"Graph"];     [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeGraph];
    [_viewModePopup addItemWithTitle:@"Board"];     [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeBoard];
    [_viewModePopup addItemWithTitle:@"Activity"];  [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeActivity];
    [_viewModePopup selectItemWithTag:_viewMode];
    _viewModePopup.target = self;
    _viewModePopup.action = @selector(_didChangeViewMode:);
    _viewModePopup.toolTip = @"Switch between Dashboard / Issues / Graph / Board";
    [_titleBar addSubview:_viewModePopup];

    // Search field — filters Board (and, in future, the Rich-viewer list).
    _searchField = [[NSSearchField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.controlSize = NSControlSizeSmall;
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.placeholderString = @"Search beads";
    _searchField.delegate = self;
    _searchField.sendsSearchStringImmediately = YES;
    _searchField.sendsWholeSearchString = NO;
    [_searchField setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_titleBar addSubview:_searchField];

    _themeButton = [self _makeTitleBarButton:@"circle.lefthalf.filled"
                                      tooltip:@"Theme: Auto (click to cycle: Auto → Light → Dark)"
                                       action:@selector(_didTapTheme:)];
    [_titleBar addSubview:_themeButton];

    _refreshButton = [self _makeTitleBarButton:@"arrow.clockwise"
                                        tooltip:@"Reload issues from disk"
                                         action:@selector(_didTapRefresh:)];
    [_titleBar addSubview:_refreshButton];

    _openDirButton = [self _makeTitleBarButton:@"folder"
                                        tooltip:@"Reveal .beads/ in Finder"
                                         action:@selector(openBeadsDirInFinder:)];
    [_titleBar addSubview:_openDirButton];

    _menuButton = [self _makeTitleBarButton:@"ellipsis.circle"
                                      tooltip:@"More actions"
                                       action:@selector(_didTapMenu:)];
    [_titleBar addSubview:_menuButton];

    // WKWebView configured with a custom-scheme handler so the viewer is
    // served from `nppbeads://viewer/…` instead of `file://`. Same origin
    // for every sibling file means ES-module dynamic `import()` works,
    // `WebAssembly.instantiateStreaming` gets the right MIME, and XHR/fetch
    // no longer hit file:// restrictions.
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;

    NSString *viewerDir = [self.resourcesDir stringByAppendingPathComponent:@"viewer"];
    _schemeHandler = [[BeadsSchemeHandler alloc] initWithViewerRoot:viewerDir];
    [config setURLSchemeHandler:_schemeHandler forURLScheme:@"nppbeads"];

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"beadsBridge"];
    config.userContentController = ucc;

    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.navigationDelegate = self;

    // Apply the persisted page zoom — fresh installs default to
    // kBeadsZoomDefault so Dashboard / Insights fit a reasonable panel
    // width. User adjusts live via ⌘+/⌘-/⌘0 (see zoom handlers).
    _webView.pageZoom = [self _loadPersistedZoom];

    // Observe URL changes so when the Rich viewer navigates internally
    // (e.g. user clicks an issue card in Insights and viewer jumps to
    // #/issue/bd-123), our view-mode popup reflects the new state.
    [_webView addObserver:self
               forKeyPath:@"URL"
                  options:NSKeyValueObservingOptionNew
                  context:nil];
#if defined(__MAC_13_3) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_13_3
    if (@available(macOS 13.3, *)) {
        _webView.inspectable = YES;   // right-click → Inspect Element for debugging
    }
#endif
    [self addSubview:_webView];

    // Status bar
    _statusBar = [[NSView alloc] init];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.wantsLayer = YES;
    [self addSubview:_statusBar];

    _statusLabel = [[NSTextField alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.bordered    = NO;
    _statusLabel.editable    = NO;
    _statusLabel.drawsBackground = NO;
    _statusLabel.font        = [NSFont systemFontOfSize:10];
    _statusLabel.textColor   = [NSColor tertiaryLabelColor];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _statusLabel.stringValue = @"no project";
    [_statusBar addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        // Toolbar: full width, 28pt, top.
        [_titleBar.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_titleBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_titleBar.heightAnchor   constraintEqualToConstant:28],

        // Project chip (leftmost, hugs start, compresses to squeeze).
        [_projectChip.leadingAnchor constraintEqualToAnchor:_titleBar.leadingAnchor constant:8],
        [_projectChip.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        // Keep the chip from growing past 40% of toolbar — otherwise it
        // squeezes the search field down to the placeholder.
        [_projectChip.widthAnchor   constraintLessThanOrEqualToAnchor:_titleBar.widthAnchor multiplier:0.40],

        // View mode popup immediately after the project chip.
        [_viewModePopup.leadingAnchor constraintEqualToAnchor:_projectChip.trailingAnchor constant:6],
        [_viewModePopup.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_viewModePopup.widthAnchor   constraintGreaterThanOrEqualToConstant:100],

        // Search field flexes.
        [_searchField.leadingAnchor   constraintEqualToAnchor:_viewModePopup.trailingAnchor constant:6],
        [_searchField.trailingAnchor  constraintEqualToAnchor:_themeButton.leadingAnchor constant:-6],
        [_searchField.centerYAnchor   constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_searchField.heightAnchor    constraintEqualToConstant:20],
        [_searchField.widthAnchor     constraintGreaterThanOrEqualToConstant:60],

        // Trailing cluster: theme, refresh, folder, menu.
        [_themeButton.centerYAnchor   constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_themeButton.trailingAnchor  constraintEqualToAnchor:_refreshButton.leadingAnchor constant:-2],
        [_refreshButton.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:_openDirButton.leadingAnchor constant:-2],
        [_openDirButton.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_openDirButton.trailingAnchor constraintEqualToAnchor:_menuButton.leadingAnchor constant:-2],
        [_menuButton.centerYAnchor    constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_menuButton.trailingAnchor   constraintEqualToAnchor:_titleBar.trailingAnchor constant:-6],

        // WebView fills the middle band.
        [_webView.topAnchor      constraintEqualToAnchor:_titleBar.bottomAnchor],
        [_webView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_webView.bottomAnchor   constraintEqualToAnchor:_statusBar.topAnchor],

        // Status bar: full width, 18pt, bottom
        [_statusBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_statusBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_statusBar.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        [_statusBar.heightAnchor   constraintEqualToConstant:18],
        [_statusLabel.leadingAnchor  constraintEqualToAnchor:_statusBar.leadingAnchor constant:8],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-8],
        [_statusLabel.centerYAnchor  constraintEqualToAnchor:_statusBar.centerYAnchor],
    ]];
}

- (NSButton *)_makeTitleBarButton:(NSString *)symbol
                          tooltip:(NSString *)tip
                           action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.bezelStyle = NSBezelStyleRegularSquare;
    b.bordered   = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip    = tip;
    b.target     = self;
    b.action     = action;
    if (@available(macOS 11.0, *)) {
        b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    }
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor  constraintEqualToConstant:18],
        [b.heightAnchor constraintEqualToConstant:18],
    ]];
    return b;
}

// ─────────────────────────────────────────────────────────────────────────
//  Viewer load
// ─────────────────────────────────────────────────────────────────────────
- (void)_loadViewer {
    NSString *resDir = self.resourcesDir;
    if (resDir.length == 0) {
        _lastLoadError = @"resourcesDir is nil (bootstrap bug)";
        [self _showErrorPage:_lastLoadError];
        return;
    }
    NSString *idx = [[resDir stringByAppendingPathComponent:@"viewer"]
                          stringByAppendingPathComponent:@"index.html"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:idx]) {
        _lastLoadError = [NSString stringWithFormat:@"viewer missing at %@", idx];
        NSLog(@"[NppBeads] %@", _lastLoadError);
        [self _showErrorPage:_lastLoadError];
        return;
    }
    _lastLoadError = nil;
    _loadCount++;
    NSLog(@"[NppBeads] _loadViewer (#%lu, mode=%ld)",
          (unsigned long)_loadCount, (long)_viewMode);
    [self _installJsonlUserScript];

    // Wipe caches + SW registrations so plugin file edits take effect.
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    WKWebsiteDataStore *ds = _webView.configuration.websiteDataStore;
    NSMutableSet *types = [NSMutableSet setWithArray:@[
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeLocalStorage,
    ]];
    if (@available(macOS 11.3, *)) {
        [types addObject:WKWebsiteDataTypeServiceWorkerRegistrations];
    }
    NSURL *url = [self _urlForViewMode:_viewMode];
    [ds removeDataOfTypes:types
           modifiedSince:[NSDate distantPast]
       completionHandler:^{
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    }];
}

// Map a view mode to the nppbeads:// URL it lives at.
- (NSURL *)_urlForViewMode:(BeadsViewMode)mode {
    switch (mode) {
        case BeadsViewModeDashboard:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/"];
        case BeadsViewModeIssues:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/issues"];
        case BeadsViewModeInsights:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/insights"];
        case BeadsViewModeGraph:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/graph"];
        case BeadsViewModeBoard:
            return [NSURL URLWithString:@"nppbeads://viewer/app/board.html"];
        case BeadsViewModeActivity:
            return [NSURL URLWithString:@"nppbeads://viewer/app/activity.html"];
    }
    return [NSURL URLWithString:@"nppbeads://viewer/index.html#/"];
}

// Inject the JSONL text + the sql-wasm.wasm bytes directly into the page
// at document-start via WKUserScripts. bridge.js and our viewer.js patch
// see them synchronously — no IPC handshake, no file:// fetch (which
// WKWebView refuses for XHR and gives empty MIME for fetch). We remove
// + reinstall when the project changes.
- (void)_installJsonlUserScript {
    WKUserContentController *ucc = _webView.configuration.userContentController;
    [ucc removeAllUserScripts];

    NSString *raw = [_ds rawText] ?: @"";
    NSString *jsonlJs = [NSString stringWithFormat:
        @"window.__nppBeadsPreloadedJsonl = %@;"
         "window.__nppBeadsProjectPath = %@;",
        jsStringLiteral(raw),
        jsStringLiteral(self.project.projectRoot ?: @"")];
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:jsonlJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    // Load every .wasm from vendor/ into a base64 blob, inject as a
    // document-start script that decodes them into Uint8Arrays on
    // window.__nppBeadsWasmBytesMap[filename]. bridge.js serves these
    // bytes for matching fetch() calls, bypassing WKWebView's broken
    // file:// wasm loading. Also keeps the specific sql-wasm bytes as
    // __nppBeadsWasmBytes for the sqlJs({wasmBinary:...}) path.
    NSString *vendorDir = [self.resourcesDir
        stringByAppendingPathComponent:@"viewer/vendor"];
    NSArray<NSString *> *wasmFiles = @[ @"sql-wasm.wasm", @"bv_graph_bg.wasm" ];
    NSMutableString *wasmJs = [NSMutableString string];
    [wasmJs appendString:
        @"(function(){"
         "window.__nppBeadsWasmBytesMap={};"
         "function dec(b64){var bin=atob(b64);var arr=new Uint8Array(bin.length);"
         "for(var i=0;i<bin.length;i++)arr[i]=bin.charCodeAt(i);return arr;}"];
    for (NSString *fname in wasmFiles) {
        NSString *p = [vendorDir stringByAppendingPathComponent:fname];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d.length == 0) { NSLog(@"[NppBeads] wasm missing: %@", p); continue; }
        NSString *b64 = [d base64EncodedStringWithOptions:0];
        [wasmJs appendFormat:
            @"window.__nppBeadsWasmBytesMap[%@]=dec(%@);",
            jsStringLiteral(fname), jsStringLiteral(b64)];
        if ([fname isEqualToString:@"sql-wasm.wasm"]) {
            [wasmJs appendFormat:
                @"window.__nppBeadsWasmBytes=window.__nppBeadsWasmBytesMap[%@];",
                jsStringLiteral(fname)];
        }
        NSLog(@"[NppBeads] embedded %@ (%lu bytes)", fname, (unsigned long)d.length);
    }
    [wasmJs appendString:@"})();"];
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:wasmJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    // Theme bootstrap — run BEFORE page scripts so the viewer sees the
    // correct `dark` class on <html> and our app views pick up the right
    // [data-theme]. Without this there's a flash of wrong-theme.
    BOOL dark = [self _isDarkMode];
    NSString *themeJs = dark
        ? @"document.documentElement.classList.add('dark');"
           "document.documentElement.dataset.theme='dark';"
           "try{localStorage.setItem('darkMode','true');}catch(e){}"
        : @"document.documentElement.classList.remove('dark');"
           "document.documentElement.dataset.theme='light';"
           "try{localStorage.setItem('darkMode','false');}catch(e){}";
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:themeJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    // Viewer's header + mobile bottom-nav + Dependency-Graph hero card
    // are stripped from index.html directly (search for the marker
    // comment `<!-- NppBeads:`). No runtime CSS injection needed.
}

// Render a plain HTML page inside the webview when the real viewer can't
// be shown. Gives the user something to look at + debug info + a button.
- (void)_showErrorPage:(NSString *)message {
    if (!_webView) return;
    NSString *safe = message ?: @"(unknown)";
    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset='utf-8'>"
         "<style>body{margin:0;padding:32px;font:13px -apple-system,BlinkMacSystemFont,"
         "system-ui;background:#fafafa;color:#222}h1{font-size:15px;margin:0 0 8px}"
         "pre{background:#fff;border:1px solid #e5e5e5;padding:10px;border-radius:6px;"
         "white-space:pre-wrap;word-break:break-word;font:12px ui-monospace,Menlo}"
         "@media(prefers-color-scheme:dark){body{background:#1a1a1a;color:#ddd}"
         "pre{background:#111;border-color:#333}}</style></head><body>"
         "<h1>NppBeads — viewer not rendered</h1>"
         "<pre>%@</pre>"
         "<p>Use the panel's right-click menu for diagnostics.</p>"
         "</body></html>", safe];
    [_webView loadHTMLString:html baseURL:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Public API
// ─────────────────────────────────────────────────────────────────────────
- (void)bindProject:(BeadsProject *)project {
    // Crash-mitigation: detect a no-op rebind (same .beads/ directory)
    // and short-circuit BEFORE tearing anything down. Even three full
    // rebinds in a row on the same project cause three [_webView reload]
    // cycles, which on macOS 15.x are documented (see EditorView.mm's
    // SCN_MODIFIED forwarding comment) to destabilize the TextInputUI
    // /CursorUI ViewBridge: the cursor-overlay view loses its anchor
    // during one of the WebKit teardown/setup cycles, then AppKit
    // throws on the next view-tree walk and NSApplication.run rethrows
    // out to abort(). We've reproduced this signature three times.
    //
    // Cheap pointer-equal-on-jsonlPath check; covers the common case
    // (same project re-supplied by switcher / rescan / probe-redo)
    // without changing semantics for genuine project transitions or
    // for bindProject:nil.
    if (project && self.project &&
        project.beadsDir.length && self.project.beadsDir.length &&
        [project.beadsDir isEqualToString:self.project.beadsDir]) {
        NSLog(@"[NppBeads] bindProject: same project (%@) — refresh only, "
              @"no webview reload",
              project.projectRoot.lastPathComponent ?: @"?");
        // Make sure the chip / status / MRU still reflect any subtle
        // metadata change in the new BeadsProject instance, but don't
        // tear down the webview.
        self.project = project;
        [_ds bindToPath:project.jsonlPath];
        [_watcher watchPath:project.jsonlPath];
        if (project.projectRoot.length) {
            [BeadsPanel _recordRecentProjectRoot:project.projectRoot];
        }
        [self _refreshTitleBar];
        [self _refreshStatusBar];
        // Notify host (e.g. standalone Beads.app's window controller) so
        // chrome that depends on the project name — like the window title
        // — can update. Plugin shells leave the handler unset and see no
        // behaviour change.
        if (self.projectDidChangeHandler) self.projectDidChangeHandler(project);
        return;
    }

    // Tear down any previous-project live-sync BEFORE changing state.
    // BeadsPoll's -stop bumps its generation counter so any in-flight bd
    // completion for the old project becomes a no-op; the events tail
    // terminates its child process.
    [_poll stop];
    _poll = nil;
    [_tail stop];
    _tail = nil;

    self.project = project;
    [_ds bindToPath:project.jsonlPath];
    [_watcher watchPath:project.jsonlPath];

    // Phase 3: probe bd against the project root. Pick BdDataSource when
    // bd is available + project has a working Dolt DB; fall back to JSONL
    // otherwise. Probe is async, so we default to JSONL immediately and
    // upgrade in the completion.
    _activeDataSource = _ds;
    if (project.projectRoot.length) {
        _bdRunner = [[BdCommandRunner alloc] initWithProjectDir:project.projectRoot];
        // Phase 3.5 — honor per-project auto-push opt-in. Default is
        // useSandbox=YES (sandbox on, auto-push off). If this project's
        // standardized root is in NppBeadsAutoPushProjects, flip it off
        // so subsequent bd calls don't pass --sandbox.
        _bdRunner.useSandbox = ![BeadsPanel _autoPushEnabledForProject:project.projectRoot];
        // Capture the runner locally so a rapid second bindProject: can't
        // make this completion attach to a DIFFERENT runner. If the user
        // flips projects while a probe is in flight, the stale completion
        // lands with `probedRunner != self->_bdRunner` and bails — the
        // new bindProject's probe owns the state transition.
        BdCommandRunner *probedRunner = _bdRunner;
        __weak typeof(self) weakSelf = self;
        [probedRunner probeWithCompletion:^(BOOL bdPresent, BOOL projectReady) {
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            if (s->_bdRunner != probedRunner) {
                NSLog(@"[NppBeads] probe completion ignored — superseded by later bindProject");
                return;
            }
            if (bdPresent && projectReady) {
                s->_activeDataSource = [[BdDataSource alloc] initWithRunner:probedRunner];
                NSLog(@"[NppBeads] bd backend active — %@",
                      s->_activeDataSource.backendLabel);
                // Live sync: events feed on bd >= 1.3 (with a one-time
                // per-project opt-in prompt for the journal), else the
                // classic 2s poll. Either one pauses whenever the host
                // window isn't key (see _installWindowKeyStateObservers).
                [s _startLiveSyncWithRunner:probedRunner];
            } else {
                NSLog(@"[NppBeads] JSONL fallback (bd=%d, projectReady=%d)",
                      bdPresent, projectReady);
            }
            [s _refreshStatusBar];
        }];
    } else {
        _bdRunner = nil;
    }

    // Record this bind in the cross-session MRU so the switcher dropdown
    // can offer it on next launch. Nil binds (explicit unbind or
    // unusable project) are NOT recorded.
    if (project.projectRoot.length) {
        [BeadsPanel _recordRecentProjectRoot:project.projectRoot];
    }

    [self _refreshTitleBar];
    [self _refreshStatusBar];
    // Reinstall the user script so future page navigations (e.g. user
    // switches view modes) inject the latest JSONL at document-start.
    [self _installJsonlUserScript];
    // Two sub-cases for the post-bind page update. The threshold that
    // matters is whether the page is SETTLED — `_viewerLoaded == YES`
    // means didFinishNavigation has fired and the load is done.
    //
    //  PAGE MID-LOAD (`_viewerLoaded == NO`).
    //     Either _loadViewer just kicked off (cold start) or a prior
    //     reload is still in flight. Reloading here would race the
    //     in-flight load — we observed a 30 s 'Client reload'
    //     timeout followed by a TextInputUI/CursorUI ViewBridge
    //     collapse and an abort. Skip the reload; the user script
    //     we just reinstalled will inject the right JSONL at
    //     document-start when the in-flight load finishes.
    //
    //  PAGE SETTLED (`_viewerLoaded == YES`).
    //     Reload is safe and is the only thing that reliably refreshes
    //     the Rich viewer. evaluateJavaScript-pushed JSONL is enough
    //     for Board/Activity (`__nppApp.reload(jsonl)` is a defined
    //     refresh hook), but for the Dashboard/Issues/Insights/Graph
    //     views the Rich viewer reads its data once at init from
    //     `__nppBeadsPreloadedJsonl` and never re-reads it —
    //     `__nppBeads.receiveJsonl` only resolves pending init-time
    //     promises, which there aren't any once init has completed.
    //     A reload re-runs the Rich viewer's init with the just-
    //     reinstalled user script, which now embeds the new JSONL.
    //
    //     Earlier versions split this case three ways and broadcast
    //     instead of reloading when there was no prior project; that
    //     path silently dropped data into the Rich viewer because of
    //     the receiveJsonl no-op described above. The unbind→rebind
    //     workflow surfaced it: the unbind reloaded the page (now
    //     settled with empty data), then the rebind broadcast was a
    //     no-op for the Rich viewer, so the Dashboard appeared empty
    //     until a second project switch forced a real reload.
    //
    // Same-project rebinds short-circuit at the top of this method
    // and never reach here, so the reload below is never wasted on a
    // "nothing changed" path.
    if (_webView.URL && _viewerLoaded) {
        _viewerLoaded = NO;
        [_webView reload];
    }
    // else: page mid-load — didFinishNavigation will inject the fresh
    // JSONL via the user script we just reinstalled.

    // Notify host (e.g. standalone Beads.app's window controller) so
    // chrome that depends on the project name — like the window title
    // — can update. Plugin shells leave the handler unset and see no
    // behaviour change. Fired AFTER the webview reload kicks off so any
    // host UI the handler updates renders simultaneously with the new
    // project's content.
    if (self.projectDidChangeHandler) self.projectDidChangeHandler(project);
}

- (void)reloadData {
    [_ds reload];
    [self _refreshStatusBar];
    // Content-hash gate: if the JSONL hasn't actually changed (e.g. watcher
    // fired on a no-op file touch), skip the webView reload to avoid the
    // 37-fires-per-second thrash we saw with DISPATCH_VNODE_ATTRIB.
    NSString *fresh = [_ds rawText] ?: @"";
    NSUInteger len  = fresh.length;
    if (len == _jsonlBytesLastSeen && _viewerLoaded) {
        NSLog(@"[NppBeads] reloadData: unchanged (%lu bytes), skipping reload", (unsigned long)len);
        return;
    }
    _jsonlBytesLastSeen = len;
    _reloadDataCount++;
    NSLog(@"[NppBeads] reloadData (#%lu, %lu bytes)",
          (unsigned long)_reloadDataCount, (unsigned long)len);
    // Reinstall the user script so the next genuine page navigation
    // (view-mode switch, etc.) injects the fresh JSONL at document
    // -start. Then push the data into the live page via
    // evaluateJavaScript instead of forcing [_webView reload]. Same
    // crash-mitigation rationale as bindProject:: WebKit reloads
    // race the host's TextInputUI/CursorUI subsystem and trigger a
    // ViewBridge collapse + AppKit abort. evaluateJavaScript leaves
    // the WebKit page intact, so no view-tree churn.
    [self _installJsonlUserScript];
    if (_webView.URL && _viewerLoaded) {
        [self _broadcastDataChanged];
    }
}

- (void)openBeadsDirInFinder:(id)sender {
    if (self.project.beadsDir.length == 0) return;
    [[NSWorkspace sharedWorkspace] selectFile:self.project.jsonlPath
                     inFileViewerRootedAtPath:self.project.beadsDir];
}

// ─────────────────────────────────────────────────────────────────────────
//  Live sync — events feed (bd >= 1.3, opt-in journal) with poll fallback
// ─────────────────────────────────────────────────────────────────────────

// Per-project "did we already ask?" answers ("enabled"/"declined") and
// per-project journal checkpoints, both keyed by standardized project root.
static NSString * const kEventsPromptAnswersKey = @"NppBeadsEventsFeedAnswers";
static NSString * const kEventsSeqKeyPrefix     = @"NppBeadsEventsSeq.";

- (void)_startLiveSyncWithRunner:(BdCommandRunner *)runner {
    if (![runner supportsEventsFeed] || runner.bdPath.length == 0) {
        [self _startPollWithRunner:runner];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [runner fetchEventsJournalEnabled:^(BOOL enabled) {
        __strong typeof(self) s = weakSelf;
        if (!s || s->_bdRunner != runner) return;   // superseded by later bind
        if (enabled) [s _startTailWithRunner:runner];
        else         [s _offerEventsFeedForRunner:runner];
    }];
}

- (void)_startPollWithRunner:(BdCommandRunner *)runner {
    [_poll stop];
    _poll = [[BeadsPoll alloc] initWithRunner:runner intervalMs:2000];
    __weak typeof(self) weakSelf = self;
    _poll.onChange = ^(NSString *payload) {
        __strong typeof(self) ss = weakSelf;
        if (!ss) return;
        NSLog(@"[NppBeads] poll detected change (#%lu) — rebroadcasting",
              (unsigned long)ss->_poll.changeCount);
        [ss _broadcastDataChanged];
    };
    [_poll start];
    // Match the focus invariant immediately; resume() fires on
    // NSWindowDidBecomeKeyNotification.
    if (self.window && !self.window.isKeyWindow) [_poll pause];
    NSLog(@"[NppBeads] live sync: 2s poll (bd %@)", runner.bdVersion ?: @"?");
}

- (void)_startTailWithRunner:(BdCommandRunner *)runner {
    [_tail stop];
    _tail = nil;
    NSString *seqKey = [kEventsSeqKeyPrefix stringByAppendingString:
                        runner.projectDir.stringByStandardizingPath];
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:seqKey];
    BdEventsTail *tail = [[BdEventsTail alloc] initWithBdPath:runner.bdPath
                                                   projectDir:runner.projectDir];
    tail.sinceSeq = [saved isKindOfClass:[NSNumber class]]
                        ? saved.unsignedLongLongValue : 0;
    __weak typeof(self) weakSelf = self;
    tail.onChange = ^{
        __strong typeof(self) s = weakSelf;
        if (!s || s->_bdRunner != runner || !s->_tail) return;
        [[NSUserDefaults standardUserDefaults] setObject:@(s->_tail.lastSeq)
                                                  forKey:seqKey];
        NSLog(@"[NppBeads] events feed change (records=%lu seq=%llu) — rebroadcasting",
              (unsigned long)s->_tail.recordCount, s->_tail.lastSeq);
        [s _broadcastDataChanged];
    };
    tail.onBroken = ^(NSString *reason) {
        __strong typeof(self) s = weakSelf;
        if (!s || s->_bdRunner != runner) return;
        NSLog(@"[NppBeads] events feed broken (%@) — falling back to 2s poll", reason);
        s->_tail = nil;
        [s _startPollWithRunner:runner];
        [s _broadcastDataChanged];      // resync once; we may have missed changes
    };
    _tail = tail;
    [tail start];
    if (self.window && !self.window.isKeyWindow) [tail pause];
    NSLog(@"[NppBeads] live sync: events feed (bd %@, since=%llu)",
          runner.bdVersion ?: @"?", tail.sinceSeq);
}

// Option (a): one-time per-project prompt before flipping the journal on,
// because `bd config set events-journal true` writes .beads/config.yaml,
// which is often tracked in git. Any remembered answer suppresses the
// prompt forever; a user who later runs the config command themselves is
// picked up by the `fetchEventsJournalEnabled` check on the next bind.
- (void)_offerEventsFeedForRunner:(BdCommandRunner *)runner {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *root = runner.projectDir.stringByStandardizingPath;
    NSDictionary *answers = [ud dictionaryForKey:kEventsPromptAnswersKey] ?: @{};
    if ([answers[root] isKindOfClass:[NSString class]]) {
        // Already asked (or previously enabled and since turned off
        // outside the panel) — don't nag; poll.
        [self _startPollWithRunner:runner];
        return;
    }
    NSWindow *win = self.window;
    if (!win) {
        // No UI to ask with right now. Poll for this session WITHOUT
        // recording an answer, so the prompt can happen on a later bind.
        [self _startPollWithRunner:runner];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Enable live updates for this project?";
    alert.informativeText = [NSString stringWithFormat:
        @"Beads %@ can stream changes to this panel as they happen "
        @"(bd events journal) instead of polling every 2 seconds.\n\n"
        @"Enabling writes \"events-journal: true\" into this project's "
        @".beads/config.yaml — note that file may be tracked in git.\n\n"
        @"You can also enable it later yourself:\n"
        @"bd config set events-journal true",
        runner.bdVersion ?: @"1.3"];
    [alert addButtonWithTitle:@"Enable Live Updates"];
    [alert addButtonWithTitle:@"Not Now"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:win completionHandler:^(NSModalResponse resp) {
        __strong typeof(self) s = weakSelf;
        if (!s || s->_bdRunner != runner) return;
        NSMutableDictionary *a =
            [([ud dictionaryForKey:kEventsPromptAnswersKey] ?: @{}) mutableCopy];
        if (resp == NSAlertFirstButtonReturn) {
            a[root] = @"enabled";
            [ud setObject:a forKey:kEventsPromptAnswersKey];
            [runner enableEventsJournalWithCompletion:^(BdResult *r) {
                __strong typeof(self) s2 = weakSelf;
                if (!s2 || s2->_bdRunner != runner) return;
                if (r.ok) {
                    [s2 _startTailWithRunner:runner];
                } else {
                    NSLog(@"[NppBeads] enabling events journal failed: %@ — polling",
                          r.errorMessage);
                    [s2 _startPollWithRunner:runner];
                }
            }];
        } else {
            a[root] = @"declined";
            [ud setObject:a forKey:kEventsPromptAnswersKey];
            [s _startPollWithRunner:runner];
        }
    }];
}

- (void)_didTapRefresh:(id)sender {
    [self reloadData];
    // Re-baseline the poll so its next natural tick compares against
    // post-refresh state (prevents a ghost "changed" fire right after the
    // user hit Refresh). No-op in events-feed mode (_poll is nil there).
    [_poll kick];
}

// View-mode popup action: navigate webview without reloading data.
// We just change the URL; the JSONL user-script is reinstalled in case
// the user switched projects in between, but the webview reload() vs
// load(URL) distinction matters — we want a full URL change here.
- (void)_didChangeViewMode:(NSPopUpButton *)sender {
    BeadsViewMode newMode = (BeadsViewMode)sender.selectedTag;
    if (newMode == _viewMode) return;
    _viewMode = newMode;
    _viewerLoaded = NO;
    NSURL *url = [self _urlForViewMode:_viewMode];
    NSLog(@"[NppBeads] view mode → %ld (%@)", (long)newMode, url);
    // Make sure the JSONL user-script is refreshed (sticky across mode
    // switches — bridge.js re-runs on every load and re-reads the
    // WKUserScript-injected globals).
    [self _installJsonlUserScript];
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    [self _refreshTitleBar];
    // Phase 6 — visiting Activity acknowledges the "N new" badge and
    // rebases it against now(). Refresh the status bar so the badge
    // disappears immediately (next fresh update will re-populate).
    if (_viewMode == BeadsViewModeActivity) {
        [self _markActivityVisitedForCurrentProject];
        [self _refreshStatusBar];
    }
}

// Overflow "⋯" button reuses the right-click context menu.
- (void)_didTapMenu:(NSButton *)sender {
    NSPoint pt = NSMakePoint(0, sender.bounds.size.height + 2);
    [self.menu popUpMenuPositioningItem:nil
                             atLocation:[sender convertPoint:pt toView:nil]
                                 inView:sender.window.contentView];
}

// ─────────────────────────────────────────────────────────────────────────
//  NSSearchFieldDelegate — live search
// ─────────────────────────────────────────────────────────────────────────
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != _searchField) return;
    NSString *q = _searchField.stringValue ?: @"";
    if ([q isEqualToString:_lastSearchQuery]) return;
    _lastSearchQuery = [q copy];
    [self _pushSearchQuery:q];
}

- (void)_pushSearchQuery:(NSString *)q {
    if (!_viewerLoaded) return;
    NSString *js = nil;
    if (_viewMode == BeadsViewModeBoard ||
        _viewMode == BeadsViewModeActivity) {
        // Board + Activity both use __nppApp.setFilter. Activity's
        // applyFilter is wired to its render() which filters the list.
        js = [NSString stringWithFormat:
            @"if (window.__nppApp && typeof window.__nppApp.setFilter === 'function') {"
             "  window.__nppApp.setFilter({ query: %@ });"
             "}",
            jsStringLiteral(q)];
    } else if (_viewMode == BeadsViewModeIssues) {
        // Rich Issues — bridge.js installs __nppRichSearch which routes
        // into the Alpine root and calls loadIssues() (LIKE fallback for
        // missing FTS5).
        js = [NSString stringWithFormat:
            @"if (typeof window.__nppRichSearch === 'function') {"
             "  window.__nppRichSearch(%@);"
             "}",
            jsStringLiteral(q)];
    } else {
        return;   // Dashboard/Insights/Graph — search is hidden anyway
    }
    // Log eval errors so a broken JS path is diagnosable from the
    // system console — the Issues view search is the one that's most
    // likely to silently fail (no UI indicator of "nothing happened").
    [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[NppBeads] _pushSearchQuery(q=\"%@\") err=%@",
                     q ?: @"", e.localizedDescription);
    }];
}

// ─────────────────────────────────────────────────────────────────────────
//  Dark/light theme sync — track macOS system appearance
// ─────────────────────────────────────────────────────────────────────────
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self _pushThemeToWebView];
}

- (BOOL)_isDarkMode {
    switch (_themePref) {
        case BeadsThemePrefLight: return NO;
        case BeadsThemePrefDark:  return YES;
        case BeadsThemePrefAuto:
        default: {
            NSAppearanceName match = [self.effectiveAppearance
                bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                     NSAppearanceNameDarkAqua ]];
            return [match isEqualToString:NSAppearanceNameDarkAqua];
        }
    }
}

// Cycle Auto → Light → Dark → Auto. Persist. Reflect new state in
// the button icon/tooltip and push a theme update to the webview.
- (void)_didTapTheme:(id)sender {
    _themePref = (BeadsThemePref)((_themePref + 1) % 3);
    [[NSUserDefaults standardUserDefaults] setInteger:_themePref
                                               forKey:@"NppBeadsThemePref"];
    [self _refreshThemeButton];
    [self _pushThemeToWebView];
}

- (void)_refreshThemeButton {
    if (!_themeButton) return;
    NSString *symbol, *tip;
    switch (_themePref) {
        case BeadsThemePrefLight:
            symbol = @"sun.max";
            tip = @"Theme: Light (click to cycle to Dark)";
            break;
        case BeadsThemePrefDark:
            symbol = @"moon";
            tip = @"Theme: Dark (click to cycle to Auto)";
            break;
        case BeadsThemePrefAuto:
        default:
            symbol = @"circle.lefthalf.filled";
            tip = @"Theme: Auto (follows macOS) — click to cycle to Light";
            break;
    }
    if (@available(macOS 11.0, *)) {
        _themeButton.image = [NSImage imageWithSystemSymbolName:symbol
                                     accessibilityDescription:tip];
    }
    _themeButton.toolTip = tip;
}

- (void)_pushThemeToWebView {
    if (!_webView) return;
    BOOL dark = [self _isDarkMode];
    // The Rich viewer toggles `dark` class on <html> and reads/writes
    // localStorage.darkMode. Our own app views read
    // document.documentElement.dataset.theme. Update both in one pass
    // so either surface is correct.
    //
    // Phase 7 tweak: graph.js snapshots its color palette at module
    // load time + force-graph's .backgroundColor(…) is a one-shot
    // setter. Tell the graph module to live-swap its palette + re-apply
    // canvas bg so the Graph view flips instantly instead of requiring
    // a view-away-and-back. Safe no-op on non-Graph views (guarded).
    NSString *js = dark
        ? @"document.documentElement.classList.add('dark');"
           "document.documentElement.dataset.theme = 'dark';"
           "try{localStorage.setItem('darkMode','true');}catch(e){}"
           "if(window.__nppApp)window.__nppApp.setTheme('dark');"
           "if(window.__nppGraph&&window.__nppGraph.applyTheme)"
           "window.__nppGraph.applyTheme(true);"
        : @"document.documentElement.classList.remove('dark');"
           "document.documentElement.dataset.theme = 'light';"
           "try{localStorage.setItem('darkMode','false');}catch(e){}"
           "if(window.__nppApp)window.__nppApp.setTheme('light');"
           "if(window.__nppGraph&&window.__nppGraph.applyTheme)"
           "window.__nppGraph.applyTheme(false);";
    [_webView evaluateJavaScript:js completionHandler:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Context menu (right-click anywhere in the panel)
// ─────────────────────────────────────────────────────────────────────────
- (NSMenu *)_buildContextMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"NppBeads"];
    auto add = ^(NSString *title, SEL sel) {
        NSMenuItem *it = [m addItemWithTitle:title action:sel keyEquivalent:@""];
        it.target = self;
        return it;
    };
    add(@"Switch project…",                @selector(_didTapProjectChip:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Reload issues from disk",        @selector(ctxReloadIssues:));
    add(@"Reload viewer",                  @selector(ctxReloadViewer:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Reveal issues.jsonl in Finder",  @selector(ctxRevealJsonl:));
    add(@"Open .beads/ folder in Finder",  @selector(openBeadsDirInFinder:));
    [m addItem:[NSMenuItem separatorItem]];
    // Phase 3.5 — per-project auto-push opt-in. Checkmark state is
    // computed in validateMenuItem: against the currently-bound project.
    add(@"Enable bd auto-push for this project", @selector(_didToggleAutoPush:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Copy diagnostics to clipboard",  @selector(ctxCopyDiagnostics:));
    add(@"Show raw JSONL head (first 1000 chars)", @selector(ctxShowJsonlHead:));
    if (_showsHidePanelMenuItem) {
        [m addItem:[NSMenuItem separatorItem]];
        add(@"Hide panel",                 @selector(ctxHidePanel:));
    }
    return m;
}

// Setter: rebuild the menu in place so a runtime change is reflected
// in the next ⋯ tap or right-click. No-op when the value is unchanged.
- (void)setShowsHidePanelMenuItem:(BOOL)v {
    if (_showsHidePanelMenuItem == v) return;
    _showsHidePanelMenuItem = v;
    self.menu = [self _buildContextMenu];
}

// NSMenuValidation — computes checkmark + enabled state for dynamic
// items just before the menu is shown. Currently only the auto-push
// toggle depends on runtime state; other items are always enabled.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(_didToggleAutoPush:)) {
        if (!self.project || self.project.projectRoot.length == 0) {
            item.state = NSControlStateValueOff;
            return NO;   // disabled when no project is bound
        }
        BOOL on = [BeadsPanel _autoPushEnabledForProject:self.project.projectRoot];
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    return YES;
}

// Override so the panel's menu wins over any WKWebView ancestor menu too.
- (NSMenu *)menuForEvent:(NSEvent *)event { return self.menu; }

- (void)ctxReloadViewer:(id)sender {
    // Re-navigate the webview to the bundled index.html. This is safer
    // than WKWebView.reload when the previous load failed.
    _viewerLoaded = NO;
    [self _loadViewer];
}

- (void)ctxReloadIssues:(id)sender { [self reloadData]; }

- (void)ctxHidePanel:(id)sender {
    if (self.hideHandler) self.hideHandler();
}

- (void)ctxRevealJsonl:(id)sender {
    NSString *jsonl = self.project.jsonlPath;
    if (jsonl.length == 0) { NSBeep(); return; }
    [[NSWorkspace sharedWorkspace] selectFile:jsonl
                     inFileViewerRootedAtPath:self.project.beadsDir];
}

- (void)ctxCopyDiagnostics:(id)sender {
    // Kick off the JS probe FIRST, then assemble the rest while it runs;
    // present the alert from the completion handler so bridge state is
    // actually captured.
    NSString *probe =
        @"(function(){var out={};"
         "out.hasBridge=!!window.__nppBeads;"
         "out.bridgeVersion=(window.__nppBeads&&window.__nppBeads.version)||null;"
         "out.bridgeMode=(window.__nppBeads&&window.__nppBeads.mode)||null;"
         "out.jsonlLen=(window.__nppBeads&&window.__nppBeads.jsonl)?window.__nppBeads.jsonl.length:null;"
         "out.hasDbPromise=!!(window.__nppBeads&&window.__nppBeads.dbBytesPromise);"
         "out.hasInitSqlJs=typeof window.initSqlJs==='function';"
         "out.hasSQLCached=!!(window.initSqlJs&&window.initSqlJs.cached);"
         "out.hasBeadsViewer=!!window.beadsViewer;"
         "out.hasDB=!!(window.beadsViewer&&window.beadsViewer.DB_STATE&&window.beadsViewer.DB_STATE.db);"
         "out.dbSource=(window.beadsViewer&&window.beadsViewer.DB_STATE&&window.beadsViewer.DB_STATE.source)||null;"
         "out.loadingMessage=(document.querySelector('[x-text*=loadingMessage]')||{}).textContent||null;"
         "out.errorTitle=(window.beadsViewer&&window.beadsViewer.ERROR_STATE&&window.beadsViewer.ERROR_STATE.error)?window.beadsViewer.ERROR_STATE.error.title:null;"
         "out.errorDetails=(window.beadsViewer&&window.beadsViewer.ERROR_STATE&&window.beadsViewer.ERROR_STATE.error)?window.beadsViewer.ERROR_STATE.error.details:null;"
         "out.diagWasm=(window.beadsViewer&&window.beadsViewer.DIAGNOSTICS)?window.beadsViewer.DIAGNOSTICS.wasm:null;"
         "out.diagDbSource=(window.beadsViewer&&window.beadsViewer.DIAGNOSTICS)?window.beadsViewer.DIAGNOSTICS.dbSource:null;"
         "out.viewerReached=window.__nppViewerReached||null;"
         "out.hasWasmBytes=!!window.__nppBeadsWasmBytes;"
         "out.wasmBytesLen=window.__nppBeadsWasmBytes?window.__nppBeadsWasmBytes.byteLength:null;"
         "out.hasPreloadedJsonl=typeof window.__nppBeadsPreloadedJsonl==='string';"
         "out.preloadedJsonlLen=(typeof window.__nppBeadsPreloadedJsonl==='string')?window.__nppBeadsPreloadedJsonl.length:null;"
         "out.consoleTail=(window.__nppConsoleTail||[]).slice(-20);"
         "return JSON.stringify(out,null,2);})()";

    __weak typeof(self) weakSelf = self;
    [_webView evaluateJavaScript:probe completionHandler:^(id r, NSError *e) {
        __strong typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *bridgeState = @"(no response)";
        if ([r isKindOfClass:[NSString class]]) bridgeState = r;
        else if (e) bridgeState = e.localizedDescription;

        NSMutableString *s = [NSMutableString string];
        [s appendString:@"NppBeads diagnostics\n====================\n"];
        [s appendFormat:@"resourcesDir: %@\n", self_.resourcesDir ?: @"(nil)"];
        [s appendFormat:@"viewer index.html exists: %@\n",
            [[NSFileManager defaultManager] fileExistsAtPath:
                [[self_.resourcesDir stringByAppendingPathComponent:@"viewer"]
                    stringByAppendingPathComponent:@"index.html"]] ? @"YES" : @"NO"];
        [s appendFormat:@"project root: %@\n", self_.project.projectRoot ?: @"(nil)"];
        [s appendFormat:@".beads dir  : %@\n", self_.project.beadsDir    ?: @"(nil)"];
        [s appendFormat:@"jsonl path  : %@\n", self_.project.jsonlPath   ?: @"(nil)"];
        [s appendFormat:@"db path     : %@\n", self_.project.dbPath      ?: @"(nil)"];
        [s appendFormat:@"issues: %lu open, %lu blocked, %lu closed, %lu total\n",
            (unsigned long)[self_->_ds openIssueCount],
            (unsigned long)[self_->_ds blockedIssueCount],
            (unsigned long)[self_->_ds closedIssueCount],
            (unsigned long)[self_->_ds issueCount]];
        [s appendFormat:@"viewerLoaded: %@\n", self_->_viewerLoaded ? @"YES" : @"NO"];
        [s appendFormat:@"lastLoadError: %@\n", self_->_lastLoadError ?: @"(none)"];
        [s appendFormat:@"webView URL: %@\n", self_->_webView.URL.absoluteString ?: @"(none)"];
        [s appendFormat:@"webView title: %@\n", self_->_webView.title ?: @"(none)"];
        [s appendFormat:@"_loadViewer calls: %lu\n", (unsigned long)self_->_loadCount];
        [s appendFormat:@"reloadData calls: %lu\n",  (unsigned long)self_->_reloadDataCount];
        [s appendFormat:@"watcher fires: %lu\n",    (unsigned long)self_->_watcherFireCount];
        if (self_->_tail) {
            [s appendFormat:@"events feed: records=%lu lastSeq=%llu running=%@ paused=%@\n",
                (unsigned long)self_->_tail.recordCount,
                self_->_tail.lastSeq,
                self_->_tail.isRunning ? @"YES" : @"NO",
                self_->_tail.isPaused  ? @"YES" : @"NO"];
        } else if (self_->_poll) {
            [s appendFormat:@"poll: ticks=%lu changes=%lu skips(inflight)=%lu paused=%@\n",
                (unsigned long)self_->_poll.tickCount,
                (unsigned long)self_->_poll.changeCount,
                (unsigned long)self_->_poll.skipInFlightCount,
                self_->_poll.isPaused ? @"YES" : @"NO"];
        } else {
            [s appendString:@"poll: (not active — JSONL backend)\n"];
        }
        [s appendString:@"\n-- bridge state (JS) --\n"];
        [s appendString:bridgeState];
        [s appendString:@"\n"];

        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:s forType:NSPasteboardTypeString];

        // Short confirmation — the full diagnostic text is on the
        // clipboard for paste-into-bug-report; showing the whole thing
        // in the alert locked the panel on smaller screens because the
        // alert grew taller than the display.
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"NppBeads diagnostics copied";
        a.informativeText = [NSString stringWithFormat:
            @"%lu bytes copied to the clipboard. Paste it into a bug report "
             "or Preview the contents in any text editor.",
            (unsigned long)s.length];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }];
}

- (void)ctxShowJsonlHead:(id)sender {
    NSString *raw = [_ds rawText];
    NSString *head = (raw.length > 1000) ? [raw substringToIndex:1000] : raw;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"JSONL head (%lu bytes total)", (unsigned long)raw.length];
    a.informativeText = head.length ? head : @"(empty — no JSONL loaded)";
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

// ─────────────────────────────────────────────────────────────────────────
//  Phase 4 — Project switcher (dropdown attached to the project chip)
// ─────────────────────────────────────────────────────────────────────────

- (void)noteFileActivated:(NSString *)filePath {
    if (filePath.length == 0) return;
    NSString *std = [filePath stringByStandardizingPath];
    if (!std) return;
    // Unbounded growth is fine — NSMutableSet of strings at realistic
    // scale (a few thousand paths) is well under 1 MB and discovery
    // dedupes on beadsDir anyway. Worst case: we scan more candidates,
    // which is capped inside _buildProjectSwitcherMenu.
    [_seenFilePaths addObject:std];
}

// ─────────────────────────────────────────────────────────────────────────
//  Phase 5 — programmatic modal entry points (driven from editor menu)
// ─────────────────────────────────────────────────────────────────────────

- (void)showBeadDetail:(NSString *)beadId {
    if (beadId.length == 0) { NSBeep(); return; }
    NSString *bidEsc = [beadId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    bidEsc = [bidEsc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppApp && typeof window.__nppApp.openBeadModalById === 'function') {"
         "  window.__nppApp.openBeadModalById('%@');"
         "} else {"
         "  window.__nppBeadsPendingModalId = '%@';"
         "}",
        bidEsc, bidEsc];
    [self _runOnBoardView:js];
}

- (void)showCreateIssueWithTitle:(NSString *)title {
    NSString *safeTitle = title ?: @"";
    NSString *titleEsc = [safeTitle stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    titleEsc = [titleEsc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    // Strip newlines (selection may carry them; title must be one line).
    titleEsc = [titleEsc stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    titleEsc = [titleEsc stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppApp && typeof window.__nppApp.openNewIssueWithTitle === 'function') {"
         "  window.__nppApp.openNewIssueWithTitle('%@');"
         "} else {"
         "  window.__nppBeadsPendingCreateTitle = '%@';"
         "}",
        titleEsc, titleEsc];
    [self _runOnBoardView:js];
}

// Route a bit of JS at the Board view. If the view is already loaded on
// board.html, fire immediately. Otherwise switch to Board and queue the
// JS to fire in didFinishNavigation.
- (void)_runOnBoardView:(NSString *)js {
    if (_viewMode == BeadsViewModeBoard && _viewerLoaded && _webView) {
        [_webView evaluateJavaScript:js completionHandler:nil];
        return;
    }
    _pendingPostLoadJS = [js copy];
    if (_viewMode != BeadsViewModeBoard) {
        _viewMode = BeadsViewModeBoard;
        [_viewModePopup selectItemWithTag:_viewMode];
        _viewerLoaded = NO;
        [self _installJsonlUserScript];
        NSURL *url = [self _urlForViewMode:_viewMode];
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
        [self _refreshTitleBar];
    }
    // If we're on Board but not loaded yet (very early race), just wait —
    // didFinishNavigation will flush pendingPostLoadJS.
}

// MRU helpers — persist last-N bound project roots to NSUserDefaults.

+ (NSArray<NSString *> *)_persistedRecentProjectRoots {
    NSArray *arr = [[NSUserDefaults standardUserDefaults]
                    arrayForKey:kBeadsRecentProjectsKey];
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:arr.count];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (id entry in arr) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *root = [(NSString *)entry stringByStandardizingPath];
        // Defaults must contain absolute paths — a relative or malformed
        // entry would resolve in the plugin's cwd, which is nonsense.
        if (root.length == 0 || ![root isAbsolutePath]) continue;
        // Filter out projects whose .beads/ no longer exists. Cheap stat.
        NSString *beadsDir = [root stringByAppendingPathComponent:@".beads"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:beadsDir isDirectory:&isDir] && isDir) {
            [out addObject:root];
        }
    }
    return out;
}

+ (void)_recordRecentProjectRoot:(NSString *)root {
    if (root.length == 0) return;
    NSString *std = [root stringByStandardizingPath];
    if (!std) return;
    NSMutableArray<NSString *> *list =
        [[[NSUserDefaults standardUserDefaults] arrayForKey:kBeadsRecentProjectsKey] mutableCopy];
    if (!list) list = [NSMutableArray array];
    // Remove any prior occurrences (dedupe) regardless of position.
    NSMutableIndexSet *kill = [NSMutableIndexSet indexSet];
    [list enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([obj isKindOfClass:[NSString class]] &&
            [[(NSString *)obj stringByStandardizingPath] isEqualToString:std]) {
            [kill addIndex:idx];
        }
    }];
    [list removeObjectsAtIndexes:kill];
    [list insertObject:std atIndex:0];
    while (list.count > kBeadsRecentProjectsCap) {
        [list removeLastObject];
    }
    [[NSUserDefaults standardUserDefaults] setObject:list
                                              forKey:kBeadsRecentProjectsKey];
}

// Dropdown trigger — dynamically builds the menu every time so recency
// and file-path activation state reflect the moment of the click.
- (void)_didTapProjectChip:(id)sender {
    NSMenu *m = [self _buildProjectSwitcherMenu];
    if (m.itemArray.count == 0) { NSBeep(); return; }
    NSButton *btn = (NSButton *)sender;
    NSPoint pt = NSMakePoint(0, btn.bounds.size.height + 2);
    [m popUpMenuPositioningItem:nil
                     atLocation:[btn convertPoint:pt toView:nil]
                         inView:btn.window.contentView];
}

- (NSMenu *)_buildProjectSwitcherMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Switch Project"];
    m.autoenablesItems = NO;

    NSString *currentStd = [self.project.projectRoot stringByStandardizingPath];

    // Current project (checked, non-actionable label row). Hidden when
    // no project is bound — no value in showing "(no project) ✓".
    if (self.project) {
        NSString *leaf = self.project.projectRoot.lastPathComponent ?: @"(project)";
        NSMenuItem *cur = [[NSMenuItem alloc] initWithTitle:leaf
                                                     action:nil
                                              keyEquivalent:@""];
        cur.toolTip = self.project.projectRoot;
        cur.state   = NSControlStateValueOn;
        cur.enabled = NO;
        [m addItem:cur];
        [m addItem:[NSMenuItem separatorItem]];
    }

    // Collect candidate project roots from three sources, MRU-ordered:
    //   1. NSUserDefaults (cross-session recent binds)
    //   2. Session-seen file paths, walked up for .beads/
    //   3. NSDocumentController's recent documents (system-wide)
    // Dedupe by standardized projectRoot.
    NSMutableOrderedSet<NSString *> *rootsMRU = [NSMutableOrderedSet orderedSet];
    for (NSString *r in [BeadsPanel _persistedRecentProjectRoots]) {
        [rootsMRU addObject:r];
    }

    NSMutableArray<NSString *> *walkInputs = [NSMutableArray array];
    [walkInputs addObjectsFromArray:_seenFilePaths.allObjects];
    for (NSURL *u in [[NSDocumentController sharedDocumentController] recentDocumentURLs]) {
        NSString *p = u.path;
        if (p.length) [walkInputs addObject:p];
    }
    // Cap scanning work: 64 inputs = ~640 stat calls worst-case at our
    // depth limit of 10 (most walks terminate far earlier at $HOME).
    if (walkInputs.count > 64) {
        walkInputs = [[walkInputs subarrayWithRange:NSMakeRange(0, 64)] mutableCopy];
    }
    NSArray<BeadsProject *> *discovered =
        [BeadsProjectScanner discoverUniqueProjectsFromPaths:walkInputs max:32];
    for (BeadsProject *p in discovered) {
        NSString *std = [p.projectRoot stringByStandardizingPath];
        if (std) [rootsMRU addObject:std];
    }

    // Render — skip the currently-bound one (already shown above).
    BOOL anyListed = NO;
    for (NSString *root in rootsMRU) {
        if (currentStd && [root isEqualToString:currentStd]) continue;
        NSString *leaf = root.lastPathComponent ?: root;
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:leaf
                                                    action:@selector(_didPickRecentProject:)
                                             keyEquivalent:@""];
        it.target = self;
        it.toolTip = root;
        it.representedObject = root;
        [m addItem:it];
        anyListed = YES;
    }
    if (anyListed) [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open .beads folder…"
                                                  action:@selector(_didPickOpenBeadsDir:)
                                           keyEquivalent:@""];
    open.target = self;
    [m addItem:open];

    if (self.project) {
        NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Unbind current project"
                                                       action:@selector(_didPickUnbind:)
                                                keyEquivalent:@""];
        clear.target = self;
        [m addItem:clear];
    }

    return m;
}

- (void)_didPickRecentProject:(NSMenuItem *)sender {
    NSString *root = [sender.representedObject isKindOfClass:[NSString class]]
                     ? sender.representedObject : nil;
    if (root.length == 0) return;
    BeadsProject *p = [BeadsProjectScanner projectFromRoot:root];
    if (!p) {
        // .beads disappeared since we built the menu — surface a friendly
        // error + prune the stale defaults entry so it stops appearing.
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Project not found";
        a.informativeText = [NSString stringWithFormat:
            @"The .beads/ directory for this project no longer exists:\n\n%@", root];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        // Prune from defaults — easiest is to re-record a sentinel then
        // strip: simpler, just rewrite the list without this entry.
        NSMutableArray *list = [[[NSUserDefaults standardUserDefaults]
            arrayForKey:kBeadsRecentProjectsKey] mutableCopy] ?: [NSMutableArray array];
        [list removeObject:root];
        [[NSUserDefaults standardUserDefaults] setObject:list
                                                  forKey:kBeadsRecentProjectsKey];
        return;
    }
    [self bindProject:p];
}

- (void)_didPickOpenBeadsDir:(NSMenuItem *)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles          = NO;
    op.canChooseDirectories    = YES;
    op.canCreateDirectories    = NO;
    op.allowsMultipleSelection = NO;
    op.resolvesAliases         = YES;
    op.treatsFilePackagesAsDirectories = YES;   // .beads may have xattrs
    op.title   = @"Open .beads folder";
    op.message = @"Pick the .beads directory of the project you want to view.";
    op.prompt  = @"Open";
    // Default to the current project's parent so the user doesn't start
    // from scratch; fall back to $HOME.
    NSString *start = self.project.projectRoot ?: NSHomeDirectory();
    op.directoryURL = [NSURL fileURLWithPath:start isDirectory:YES];

    __weak typeof(self) weakSelf = self;
    [op beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse result) {
        __strong typeof(self) s = weakSelf;
        if (!s || result != NSModalResponseOK) return;
        NSString *chosen = op.URL.path;
        if (chosen.length == 0) return;
        // Accept both the .beads/ itself or its parent (project root);
        // canonicalize to .beads/ and validate.
        NSString *beadsDir = chosen;
        if (![beadsDir.lastPathComponent isEqualToString:@".beads"]) {
            beadsDir = [chosen stringByAppendingPathComponent:@".beads"];
        }
        BeadsProject *p = [BeadsProjectScanner projectFromBeadsDir:beadsDir];
        if (!p) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"Not a beads project";
            a.informativeText =
                @"The chosen directory doesn't contain a usable .beads/ "
                 "folder (expected issues.jsonl or beads.db inside).";
            [a addButtonWithTitle:@"OK"];
            [a runModal];
            return;
        }
        [s bindProject:p];
    }];
}

- (void)_didPickUnbind:(NSMenuItem *)sender {
    if (!self.project) return;
    [self bindProject:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Phase 3.5 — per-project auto-push (anti-sandbox) toggle
// ─────────────────────────────────────────────────────────────────────────

+ (BOOL)_autoPushEnabledForProject:(NSString *)projectRoot {
    NSString *std = [projectRoot stringByStandardizingPath];
    if (std.length == 0) return NO;
    NSArray *arr = [[NSUserDefaults standardUserDefaults]
                    arrayForKey:kBeadsAutoPushProjectsKey];
    if (![arr isKindOfClass:[NSArray class]]) return NO;
    for (id entry in arr) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        if ([[(NSString *)entry stringByStandardizingPath] isEqualToString:std]) return YES;
    }
    return NO;
}

+ (void)_setAutoPushEnabled:(BOOL)enabled forProject:(NSString *)projectRoot {
    NSString *std = [projectRoot stringByStandardizingPath];
    if (std.length == 0) return;
    NSMutableArray *list =
        [[[NSUserDefaults standardUserDefaults] arrayForKey:kBeadsAutoPushProjectsKey] mutableCopy];
    if (!list) list = [NSMutableArray array];
    // Filter existing entries that equal std (dedupe).
    NSMutableIndexSet *kill = [NSMutableIndexSet indexSet];
    [list enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([obj isKindOfClass:[NSString class]] &&
            [[(NSString *)obj stringByStandardizingPath] isEqualToString:std]) {
            [kill addIndex:idx];
        }
    }];
    [list removeObjectsAtIndexes:kill];
    if (enabled) [list addObject:std];
    [[NSUserDefaults standardUserDefaults] setObject:list
                                              forKey:kBeadsAutoPushProjectsKey];
}

// Overflow-menu action: flip auto-push for the currently bound project.
// Updates persistence, the live runner's useSandbox flag, and invalidates
// the read cache so the next bd call reflects the new mode.
- (void)_didToggleAutoPush:(NSMenuItem *)sender {
    if (!self.project || self.project.projectRoot.length == 0) { NSBeep(); return; }
    BOOL wasEnabled = [BeadsPanel _autoPushEnabledForProject:self.project.projectRoot];
    BOOL nowEnabled = !wasEnabled;
    [BeadsPanel _setAutoPushEnabled:nowEnabled forProject:self.project.projectRoot];
    if (_bdRunner) {
        _bdRunner.useSandbox = !nowEnabled;
        [_bdRunner invalidateCache];
    }
    NSLog(@"[NppBeads] auto-push %@ for %@",
          nowEnabled ? @"ENABLED (sandbox OFF)" : @"disabled (sandbox ON — default)",
          self.project.projectRoot);
    // Nudge the user about the trade-off the first time they flip it on
    // for a project. No modal confirmation — toggle is reversible.
    if (nowEnabled) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"bd auto-push enabled for this project";
        a.informativeText =
            @"Every bd write will now attempt a `dolt push` to the git "
             "remote. If non-interactive git auth isn't set up, writes "
             "will hang ~23s each. Toggle back off via the same menu if "
             "writes become slow.";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Status/title updates
// ─────────────────────────────────────────────────────────────────────────
- (void)_refreshTitleBar {
    if (self.project) {
        NSString *leaf = self.project.projectRoot.lastPathComponent ?: @"(project)";
        _projectChip.title    = [leaf stringByAppendingString:@" ▾"];
        _projectChip.toolTip  = self.project.projectRoot;
        _refreshButton.enabled = YES;
        _openDirButton.enabled = YES;
        _viewModePopup.enabled = YES;
        _searchField.enabled   = YES;
    } else {
        _projectChip.title    = @"(no project) ▾";
        _projectChip.toolTip  = @"Click to pick a .beads/ project.";
        _refreshButton.enabled = NO;
        _openDirButton.enabled = NO;
        _viewModePopup.enabled = NO;
        _searchField.enabled   = NO;
    }
    // Chip is ALWAYS enabled — that's the entry point to Open/Scan even
    // when no project is currently bound.
    _projectChip.enabled = YES;
    [_viewModePopup selectItemWithTag:_viewMode];

    // Search field: Board + Issues + Activity (views with per-issue
    // filtering). Dashboard / Insights are aggregates; Graph has its
    // own "Find node…". Issues uses a LIKE fallback on loadIssues.
    BOOL showSearch = (_viewMode == BeadsViewModeBoard ||
                       _viewMode == BeadsViewModeIssues ||
                       _viewMode == BeadsViewModeActivity);
    _searchField.hidden = !showSearch;
    if (!showSearch && _searchField.stringValue.length) {
        // Clear any stale query so switching back to Board shows the
        // full list.
        _searchField.stringValue = @"";
        _lastSearchQuery = @"";
    }
}

- (void)_refreshStatusBar {
    if (!self.project) {
        _statusLabel.stringValue = @"no project · click the project name ▾ to pick one";
        return;
    }
    if (!self.project.jsonlPath) {
        _statusLabel.stringValue = [NSString stringWithFormat:@"%@ · no issues.jsonl yet",
                                    self.project.projectRoot.lastPathComponent ?: @""];
        return;
    }
    NSUInteger total = [_ds issueCount];
    NSUInteger open  = [_ds openIssueCount];
    NSUInteger blkd  = [_ds blockedIssueCount];
    NSUInteger cls   = [_ds closedIssueCount];
    NSString *backend = _activeDataSource.backendLabel ?: @"read-only (JSONL)";
    NSUInteger newCount = [self _newActivityCountSinceLastVisit];
    NSString *badge = (newCount > 0)
        ? [NSString stringWithFormat:@" · ● %lu new", (unsigned long)newCount]
        : @"";
    _statusLabel.stringValue = [NSString stringWithFormat:
        @"%@ · %lu issues (%lu open · %lu blocked · %lu closed) · %@%@",
        self.project.projectRoot.lastPathComponent ?: @"(project)",
        (unsigned long)total, (unsigned long)open,
        (unsigned long)blkd,  (unsigned long)cls,
        backend, badge];
}

// ─────────────────────────────────────────────────────────────────────────
//  Phase 6 — "N new" badge helpers. Uses updated_at from the parsed JSONL
//  (no bd calls). "Acknowledged" when the user visits the Activity view.
// ─────────────────────────────────────────────────────────────────────────

- (NSString *)_lastActivityVisitForCurrentProject {
    if (!self.project || self.project.projectRoot.length == 0) return nil;
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults]
                          dictionaryForKey:kBeadsLastVisitKey];
    NSString *std = [self.project.projectRoot stringByStandardizingPath];
    if (![dict isKindOfClass:[NSDictionary class]] || std.length == 0) return nil;
    id v = dict[std];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (void)_markActivityVisitedForCurrentProject {
    if (!self.project || self.project.projectRoot.length == 0) return;
    NSString *std = [self.project.projectRoot stringByStandardizingPath];
    if (std.length == 0) return;
    NSMutableDictionary *dict =
        [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kBeadsLastVisitKey] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];
    NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                      NSISO8601DateFormatWithFractionalSeconds;
    dict[std] = [f stringFromDate:[NSDate date]];
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:kBeadsLastVisitKey];
}

// Count beads whose updated_at (or created_at fallback) is STRICTLY later
// than the stored last-visit timestamp. No stored timestamp → everything
// is "new" until the user visits Activity once.
- (NSUInteger)_newActivityCountSinceLastVisit {
    NSString *since = [self _lastActivityVisitForCurrentProject];
    // No lastVisit recorded yet — don't surface a giant "N new" badge on
    // first open (would be the full issue count). Return 0 until the
    // user has visited Activity at least once.
    if (since.length == 0) return 0;
    NSString *raw = [_ds rawText] ?: @"";
    if (raw.length == 0) return 0;
    NSUInteger count = 0;
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSString *when = [(NSDictionary *)obj objectForKey:@"updated_at"];
        if (![when isKindOfClass:[NSString class]] || when.length == 0) {
            when = [(NSDictionary *)obj objectForKey:@"created_at"];
        }
        if (![when isKindOfClass:[NSString class]] || when.length == 0) continue;
        // String comparison works for ISO 8601 timestamps since they're
        // lexicographically sortable — avoids a full date-parse round-trip
        // per line. Matches bd's output format.
        if ([when compare:since] == NSOrderedDescending) count++;
    }
    return count;
}

// ─────────────────────────────────────────────────────────────────────────
//  Bridge (WKScriptMessageHandler)
// ─────────────────────────────────────────────────────────────────────────
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"beadsBridge"]) return;
    NSDictionary *body = nil;
    if ([message.body isKindOfClass:[NSDictionary class]]) body = message.body;
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"getJsonl"]) {
        [self _pushJsonlToBridge];
    } else if ([type isEqualToString:@"openExternal"]) {
        NSString *url = body[@"url"];
        if ([url isKindOfClass:[NSString class]]) {
            NSURL *u = [NSURL URLWithString:url];
            if (u) [[NSWorkspace sharedWorkspace] openURL:u];
        }
    } else if ([type isEqualToString:@"openBeadDetails"]) {
        NSString *bid = body[@"id"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            // Phase 2: jump to the Rich viewer's detail route. Phase 4
            // introduces our native Detail view which will claim this.
            _viewMode = BeadsViewModeDashboard;   // index.html is where #/issue/… lives
            [_viewModePopup selectItemWithTag:BeadsViewModeDashboard];
            NSCharacterSet *safe = [NSCharacterSet URLPathAllowedCharacterSet];
            NSString *encoded = [bid stringByAddingPercentEncodingWithAllowedCharacters:safe];
            NSString *href = [NSString stringWithFormat:
                @"nppbeads://viewer/index.html#/issue/%@", encoded];
            _viewerLoaded = NO;
            [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:href]]];
        }
    } else if ([type isEqualToString:@"openBeadModal"]) {
        // Phase 6 — from Activity view, clicking a row routes here.
        // showBeadDetail: handles the view switch + post-load JS queue.
        NSString *bid = body[@"id"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            [self showBeadDetail:bid];
        }
    } else if ([type isEqualToString:@"updateBead"]) {
        [self _handleUpdateBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"createBead"]) {
        [self _handleCreateBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"closeBead"]) {
        [self _handleCloseBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"reopenBead"]) {
        [self _handleReopenBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"claimBead"]) {
        [self _handleClaimBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"depAdd"]) {
        [self _handleDepAdd:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"depRemove"]) {
        [self _handleDepRemove:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"deleteBead"]) {
        [self _handleDeleteBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"unassignBead"]) {
        [self _handleUnassignBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"addComment"]) {
        [self _handleAddComment:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"fetchBead"]) {
        [self _handleFetchBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"zoomIn"]) {
        [self _adjustPageZoomBy:+kBeadsZoomStep];
    } else if ([type isEqualToString:@"zoomOut"]) {
        [self _adjustPageZoomBy:-kBeadsZoomStep];
    } else if ([type isEqualToString:@"zoomReset"]) {
        [self _setPageZoom:kBeadsZoomDefault persist:YES];
    } else {
        // Unknown message — ignore for forward-compat.
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Bridge: write handlers → _activeDataSource
//
//  Every write responds back to the webview via
//    window.__nppBridge.resolve(reqId, {ok, bead?, error?, errorKind?, blockers?})
//  The webview side (app.js helper in bridge.js) tracks pending requests
//  by reqId and resolves the matching Promise. This keeps JS code
//  write-agnostic and lets all views react uniformly.
// ─────────────────────────────────────────────────────────────────────────

- (void)_resolveRequest:(nullable NSString *)reqId
                     ok:(BOOL)ok
                   bead:(nullable NSDictionary *)bead
                  error:(nullable NSError *)err {
    if (!reqId.length) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"ok"] = @(ok);
    if (bead) payload[@"bead"] = bead;
    if (err) {
        payload[@"error"] = err.localizedDescription ?: @"unknown";
        payload[@"errorKind"] = @(err.code);
        NSArray *blockers = err.userInfo[@"blockers"];
        if (blockers.count) payload[@"blockers"] = blockers;
    }
    NSError *jerr = nil;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:payload
                                                 options:0 error:&jerr];
    if (!jd) return;
    NSString *jstr = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
    if (!jstr) return;
    NSString *encodedReq = [reqId stringByReplacingOccurrencesOfString:@"\""
                                                            withString:@"\\\""];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppBridge && typeof window.__nppBridge.resolve === 'function') {"
         "  window.__nppBridge.resolve(\"%@\", %@);"
         "}", encodedReq, jstr];
    [_webView evaluateJavaScript:js completionHandler:nil];
}

// Trigger a fresh list on all views after any successful write, so the
// Board/Issues/Details panels catch up without waiting for the next poll.
// CRITICAL: bd auto-exports issues.jsonl on every write (via its post-
// commit hook). To reflect that on-disk change, we must (1) invalidate
// the bd cache, (2) reload the JsonlDataSource so it re-reads the file,
// and (3) push the fresh text to JS — both as the preloaded global
// (so a subsequent navigation sees the new data) and via reload() so
// the currently-rendered view updates now.
- (void)_broadcastDataChanged {
    [_activeDataSource invalidateCache];
    [_ds reload];                         // JSONL cache — forces re-read on next rawText
    NSString *fresh = [_ds rawText] ?: @"";
    [self _refreshStatusBar];             // counters in status bar
    NSString *jsLit = jsStringLiteral(fresh);
    NSString *js = [NSString stringWithFormat:
        @"window.__nppBeadsPreloadedJsonl = %@;"
         "if (window.__nppApp && typeof window.__nppApp.reload === 'function') {"
         "  window.__nppApp.reload(window.__nppBeadsPreloadedJsonl);"
         "} else if (window.__nppBeads && typeof window.__nppBeads.receiveJsonl === 'function') {"
         "  window.__nppBeads.receiveJsonl(window.__nppBeadsPreloadedJsonl);"
         "}", jsLit];
    [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[NppBeads] _broadcastDataChanged eval error: %@", e);
    }];
}

- (void)_handleUpdateBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid     = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *status  = [body[@"status"] isKindOfClass:[NSString class]] ? body[@"status"] : nil;
    NSString *title   = [body[@"title"]  isKindOfClass:[NSString class]] ? body[@"title"]  : nil;
    NSString *descr   = [body[@"description"] isKindOfClass:[NSString class]] ? body[@"description"] : nil;
    NSNumber *prio    = [body[@"priority"] isKindOfClass:[NSNumber class]] ? body[@"priority"] : nil;
    // NOTE: the bridge envelope itself uses `type` for message routing
    // (updateBead/createBead/…), so bead-issue-type lives under
    // `issueType`. Reading `type` here would pass the message name to
    // `bd --type` and make every drag a bogus-type update.
    NSString *type    = [body[@"issueType"] isKindOfClass:[NSString class]] ? body[@"issueType"] : nil;
    NSString *assgn   = [body[@"assignee"] isKindOfClass:[NSString class]] ? body[@"assignee"] : nil;
    NSArray  *addL    = [body[@"addLabels"]    isKindOfClass:[NSArray class]] ? body[@"addLabels"]    : nil;
    NSArray  *rmL     = [body[@"removeLabels"] isKindOfClass:[NSArray class]] ? body[@"removeLabels"] : nil;

    if (!bid.length) {
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:@"missing id"}]];
        return;
    }
    NSLog(@"[NppBeads] updateBead id=%@ status=%@ backend=%@",
          bid, status ?: @"(nil)", _activeDataSource.backendLabel ?: @"?");
    __weak typeof(self) weakSelf = self;
    [_activeDataSource updateIssue:bid title:title description:descr status:status
                          priority:prio type:type assignee:assgn
                         addLabels:addL removeLabels:rmL
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        if (err) {
            NSLog(@"[NppBeads] updateBead %@ FAILED: code=%ld msg=%@",
                  bid, (long)err.code, err.localizedDescription);
        } else {
            NSLog(@"[NppBeads] updateBead %@ OK new_status=%@",
                  bid, bead[@"status"] ?: @"(none)");
        }
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleCreateBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *title = [body[@"title"] isKindOfClass:[NSString class]] ? body[@"title"] : nil;
    NSString *type  = [body[@"issueType"] isKindOfClass:[NSString class]] ? body[@"issueType"] : nil;
    NSNumber *prio  = [body[@"priority"] isKindOfClass:[NSNumber class]] ? body[@"priority"] : nil;
    NSString *descr = [body[@"description"] isKindOfClass:[NSString class]] ? body[@"description"] : nil;
    NSArray  *lbls  = [body[@"labels"] isKindOfClass:[NSArray class]] ? body[@"labels"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource createIssueWithTitle:title type:type priority:prio
                                 description:descr labels:lbls
                                  completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleCloseBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid    = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *reason = [body[@"reason"] isKindOfClass:[NSString class]] ? body[@"reason"] : nil;
    BOOL      force  = [body[@"force"] boolValue];
    __weak typeof(self) weakSelf = self;
    [_activeDataSource closeIssue:bid reason:reason force:force
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleReopenBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid    = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *reason = [body[@"reason"] isKindOfClass:[NSString class]] ? body[@"reason"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource reopenIssue:bid reason:reason
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleClaimBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource claimIssue:bid completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleDepAdd:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *dep  = [body[@"dependent"]  isKindOfClass:[NSString class]] ? body[@"dependent"]  : nil;
    NSString *dpd  = [body[@"dependency"] isKindOfClass:[NSString class]] ? body[@"dependency"] : nil;
    NSString *kind = [body[@"depType"]    isKindOfClass:[NSString class]] ? body[@"depType"]    : @"blocks";
    __weak typeof(self) weakSelf = self;
    [_activeDataSource addDependencyFromIssue:dep toIssue:dpd type:kind
                                  completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleDepRemove:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *dep  = [body[@"dependent"]  isKindOfClass:[NSString class]] ? body[@"dependent"]  : nil;
    NSString *dpd  = [body[@"dependency"] isKindOfClass:[NSString class]] ? body[@"dependency"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource removeDependencyFromIssue:dep toIssue:dpd
                                     completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleDeleteBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    if (!bid.length) {
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:@"missing id"}]];
        return;
    }
    NSLog(@"[NppBeads] deleteBead id=%@", bid);
    __weak typeof(self) weakSelf = self;
    [_activeDataSource deleteIssue:bid completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        if (err) NSLog(@"[NppBeads] deleteBead %@ FAILED: %@", bid, err.localizedDescription);
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleUnassignBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    if (!bid.length) {
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:@"missing id"}]];
        return;
    }
    NSLog(@"[NppBeads] unassignBead id=%@", bid);
    __weak typeof(self) weakSelf = self;
    [_activeDataSource unassignIssue:bid completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleAddComment:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid  = [body[@"id"]   isKindOfClass:[NSString class]] ? body[@"id"]   : nil;
    NSString *text = [body[@"body"] isKindOfClass:[NSString class]] ? body[@"body"] : nil;
    if (!bid.length || !text.length) {
        NSString *msg = !bid.length ? @"missing id" : @"empty comment body";
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:msg}]];
        return;
    }
    NSLog(@"[NppBeads] addComment id=%@ bodyLen=%lu", bid, (unsigned long)text.length);
    __weak typeof(self) weakSelf = self;
    [_activeDataSource addCommentToIssue:bid body:text completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

// Option B zoom helpers. Called from the bridge when the JS-side
// keydown listener in bridge.js catches ⌘+/⌘-/⌘0 inside the webview.

- (CGFloat)_loadPersistedZoom {
    // -doubleForKey: returns 0.0 when the key is absent — use that as
    // the "never set" signal and fall back to the default. Also defend
    // against clipped values that could wander outside our clamps if
    // a user manually edits defaults.
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if (![defs objectForKey:kBeadsPanelZoomKey]) return kBeadsZoomDefault;
    double z = [defs doubleForKey:kBeadsPanelZoomKey];
    if (z < kBeadsZoomMin - 0.001) return kBeadsZoomDefault;
    if (z > kBeadsZoomMax + 0.001) return kBeadsZoomDefault;
    return (CGFloat)z;
}

- (void)_setPageZoom:(CGFloat)zoom persist:(BOOL)persist {
    if (!_webView) return;
    CGFloat clamped = MAX(kBeadsZoomMin, MIN(kBeadsZoomMax, zoom));
    _webView.pageZoom = clamped;
    if (persist) {
        [[NSUserDefaults standardUserDefaults] setDouble:(double)clamped
                                                  forKey:kBeadsPanelZoomKey];
    }
    NSLog(@"[NppBeads] pageZoom = %.2f", (double)clamped);
}

- (void)_adjustPageZoomBy:(CGFloat)delta {
    if (!_webView) return;
    // Snap to a 0.05 grid to avoid floating-point drift on repeated
    // ⌘+/⌘- presses (otherwise zoom creeps to 0.8000000000001).
    CGFloat next = _webView.pageZoom + delta;
    next = round(next * 20.0) / 20.0;
    [self _setPageZoom:next persist:YES];
}

// Phase 6 — fetch a single bead with its full payload (dependencies +
// comments, which the JSONL export omits for comments). Used by the
// detail modal's comments section to get the live comment list.
- (void)_handleFetchBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    if (!bid.length) {
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:@"missing id"}]];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [_activeDataSource showIssue:bid completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        // No broadcast — this is a read. Cache invalidation on writes
        // already covers freshness.
    }];
}

- (void)_pushJsonlToBridge {
    NSString *raw = [_ds rawText];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppBeads) { window.__nppBeads.receiveJsonl(%@); }",
        jsStringLiteral(raw)];
    [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[NppBeads] receiveJsonl eval error: %@", e);
    }];
}

// ─────────────────────────────────────────────────────────────────────────
//  WKNavigationDelegate — open external http(s) links in default browser
// ─────────────────────────────────────────────────────────────────────────
- (void)dealloc {
    [_poll stop];
    _poll = nil;
    [_tail stop];
    _tail = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    @try { [_webView removeObserver:self forKeyPath:@"URL"]; }
    @catch (NSException *e) { /* not added */ }
}

// Fires when the panel's host window changes — pop-out to a floating
// panel, docking back into the side-panel stack, or parent-window
// reparenting. Alpine keeps its reactive state across these transitions
// but its x-transition animations often leave overlays (the graph
// detail panel, the selectedIssue modal) in a "visible-but-zombie"
// state. We nudge Alpine to clear them.
//
// Also: rewire the window-key notifications so BeadsPoll pauses whenever
// the host isn't key. Re-registered on every window change (dock/float/
// remove) because NSNotificationCenter observers are scoped to `object:`.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self _installWindowKeyStateObservers];
    if (!_viewerLoaded || !_webView || !self.window) return;
    [_webView evaluateJavaScript:
        @"if (typeof window.__nppClearTransientState === 'function') {"
         "  window.__nppClearTransientState();"
         "}"
        completionHandler:nil];
}

- (void)_installWindowKeyStateObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // Drop any previous wiring. We own *all* notifications on self, so
    // removeObserver:name:object: with nil object clears per-name fanout.
    [nc removeObserver:self name:NSWindowDidBecomeKeyNotification  object:nil];
    [nc removeObserver:self name:NSWindowDidResignKeyNotification object:nil];

    NSWindow *w = self.window;
    if (!w) {
        // Moved out of any window (panel torn down / pre-init). Pause
        // live sync defensively — nothing to display on anyway.
        [_poll pause];
        [_tail pause];
        return;
    }

    [nc addObserver:self selector:@selector(_hostWindowBecameKey:)
               name:NSWindowDidBecomeKeyNotification  object:w];
    [nc addObserver:self selector:@selector(_hostWindowResignedKey:)
               name:NSWindowDidResignKeyNotification object:w];

    // Snapshot current state so we match reality (e.g. panel attached
    // to a non-key window during a dock restore).
    if (w.isKeyWindow) { [_poll resume]; [_tail resume]; }
    else               { [_poll pause];  [_tail pause];  }
}

- (void)_hostWindowBecameKey:(NSNotification *)note {
    [_poll resume];
    [_tail resume];   // flushes any change that arrived while blurred
    // Phase 6 — user is back; recompute the "N new" badge against any
    // JSONL that landed while the panel was blurred.
    [self _refreshStatusBar];
}

- (void)_hostWindowResignedKey:(NSNotification *)note {
    [_poll pause];
    [_tail pause];
}

// Called by NppBeads.mm every time the user shows the panel. Resets
// the view to Dashboard + clears the search so re-opening feels fresh
// rather than resuming whatever weird state the user last left behind.
- (void)prepareForShow {
    BeadsViewMode oldMode = _viewMode;
    _viewMode = BeadsViewModeDashboard;
    [_viewModePopup selectItemWithTag:_viewMode];
    _searchField.stringValue = @"";
    _lastSearchQuery = @"";
    [self _refreshTitleBar];

    // Crash-mitigation: skip the full webview reload when we're
    // already loaded on the dashboard URL. Fresh loadRequest yanks
    // WebKit's view tree which has been documented in the host's
    // EditorView.mm SCN_MODIFIED comment to destabilize TextInputUI's
    // CursorUIViewService, with stale views surviving long enough to
    // trip an exception on the next AppKit view-tree walk. Three
    // confirmed crashes followed this pattern.
    //
    // If we're already on Dashboard with the viewer loaded, just push
    // a clear-transient-state JS poke (the same one viewDidMoveToWindow
    // uses) and return. If we're on a different view mode (Issues /
    // Graph / Board / Activity), navigate to Dashboard via a
    // hash-only fragment change which doesn't tear down the page.
    NSURL *targetURL = [self _urlForViewMode:_viewMode];
    NSURL *currentURL = _webView.URL;
    if (_viewerLoaded && currentURL) {
        NSString *currentPath = currentURL.path ?: @"";
        NSString *targetPath  = targetURL.path  ?: @"";
        // Same page (typically index.html) — drive routing via hash.
        if ([currentPath isEqualToString:targetPath]) {
            [_webView evaluateJavaScript:
                @"if (typeof window.__nppClearTransientState === 'function') {"
                 "  window.__nppClearTransientState();"
                 "}"
                 "if (location.hash !== '#/') location.hash = '/';"
                completionHandler:nil];
            return;
        }
        // Different page (Board → Dashboard, Activity → Dashboard).
        // Still need a real navigation but at least we've collapsed
        // the same-page case which is the common one when re-toggling
        // visibility without changing the view mode in between.
    }
    (void)oldMode;
    _viewerLoaded = NO;
    [self _installJsonlUserScript];
    [_webView loadRequest:[NSURLRequest requestWithURL:targetURL]];
}

// KVO: webView.URL changed. Map it back to a BeadsViewMode and update
// the popup so internal navigation stays in sync with our toolbar.
//
// Also critical for fragment-only navigations: WKWebView often doesn't
// fire didFinishNavigation when ONLY the URL fragment changes (e.g.
// Dashboard #/ → Issues #/issues — same index.html). Without a signal
// that the "new view" is ready, _viewerLoaded stays NO forever and
// anything gated on it (toolbar search, post-load JS queue, etc.)
// silently bails. The KVO observer is the reliable signal: if the path
// resolves to a page we recognize AND the DOM is already loaded (it is,
// since we're just navigating a fragment on an already-loaded page),
// flip _viewerLoaded back to YES and drain any pending actions.
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)ctx {
    if (object != _webView || ![keyPath isEqualToString:@"URL"]) return;
    NSURL *url = _webView.URL;
    if (!url) return;
    BeadsViewMode detected = [self _viewModeFromURL:url];
    if (detected != _viewMode) {
        _viewMode = detected;
        [_viewModePopup selectItemWithTag:_viewMode];
        [self _refreshTitleBar];
    }
    // Fragment-only navigation fix: if URL is now a known route and we
    // still think the viewer isn't loaded, adopt the new URL as ready.
    // Guard on URL.path ending with index.html or an app/*.html — any
    // other URL (error page, data: blob) shouldn't auto-flag.
    if (!_viewerLoaded) {
        NSString *path = url.path ?: @"";
        if ([path hasSuffix:@"/index.html"] ||
            [path hasSuffix:@"/app/board.html"] ||
            [path hasSuffix:@"/app/activity.html"]) {
            _viewerLoaded = YES;
            // Drain anything queued for post-load (Phase 5 modal-open
            // directives, search-query flushes).
            if (_pendingPostLoadJS.length) {
                NSString *js = _pendingPostLoadJS;
                _pendingPostLoadJS = nil;
                [_webView evaluateJavaScript:js completionHandler:nil];
            }
            // If a search was typed during the dark window, replay it
            // now that the bridge is reachable.
            if (_lastSearchQuery.length) {
                [self _pushSearchQuery:_lastSearchQuery];
            }
        }
    }
}

// Map a current webView URL back to the popup's view mode. Detail
// routes (#/issue/bd-…) count as Issues since that's where detail is
// rendered. Unknown URLs stay on current.
- (BeadsViewMode)_viewModeFromURL:(NSURL *)url {
    NSString *path = url.path ?: @"";
    NSString *frag = url.fragment ?: @"";
    if ([path hasSuffix:@"/app/board.html"])    return BeadsViewModeBoard;
    if ([path hasSuffix:@"/app/activity.html"]) return BeadsViewModeActivity;
    if ([path hasSuffix:@"/index.html"] || path.length == 0) {
        if ([frag hasPrefix:@"/graph"])    return BeadsViewModeGraph;
        if ([frag hasPrefix:@"/insights"]) return BeadsViewModeInsights;
        if ([frag hasPrefix:@"/issues"] ||
            [frag hasPrefix:@"/issue/"])   return BeadsViewModeIssues;
        return BeadsViewModeDashboard;
    }
    return _viewMode;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url = action.request.URL;
    if (action.navigationType == WKNavigationTypeLinkActivated &&
        url && ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        handler(WKNavigationActionPolicyCancel);
        return;
    }
    handler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    _viewerLoaded = YES;
    if (_pendingReload || self.project) {
        _pendingReload = NO;
        [self _pushJsonlToBridge];
    }
    // Re-apply theme + current search filter for this freshly-loaded page.
    [self _pushThemeToWebView];
    if (_lastSearchQuery.length) [self _pushSearchQuery:_lastSearchQuery];
    // Phase 5 — fire-once post-load JS (showBeadDetail: / showCreateIssue:
    // stashes this while waiting for a view switch to finish loading).
    // Only drain when the just-loaded page is Board — board.js defines
    // window.__nppApp. Running the JS on dashboard.html would stash a
    // pending global on a window that's about to be replaced when the
    // board.html load fires next.
    if (_pendingPostLoadJS.length) {
        NSString *path = webView.URL.path ?: @"";
        if ([path hasSuffix:@"/app/board.html"]) {
            NSString *js = _pendingPostLoadJS;
            _pendingPostLoadJS = nil;
            [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
                if (e) NSLog(@"[NppBeads] pending post-load JS error: %@", e);
            }];
        }
    }
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
    NSLog(@"[NppBeads] webview didFailNavigation: %@", error);
}
- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
    NSLog(@"[NppBeads] webview didFailProvisionalNavigation: %@", error);
}

@end
