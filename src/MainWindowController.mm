#import "MainWindowController.h"
#import "ImageScrollView.h"

#include "ImageList.h"
#include "ImageLoading.h"

#include <atomic>

static const CGFloat kDefaultSidebarWidth = 200.0;
static const CGFloat kMinSidebarWidth = 120.0;
static const CGFloat kMinMainPaneWidth = 300.0;

@implementation MainWindowController {
    NSSplitView* _splitView;
    NSView* _sidebarView;
    ImageScrollView* _viewer;

    NSURL* _folderURL;
    NSArray<NSString*>* _imagePaths;  // full paths, natural-sorted by filename

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

    // Placeholder sidebar; the thumbnail table arrives in Phase 4.
    _sidebarView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kDefaultSidebarWidth, NSHeight(content.bounds))];
    _viewer = [[ImageScrollView alloc] initWithFrame:NSZeroRect];

    [_splitView addSubview:_sidebarView];
    [_splitView addSubview:_viewer];

    [content addSubview:_splitView];
    [_splitView adjustSubviews];
    [_splitView setPosition:kDefaultSidebarWidth ofDividerAtIndex:0];
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

    [self showImageAtPath:_imagePaths.firstObject];
}

#pragma mark - Main viewer

- (void)showImageAtPath:(NSString*)path {
    uint64_t token = ++_imageToken;
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
    return view != _sidebarView;
}

@end
