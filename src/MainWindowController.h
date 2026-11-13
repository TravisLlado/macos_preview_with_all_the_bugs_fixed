#import <AppKit/AppKit.h>

// Owns one viewer window: a split view with the thumbnail sidebar on the left
// (shown only when more than one image is open) and the image pane on the right.
@interface MainWindowController : NSWindowController <NSSplitViewDelegate>
- (instancetype)init;

// YES until images have been opened in this window (or if none were found).
@property(nonatomic, readonly) BOOL isEmpty;

// Shows the given images and selects the first. Image files
// are shown as-is; a folder contributes every image directly inside it.
- (void)openURLs:(NSArray<NSURL*>*)urls;
@end
