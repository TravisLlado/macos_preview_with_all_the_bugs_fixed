// App behavior: windows, sidebar, opening images, duplicates, thumbnails,
// menus, no persistence, and Move to Trash.
//
// These drive the real AppDelegate and MainWindowController (windows appear
// briefly on screen). Two system calls are replaced with fakes so the tests
// never touch the user's real Trash or show the Open panel:
//   - -[NSWorkspace recycleURLs:completionHandler:] moves files into a temp
//     "trash" folder and records the request;
//   - -[NSSavePanel beginWithCompletionHandler:] just records the panel.

#import "AppDelegate.h"
#import "ImageScrollView.h"
#import "MainWindowController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#include "AppTestSupport.h"

#include <filesystem>

namespace fs = std::filesystem;

// Private methods the tests call.
@interface AppDelegate (Testing)
- (void)openImagesAtURLs:(NSArray<NSURL*>*)urls;
- (IBAction)openDocument:(id)sender;
@end

@interface MainWindowController (Testing)
- (NSImage*)thumbnailForPath:(NSString*)path;
- (IBAction)moveToTrash:(id)sender;
- (IBAction)zoomIn:(id)sender;
- (IBAction)zoomOut:(id)sender;
- (IBAction)zoomToActualSize:(id)sender;
- (IBAction)zoomToFit:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem*)item;
@end

#pragma mark - Fakes

static NSMutableArray<NSURL*>* gRecycledURLs;
static NSError* gRecycleError;
static NSString* gFakeTrashDir;
static double gRecycleDelay;
static NSSavePanel* gLastPanel;

@implementation NSWorkspace (PVTestFake)
- (void)pvtest_recycleURLs:(NSArray<NSURL*>*)urls
         completionHandler:(void (^)(NSDictionary<NSURL*, NSURL*>*, NSError*))handler {
    NSError* error = gRecycleError;
    NSMutableDictionary<NSURL*, NSURL*>* moved = [NSMutableDictionary dictionary];
    if (!error) {
        for (NSURL* url in urls) {
            NSURL* destination = [NSURL fileURLWithPath:[gFakeTrashDir stringByAppendingPathComponent:url.lastPathComponent]];
            [NSFileManager.defaultManager moveItemAtURL:url toURL:destination error:nil];
            [gRecycledURLs addObject:url];
            moved[url] = destination;
        }
    }
    // Like the real API, report back later on another queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gRecycleDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                       if (handler) handler(moved, error);
                   });
}
@end

@implementation NSSavePanel (PVTestFake)
- (void)pvtest_beginWithCompletionHandler:(void (^)(NSModalResponse))handler {
    (void)handler;
    gLastPanel = self;
}
@end

static void installFakes() {
    static bool installed = false;
    if (installed) return;
    installed = true;
    method_exchangeImplementations(
        class_getInstanceMethod(NSWorkspace.class, @selector(recycleURLs:completionHandler:)),
        class_getInstanceMethod(NSWorkspace.class, @selector(pvtest_recycleURLs:completionHandler:)));
    method_exchangeImplementations(
        class_getInstanceMethod(NSSavePanel.class, @selector(beginWithCompletionHandler:)),
        class_getInstanceMethod(NSSavePanel.class, @selector(pvtest_beginWithCompletionHandler:)));
    gRecycledURLs = [NSMutableArray array];
    gFakeTrashDir = @(test::makeTempDir().c_str());
}

#pragma mark - Fixtures

