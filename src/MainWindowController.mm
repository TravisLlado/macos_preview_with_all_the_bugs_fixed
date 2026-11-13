#import "MainWindowController.h"
#import "ImageScrollView.h"

#include "ImageList.h"
#include "ImageLoading.h"
#include "ThumbnailCache.h"

#include <atomic>

static const CGFloat kDefaultSidebarWidth = 200.0;
static const CGFloat kMinSidebarWidth = 120.0;
static const CGFloat kMinMainPaneWidth = 300.0;

static const CGFloat kRowHeight = 150.0;
static const CGFloat kThumbnailHeight = 112.0;
static const int kThumbnailMaxPixels = 256;

// Pasteboard type for dragging a sidebar row to a new position.
static NSPasteboardType const kSidebarRowType = @"com.local.previewviewer.sidebar-row";

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

#pragma mark - Sidebar table

// The sidebar table, plus the white line that shows where a dragged
// thumbnail will land.
@interface SidebarTableView : NSTableView
- (void)showDropIndicatorAboveRow:(NSInteger)row;
- (void)hideDropIndicator;
@end

// A view that ignores the mouse, so the indicator never gets in the way.
@interface PassThroughView : NSView
@end

@implementation PassThroughView
- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@implementation SidebarTableView {
    NSView* _dropIndicator;
}

static const CGFloat kDropIndicatorHeight = 2.0;
static const CGFloat kDropIndicatorInset = 8.0;

- (void)showDropIndicatorAboveRow:(NSInteger)row {
    NSInteger count = self.numberOfRows;
    if (count == 0) {
        return;
    }
    // The table is flipped: y grows downwards. Row `count` means after the last row.
    CGFloat y = row < count ? NSMinY([self rectOfRow:row]) : NSMaxY([self rectOfRow:count - 1]);
    y = MAX(kDropIndicatorHeight / 2, MIN(y, NSHeight(self.bounds) - kDropIndicatorHeight / 2));
    if (!_dropIndicator) {
        _dropIndicator = [[PassThroughView alloc] initWithFrame:NSZeroRect];
        _dropIndicator.wantsLayer = YES;
        _dropIndicator.layer.backgroundColor = NSColor.whiteColor.CGColor;
        _dropIndicator.layer.cornerRadius = kDropIndicatorHeight / 2;
        // A faint shadow keeps the white line visible on the light sidebar too.
        _dropIndicator.layer.shadowColor = NSColor.blackColor.CGColor;
        _dropIndicator.layer.shadowOpacity = 0.35;
        _dropIndicator.layer.shadowRadius = 1.0;
        _dropIndicator.layer.shadowOffset = CGSizeZero;
    }
    _dropIndicator.frame = NSMakeRect(kDropIndicatorInset, y - kDropIndicatorHeight / 2,
                                      NSWidth(self.bounds) - 2 * kDropIndicatorInset, kDropIndicatorHeight);
    [self addSubview:_dropIndicator positioned:NSWindowAbove relativeTo:nil];  // above every row
}

- (void)hideDropIndicator {
    [_dropIndicator removeFromSuperview];
}

// Both are optional NSDraggingDestination methods, so only forward them if
// NSTableView implements them.
- (void)draggingExited:(id<NSDraggingInfo>)sender {
    [self hideDropIndicator];
    if ([NSTableView instancesRespondToSelector:_cmd]) {
        [super draggingExited:sender];
    }
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    [self hideDropIndicator];
    if ([NSTableView instancesRespondToSelector:_cmd]) {
        [super draggingEnded:sender];
    }
}

@end

#pragma mark - Window controller

@interface MainWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation MainWindowController {
    NSSplitView* _splitView;
    NSScrollView* _sidebarScrollView;
    SidebarTableView* _tableView;
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

    BOOL _removingRow;  // ignore selection changes while rows are removed/inserted

