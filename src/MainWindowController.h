#import <AppKit/AppKit.h>

// Owns the single viewer window: a split view with the thumbnail sidebar on
// the left and the image pane on the right.
@interface MainWindowController : NSWindowController <NSSplitViewDelegate>
- (instancetype)init;

// Loads the images in `folderURL` into the sidebar and selects the first one.
- (void)openFolder:(NSURL*)folderURL;

// Same, but selects `fileURL` (an image inside `folderURL`) if it is listed.
- (void)openFolder:(NSURL*)folderURL selectingFile:(NSURL*)fileURL;
@end
