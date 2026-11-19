#import "BeadsAppDelegate.h"
#import "BeadsMainWindowController.h"
#import "BeadsMenuBuilder.h"
#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"  // declares both BeadsProject and BeadsProjectScanner

// Same key the plugin uses, so the standalone and plugin share a project list.
static NSString * const kBeadsRecentProjectsKey = @"NppBeadsRecentProjectRoots";
// First-launch hint flag.
static NSString * const kBeadsHasLaunchedKey    = @"BeadsHasLaunched";

@implementation BeadsAppDelegate {
    // All open project windows, in creation order. Strong refs so they
    // stay alive until their NSWindow closes; we remove on
    // NSWindowWillCloseNotification (see _registerCloseHandlerFor:).
    NSMutableArray<BeadsMainWindowController *> *_windowControllers;

    // Lazy-built each time File menu opens so the latest MRU shows.
    NSMenu *_recentProjectsMenu;
}

- (instancetype)init {
    if ((self = [super init])) {
        _windowControllers = [NSMutableArray new];
    }
    return self;
}

#pragma mark - NSApplicationDelegate lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)note {
    // Build menu bar BEFORE finishLaunching so the system has it ready
    // when it's about to display the main window.
    NSMenu *mainMenu = [BeadsMenuBuilder buildMainMenuForDelegate:self];
    [NSApp setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Resume the most-recent project on launch — same behavior as the
    // single-window predecessor. The user can open additional projects
    // from File menu, drag-onto-dock, or double-click .beads files, each
    // of which spawns its own window.
    NSString *firstMRU = [self _firstResolvableMRUProjectRoot];
    BeadsProject *firstProj = firstMRU.length
        ? [BeadsProjectScanner projectFromRoot:firstMRU]
        : nil;
    if (!firstProj) {
        // No resolvable local project — fall back to the most recent
        // REMOTE connection (nppmac-0th). This is the manager persona:
        // nothing on disk, monitoring a repo over HTTPS.
        NSDictionary *remote = [BeadsPanel persistedRecentRemotes].firstObject;
        if (remote) {
            firstProj = [BeadsProjectScanner remoteProjectWithSpec:remote[@"spec"]
                                                           display:remote[@"display"]];
        }
    }

    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    BOOL firstLaunch = ![def boolForKey:kBeadsHasLaunchedKey];
    if (firstLaunch) [def setBool:YES forKey:kBeadsHasLaunchedKey];

    if (firstProj) {
        [self _openWindowForProject:firstProj];
    } else if (firstLaunch) {
        // No MRU + never launched: skip the empty window and go straight
        // to the open-folder dialog. Saves the user a click and avoids
        // showing a blank shell on first impression.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openProjectFolder:nil];
        });
    } else {
        // Returning user but every saved MRU went stale (projects moved
        // / deleted). Open an empty window so File menu is accessible.
        [self _openWindowForProject:nil];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    // Closing the last project window quits — matches Calculator, Stickies,
    // Activity Monitor. Multi-window doesn't change this: with N windows
    // open, closing N-1 of them leaves the app running on the last one;
    // closing the last quits.
    return YES;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    // On launch with no document URL, AppKit would otherwise call
    // applicationOpenUntitledFile: between willFinishLaunching: and
    // didFinishLaunching: — racing our own startup logic and producing
    // a duplicate empty window stacked under the MRU window. Returning
    // NO suppresses that path entirely; didFinishLaunching: owns
    // startup-time window creation.
    //
    // We don't need an openUntitled hook for dock-click either:
    // applicationShouldTerminateAfterLastWindowClosed: returns YES, so
    // the app quits the moment the last window closes — clicking the
    // dock icon afterwards is a fresh launch (didFinishLaunching: runs
    // again). The "running with no windows" state never persists.
    return NO;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    // Drag-folder-onto-app, double-click-folder, or `open <path>` from the
    // shell. One window per resolvable URL; duplicates focus the existing
    // window instead of opening a second copy.
    BOOL openedAny = NO;
    NSURL *failedURL = nil;
    for (NSURL *url in urls) {
        if (!url.isFileURL) continue;
        BeadsProject *proj = [BeadsProjectScanner findProjectFromPath:url.path];
        if (proj) {
            [self _openOrFocusProject:proj];
            openedAny = YES;
        } else if (!failedURL) {
            failedURL = url;
        }
    }
    if (!openedAny && failedURL) {
        [self _showAlertNoBeadsFound:failedURL.path];
    }
}

#pragma mark - Window management

- (NSArray<BeadsMainWindowController *> *)windowControllers {
    return [_windowControllers copy];
}

