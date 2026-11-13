// App behavior: windows, sidebar, opening images, duplicates, thumbnails,
// menus, no persistence, Move to Trash, and undo/redo.
//
// These drive the real AppDelegate and MainWindowController (windows appear
// briefly on screen). Two system calls are replaced with fakes so the tests
// never touch the user's real Trash or show the Open panel:
//   - -[NSFileManager trashItemAtURL:resultingItemURL:error:] moves files into
//     a temp "trash" folder and records the request;
//   - -[NSSavePanel beginWithCompletionHandler:] just records the panel.

#import "AppDelegate.h"
#import "ImageScrollView.h"
#import "MainWindowController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#include <sys/attr.h>
#include <sys/time.h>
#include <unistd.h>

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

static NSMutableArray<NSURL*>* gTrashedURLs;
static NSError* gTrashError;
static NSString* gFakeTrashDir;
static NSSavePanel* gLastPanel;

@implementation NSFileManager (PVTestFake)
- (BOOL)pvtest_trashItemAtURL:(NSURL*)url resultingItemURL:(NSURL**)outURL error:(NSError**)outError {
    if (gTrashError) {
        if (outError) *outError = gTrashError;
        return NO;
    }
    // Like the real Trash, never overwrite: add a number if the name is taken.
    NSString* name = url.lastPathComponent;
    NSString* destination = [gFakeTrashDir stringByAppendingPathComponent:name];
    for (int i = 2; [self fileExistsAtPath:destination]; ++i) {
        destination = [gFakeTrashDir stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"%@ %d.%@", name.stringByDeletingPathExtension, i,
                                                                    name.pathExtension]];
    }
    if (![self moveItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:outError]) {
        return NO;
    }
    [gTrashedURLs addObject:url];
    if (outURL) *outURL = [NSURL fileURLWithPath:destination];
    return YES;
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
        class_getInstanceMethod(NSFileManager.class, @selector(trashItemAtURL:resultingItemURL:error:)),
        class_getInstanceMethod(NSFileManager.class, @selector(pvtest_trashItemAtURL:resultingItemURL:error:)));
    method_exchangeImplementations(
        class_getInstanceMethod(NSSavePanel.class, @selector(beginWithCompletionHandler:)),
        class_getInstanceMethod(NSSavePanel.class, @selector(pvtest_beginWithCompletionHandler:)));
    gTrashedURLs = [NSMutableArray array];
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
        {@"Edit", @"Undo", @selector(undo:), @"z", NSEventModifierFlagCommand},
        {@"Edit", @"Redo", @selector(redo:), @"z", NSEventModifierFlagCommand | NSEventModifierFlagShift},
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

// Resets the fake Trash for a test.
static void resetTrash() {
    gTrashError = nil;
    [gTrashedURLs removeAllObjects];
}

static std::string fakeTrash(const char* name) {
    return test::str(gFakeTrashDir) + "/" + name;
}

// Ends the current undo group, as the end of a real key press would.
static void endEvent() {
    test::runFor(0.05);
}