namespace {

// A folder of sample images shared by the tests (they never modify it).
const std::string& samples() {
    static std::string dir = [] {
        std::string d = test::canonical(test::makeTempDir());
        test::writeTestImage(d + "/a1.jpg", "public.jpeg", 400, 300);
        test::writeTestImage(d + "/a2.jpg", "public.jpeg", 400, 300);
        test::writeTestImage(d + "/a3.png", "public.png", 300, 200);
        test::writeTestImage(d + "/a10.jpg", "public.jpeg", 400, 300);
        test::writeTestImage(d + "/big.jpg", "public.jpeg", 4000, 3000);
        test::touch(d + "/broken.jpg", "not an image");
        test::touch(d + "/notes.txt", "not listed");
        fs::create_directory(d + "/empty");
        return d;
    }();
    return dir;
}

NSURL* url(const std::string& path) {
    return [NSURL fileURLWithPath:@(path.c_str())];
}

NSURL* sample(const char* name) {
    return url(samples() + "/" + name);
}

// A fresh AppDelegate, launched as the real app would be. On destruction its
// windows are hidden (not closed: closing the last window would quit).
struct App {
    AppDelegate* delegate;

    explicit App(bool launch = true) {
        test::ensureApplication();
        installFakes();
        delegate = [[AppDelegate alloc] init];
        NSApp.delegate = delegate;
        [delegate applicationWillFinishLaunching:[NSNotification notificationWithName:@"" object:nil]];
        if (launch) {
            finishLaunching();
        }
    }
    ~App() {
        for (MainWindowController* c in controllers()) {
            [c.window orderOut:nil];
        }
        NSApp.delegate = nil;
    }

    void finishLaunching() {
        [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"" object:nil]];
    }

    NSArray<MainWindowController*>* controllers() const {
        return [[delegate valueForKey:@"windowControllers"] copy];
    }

    void open(NSArray<NSURL*>* urls) { [delegate openImagesAtURLs:urls]; }

    // Front-most window controller of this app instance.
    MainWindowController* front() const {
        NSArray* mine = controllers();
        for (NSWindow* w in NSApp.orderedWindows) {
            if (w.isVisible && [mine containsObject:w.windowController]) return w.windowController;
        }
        return nil;
    }
};

NSTableView* tableOf(MainWindowController* c) { return [c valueForKey:@"tableView"]; }
NSScrollView* sidebarOf(MainWindowController* c) { return [c valueForKey:@"sidebarScrollView"]; }
ImageScrollView* viewerOf(MainWindowController* c) { return [c valueForKey:@"viewer"]; }
NSSplitView* splitOf(MainWindowController* c) { return [c valueForKey:@"splitView"]; }
NSImage* placeholderOf(MainWindowController* c) { return [c valueForKey:@"placeholder"]; }

std::string names(MainWindowController* c) {
    std::string out;
    for (NSString* p in c.imagePaths) out += (out.empty() ? "" : ",") + test::str(p.lastPathComponent);
    return out;
}

NSSize contentSize(MainWindowController* c) { return c.window.contentView.frame.size; }

bool waitForImage(MainWindowController* c) {
    return test::runUntil(^BOOL { return viewerOf(c).hasImage; });
}

// True once every visible sidebar row shows a real thumbnail.
bool visibleThumbnailsLoaded(MainWindowController* c) {
    NSTableView* table = tableOf(c);
    NSRange rows = [table rowsInRect:table.visibleRect];
    if (rows.length == 0) return false;
    for (NSUInteger r = rows.location; r < NSMaxRange(rows); ++r) {
        NSTableCellView* cell = [table viewAtColumn:0 row:(NSInteger)r makeIfNecessary:NO];
        if (!cell || cell.imageView.image == placeholderOf(c)) return false;
    }
    return true;
}

int cachedThumbnailCount(MainWindowController* c) {
    int count = 0;
    NSImage* placeholder = placeholderOf(c);
    for (NSString* p in c.imagePaths) {
        if ([c thumbnailForPath:p] != placeholder) ++count;
    }
    return count;
}

NSMenuItem* menuItem(NSString* menu, NSString* title) {
    return [[NSApp.mainMenu itemWithTitle:menu].submenu itemWithTitle:title];
}

BOOL enabled(MainWindowController* c, SEL action) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
    return [c validateMenuItem:item];
}