/// Create a new window controller for `proj` (nil → empty window), wire
/// up close-tracking, and bring it forward.
- (BeadsMainWindowController *)_openWindowForProject:(nullable BeadsProject *)proj {
    BeadsMainWindowController *wc = [[BeadsMainWindowController alloc] initWithProject:proj];
    [_windowControllers addObject:wc];
    [self _registerCloseHandlerFor:wc];
    [wc showWindow:self];
    [wc.window makeKeyAndOrderFront:nil];
    return wc;
}

/// Window-close observer: when an NSWindow fires WillClose, drop our
/// strong ref to its controller. Without this, the WC stays alive (and
/// so does its BeadsPanel + WKWebView + bd CLI runner), AND
/// applicationShouldTerminateAfterLastWindowClosed: never fires because
/// AppKit thinks there are still windows pending.
///
/// Self-unregistering: the observer block captures its own token via
/// __block and removes itself at the end. Otherwise we'd leak one
/// observer per opened window over the app's lifetime.
- (void)_registerCloseHandlerFor:(BeadsMainWindowController *)wc {
    __weak typeof(self) weakSelf = self;
    __weak BeadsMainWindowController *weakWC = wc;
    __block id token = nil;
    token = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:wc.window
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        BeadsMainWindowController *strongWC = weakWC;
        if (strongSelf && strongWC) {
            [strongSelf->_windowControllers removeObject:strongWC];
        }
        if (token) [[NSNotificationCenter defaultCenter] removeObserver:token];
    }];
}

/// If a window is already bound to `proj.projectRoot`, focus it; else
/// open a new window. Path comparison uses standardized paths to ignore
/// trailing slashes and symlink differences.
- (BeadsMainWindowController *)_openOrFocusProject:(BeadsProject *)proj {
    BeadsMainWindowController *existing =
        [self _existingWindowControllerForProjectRoot:proj.projectRoot];
    if (existing) {
        if (existing.window.isMiniaturized) [existing.window deminiaturize:nil];
        [existing.window makeKeyAndOrderFront:nil];
        return existing;
    }
    return [self _openWindowForProject:proj];
}

/// Returns the window controller whose bound project root matches `root`,
/// or nil if none. Empty windows (boundProjectRoot == nil) never match.
- (nullable BeadsMainWindowController *)_existingWindowControllerForProjectRoot:(NSString *)root {
    if (!root.length) return nil;
    NSString *target = [root stringByStandardizingPath];
    for (BeadsMainWindowController *wc in _windowControllers) {
        if (wc.boundProjectRoot.length && [wc.boundProjectRoot isEqualToString:target]) {
            return wc;
        }
    }
    return nil;
}

/// The window that should receive a per-window menu action (Reload,
/// Reveal). Prefer the key window; fall back to the first one in our
/// list (no key window typically means the app is in the background or
/// only the menu bar is active).
- (nullable BeadsMainWindowController *)_activeWindowController {
    NSWindow *key = NSApp.keyWindow;
    for (BeadsMainWindowController *wc in _windowControllers) {
        if (wc.window == key) return wc;
    }
    return _windowControllers.firstObject;
}

#pragma mark - Dock menu

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
    // Right-click / Ctrl-click on the dock icon shows this menu merged
    // above macOS's stock items (Options, Show All Windows, Quit). One
    // entry — "New Window" — opens an empty BeadsViewer window so users
    // can quickly bind another project without going through the menu
    // bar or the running app's File menu.
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *newWin = [[NSMenuItem alloc] initWithTitle:@"New Window"
                                                    action:@selector(newWindow:)
                                             keyEquivalent:@""];
    newWin.target = self;
    [menu addItem:newWin];
    return menu;
}

#pragma mark - File menu actions

- (IBAction)newWindow:(id)sender {
    // Opens a fresh empty window. The panel inside it picks up the user's
    // most recent project as a default via its in-panel project chip; the
    // user can also switch projects from File > Open Project Folder.
    [self _openWindowForProject:nil];
}

- (IBAction)openProjectFolder:(id)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles          = NO;
    op.canChooseDirectories    = YES;
    op.allowsMultipleSelection = NO;
    op.prompt                  = @"Open";
    op.message                 = @"Select a project folder (the one containing .beads/), "
                                 @"or the .beads/ directory itself.";
    op.directoryURL            = [self _bestStartingDirectoryForOpen];

    void (^handle)(NSModalResponse) = ^(NSModalResponse rc) {
        if (rc != NSModalResponseOK) return;
        NSURL *url = op.URL;
        if (!url) return;

        // Walk up to find a .beads/. Handles all three cases:
        //   - User picked the project root directly.
        //   - User picked the .beads/ folder itself.
        //   - User picked some random file/folder under the project.
        BeadsProject *proj = [BeadsProjectScanner findProjectFromPath:url.path];
        if (proj) {
            [self _openOrFocusProject:proj];
        } else {
            [self _showAlertNoBeadsFound:url.path];
        }
    };

    // Sheet-mode when we have a window to attach to; modal otherwise (eg.
    // launch path with no windows yet, or all windows already closed).
    NSWindow *parent = NSApp.keyWindow ?: _windowControllers.firstObject.window;
    if (parent) {
        [op beginSheetModalForWindow:parent completionHandler:handle];
    } else {
        handle([op runModal]);
    }
}

