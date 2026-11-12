#import "MainWindowController.h"
#import "ImageScrollView.h"

#include "ImageList.h"
#include "ImageLoading.h"
#include "ThumbnailCache.h"

#include <atomic>

static const CGFloat kDefaultSidebarWidth = 200.0;
static const CGFloat kMinSidebarWidth = 120.0;
static const CGFloat kMinMainPaneWidth = 300.0;

static NSString* const kWindowFrameName = @"MainWindow";
static NSString* const kSidebarWidthKey = @"SidebarWidth";

static const CGFloat kRowHeight = 150.0;
static const CGFloat kThumbnailHeight = 112.0;
static const int kThumbnailMaxPixels = 256;

#pragma mark - Sidebar cell

// One sidebar row: a thumbnail with the filename centered below it.
@interface ThumbnailCellView : NSTableCellView
@end

@implementation ThumbnailCellView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        NSImageView* imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        imageView.imageScaling = NSImageScaleProportionallyDown;
        imageView.imageFrameStyle = NSImageFrameNone;
        imageView.contentTintColor = NSColor.tertiaryLabelColor;  // tints the placeholder symbol
        imageView.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField* label = [NSTextField labelWithString:@""];
        label.alignment = NSTextAlignmentCenter;
        label.font = [NSFont systemFontOfSize:11];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.maximumNumberOfLines = 1;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];

        [self addSubview:imageView];
        [self addSubview:label];
        self.imageView = imageView;
        self.textField = label;  // lets NSTableCellView recolor the text when selected

        [NSLayoutConstraint activateConstraints:@[
            [imageView.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [imageView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [imageView.heightAnchor constraintEqualToConstant:kThumbnailHeight],
            [label.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:6],
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        ]];
    }
    return self;
}

@end

#pragma mark - Window controller

@interface MainWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation MainWindowController {
    NSSplitView* _splitView;
    NSScrollView* _sidebarScrollView;
    NSTableView* _tableView;
    ImageScrollView* _viewer;

    NSURL* _folderURL;
    NSArray<NSString*>* _imagePaths;  // full paths, natural-sorted by filename
    NSString* _currentPath;           // image shown (or loading) in the viewer

    // Full-size images decode on a background queue. Each request bumps the
    // token, so stale requests (the user has moved on) are skipped.
    dispatch_queue_t _imageQueue;
    std::atomic<uint64_t> _imageToken;

    // Thumbnails decode on a concurrent background queue and are cached on
    // the main thread. Only rows in [_wantedFirstRow, _wantedLastRow] (visible
    // plus about a screenful either side) are worth decoding; a queued request
    // that falls outside the range by the time it runs is dropped. The folder
    // token discards results that arrive after a different folder was opened.
    ThumbnailCache _thumbnails;
    dispatch_queue_t _thumbnailQueue;
    std::atomic<uint64_t> _folderToken;
    std::atomic<NSInteger> _wantedFirstRow;
    std::atomic<NSInteger> _wantedLastRow;
    NSImage* _placeholder;

    BOOL _layoutRestored;  // don't save the sidebar width until it has been restored
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 1000, 700);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = NSProcessInfo.processInfo.processName;
    window.minSize = NSMakeSize(kMinSidebarWidth + kMinMainPaneWidth, 300);
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        // Save the window frame whenever it changes, and restore the last one.
        // (Set via the controller: NSWindowController otherwise overrides the
        // window's own autosave name with its empty one.)
        self.shouldCascadeWindows = NO;
        self.windowFrameAutosaveName = kWindowFrameName;
        [window setFrameUsingName:kWindowFrameName];
        _imageQueue = dispatch_queue_create(
            "previewviewer.image",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _thumbnailQueue = dispatch_queue_create(
            "previewviewer.thumbnails",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
        NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:40
                                                                                             weight:NSFontWeightUltraLight];
        _placeholder = [[NSImage imageWithSystemSymbolName:@"photo" accessibilityDescription:@"Loading"]
            imageWithSymbolConfiguration:config];
        [self buildSplitView];
    }
    return self;
}