void pressKey(NSTableView* table, unichar key, unsigned short code) {
    NSString* chars = [NSString stringWithCharacters:&key length:1];
    NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad
                                     timestamp:0 windowNumber:table.window.windowNumber context:nil
                                    characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
    [table keyDown:event];
}

// Copies of a sample image in a new temp folder, for tests that trash files.
std::string folderOfCopies(const std::vector<std::string>& names) {
    std::string dir = test::canonical(test::makeTempDir());
    for (const std::string& n : names) fs::copy_file(samples() + "/a1.jpg", dir + "/" + n);
    return dir;
}

}  // namespace

#pragma mark - Launch and windows

TEST(launch_shows_one_empty_window_with_the_sidebar) {
    App app;
    REQUIRE(app.controllers().count == 1);
    MainWindowController* c = app.controllers()[0];
    CHECK(c.window.isVisible);
    CHECK(c.isEmpty);
    CHECK(!sidebarOf(c).hidden);
}

TEST(windows_have_a_fixed_default_size) {
    App app;
    app.open(@[ sample("a1.jpg") ]);
    app.open(@[ sample("a2.jpg"), sample("a3.png") ]);
    for (MainWindowController* c in app.controllers()) {
        CHECK(NSEqualSizes(contentSize(c), NSMakeSize(1000, 700)));
    }
}

TEST(launching_by_opening_files_shows_no_extra_empty_window) {
    App app(/*launch=*/false);
    [app.delegate application:NSApp openURLs:@[ sample("a1.jpg"), sample("a2.jpg") ]];
    app.finishLaunching();
    test::runFor(0.6);  // let the Open With burst settle
    REQUIRE(app.controllers().count == 1);
    CHECK_EQ(names(app.controllers()[0]), std::string("a1.jpg,a2.jpg"));
}

TEST(closing_the_last_window_quits_the_app) {
    App app;
    CHECK([app.delegate applicationShouldTerminateAfterLastWindowClosed:NSApp]);
}

TEST(closing_a_window_forgets_it_and_its_images) {
    App app;
    app.open(@[ sample("a1.jpg") ]);
    app.open(@[ sample("a2.jpg") ]);
    REQUIRE(app.controllers().count == 2);
    MainWindowController* second = app.front();
    [second.window performClose:nil];  // another window stays open, so the app keeps running
    CHECK_EQ(app.controllers().count, NSUInteger(1));
    app.open(@[ sample("a2.jpg") ]);  // may be opened again now
    CHECK_EQ(app.controllers().count, NSUInteger(2));
}

#pragma mark - Opening images

TEST(single_image_fills_the_window_without_a_sidebar) {
    App app;
    app.open(@[ sample("a1.jpg") ]);
    REQUIRE(app.controllers().count == 1);  // reused the empty launch window
    MainWindowController* c = app.controllers()[0];
    CHECK(sidebarOf(c).hidden);
    CHECK(test::nearlyEqual(NSWidth(viewerOf(c).frame), contentSize(c).width));
    CHECK(waitForImage(c));
    CHECK_EQ(test::str(c.window.title), std::string("a1.jpg"));
}

