#import "BeadsMenuBuilder.h"
#import "BeadsAppDelegate.h"

// Helper: add a menu item with a target/action and key equivalent.
static NSMenuItem *addItem(NSMenu *m, NSString *title, SEL action,
                           NSString *key, NSEventModifierFlags mods,
                           id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:key];
    if (mods != 0) item.keyEquivalentModifierMask = mods;
    item.target = target;
    [m addItem:item];
    return item;
}

@implementation BeadsMenuBuilder

+ (NSMenu *)buildMainMenuForDelegate:(BeadsAppDelegate *)delegate {
    NSMenu *root = [[NSMenu alloc] initWithTitle:@""];

    [root addItem:[self _appMenu]];
    [root addItem:[self _fileMenuForDelegate:delegate]];
    [root addItem:[self _editMenu]];
    [root addItem:[self _viewMenu]];
    [root addItem:[self _windowMenu]];
    [root addItem:[self _helpMenuForDelegate:delegate]];

    return root;
}

#pragma mark - Application menu

+ (NSMenuItem *)_appMenu {
    // The first menu's title isn't displayed — AppKit replaces it with the
    // app's CFBundleName ("BeadsViewer"). Conventional title is the app
    // name itself, but anything works.
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"BeadsViewer"];

    addItem(appMenu, @"About BeadsViewer", @selector(orderFrontStandardAboutPanel:),
            @"", 0, NSApp);
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *services = [[NSMenuItem alloc] initWithTitle:@"Services"
                                                      action:nil
                                               keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
    services.submenu = servicesMenu;
    [NSApp setServicesMenu:servicesMenu];
    [appMenu addItem:services];
    [appMenu addItem:[NSMenuItem separatorItem]];

    addItem(appMenu, @"Hide BeadsViewer", @selector(hide:), @"h", 0, NSApp);
    NSMenuItem *hideOthers = addItem(appMenu, @"Hide Others",
                                     @selector(hideOtherApplications:), @"h",
                                     NSEventModifierFlagOption | NSEventModifierFlagCommand,
                                     NSApp);
    (void)hideOthers;
    addItem(appMenu, @"Show All", @selector(unhideAllApplications:),
            @"", 0, NSApp);
    [appMenu addItem:[NSMenuItem separatorItem]];
    addItem(appMenu, @"Quit BeadsViewer", @selector(terminate:), @"q", 0, NSApp);

    appMenuItem.submenu = appMenu;
    return appMenuItem;
}

#pragma mark - File menu

+ (NSMenuItem *)_fileMenuForDelegate:(BeadsAppDelegate *)delegate {
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    addItem(fileMenu, @"Open Project Folder…",
            @selector(openProjectFolder:), @"o", 0, delegate);

    // Open Recent — submenu is delegate-driven; the AppDelegate implements
    // menuNeedsUpdate: against this submenu's title.
    NSMenuItem *openRecentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                            action:nil
                                                     keyEquivalent:@""];
    NSMenu *openRecentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    openRecentMenu.delegate = delegate;
    openRecentMenu.autoenablesItems = NO;
    openRecentItem.submenu = openRecentMenu;
    [fileMenu addItem:openRecentItem];

    [fileMenu addItem:[NSMenuItem separatorItem]];

    addItem(fileMenu, @"Reload Data",
            @selector(reloadProjectData:), @"r", 0, delegate);
    addItem(fileMenu, @"Reveal .beads in Finder",
            @selector(revealBeadsInFinder:), @"b",
            NSEventModifierFlagCommand | NSEventModifierFlagShift,
            delegate);

    [fileMenu addItem:[NSMenuItem separatorItem]];

    // Standard close-window. Targets the first responder so the active
    // window handles it (NSWindow → performClose:).
    addItem(fileMenu, @"Close Window", @selector(performClose:), @"w", 0, nil);

    fileMenuItem.submenu = fileMenu;
    return fileMenuItem;
}

#pragma mark - Edit menu

+ (NSMenuItem *)_editMenu {
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    // Targets nil → AppKit walks the responder chain. Inside our window
    // this lands on the WKWebView, which handles undo/redo/clipboard
    // correctly for HTML-rendered content.
    addItem(editMenu, @"Undo",       @selector(undo:),   @"z", 0, nil);
    addItem(editMenu, @"Redo",       @selector(redo:),   @"z",
            NSEventModifierFlagCommand | NSEventModifierFlagShift, nil);
    [editMenu addItem:[NSMenuItem separatorItem]];
    addItem(editMenu, @"Cut",        @selector(cut:),    @"x", 0, nil);
    addItem(editMenu, @"Copy",       @selector(copy:),   @"c", 0, nil);
    addItem(editMenu, @"Paste",      @selector(paste:),  @"v", 0, nil);
    addItem(editMenu, @"Paste and Match Style",
            @selector(pasteAsPlainText:), @"v",
            NSEventModifierFlagCommand | NSEventModifierFlagShift |
            NSEventModifierFlagOption, nil);
    addItem(editMenu, @"Delete",     @selector(delete:), @"", 0, nil);
    addItem(editMenu, @"Select All", @selector(selectAll:), @"a", 0, nil);
    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *findItem = [[NSMenuItem alloc] initWithTitle:@"Find"
                                                      action:nil
                                               keyEquivalent:@""];
    NSMenu *findMenu = [[NSMenu alloc] initWithTitle:@"Find"];
    addItem(findMenu, @"Find…", @selector(performTextFinderAction:), @"f", 0, nil);
    findItem.submenu = findMenu;
    [editMenu addItem:findItem];

    editMenuItem.submenu = editMenu;
    return editMenuItem;
}

#pragma mark - View menu

+ (NSMenuItem *)_viewMenu {
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];

    // Full-screen toggle is the standard one AppKit auto-wires. The view
    // popup inside the panel toolbar is the canonical place for switching
    // among Dashboard / Insights / etc., so we don't duplicate that into
    // the menu bar — keeps the View menu uncluttered and avoids competing
    // with the panel's existing affordance.
    NSMenuItem *full = addItem(viewMenu, @"Enter Full Screen",
                               @selector(toggleFullScreen:), @"f",
                               NSEventModifierFlagCommand |
                               NSEventModifierFlagControl,
                               nil);
    (void)full;

    viewMenuItem.submenu = viewMenu;
    return viewMenuItem;
}

#pragma mark - Window menu

+ (NSMenuItem *)_windowMenu {
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

    addItem(windowMenu, @"Minimize",
            @selector(performMiniaturize:), @"m", 0, nil);
    addItem(windowMenu, @"Zoom",
            @selector(performZoom:), @"", 0, nil);
    [windowMenu addItem:[NSMenuItem separatorItem]];
    addItem(windowMenu, @"Bring All to Front",
            @selector(arrangeInFront:), @"", 0, NSApp);

    [NSApp setWindowsMenu:windowMenu];

    windowMenuItem.submenu = windowMenu;
    return windowMenuItem;
}

#pragma mark - Help menu

+ (NSMenuItem *)_helpMenuForDelegate:(BeadsAppDelegate *)delegate {
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

    addItem(helpMenu, @"Beads on GitHub",
            @selector(showBeadsHelp:), @"", 0, delegate);

    [NSApp setHelpMenu:helpMenu];
    helpMenuItem.submenu = helpMenu;
    return helpMenuItem;
}

@end