    SidebarOrder _sidebarOrder;  // current Sort By choice, or custom after a drag
    NSInteger _draggedRow;       // row being dragged within the sidebar
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
    _tableView = [[SidebarTableView alloc] initWithFrame:sidebarFrame];
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
    // Rows can be dragged to a new position (within this sidebar only).
    [_tableView registerForDraggedTypes:@[ kSidebarRowType ]];
    [_tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    _tableView.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleNone;  // own line
    _tableView.menu = [self makeSidebarMenu];
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
    _imagePaths = [imagePaths copy];  // always opened in filename order
    _currentPath = nil;
    _sidebarOrder = SidebarOrderName;

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

#pragma mark - Reordering and Sort By
//
// The order lasts only while the window is open; nothing is saved, and
// neither reordering nor sorting is undoable.

- (NSMenu*)makeSidebarMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem* sortBy = [menu addItemWithTitle:@"Sort By" action:nil keyEquivalent:@""];
    NSMenu* orders = [[NSMenu alloc] initWithTitle:@"Sort By"];
    struct {
        NSString* title;
        SidebarOrder order;
    } choices[] = {
        {@"Name", SidebarOrderName},
        {@"Date Created", SidebarOrderDateCreated},
        {@"Date Modified", SidebarOrderDateModified},
    };
    for (auto& choice : choices) {
        NSMenuItem* item = [orders addItemWithTitle:choice.title action:@selector(sortSidebar:) keyEquivalent:@""];
        item.tag = choice.order;
        item.target = self;
    }
    sortBy.submenu = orders;
    return menu;
}

- (SidebarOrder)sidebarOrder {
    return _sidebarOrder;
}

- (IBAction)sortSidebar:(NSMenuItem*)sender {
    [self sortImagesBy:(SidebarOrder)sender.tag];
}

- (void)sortImagesBy:(SidebarOrder)order {
    if (order == SidebarOrderCustom) {
        return;
    }
    std::vector<std::string> paths;
    for (NSString* p in _imagePaths) {
        paths.push_back(p.fileSystemRepresentation);
    }
    imagelist::sortImages(paths, order == SidebarOrderName          ? imagelist::SortOrder::Name
                                 : order == SidebarOrderDateCreated ? imagelist::SortOrder::DateCreated
                                                                    : imagelist::SortOrder::DateModified);
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<NSString*>* sorted = [NSMutableArray arrayWithCapacity:paths.size()];
    for (const std::string& p : paths) {
        [sorted addObject:[fm stringWithFileSystemRepresentation:p.c_str() length:p.size()]];
    }
    NSString* selected = [self selectedSidebarPath];
    _imagePaths = sorted;
    _sidebarOrder = order;

    // Keep the same image selected (the viewer does not change).
    _removingRow = YES;
    [_tableView reloadData];
    NSInteger row = selected ? [self rowForPath:selected] : -1;
    if (row >= 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:row];
    }
    _removingRow = NO;
    [self requestThumbnailsForWantedRows];
}

// Moves one image to a new position; `toRow` is the insertion point in the
// list before the move (as a table drop reports it).
- (void)moveImageAtRow:(NSInteger)fromRow toRow:(NSInteger)toRow {
    NSInteger count = (NSInteger)_imagePaths.count;
    if (fromRow < 0 || fromRow >= count || toRow < 0 || toRow > count) {
        return;
    }
    NSInteger destination = toRow > fromRow ? toRow - 1 : toRow;  // index after removal
    if (destination == fromRow) {
        return;
    }
    NSMutableArray<NSString*>* paths = [_imagePaths mutableCopy];
    NSString* moved = paths[(NSUInteger)fromRow];
    [paths removeObjectAtIndex:(NSUInteger)fromRow];
    [paths insertObject:moved atIndex:(NSUInteger)destination];
    _imagePaths = paths;
    _sidebarOrder = SidebarOrderCustom;

    _removingRow = YES;  // the selection follows the moved row; the viewer does not change
    [_tableView moveRowAtIndex:fromRow toIndex:destination];
    _removingRow = NO;
}

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row {
    (void)tableView;
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row] forType:kSidebarRowType];
    return item;
}

- (void)tableView:(NSTableView*)tableView
    draggingSession:(NSDraggingSession*)session
    willBeginAtPoint:(NSPoint)screenPoint
       forRowIndexes:(NSIndexSet*)rowIndexes {
    (void)tableView;
    (void)session;
    (void)screenPoint;
    _draggedRow = (NSInteger)rowIndexes.firstIndex;
}

- (void)tableView:(NSTableView*)tableView
    draggingSession:(NSDraggingSession*)session
       endedAtPoint:(NSPoint)screenPoint
          operation:(NSDragOperation)operation {
    (void)tableView;
    (void)session;
    (void)screenPoint;
    (void)operation;
    [_tableView hideDropIndicator];  // dropped, cancelled, or released elsewhere
}

