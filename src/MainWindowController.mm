#import "MainWindowController.h"
#import "ImageScrollView.h"

#include "ImageLoading.h"
#include "ThumbnailCache.h"

#include <atomic>

static const CGFloat kDefaultSidebarWidth = 200.0;
static const CGFloat kMinSidebarWidth = 120.0;
static const CGFloat kMinMainPaneWidth = 300.0;

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

    NSString* _emptyTitle;
    NSArray<NSString*>* _imagePaths;  // full paths, natural-sorted by filename
    NSString* _currentPath;           // image shown (or loading) in the viewer

    // Full-size images decode on a background queue. Each request bumps the
    // token, so stale requests (the user has moved on) are skipped.
    dispatch_queue_t _imageQueue;
    std::atomic<uint64_t> _imageToken;

    // Thumbnails decode on a concurrent background queue and are cached on
    // the main thread. Only rows in [_wantedFirstRow, _wantedLastRow] (visible
    // plus about a screenful either side) are worth decoding; a queued request
    // that falls outside the range by the time it runs is dropped. The list
    // token discards results that arrive after different images were opened.
    ThumbnailCache _thumbnails;
    dispatch_queue_t _thumbnailQueue;
    std::atomic<uint64_t> _listToken;
    std::atomic<NSInteger> _wantedFirstRow;
    std::atomic<NSInteger> _wantedLastRow;
    NSImage* _placeholder;

    NSMutableSet<NSString*>* _pathsBeingTrashed;  // guards against trashing twice
    BOOL _removingRow;                            // ignore selection changes mid-removal
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
        _pathsBeingTrashed = [NSMutableSet set];
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
    [_splitView setPosition:kDefaultSidebarWidth ofDividerAtIndex:0];
}

- (void)setSidebarVisible:(BOOL)visible {
    if (_sidebarScrollView.hidden != visible) {
        return;
    }
    // NSSplitView treats a hidden subview as collapsed: the viewer takes the full width.
    _sidebarScrollView.hidden = !visible;
    [_splitView adjustSubviews];
    if (visible) {
        [_splitView setPosition:kDefaultSidebarWidth ofDividerAtIndex:0];
    }
}

- (BOOL)isEmpty {
    return _imagePaths.count == 0;
}

- (NSArray<NSString*>*)imagePaths {
    return _imagePaths ?: @[];
}

- (void)selectImagePath:(NSString*)path {
    NSUInteger row = [_imagePaths indexOfObject:path];
    if (row != NSNotFound) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:(NSInteger)row];
    }
}

#pragma mark - Opening images

- (void)showImagePaths:(NSArray<NSString*>*)imagePaths emptyTitle:(NSString*)emptyTitle {
    _emptyTitle = emptyTitle;
    _imagePaths = [imagePaths copy];
    _currentPath = nil;

    ++_listToken;
    _thumbnails.clear();
    [_tableView reloadData];
    if (_imagePaths.count > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:0];
    }
    if (_tableView.selectedRow < 0) {
        [self showImageAtPath:nil];  // nothing to show: clear the viewer
    } else {
        [self showSelectedImage];  // selection may not have changed (row 0 -> row 0)
    }

    // A single image gets the whole window; otherwise show the sidebar.
    BOOL showSidebar = _imagePaths.count != 1;
    [self setSidebarVisible:showSidebar];
    if (showSidebar) {
        [self.window makeFirstResponder:_tableView];  // arrow keys move through the list
        [self requestThumbnailsForWantedRows];
    }
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
    NSString* imagePath = _imagePaths[(NSUInteger)row];
    std::string path = imagePath.fileSystemRepresentation;
    if (!_thumbnails.beginRequest(path)) {
        return;  // cached or already in flight
    }
    uint64_t listToken = _listToken;
    dispatch_async(_thumbnailQueue, ^{
        if (listToken != self->_listToken) {
            return;  // another set of images was opened; the cache was cleared
        }
        if (row < self->_wantedFirstRow || row > self->_wantedLastRow) {
            // Scrolled away before we got to it; allow a fresh request later
            // (or right away, if the range moved back while this was queued).
            dispatch_async(dispatch_get_main_queue(), ^{
                if (listToken == self->_listToken) {
                    self->_thumbnails.cancelRequest(path);
                    NSInteger currentRow = [self rowForPath:imagePath];
                    if (currentRow >= self->_wantedFirstRow && currentRow <= self->_wantedLastRow) {
                        [self requestThumbnailForRow:currentRow];
                    }
                }
            });
            return;
        }
        CGImageRef thumbnail = imageio::createImage(path, kThumbnailMaxPixels);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (listToken == self->_listToken) {
                self->_thumbnails.insert(path, thumbnail);  // nullptr records a failure
                [self reloadThumbnailInRow:[self rowForPath:imagePath]];
            }
            CGImageRelease(thumbnail);
        });
    });
}

