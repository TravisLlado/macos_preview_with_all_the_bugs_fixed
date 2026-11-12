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

    // File menu. Open is routed through the responder chain (implemented in Phase 2).
    NSMenu* fileMenu = AddSubmenu(menuBar, @"File");
    AddItem(fileMenu, @"Open…", @selector(openDocument:), @"o");
    [fileMenu addItem:[NSMenuItem separatorItem]];
    AddItem(fileMenu, @"Close", @selector(performClose:), @"w");

    // View menu: zoom commands are added in Phase 3.
    AddSubmenu(menuBar, @"View");

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
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _windowController = [[MainWindowController alloc] init];
    [_windowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end
