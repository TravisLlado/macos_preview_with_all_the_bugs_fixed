#import "ImageScrollView.h"

static const CGFloat kZoomStep = 1.25;

// Clip view that centers the document when it is smaller than the visible area
// (NSClipView's default pins it to the bottom-left corner).
@interface CenteringClipView : NSClipView
@end

@implementation CenteringClipView

- (NSRect)constrainBoundsRect:(NSRect)proposedBounds {
    NSRect bounds = [super constrainBoundsRect:proposedBounds];
    NSView* document = self.documentView;
    if (document) {
        NSRect docFrame = document.frame;
        if (NSWidth(bounds) > NSWidth(docFrame)) {
            bounds.origin.x = NSMinX(docFrame) - (NSWidth(bounds) - NSWidth(docFrame)) / 2;
        }
        if (NSHeight(bounds) > NSHeight(docFrame)) {
            bounds.origin.y = NSMinY(docFrame) - (NSHeight(bounds) - NSHeight(docFrame)) / 2;
        }
    }
    return bounds;
}

@end

@implementation ImageScrollView {
    NSImageView* _imageView;
    BOOL _fitMode;  // re-fit on resize until the user picks another zoom
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.contentView = [[CenteringClipView alloc] initWithFrame:NSZeroRect];
        self.hasVerticalScroller = YES;
        self.hasHorizontalScroller = YES;
        self.autohidesScrollers = YES;
        self.borderType = NSNoBorder;
        self.backgroundColor = NSColor.underPageBackgroundColor;
        self.drawsBackground = YES;

        self.allowsMagnification = YES;
        self.minMagnification = 0.02;
        self.maxMagnification = 32.0;

        _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _imageView.imageScaling = NSImageScaleAxesIndependently;  // frame always matches image size
        _imageView.imageFrameStyle = NSImageFrameNone;
        _imageView.editable = NO;
        _imageView.animates = NO;
        self.documentView = _imageView;

        // A pinch gesture ends "fit" mode.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(liveMagnifyWillStart:)
                                                   name:NSScrollViewWillStartLiveMagnifyNotification
                                                 object:self];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)liveMagnifyWillStart:(NSNotification*)notification {
    (void)notification;
    _fitMode = NO;
}

- (BOOL)hasImage {
    return _imageView.image != nil;
}

- (void)setImage:(NSImage*)image {
    _imageView.image = image;
    [_imageView setFrameSize:image ? image.size : NSZeroSize];
    [self zoomToFit];
}

#pragma mark - Zooming

- (NSPoint)visibleCenter {
    NSRect visible = self.contentView.bounds;
    return NSMakePoint(NSMidX(visible), NSMidY(visible));
}

- (void)zoomBy:(CGFloat)factor {
    _fitMode = NO;
    [self setMagnification:self.magnification * factor centeredAtPoint:[self visibleCenter]];
}

- (void)zoomIn {
    [self zoomBy:kZoomStep];
}

- (void)zoomOut {
    [self zoomBy:1.0 / kZoomStep];
}

- (void)zoomToActualSize {
    _fitMode = NO;
    [self setMagnification:1.0 centeredAtPoint:[self visibleCenter]];
}

- (void)zoomToFit {
    _fitMode = YES;
    [self applyFit];
}

- (void)applyFit {
    NSSize imageSize = _imageView.frame.size;
    NSSize available = self.contentSize;
    if (imageSize.width > 0 && imageSize.height > 0 && available.width > 0 && available.height > 0) {
        CGFloat scale = MIN(available.width / imageSize.width, available.height / imageSize.height);
        self.magnification = MIN(scale, 1.0);
    } else {
        self.magnification = 1.0;
    }
    // Re-apply the clip view's constraint so the image is centered right away.
    NSClipView* clip = self.contentView;
    [clip scrollToPoint:[clip constrainBoundsRect:clip.bounds].origin];
    [self reflectScrolledClipView:clip];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (_fitMode) {
        [self applyFit];
    }
}

@end