- (NSDragOperation)tableView:(NSTableView*)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    (void)dropOperation;
    if (info.draggingSource != tableView) {
        [_tableView hideDropIndicator];
        return NSDragOperationNone;  // only rows from this sidebar
    }
    // Always drop between rows: above the thumbnail under the pointer if the
    // pointer is in its upper half, below it if in the lower half.
    NSPoint point = [tableView convertPoint:info.draggingLocation fromView:nil];
    NSInteger hovered = [tableView rowAtPoint:point];
    if (hovered >= 0) {
        row = point.y < NSMidY([tableView rectOfRow:hovered]) ? hovered : hovered + 1;
    }
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    [_tableView showDropIndicatorAboveRow:row];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView*)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    (void)tableView;
    (void)info;
    (void)dropOperation;
    [_tableView hideDropIndicator];
    [self moveImageAtRow:_draggedRow toRow:row];
    return YES;
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
    if (path) {
        [self trashImagePath:path];
    }
}

#pragma mark - Undo / redo
//
// Undoable actions are registered with the window's NSUndoManager, which the
// Edit menu's Undo (Cmd-Z) and Redo (Shift-Cmd-Z) items drive. Each undo
// handler registers its own inverse, which NSUndoManager files as the redo.

static NSString* const kMoveToTrashActionName = @"Move to Trash";

// Moves `path` to the Trash (never deletes it) and removes it from the list.
// Undo moves it back.
- (void)trashImagePath:(NSString*)path {
    NSURL* trashURL = nil;
    NSError* error = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path]
                                     resultingItemURL:&trashURL
                                                error:&error]) {
        [self presentErrorSheet:error];
        return;
    }
    NSInteger row = [self rowForPath:path];
    [self removeImagePath:path];

    if (trashURL) {  // nil only on volumes that cannot say where the item went
        NSUndoManager* undoManager = self.window.undoManager;
        [undoManager registerUndoWithTarget:self
                                    handler:^(MainWindowController* target) {
                                        [target restoreImagePath:path fromTrashURL:trashURL atRow:row];
                                    }];
        [undoManager setActionName:kMoveToTrashActionName];
    }
}

// Undo of Move to Trash: moves the file back to where it was and lists it
// again at the row it was trashed from.
- (void)restoreImagePath:(NSString*)path fromTrashURL:(NSURL*)trashURL atRow:(NSInteger)row {
    NSError* error = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:trashURL toURL:[NSURL fileURLWithPath:path] error:&error]) {
        [self presentErrorSheet:error];  // e.g. the Trash was emptied, or the name is taken
        return;
    }
    [self insertImagePath:path atRow:row];

    NSUndoManager* undoManager = self.window.undoManager;
    [undoManager registerUndoWithTarget:self
                                handler:^(MainWindowController* target) {
                                    [target trashImagePath:path];
                                }];
    [undoManager setActionName:kMoveToTrashActionName];
}

- (void)presentErrorSheet:(NSError*)error {
    NSAlert* alert = [NSAlert alertWithError:error];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

// Puts a restored image back at `row` (clamped to the list) and selects it.
- (void)insertImagePath:(NSString*)path atRow:(NSInteger)row {
    NSMutableArray<NSString*>* paths = [_imagePaths mutableCopy] ?: [NSMutableArray array];
    row = MAX(0, MIN(row, (NSInteger)paths.count));
    [paths insertObject:path atIndex:(NSUInteger)row];
    _imagePaths = paths;

    [self setSidebarVisible:_imagePaths.count != 1];
    _removingRow = YES;  // suppress intermediate selection changes
    [_tableView insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                      withAnimation:NSTableViewAnimationEffectFade];
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_tableView scrollRowToVisible:row];
    _removingRow = NO;
    [self showSelectedImage];
    if (!_sidebarScrollView.hidden) {
        [self.window makeFirstResponder:_tableView];
    }
    [self requestThumbnailsForWantedRows];
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
    if (action == @selector(sortSidebar:)) {
        item.state = item.tag == _sidebarOrder ? NSControlStateValueOn : NSControlStateValueOff;
        return _imagePaths.count > 1;
    }
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