TEST(move_to_trash_sends_the_file_to_the_trash_and_selects_the_next) {
    std::string dir = folderOfCopies({"t1.jpg", "t2.jpg", "t3.jpg", "t4.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    NSTableView* table = tableOf(c);

    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [c moveToTrash:nil];
    REQUIRE(gTrashedURLs.count == 1);
    CHECK_EQ(test::str(gTrashedURLs[0].path), dir + "/t2.jpg");  // asked macOS to trash it
    CHECK(!fs::exists(dir + "/t2.jpg"));
    CHECK(fs::exists(fakeTrash("t2.jpg")));                        // moved, not deleted
    CHECK_EQ(names(c), std::string("t1.jpg,t3.jpg,t4.jpg"));
    CHECK_EQ(table.selectedRow, NSInteger(1));                     // the image that took its place
    CHECK_EQ(test::str(c.window.title), std::string("t3.jpg"));

    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [c moveToTrash:nil];  // the last row
    CHECK_EQ(c.imagePaths.count, NSUInteger(2));
    CHECK_EQ(table.selectedRow, NSInteger(1));                     // the new last row
    CHECK_EQ(test::str(c.window.title), std::string("t3.jpg"));
}

TEST(trashing_down_to_one_image_hides_the_sidebar) {
    std::string dir = folderOfCopies({"u1.jpg", "u2.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    CHECK_EQ(c.imagePaths.count, NSUInteger(1));
    CHECK(sidebarOf(c).hidden);
    CHECK(!enabled(c, @selector(moveToTrash:)));
    CHECK_EQ(test::str(c.window.title), std::string("u2.jpg"));
}

TEST(a_failed_trash_keeps_the_image_and_shows_the_error) {
    std::string dir = folderOfCopies({"w1.jpg", "w2.jpg"});
    resetTrash();
    gTrashError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    CHECK(test::runUntil(^BOOL { return c.window.attachedSheet != nil; }));
    CHECK_EQ(c.imagePaths.count, NSUInteger(2));
    CHECK(fs::exists(dir + "/w1.jpg"));
    CHECK(!c.window.undoManager.canUndo);  // nothing happened, so nothing to undo
    if (c.window.attachedSheet) [c.window endSheet:c.window.attachedSheet];
    gTrashError = nil;
}

#pragma mark - Undo / redo

TEST(nothing_to_undo_until_something_changes) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [c zoomIn:nil];
    endEvent();
    CHECK(!c.window.undoManager.canUndo);  // opening, selecting and zooming are not undoable
}

TEST(undo_puts_a_trashed_file_back) {
    std::string dir = folderOfCopies({"x1.jpg", "x2.jpg", "x3.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    NSUndoManager* undo = c.window.undoManager;
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [c moveToTrash:nil];
    endEvent();
    REQUIRE(undo.canUndo);
    CHECK_EQ(test::str(undo.undoMenuItemTitle), std::string("Undo Move to Trash"));

    [undo undo];
    CHECK(fs::exists(dir + "/x2.jpg"));          // back where it was
    CHECK(!fs::exists(fakeTrash("x2.jpg")));     // and out of the Trash
    CHECK_EQ(names(c), std::string("x1.jpg,x2.jpg,x3.jpg"));  // in its place in the list
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(1));
    CHECK_EQ(test::str(c.window.title), std::string("x2.jpg"));
    CHECK(undo.canRedo);
    CHECK_EQ(test::str(undo.redoMenuItemTitle), std::string("Redo Move to Trash"));
}

TEST(redo_trashes_the_file_again) {
    std::string dir = folderOfCopies({"y1.jpg", "y2.jpg", "y3.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    NSUndoManager* undo = c.window.undoManager;
    [c moveToTrash:nil];  // y1
    endEvent();
    [undo undo];
    endEvent();
    [undo redo];
    CHECK(!fs::exists(dir + "/y1.jpg"));
    CHECK(fs::exists(fakeTrash("y1.jpg")));
    CHECK_EQ(names(c), std::string("y2.jpg,y3.jpg"));
    CHECK(undo.canUndo);  // and it can be undone again
    endEvent();
    [undo undo];
    CHECK(fs::exists(dir + "/y1.jpg"));
}

TEST(undo_steps_back_through_several_trashings_in_order) {
    std::string dir = folderOfCopies({"z1.jpg", "z2.jpg", "z3.jpg", "z4.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    NSUndoManager* undo = c.window.undoManager;
    [c moveToTrash:nil];  // z1 (row 0)
    endEvent();
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [c moveToTrash:nil];  // z3
    endEvent();
    CHECK_EQ(names(c), std::string("z2.jpg,z4.jpg"));

    [undo undo];
    CHECK_EQ(names(c), std::string("z2.jpg,z3.jpg,z4.jpg"));  // most recent first
    endEvent();
    [undo undo];
    CHECK_EQ(names(c), std::string("z1.jpg,z2.jpg,z3.jpg,z4.jpg"));
    CHECK(!undo.canUndo);
    endEvent();
    [undo redo];
    [undo redo];
    CHECK_EQ(names(c), std::string("z2.jpg,z4.jpg"));
}

TEST(undo_brings_the_sidebar_back) {
    std::string dir = folderOfCopies({"s1.jpg", "s2.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];
    endEvent();
    REQUIRE(sidebarOf(c).hidden);
    [c.window.undoManager undo];
    CHECK(!sidebarOf(c).hidden);
    CHECK_EQ(names(c), std::string("s1.jpg,s2.jpg"));
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(0));
}

TEST(undo_when_the_trash_was_emptied_reports_an_error) {
    std::string dir = folderOfCopies({"e1.jpg", "e2.jpg", "e3.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];  // e1
    endEvent();
    fs::remove(fakeTrash("e1.jpg"));  // the user empties the Trash
    [c.window.undoManager undo];
    CHECK(test::runUntil(^BOOL { return c.window.attachedSheet != nil; }));
    CHECK_EQ(names(c), std::string("e2.jpg,e3.jpg"));  // unchanged
    if (c.window.attachedSheet) [c.window endSheet:c.window.attachedSheet];
}

TEST(undo_does_not_overwrite_a_new_file_with_the_same_name) {
    std::string dir = folderOfCopies({"n1.jpg", "n2.jpg", "n3.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveToTrash:nil];  // n1
    endEvent();
    test::touch(dir + "/n1.jpg", "a different file");
    [c.window.undoManager undo];
    CHECK(test::runUntil(^BOOL { return c.window.attachedSheet != nil; }));
    CHECK(fs::exists(fakeTrash("n1.jpg")));  // the trashed copy stays in the Trash
    CHECK_EQ(fs::file_size(dir + "/n1.jpg"), uintmax_t(16));  // the new file is untouched
    if (c.window.attachedSheet) [c.window endSheet:c.window.attachedSheet];
}

TEST(each_window_has_its_own_undo_history) {
    std::string dirA = folderOfCopies({"pa1.jpg", "pa2.jpg"});
    std::string dirB = folderOfCopies({"pb1.jpg", "pb2.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dirA) ]);
    app.open(@[ url(dirB) ]);
    MainWindowController* a = app.controllers()[0];
    MainWindowController* b = app.controllers()[1];
    [a moveToTrash:nil];
    endEvent();
    CHECK(a.window.undoManager.canUndo);
    CHECK(!b.window.undoManager.canUndo);
}

#pragma mark - Reordering and Sort By

// Three images whose name, creation and modification orders all differ.
static std::string datedCopies() {
    std::string dir = folderOfCopies({"b.jpg", "a.jpg", "c.jpg"});
    auto setDates = [&](const char* name, time_t created, time_t modified) {
        std::string path = dir + "/" + name;
        // Modification time first: on APFS an mtime earlier than the creation time
        // also moves the creation time back.
        struct timeval times[2] = {{modified, 0}, {modified, 0}};
        utimes(path.c_str(), times);
        struct attrlist attrs = {};
        attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
        attrs.commonattr = ATTR_CMN_CRTIME;
        struct timespec createdTime = {created, 0};
        setattrlist(path.c_str(), &attrs, &createdTime, sizeof createdTime, 0);
    };
    setDates("a.jpg", 1000000300, 1000000100);
    setDates("b.jpg", 1000000100, 1000000200);
    setDates("c.jpg", 1000000200, 1000000300);
    return dir;
}

static NSMenu* sortMenu(MainWindowController* c) {
    return [tableOf(c).menu itemWithTitle:@"Sort By"].submenu;
}

static std::string checkedSort(MainWindowController* c) {
    std::string checked;
    for (NSMenuItem* item in sortMenu(c).itemArray) {
        [c validateMenuItem:item];
        if (item.state == NSControlStateValueOn) checked += (checked.empty() ? "" : ",") + test::str(item.title);
    }
    return checked.empty() ? "(none)" : checked;
}

TEST(images_always_open_in_filename_order) {
    std::string dir = datedCopies();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    CHECK_EQ(names(c), std::string("a.jpg,b.jpg,c.jpg"));
    CHECK(c.sidebarOrder == SidebarOrderName);
}

TEST(sidebar_right_click_menu_offers_sort_by_name_and_dates) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    NSMenu* menu = sortMenu(c);
    REQUIRE(menu != nil);
    std::string titles;
    for (NSMenuItem* item in menu.itemArray) titles += (titles.empty() ? "" : ",") + test::str(item.title);
    CHECK_EQ(titles, std::string("Name,Date Created,Date Modified"));
    for (NSMenuItem* item in menu.itemArray) CHECK([c validateMenuItem:item]);
    CHECK_EQ(checkedSort(c), std::string("Name"));
}

TEST(sort_by_reorders_the_sidebar_and_keeps_the_selection) {
    std::string dir = datedCopies();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];  // b.jpg
    REQUIRE(waitForImage(c));

    [NSApp sendAction:@selector(sortSidebar:) to:c from:[sortMenu(c) itemWithTitle:@"Date Created"]];
    CHECK_EQ(names(c), std::string("b.jpg,c.jpg,a.jpg"));
    CHECK_EQ(checkedSort(c), std::string("Date Created"));
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(0));  // still b.jpg
    CHECK_EQ(test::str(c.window.title), std::string("b.jpg"));

    [c sortImagesBy:SidebarOrderDateModified];
    CHECK_EQ(names(c), std::string("a.jpg,b.jpg,c.jpg"));
    CHECK_EQ(checkedSort(c), std::string("Date Modified"));
    CHECK_EQ(tableOf(c).selectedRow, NSInteger(1));  // b.jpg followed to its new row

    [c sortImagesBy:SidebarOrderName];
    CHECK_EQ(names(c), std::string("a.jpg,b.jpg,c.jpg"));
    CHECK_EQ(checkedSort(c), std::string("Name"));
}

TEST(dragging_a_thumbnail_moves_it) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png"), sample("a10.jpg") ]);
    MainWindowController* c = app.controllers()[0];
    NSTableView* table = tableOf(c);
    CHECK([table.registeredDraggedTypes containsObject:@"com.local.previewviewer.sidebar-row"]);

    // Drag a1 (row 0) to between a3 and a10, as the table's drop callbacks report it.
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    NSDraggingSession* session = nil;  // not used by the app
    id<NSDraggingInfo> dropInfo = nil;  // not used by the app (validateDrop checks the source)
    [table.dataSource tableView:table draggingSession:session willBeginAtPoint:NSZeroPoint
                  forRowIndexes:[NSIndexSet indexSetWithIndex:0]];
    CHECK([table.dataSource tableView:table acceptDrop:dropInfo row:3 dropOperation:NSTableViewDropAbove]);
    CHECK_EQ(names(c), std::string("a2.jpg,a3.png,a1.jpg,a10.jpg"));
    CHECK_EQ(table.selectedRow, NSInteger(2));  // the moved image stays selected
    CHECK_EQ(test::str(c.window.title), std::string("a1.jpg"));
    CHECK(c.sidebarOrder == SidebarOrderCustom);
    CHECK_EQ(checkedSort(c), std::string("(none)"));

    // Upwards: a10 (row 3) to the top.
    [c moveImageAtRow:3 toRow:0];
    CHECK_EQ(names(c), std::string("a10.jpg,a2.jpg,a3.png,a1.jpg"));
}

TEST(reordering_and_sorting_are_not_undoable) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* c = app.controllers()[0];
    [c moveImageAtRow:0 toRow:3];
    endEvent();
    [c sortImagesBy:SidebarOrderDateModified];
    endEvent();
    CHECK(!c.window.undoManager.canUndo);
}

TEST(a_custom_order_is_not_carried_to_a_new_window) {
    App app;
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* c = app.controllers()[0];
    app.open(@[ sample("a10.jpg") ]);  // a second window, so closing the first doesn't quit
    [c moveImageAtRow:0 toRow:3];
    [c.window performClose:nil];
    app.open(@[ sample("a1.jpg"), sample("a2.jpg"), sample("a3.png") ]);
    MainWindowController* reopened = app.front();
    REQUIRE(reopened != nil);
    CHECK_EQ(names(reopened), std::string("a1.jpg,a2.jpg,a3.png"));
}

TEST(undo_after_reordering_restores_the_exact_row) {
    std::string dir = folderOfCopies({"r1.jpg", "r2.jpg", "r3.jpg", "r4.jpg"});
    resetTrash();
    App app;
    app.open(@[ url(dir) ]);
    MainWindowController* c = app.controllers()[0];
    [c moveImageAtRow:3 toRow:0];  // r4,r1,r2,r3
    [tableOf(c) selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];  // r2
    [c moveToTrash:nil];
    endEvent();
    CHECK_EQ(names(c), std::string("r4.jpg,r1.jpg,r3.jpg"));
    [c.window.undoManager undo];
    CHECK_EQ(names(c), std::string("r4.jpg,r1.jpg,r2.jpg,r3.jpg"));
}
