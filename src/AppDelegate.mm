#import "AppDelegate.h"
#import "MainWindowController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Offset of each new window from the front one, like Preview's cascading.
static const CGFloat kCascadeOffset = 24.0;

// Finder may deliver one multi-file "Open With" as several open requests in a
// row; files arriving within this interval are treated as one set.
static const NSTimeInterval kOpenCoalesceDelay = 0.3;

@implementation AppDelegate {
    NSMutableArray<MainWindowController*>* _windowControllers;  // one per open window
    NSMutableArray<NSURL*>* _pendingOpenURLs;                    // from Finder, not yet opened
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

    // File menu. Open is handled here; Close by the window.
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

#pragma mark - Windows

- (MainWindowController*)makeWindowController {
    MainWindowController* controller = [[MainWindowController alloc] init];
    NSWindow* front = NSApp.mainWindow ?: _windowControllers.lastObject.window;
    if (front) {
        NSPoint topLeft = NSMakePoint(NSMinX(front.frame) + kCascadeOffset, NSMaxY(front.frame) - kCascadeOffset);
        [controller.window setFrameTopLeftPoint:topLeft];
        [controller.window setFrame:[controller.window constrainFrameRect:controller.window.frame
                                                                 toScreen:front.screen]
                            display:NO];
    }
    [_windowControllers addObject:controller];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(windowWillClose:)
                                               name:NSWindowWillCloseNotification
                                             object:controller.window];
    return controller;
}

- (void)windowWillClose:(NSNotification*)notification {
    NSWindow* window = notification.object;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:window];
    MainWindowController* controller = window.windowController;
    if (controller) {
        [_windowControllers removeObject:controller];
    }
}

// The frontmost window that has no images yet (e.g. the one shown at launch).
- (MainWindowController*)emptyWindowController {
    for (NSWindow* window in NSApp.orderedWindows) {
        MainWindowController* controller = window.windowController;
        if (window.isVisible && [_windowControllers containsObject:controller] && controller.isEmpty) {
            return controller;
        }
    }
    return nil;
}

// Each set of images opens in its own window, reusing an empty window if any.
- (void)openImagesAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count == 0) {
        return;
    }
    MainWindowController* target = [self emptyWindowController] ?: [self makeWindowController];
    [target openURLs:urls];
    [target showWindow:nil];
}

- (IBAction)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = YES;
    // The same formats ImageList recognizes; folders stay selectable too.
    panel.allowedContentTypes = @[
        UTTypeJPEG, UTTypePNG, UTTypeHEIC, UTTypeHEIF, UTTypeTIFF, UTTypeGIF, UTTypeWebP, UTTypeBMP,
    ];
    panel.prompt = @"Open";
    panel.message = @"Choose images, or a folder of images";
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self openImagesAtURLs:panel.URLs];
        }
    }];
}

#pragma mark - NSApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _windowControllers = [NSMutableArray array];
    _pendingOpenURLs = [NSMutableArray array];
    [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    // Start with an empty window, unless the app was launched to open images
    // (application:openURLs: arrives before this).
    if (_windowControllers.count == 0 && _pendingOpenURLs.count == 0) {
        [[self makeWindowController] showWindow:nil];
    }
    [NSApp activateIgnoringOtherApps:YES];
}

// Finder "Open With" or files dropped on the Dock icon: show exactly those
// images together in one window, once the burst of requests has finished.
- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
    (void)application;
    [_pendingOpenURLs addObjectsFromArray:urls];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(openPendingURLs) object:nil];
    [self performSelector:@selector(openPendingURLs) withObject:nil afterDelay:kOpenCoalesceDelay];
}

- (void)openPendingURLs {
    NSArray<NSURL*>* urls = [_pendingOpenURLs copy];
    [_pendingOpenURLs removeAllObjects];
    [self openImagesAtURLs:urls];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end
