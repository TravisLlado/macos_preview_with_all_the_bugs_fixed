#import <AppKit/AppKit.h>

// Owns the single viewer window: a split view with the thumbnail sidebar on
// the left and the image pane on the right.
@interface MainWindowController : NSWindowController <NSSplitViewDelegate>
- (instancetype)init;
@end