- (void)buildSplitView {
    NSView* content = self.window.contentView;

    _splitView = [[NSSplitView alloc] initWithFrame:content.bounds];
    _splitView.vertical = YES;  // side-by-side panes
    _splitView.dividerStyle = NSSplitViewDividerStyleThin;
    _splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _splitView.delegate = self;

    NSRect sidebarFrame = NSMakeRect(0, 0, kDefaultSidebarWidth, NSHeight(content.bounds));
    _sidebarScrollView = [[NSScrollView alloc] initWithFrame:sidebarFrame];
    _sidebarScrollView.hasVerticalScroller = YES;
    _sidebarScrollView.autohidesScrollers = YES;
    _sidebarScrollView.borderType = NSNoBorder;

    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"thumbnail"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    _tableView = [[NSTableView alloc] initWithFrame:sidebarFrame];
    [_tableView addTableColumn:column];
    _tableView.headerView = nil;
    _tableView.style = NSTableViewStyleSourceList;
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _tableView.intercellSpacing = NSZeroSize;
    _tableView.rowHeight = kRowHeight;
    _tableView.allowsMultipleSelection = NO;
    _tableView.allowsEmptySelection = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _sidebarScrollView.documentView = _tableView;
    [_tableView sizeLastColumnToFit];  // the single column spans the sidebar

    // Track scrolling and resizing so thumbnails are requested as rows come into view.
    NSClipView* sidebarClip = _sidebarScrollView.contentView;
    sidebarClip.postsBoundsChangedNotifications = YES;
    sidebarClip.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sidebarVisibleRectChanged:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:sidebarClip];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sidebarVisibleRectChanged:)
                                               name:NSViewFrameDidChangeNotification
                                             object:sidebarClip];

    _viewer = [[ImageScrollView alloc] initWithFrame:NSZeroRect];

    [_splitView addSubview:_sidebarScrollView];
    [_splitView addSubview:_viewer];

    [content addSubview:_splitView];
    [_splitView adjustSubviews];
    CGFloat sidebarWidth = [NSUserDefaults.standardUserDefaults doubleForKey:kSidebarWidthKey];
    [_splitView setPosition:(sidebarWidth > 0 ? sidebarWidth : kDefaultSidebarWidth) ofDividerAtIndex:0];
    _layoutRestored = YES;

    self.window.initialFirstResponder = _tableView;  // arrow keys move through the list
}

#pragma mark - Folder loading

- (IBAction)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Open";
    panel.message = @"Choose a folder of images";
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                      if (result == NSModalResponseOK && panel.URL) {
                          [self openFolder:panel.URL];
                      }
                  }];
}

- (void)openFolder:(NSURL*)folderURL {
    [self openFolder:folderURL selectingFile:nil];
}

- (void)openFolder:(NSURL*)folderURL selectingFile:(NSURL*)fileURL {
    std::vector<std::string> paths = imagelist::listImages(folderURL.fileSystemRepresentation);

    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<NSString*>* imagePaths = [NSMutableArray arrayWithCapacity:paths.size()];
    for (const std::string& path : paths) {
        [imagePaths addObject:[fm stringWithFileSystemRepresentation:path.c_str() length:path.size()]];
    }
    _folderURL = folderURL;
    _imagePaths = imagePaths;
    _currentPath = nil;

    ++_folderToken;
    _thumbnails.clear();
    // Select the requested file (matched by name, since the folder path may be
    // spelled differently, e.g. through a symlink), else the first image.
    NSUInteger selectedRow = 0;
    if (fileURL) {
        NSString* fileName = fileURL.lastPathComponent;
        NSUInteger index = [_imagePaths indexOfObjectPassingTest:^BOOL(NSString* path, NSUInteger, BOOL*) {
            return [path.lastPathComponent isEqualToString:fileName];
        }];
        if (index != NSNotFound) {
            selectedRow = index;
        }
    }

    [_tableView reloadData];
    if (_imagePaths.count > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedRow] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:(NSInteger)selectedRow];
    }
    if (_tableView.selectedRow < 0) {
        [self showImageAtPath:nil];  // empty folder: clear the viewer
    } else {
        [self showSelectedImage];  // selection may not have changed (row 0 -> row 0)
    }
    [self.window makeFirstResponder:_tableView];
    [self requestThumbnailsForWantedRows];
}

#pragma mark - Sidebar

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    (void)tableView;
    return (NSInteger)_imagePaths.count;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)column;
    ThumbnailCellView* cell = [tableView makeViewWithIdentifier:@"ThumbnailCell" owner:self];
    if (!cell) {
        cell = [[ThumbnailCellView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(tableView.bounds), kRowHeight)];
        cell.identifier = @"ThumbnailCell";
    }
    NSString* path = _imagePaths[(NSUInteger)row];
    cell.textField.stringValue = path.lastPathComponent;

    cell.imageView.image = [self thumbnailForPath:path];
    [self requestThumbnailForRow:row];
    return cell;
}

#pragma mark - Thumbnails

// The cached thumbnail for `path`, or the placeholder.
- (NSImage*)thumbnailForPath:(NSString*)path {
    CGImageRef cgImage = _thumbnails.find(path.fileSystemRepresentation);
    if (!cgImage) {
        return _placeholder;
    }
    return [[NSImage alloc] initWithCGImage:cgImage
                                       size:NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage))];
}

- (void)sidebarVisibleRectChanged:(NSNotification*)notification {
    (void)notification;
    [self requestThumbnailsForWantedRows];
}

