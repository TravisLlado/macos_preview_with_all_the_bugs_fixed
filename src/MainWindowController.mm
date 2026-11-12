#import "MainWindowController.h"
#import "ImageScrollView.h"

#include "ImageList.h"
#include "ImageLoading.h"

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
    _tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _tableView.rowHeight = kRowHeight;
    _tableView.allowsMultipleSelection = NO;
    _tableView.allowsEmptySelection = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _sidebarScrollView.documentView = _tableView;

    _viewer = [[ImageScrollView alloc] initWithFrame:NSZeroRect];

    [_splitView addSubview:_sidebarScrollView];
    [_splitView addSubview:_viewer];

    [content addSubview:_splitView];
    [_splitView adjustSubviews];
    [_splitView setPosition:kDefaultSidebarWidth ofDividerAtIndex:0];

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
    std::vector<std::string> paths = imagelist::listImages(folderURL.fileSystemRepresentation);

    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<NSString*>* imagePaths = [NSMutableArray arrayWithCapacity:paths.size()];
    for (const std::string& path : paths) {
        [imagePaths addObject:[fm stringWithFileSystemRepresentation:path.c_str() length:path.size()]];
    }
    _folderURL = folderURL;
    _imagePaths = imagePaths;
    _currentPath = nil;

    [_tableView reloadData];
    if (_imagePaths.count > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:0];
    }
    if (_tableView.selectedRow < 0) {
        [self showImageAtPath:nil];  // empty folder: clear the viewer
    } else {
        [self showSelectedImage];  // selection may not have changed (row 0 -> row 0)
    }
    [self.window makeFirstResponder:_tableView];
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

    NSImage* thumbnail = nil;
    CGImageRef cgImage = imageio::createImage(path.fileSystemRepresentation, kThumbnailMaxPixels);
    if (cgImage) {
        thumbnail = [[NSImage alloc] initWithCGImage:cgImage
                                                size:NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage))];
        CGImageRelease(cgImage);
    }
    cell.imageView.image = thumbnail;
    return cell;
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

- (BOOL)splitView:(NSSplitView*)splitView shouldAdjustSizeOfSubview:(NSView*)view {
    (void)splitView;
    // Keep the sidebar width fixed during window resizes.
    return view != _sidebarScrollView;
}

@end