// Current row of `path`, or -1 if it is no longer listed. Looked up rather
// than remembered because rows shift when files are moved to the Trash.
- (NSInteger)rowForPath:(NSString*)path {
    NSUInteger row = [_imagePaths indexOfObject:path];
    return row == NSNotFound ? -1 : (NSInteger)row;
}

- (void)reloadThumbnailInRow:(NSInteger)row {
    if (row < 0 || row >= _tableView.numberOfRows) {
        return;
    }
    NSTableCellView* cell = [_tableView viewAtColumn:0 row:row makeIfNecessary:NO];
    if (cell) {
        cell.imageView.image = [self thumbnailForPath:_imagePaths[(NSUInteger)row]];
    }
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    (void)notification;
    if (!_removingRow) {
        [self showSelectedImage];
    }
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
    self.window.title = path ? path.lastPathComponent : (_emptyTitle ?: @"");
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

#pragma mark - Move to Trash

// The image selected in the sidebar, or nil (also nil when the sidebar is
// hidden, i.e. a single-image window).
- (NSString*)selectedSidebarPath {
    NSInteger row = _tableView.selectedRow;
    if (_sidebarScrollView.hidden || row < 0) {
        return nil;
    }
    return _imagePaths[(NSUInteger)row];
}

- (IBAction)moveToTrash:(id)sender {
    (void)sender;
    NSString* path = [self selectedSidebarPath];
    if (!path || [_pathsBeingTrashed containsObject:path]) {
        return;
    }
    [_pathsBeingTrashed addObject:path];
    // NSWorkspace moves the file to the Trash (as Finder does); it is not deleted.
    [NSWorkspace.sharedWorkspace recycleURLs:@[[NSURL fileURLWithPath:path]]
                           completionHandler:^(NSDictionary<NSURL*, NSURL*>* newURLs, NSError* error) {
                               (void)newURLs;
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   [self->_pathsBeingTrashed removeObject:path];
                                   if (error) {
                                       NSAlert* alert = [NSAlert alertWithError:error];
                                       [alert beginSheetModalForWindow:self.window completionHandler:nil];
                                   } else {
                                       [self removeImagePath:path];
                                   }
                               });
                           }];
}

// Removes a trashed image from the list and selects the image that took its
// place (or the new last one).
- (void)removeImagePath:(NSString*)path {
    NSInteger row = [self rowForPath:path];
    if (row < 0) {
        return;
    }
    NSMutableArray<NSString*>* paths = [_imagePaths mutableCopy];
    [paths removeObjectAtIndex:(NSUInteger)row];
    _imagePaths = paths;

    _removingRow = YES;
    [_tableView removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                      withAnimation:NSTableViewAnimationEffectFade];
    if (paths.count > 0) {
        NSUInteger next = MIN((NSUInteger)row, paths.count - 1);
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:(NSInteger)next];
    }
    _removingRow = NO;

    if (_tableView.selectedRow < 0) {
        [self showImageAtPath:nil];
    } else {
        [self showSelectedImage];
    }
    [self setSidebarVisible:paths.count != 1];
    [self requestThumbnailsForWantedRows];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    SEL action = item.action;
    if (action == @selector(moveToTrash:)) {
        return [self selectedSidebarPath] != nil;
    }
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

- (BOOL)splitView:(NSSplitView*)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex {
    (void)splitView;
    (void)dividerIndex;
    return _sidebarScrollView.hidden;
}

- (BOOL)splitView:(NSSplitView*)splitView shouldAdjustSizeOfSubview:(NSView*)view {
    (void)splitView;
    // Keep the sidebar width fixed during window resizes.
    return view != _sidebarScrollView;
}

@end