- (IBAction)reloadProjectData:(id)sender {
    [[self _activeWindowController].beadsPanel reloadData];
}

- (IBAction)revealBeadsInFinder:(id)sender {
    [[self _activeWindowController].beadsPanel openBeadsDirInFinder:sender];
}

- (IBAction)openRecentProject:(id)sender {
    // Tag carries the MRU index. We always rebuild the menu before it
    // opens (menuNeedsUpdate:), so tag indices are stable for the click.
    NSMenuItem *item = (NSMenuItem *)sender;
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    NSInteger idx = item.tag;
    if (idx < 0 || (NSUInteger)idx >= mru.count) return;
    NSString *root = mru[idx];
    BeadsProject *proj = [BeadsProjectScanner projectFromRoot:root];
    if (proj) {
        [self _openOrFocusProject:proj];
    } else {
        [self _showAlertNoBeadsFound:root];
        // Stale entry — strip it from the MRU so it stops appearing.
        NSMutableArray *m = [mru mutableCopy];
        [m removeObjectAtIndex:(NSUInteger)idx];
        [[NSUserDefaults standardUserDefaults] setObject:m forKey:kBeadsRecentProjectsKey];
    }
}

- (IBAction)clearRecentProjects:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBeadsRecentProjectsKey];
}

- (IBAction)showBeadsHelp:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/notepad-plus-plus-mac/NppBeads"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - NSMenuDelegate (Open Recent submenu)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (![menu.title isEqualToString:@"Open Recent"]) return;
    [self _rebuildRecentProjectsMenu:menu];
}

- (void)_rebuildRecentProjectsMenu:(NSMenu *)menu {
    [menu removeAllItems];
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];

    if (mru.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc]
                                initWithTitle:@"(no recent projects)"
                                       action:nil
                                keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
        return;
    }

    for (NSUInteger i = 0; i < mru.count; i++) {
        NSString *root = mru[i];
        if (![root isKindOfClass:[NSString class]]) continue;
        // Display lastPathComponent prominently with the parent dir as
        // a subtitle-ish trailing fragment, since multiple projects can
        // share a basename (~/work/foo and ~/personal/foo).
        NSString *base   = root.lastPathComponent;
        NSString *parent = root.stringByDeletingLastPathComponent.lastPathComponent;
        NSString *title  = (parent.length
                            ? [NSString stringWithFormat:@"%@ — %@", base, parent]
                            : base);
        NSMenuItem *it = [[NSMenuItem alloc]
                            initWithTitle:title
                                   action:@selector(openRecentProject:)
                            keyEquivalent:@""];
        it.target = self;
        it.tag    = (NSInteger)i;
        it.toolTip = root;
        [menu addItem:it];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [[NSMenuItem alloc]
                            initWithTitle:@"Clear Menu"
                                   action:@selector(clearRecentProjects:)
                            keyEquivalent:@""];
    clear.target = self;
    [menu addItem:clear];
}

#pragma mark - Helpers

- (NSString *)_firstResolvableMRUProjectRoot {
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    for (id entry in mru) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *root = (NSString *)entry;
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] && isDir) {
            // Validate by attempting to load it. The scanner returns nil
            // if the .beads/ dir doesn't have anything we can read.
            if ([BeadsProjectScanner projectFromRoot:root]) return root;
        }
    }
    return nil;
}

- (NSURL *)_bestStartingDirectoryForOpen {
    // Prefer the parent of the most-recently-used project — likely where
    // the user keeps related projects. Fall back to ~.
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    if (mru.count > 0 && [mru[0] isKindOfClass:[NSString class]]) {
        NSString *parent = [(NSString *)mru[0] stringByDeletingLastPathComponent];
        if (parent.length) return [NSURL fileURLWithPath:parent isDirectory:YES];
    }
    return [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
}

- (void)_showAlertNoBeadsFound:(NSString *)path {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = @"No .beads/ folder found";
    a.informativeText = [NSString stringWithFormat:
        @"Couldn't find a usable .beads/ directory at or above:\n\n%@\n\n"
        @"To create one, run `bd init` from your project's root in a "
        @"terminal, then retry.",
        path];
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

@end
