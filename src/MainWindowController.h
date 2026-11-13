#import <AppKit/AppKit.h>

// Owns the single viewer window: a split view with the thumbnail sidebar on
// the left and the image pane on the right.
@interface MainWindowController : NSWindowController <NSSplitViewDelegate>
- (instancetype)init;

// Shows the given images in the sidebar and selects the first. Image files
// are shown as-is; a folder contributes every image directly inside it.
- (void)openURLs:(NSArray<NSURL*>*)urls;
@end
