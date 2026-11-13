#import <AppKit/AppKit.h>

// Owns one viewer window: a split view with the thumbnail sidebar on the left
// (hidden when exactly one image is open) and the image pane on the right.
@interface MainWindowController : NSWindowController <NSSplitViewDelegate>
- (instancetype)init;

// YES until images have been shown in this window (or if none were found).
@property(nonatomic, readonly) BOOL isEmpty;

// Canonical full paths of the images in this window, in sidebar order.
@property(nonatomic, readonly) NSArray<NSString*>* imagePaths;

// Shows `imagePaths` (already sorted) and selects the first. `emptyTitle` is
// the window title used if the list is empty.
- (void)showImagePaths:(NSArray<NSString*>*)imagePaths emptyTitle:(NSString*)emptyTitle;

// Selects `path` (one of imagePaths) and shows it in the viewer.
- (void)selectImagePath:(NSString*)path;
@end