// Updates the wanted range and requests thumbnails for it: visible rows first,
// then the rows within one screenful above and below.
- (void)requestThumbnailsForWantedRows {
    NSRect visible = _sidebarScrollView.contentView.documentVisibleRect;
    NSRange visibleRows = [_tableView rowsInRect:visible];
    NSRange wantedRows = [_tableView rowsInRect:NSInsetRect(visible, 0, -NSHeight(visible))];
    if (wantedRows.length == 0) {
        _wantedFirstRow = 0;
        _wantedLastRow = -1;
        return;
    }
    _wantedFirstRow = (NSInteger)wantedRows.location;
    _wantedLastRow = (NSInteger)NSMaxRange(wantedRows) - 1;

    for (NSUInteger row = visibleRows.location; row < NSMaxRange(visibleRows); ++row) {
        [self requestThumbnailForRow:(NSInteger)row];
    }
    for (NSUInteger row = wantedRows.location; row < NSMaxRange(wantedRows); ++row) {
        [self requestThumbnailForRow:(NSInteger)row];
    }
}

- (void)requestThumbnailForRow:(NSInteger)row {
    std::string path = _imagePaths[(NSUInteger)row].fileSystemRepresentation;
    if (!_thumbnails.beginRequest(path)) {
        return;  // cached or already in flight
    }
    uint64_t folderToken = _folderToken;
    dispatch_async(_thumbnailQueue, ^{
        if (folderToken != self->_folderToken) {
            return;  // another folder was opened; its cache has been cleared
        }
        if (row < self->_wantedFirstRow || row > self->_wantedLastRow) {
            // Scrolled away before we got to it; allow a fresh request later
            // (or right away, if the range moved back while this was queued).
            dispatch_async(dispatch_get_main_queue(), ^{
                if (folderToken == self->_folderToken) {
                    self->_thumbnails.cancelRequest(path);
                    if (row >= self->_wantedFirstRow && row <= self->_wantedLastRow) {
                        [self requestThumbnailForRow:row];
                    }
                }
            });
            return;
        }
        CGImageRef thumbnail = imageio::createImage(path, kThumbnailMaxPixels);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (folderToken == self->_folderToken) {
                self->_thumbnails.insert(path, thumbnail);  // nullptr records a failure
                [self reloadThumbnailInRow:row];
            }
            CGImageRelease(thumbnail);
        });
    });
}

- (void)reloadThumbnailInRow:(NSInteger)row {
    if (row >= _tableView.numberOfRows) {
        return;
    }
    NSTableCellView* cell = [_tableView viewAtColumn:0 row:row makeIfNecessary:NO];
    if (cell) {
        cell.imageView.image = [self thumbnailForPath:_imagePaths[(NSUInteger)row]];
    }
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    (void)notification;
    [self showSelectedImage];
}

- (void)showSelectedImage {
    NSInteger row = _tableView.selectedRow;
    NSString* path = row >= 0 ? _imagePaths[(NSUInteger)row] : nil;
    if (path != _currentPath && ![path isEqualToString:_currentPath]) {
        [self showImageAtPath:path];
    }
}

#pragma mark - Main viewer

- (void)showImageAtPath:(NSString*)path {
    uint64_t token = ++_imageToken;
    _currentPath = path;
    self.window.title = path ? path.lastPathComponent : (_folderURL.lastPathComponent ?: @"");
    if (!path) {
        [_viewer setImage:nil];
        return;
    }

    std::string filePath = path.fileSystemRepresentation;
    dispatch_async(_imageQueue, ^{
        if (token != self->_imageToken) {
            return;  // superseded before we started
        }
        CGImageRef cgImage = imageio::createImage(filePath);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token == self->_imageToken) {
                NSImage* image = nil;
                if (cgImage) {
                    NSSize size = NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
                    image = [[NSImage alloc] initWithCGImage:cgImage size:size];
                }
                [self->_viewer setImage:image];
            }
            CGImageRelease(cgImage);
        });
    });
}

- (IBAction)zoomIn:(id)sender {
    (void)sender;
    [_viewer zoomIn];
}

- (IBAction)zoomOut:(id)sender {
    (void)sender;
    [_viewer zoomOut];
}

- (IBAction)zoomToActualSize:(id)sender {
    (void)sender;
    [_viewer zoomToActualSize];
}

- (IBAction)zoomToFit:(id)sender {
    (void)sender;
    [_viewer zoomToFit];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    SEL action = item.action;
    if (action == @selector(zoomIn:) || action == @selector(zoomOut:) ||
        action == @selector(zoomToActualSize:) || action == @selector(zoomToFit:)) {
        return _viewer.hasImage;
    }
    return YES;
}

#pragma mark - NSSplitViewDelegate

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
    (void)splitView;
    (void)dividerIndex;
    return MAX(proposedMinimumPosition, kMinSidebarWidth);
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
    (void)dividerIndex;
    return MIN(proposedMaximumPosition, NSWidth(splitView.bounds) - kMinMainPaneWidth);
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification {
    (void)notification;
    if (_layoutRestored) {
        [NSUserDefaults.standardUserDefaults setDouble:NSWidth(_sidebarScrollView.frame) forKey:kSidebarWidthKey];
    }
}

- (BOOL)splitView:(NSSplitView*)splitView shouldAdjustSizeOfSubview:(NSView*)view {
    (void)splitView;
    // Keep the sidebar width fixed during window resizes.
    return view != _sidebarScrollView;
}

@end