TEST(multiple_images_show_the_sidebar_sorted_with_the_first_selected) {
    App app;
    app.open(@[ sample("a10.jpg"), sample("a2.jpg"), sample("a1.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    CHECK(!sidebarOf(c).hidden);
    CHECK_EQ(names(c), std::string("a1.jpg,a2.jpg,a10.jpg"));
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(0));
    CHECK_EQ(test::str(c.window.title), std::string("a1.jpg"));
    CHECK(c.window.firstResponder == tableOf(c));  // arrow keys go to the list
}

TEST(only_the_chosen_files_open_not_their_folder) {
    App app;
    app.open(@[ sample("a2.jpg"), sample("a3.png") ]);
    CHECK_EQ(names(app.controllers()[0]), std::string("a2.jpg,a3.png"));
}

TEST(a_folder_opens_all_of_its_images) {
    App app;
    app.open(@[ url(samples()) ]);
    CHECK_EQ(names(app.controllers()[0]), std::string("a1.jpg,a2.jpg,a3.png,a10.jpg,big.jpg,broken.jpg"));
}

TEST(an_empty_folder_gives_an_empty_window_titled_by_the_folder) {
    App app;
    app.open(@[ url(samples() + "/empty") ]);
    MainWindowController* c = app.controllers()[0];
    CHECK(c.isEmpty);
    CHECK(!sidebarOf(c).hidden);  // only a single image hides the sidebar
    CHECK_EQ(test::str(c.window.title), std::string("empty"));
}

TEST(each_new_set_opens_in_a_new_cascaded_window) {
    App app;
    app.open(@[ sample("a1.jpg") ]);
    app.open(@[ sample("a2.jpg"), sample("a3.png") ]);
    REQUIRE(app.controllers().count == 2);
    NSRect first = app.controllers()[0].window.frame;
    NSRect second = app.controllers()[1].window.frame;
    CHECK_EQ(names(app.controllers()[1]), std::string("a2.jpg,a3.png"));
    CHECK(test::nearlyEqual(NSMinX(second) - NSMinX(first), 24));
    CHECK(test::nearlyEqual(NSMaxY(second) - NSMaxY(first), -24));
}

TEST(an_empty_window_is_reused_even_when_another_window_is_in_front) {
    App app;
    app.open(@[ sample("a1.jpg") ]);                // fills the launch window
    app.open(@[ url(samples() + "/empty") ]);       // a second, empty window
    MainWindowController* empty = app.controllers()[1];
    [app.controllers()[0].window orderFront:nil];   // the full window is now in front
    app.open(@[ sample("a2.jpg") ]);
    CHECK_EQ(app.controllers().count, NSUInteger(2));
    CHECK_EQ(names(empty), std::string("a2.jpg"));
}

#pragma mark - Never open a file twice

TEST(already_open_images_are_left_out_of_the_new_window) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg") ]);
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    REQUIRE(app.controllers().count == 2);
    MainWindowController* second = app.controllers()[1];
    CHECK_EQ(names(second), std::string("a3.png"));
    CHECK(sidebarOf(second).hidden);  // a single image
}

TEST(opening_only_already_open_images_brings_their_window_forward) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg") ]);
    MainWindowController* first = app.controllers()[0];
    app.open(@[ sample("a3.png") ]);
    REQUIRE(app.front() != first);
    app.open(@[ sample("a2.jpg") ]);
    CHECK_EQ(app.controllers().count, NSUInteger(2));  // no new window
    CHECK(app.front() == first);
    CHECK_EQ(tableOf(first).selectedRow, NSInteger(1));  // a2.jpg selected
}

TEST(the_same_file_through_a_symlink_is_not_opened_twice) {
    std::string linkDir = test::makeTempDir() + "/link";
    fs::create_directory_symlink(samples(), linkDir);
    App app;
    app.open(@[ sample("a1.jpg") ]);
    app.open(@[ url(linkDir + "/a1.jpg") ]);
    CHECK_EQ(app.controllers().count, NSUInteger(1));
}

#pragma mark - Finder Open With

TEST(an_open_with_burst_opens_one_window) {
    // Finder may deliver one multi-file Open With as several requests.
    App app;
    [app.delegate application:NSApp openURLs:@[ sample("a1.jpg") ]];
    [app.delegate application:NSApp openURLs:@[ sample("a2.jpg") ]];
    [app.delegate application:NSApp openURLs:@[ sample("a3.png") ]];
    test::runFor(0.6);
    REQUIRE(app.controllers().count == 1);
    CHECK_EQ(names(app.controllers()[0]), std::string("a1.jpg,a2.jpg,a3.png"));

    // A later Open With is a new set, in a new window.
    [app.delegate application:NSApp openURLs:@[ sample("a10.jpg") ]];
    test::runFor(0.6);
    CHECK_EQ(app.controllers().count, NSUInteger(2));
}

