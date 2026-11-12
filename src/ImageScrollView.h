#import <AppKit/AppKit.h>

// The main image pane: an NSImageView inside a magnifiable NSScrollView.
// The image is centered when it is smaller than the view.
@interface ImageScrollView : NSScrollView

// Shows `image` (or clears the view if nil) at zoom-to-fit.
- (void)setImage:(NSImage*)image;
@property(nonatomic, readonly) BOOL hasImage;

- (void)zoomIn;
- (void)zoomOut;
- (void)zoomToActualSize;
// Fits the whole image in the view (never enlarging past 100%), and keeps it
// fitted as the view resizes until the user zooms some other way.
- (void)zoomToFit;

@end
