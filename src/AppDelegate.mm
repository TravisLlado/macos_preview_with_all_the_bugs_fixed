#import "AppDelegate.h"
#import "MainWindowController.h"

@implementation AppDelegate {
    MainWindowController* _windowController;
}

#pragma mark - Menu construction

static NSMenuItem* AddItem(NSMenu* menu, NSString* title, SEL action, NSString* key) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [menu addItem:item];
    return item;
}

static NSMenu* AddSubmenu(NSMenu* menuBar, NSString* title) {
    NSMenuItem* holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:title];
    holder.submenu = submenu;
    [menuBar addItem:holder];
    return submenu;
}

- (void)buildMainMenu {
    NSString* appName = NSProcessInfo.processInfo.processName;
    NSMenu* menuBar = [[NSMenu alloc] init];

    // App menu (its title is replaced by the app name by AppKit).
    NSMenu* appMenu = AddSubmenu(menuBar, appName);
    AddItem(appMenu, [@"About " stringByAppendingString:appName],
            @selector(orderFrontStandardAboutPanel:), @"");
    [appMenu addItem:[NSMenuItem separatorItem]];
    AddItem(appMenu, [@"Hide " stringByAppendingString:appName], @selector(hide:), @"h");
    NSMenuItem* hideOthers = AddItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h");
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    AddItem(appMenu, @"Show All", @selector(unhideAllApplications:), @"");
    [appMenu addItem:[NSMenuItem separatorItem]];
    AddItem(appMenu, [@"Quit " stringByAppendingString:appName], @selector(terminate:), @"q");

    // File menu. Open is handled by MainWindowController via the responder chain.
    NSMenu* fileMenu = AddSubmenu(menuBar, @"File");
    AddItem(fileMenu, @"Open…", @selector(openDocument:), @"o");
    [fileMenu addItem:[NSMenuItem separatorItem]];
    AddItem(fileMenu, @"Close", @selector(performClose:), @"w");

    // View menu. Zoom actions are handled by MainWindowController.
    NSMenu* viewMenu = AddSubmenu(menuBar, @"View");
    AddItem(viewMenu, @"Zoom In", @selector(zoomIn:), @"=");
    AddItem(viewMenu, @"Zoom Out", @selector(zoomOut:), @"-");
    AddItem(viewMenu, @"Actual Size", @selector(zoomToActualSize:), @"0");
    AddItem(viewMenu, @"Zoom to Fit", @selector(zoomToFit:), @"9");

    // Window menu.
    NSMenu* windowMenu = AddSubmenu(menuBar, @"Window");
    AddItem(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m");
    AddItem(windowMenu, @"Zoom", @selector(performZoom:), @"");
    [windowMenu addItem:[NSMenuItem separatorItem]];
    AddItem(windowMenu, @"Bring All to Front", @selector(arrangeInFront:), @"");

    NSApp.mainMenu = menuBar;
    NSApp.windowsMenu = windowMenu;
}

#pragma mark - NSApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification*)notification {
    (void)notification;
    [self buildMainMenu];
    // Created here rather than in didFinishLaunching because, when the app is
    // launched by opening a file, application:openURLs: arrives in between.
    _windowController = [[MainWindowController alloc] init];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    [_windowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// Finder "Open With" or files dropped on the Dock icon: show exactly those images.
- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
    (void)application;
    [_windowController openURLs:urls];
    [_windowController showWindow:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end
