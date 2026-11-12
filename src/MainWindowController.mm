#import "MainWindowController.h"

#include "ImageList.h"

static const CGFloat kDefaultSidebarWidth = 200.0;
static const CGFloat kMinSidebarWidth = 120.0;
static const CGFloat kMinMainPaneWidth = 300.0;

@implementation MainWindowController {
    NSSplitView* _splitView;
    NSView* _sidebarView;
    NSView* _mainPaneView;

    NSArray<NSString*>* _imagePaths;  // full paths, natural-sorted by filename
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

    // Placeholder panes; the table view and image view arrive in later phases.
    _sidebarView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kDefaultSidebarWidth, NSHeight(content.bounds))];
    _mainPaneView = [[NSView alloc] initWithFrame:NSZeroRect];

    [_splitView addSubview:_sidebarView];
    [_splitView addSubview:_mainPaneView];

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
    _imagePaths = imagePaths;

    self.window.title = folderURL.lastPathComponent;
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