#pragma mark - Sidebar and viewer

TEST(selecting_a_row_shows_that_image) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* c = app.controllers()[0];
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    CHECK_EQ(test::str(c.window.title), std::string("a3.png"));
    CHECK(waitForImage(c));
}

TEST(arrow_keys_change_the_selection) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* c = app.controllers()[0];
    pressKey(tableOf(c), NSDownArrowFunctionKey, 125);
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(1));
    pressKey(tableOf(c), NSDownArrowFunctionKey, 125);
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(2));
    pressKey(tableOf(c), NSUpArrowFunctionKey, 126);
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(1));
    CHECK_EQ(test::str(c.window.title), std::string("a2.jpg"));
}

TEST(large_images_open_fitted_small_ones_at_actual_size) {
    App app;
    app.open(@[ sample("big.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    REQUIRE(waitForImage(c));
    CHECK(viewerOf(c).magnification < 1.0);
    app.open(@[ sample("a1.jpg") ]);
    MainWindowController* small = app.front();
    REQUIRE(waitForImage(small));
    CHECK(test::nearlyEqual(viewerOf(small).magnification, 1.0));
}

TEST(an_unreadable_image_shows_nothing_and_a_placeholder) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("broken.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    REQUIRE(test::runUntil(^BOOL { return [c thumbnailForPath:c.imagePaths[0]] != placeholderOf(c); }));
    test::runFor(0.3);
    CHECK([c thumbnailForPath:c.imagePaths[1]] == placeholderOf(c));
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    test::runFor(0.3);
    CHECK(!viewerOf(c).hasImage);
}

TEST(thumbnails_replace_placeholders_in_the_background) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* c = app.controllers()[0];
    CHECK(test::runUntil(^BOOL { return visibleThumbnailsLoaded(c); }));
}

TEST(sidebar_thumbnails_are_at_most_256_pixels) {
    App app;
    app.open(@[ sample("big.jpg"), sample("a1.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    NSString* big = c.imagePaths[1];
    REQUIRE(test::runUntil(^BOOL { return [c thumbnailForPath:big] != placeholderOf(c); }));
    // The app sizes each thumbnail NSImage to the decoded image's pixel size.
    NSSize size = [c thumbnailForPath:big].size;
    CHECK_EQ(MAX(size.width, size.height), CGFloat(256));
}

TEST(large_folder_opens_quickly_and_loads_only_nearby_thumbnails) {
    static std::string dir = [] {
        std::string d = test::canonical(test::makeTempDir());
        test::writeTestImage(d + "/seed.jpg", "public.jpeg", 64, 48);
        for (int i = 1; i <= 1500; ++i) fs::copy_file(d + "/seed.jpg", d + "/photo" + std::to_string(i) + ".jpg");
        fs::remove(d + "/seed.jpg");
        return d;
    }();
    App app;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    app.open(@[ url(dir) ]);
    double seconds = CFAbsoluteTimeGetCurrent() - start;
    MainWindowController* c = app.controllers()[0];
    REQUIRE(c.imagePaths.count == 1500);
    CHECK(seconds < 0.5);  // measured ~0.1 s in a debug build

    REQUIRE(test::runUntil(^BOOL { return visibleThumbnailsLoaded(c); }));
    test::runFor(0.3);
    int afterOpen = cachedThumbnailCount(c);
    CHECK(afterOpen <= 40);  // visible rows plus a screenful either side, not 1500

    [tableOf(c) scrollRowToVisible:1000];
    REQUIRE(test::runUntil(^BOOL { return visibleThumbnailsLoaded(c); }));
    test::runFor(0.3);
    CHECK(cachedThumbnailCount(c) <= afterOpen + 40);
}

#pragma mark - Nothing is remembered

TEST(window_frame_and_sidebar_width_are_not_saved) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    [c.window setFrame:NSMakeRect(100, 100, 900, 600) display:NO];
    [splitOf(c) setPosition:300 ofDividerAtIndex:0];

    CHECK_EQ(c.window.frameAutosaveName.length, NSUInteger(0));
    CHECK_EQ(c.windowFrameAutosaveName.length, NSUInteger(0));
    CHECK_EQ(splitOf(c).autosaveName.length, NSUInteger(0));
    for (NSString* key in NSUserDefaults.standardUserDefaults.dictionaryRepresentation) {
        bool saved = ([key hasPrefix:@"NSWindow Frame"] && ![key containsString:@"NavPanel"]) ||
                     [key hasPrefix:@"NSSplitView"] || [key isEqualToString:@"SidebarWidth"];
        if (saved) test::fail(__FILE__, __LINE__, "saved layout key: " + test::str(key));
    }
}

#pragma mark - Menus

TEST(menu_items_and_shortcuts) {
    App app;
    struct Expected {
        NSString* menu;
        NSString* title;
        SEL action;
        NSString* key;
        NSEventModifierFlags modifiers;
    };
    NSString* backspace = [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter];
    NSString* appName = NSProcessInfo.processInfo.processName;
    Expected expected[] = {
        {appName, [@"Quit " stringByAppendingString:appName], @selector(terminate:), @"q", NSEventModifierFlagCommand},
        {@"File", @"Open…", @selector(openDocument:), @"o", NSEventModifierFlagCommand},
        {@"File", @"Close", @selector(performClose:), @"w", NSEventModifierFlagCommand},
        {@"File", @"Move to Trash", @selector(moveToTrash:), backspace, NSEventModifierFlagCommand},
        {@"View", @"Zoom In", @selector(zoomIn:), @"=", NSEventModifierFlagCommand},
        {@"View", @"Zoom Out", @selector(zoomOut:), @"-", NSEventModifierFlagCommand},
        {@"View", @"Actual Size", @selector(zoomToActualSize:), @"0", NSEventModifierFlagCommand},
        {@"View", @"Zoom to Fit", @selector(zoomToFit:), @"9", NSEventModifierFlagCommand},
        {@"Window", @"Minimize", @selector(performMiniaturize:), @"m", NSEventModifierFlagCommand},
    };
    for (const Expected& e : expected) {
        NSMenuItem* item = menuItem(e.menu, e.title);
        if (!item) {
            test::fail(__FILE__, __LINE__, "missing menu item " + test::str(e.title));
            continue;
        }
        CHECK(item.action == e.action);
        CHECK_EQ(test::str(item.keyEquivalent), test::str(e.key));
        CHECK_EQ(item.keyEquivalentModifierMask, e.modifiers);
    }
    CHECK(NSApp.windowsMenu == [NSApp.mainMenu itemWithTitle:@"Window"].submenu);
}

TEST(zoom_commands_need_an_image) {
    App app;
    MainWindowController* c = app.controllers()[0];
    for (SEL zoom : {@selector(zoomIn:), @selector(zoomOut:), @selector(zoomToActualSize:), @selector(zoomToFit:)}) {
        CHECK(!enabled(c, zoom));
    }
    app.open(@[ sample("a1.jpg") ]);
    REQUIRE(waitForImage(c));
    for (SEL zoom : {@selector(zoomIn:), @selector(zoomOut:), @selector(zoomToActualSize:), @selector(zoomToFit:)}) {
        CHECK(enabled(c, zoom));
    }
}

TEST(open_panel_accepts_several_images_or_folders) {
    App app;
    gLastPanel = nil;
    [app.delegate openDocument:nil];
    REQUIRE(gLastPanel != nil);
    NSOpenPanel* panel = (NSOpenPanel*)gLastPanel;
    CHECK(panel.canChooseFiles);
    CHECK(panel.canChooseDirectories);
    CHECK(panel.allowsMultipleSelection);
    NSSet* expected = [NSSet setWithArray:@[ UTTypeJPEG, UTTypePNG, UTTypeHEIC, UTTypeHEIF, UTTypeTIFF, UTTypeGIF,
                                              UTTypeWebP, UTTypeBMP ]];
    CHECK([[NSSet setWithArray:panel.allowedContentTypes] isEqualToSet:expected]);
}

#pragma mark - Move to Trash

TEST(move_to_trash_needs_a_sidebar_selection) {
    App app;
    MainWindowController* c = app.controllers()[0];
    CHECK(!enabled(c, @selector(moveToTrash:)));  // empty window
    app.open(@[ sample("a1.jpg") ]);
    CHECK(!enabled(c, @selector(moveToTrash:)));  // single image: no sidebar
    app.open(@[ sample("a2.jpg"), sample("a3.png") ]);
    CHECK(enabled(app.front(), @selector(moveToTrash:)));
}

TEST(move_to_trash_sends_the_file_to_the_trash_and_selects_the_next) {
    std::string dir = folderOfCopies({"t1.jpg", "t2.jpg", "t3.jpg", "t4.jpg"});
    gRecycleError = nil;
    gRecycleDelay = 0;
    [gRecycledURLs removeAllObjects];
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    NSTableView* table = tableOf(c);

    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [c moveToTrash:nil];
    REQUIRE(test::runUntil(^BOOL { return c.imagePaths.count == 3; }));
    REQUIRE(gRecycledURLs.count == 1);
    CHECK_EQ(test::str(gRecycledURLs[0].path), dir + "/t2.jpg");  // asked macOS to trash it
    CHECK(!fs::exists(dir + "/t2.jpg"));
    CHECK(fs::exists(test::str(gFakeTrashDir) + "/t2.jpg"));        // moved, not deleted
    CHECK_EQ(names(c), std::string("t1.jpg,t3.jpg,t4.jpg"));
    CHECK_EQ(table.selectedRow, NSInteger(1));                       // the image that took its place
    CHECK_EQ(test::str(c.window.title), std::string("t3.jpg"));

    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [c moveToTrash:nil];  // the last row
    REQUIRE(test::runUntil(^BOOL { return c.imagePaths.count == 2; }));
    CHECK_EQ(table.selectedRow, NSInteger(1));                       // the new last row
    CHECK_EQ(test::str(c.window.title), std::string("t3.jpg"));
}

TEST(trashing_down_to_one_image_hides_the_sidebar) {
    std::string dir = folderOfCopies({"u1.jpg", "u2.jpg"});
    gRecycleError = nil;
    gRecycleDelay = 0;
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    REQUIRE(test::runUntil(^BOOL { return c.imagePaths.count == 1; }));
    CHECK(sidebarOf(c).hidden);
    CHECK(!enabled(c, @selector(moveToTrash:)));
    CHECK_EQ(test::str(c.window.title), std::string("u2.jpg"));
}

TEST(a_trash_request_in_progress_is_not_repeated) {
    std::string dir = folderOfCopies({"v1.jpg", "v2.jpg", "v3.jpg"});
    gRecycleError = nil;
    gRecycleDelay = 0.3;
    [gRecycledURLs removeAllObjects];
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    [c moveToTrash:nil];  // pressed again before the first finished
    test::runFor(0.6);
    CHECK_EQ(gRecycledURLs.count, NSUInteger(1));
    CHECK_EQ(c.imagePaths.count, NSUInteger(2));
    gRecycleDelay = 0;
}

TEST(a_failed_trash_keeps_the_image_and_shows_the_error) {
    std::string dir = folderOfCopies({"w1.jpg", "w2.jpg"});
    gRecycleError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
    gRecycleDelay = 0;
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    CHECK(test::runUntil(^BOOL { return c.window.attachedSheet != nil; }));
    CHECK_EQ(c.imagePaths.count, NSUInteger(2));
    CHECK(fs::exists(dir + "/w1.jpg"));
    if (c.window.attachedSheet) [c.window endSheet:c.window.attachedSheet];
    gRecycleError = nil;
}
