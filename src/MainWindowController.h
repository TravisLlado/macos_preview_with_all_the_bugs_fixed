#import <AppKit/AppKit.h>

// Sidebar order: one of the Sort By choices, or Custom after a drag.
typedef NS_ENUM(NSInteger, SidebarOrder) {
    SidebarOrderName,
    SidebarOrderDateCreated,
    SidebarOrderDateModified,
    SidebarOrderCustom,
};

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

// The current sidebar order (Name when images are first opened).
@property(nonatomic, readonly) SidebarOrder sidebarOrder;

// Re-sorts the sidebar (right-click → Sort By). The selected image stays selected.
- (void)sortImagesBy:(SidebarOrder)order;

// Moves an image within the sidebar, as dragging a thumbnail does. `toRow`
// is the insertion point counted before the move.
- (void)moveImageAtRow:(NSInteger)fromRow toRow:(NSInteger)toRow;
@end
