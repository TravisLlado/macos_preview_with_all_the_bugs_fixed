// The main image pane (ImageScrollView): zoom-to-fit, actual size, zoom steps,
// centering, and staying fitted while resizing.

#import "ImageScrollView.h"

#include "AppTestSupport.h"

namespace {

// An ImageScrollView filling a w x h window.
struct Viewer {
    NSWindow* window;
    ImageScrollView* view;

    Viewer(CGFloat w = 800, CGFloat h = 600) {
        test::ensureApplication();
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered
                                                 defer:YES];
        window.releasedWhenClosed = NO;
        view = [[ImageScrollView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        window.contentView = view;
    }
    ~Viewer() { [window close]; }

    // Magnification that fits an image of the given size, capped at 100%.
    CGFloat fitFor(CGFloat w, CGFloat h) const {
        NSSize available = view.contentSize;
        return MIN(1.0, MIN(available.width / w, available.height / h));
    }

    NSRect visible() const { return view.contentView.bounds; }  // in image coordinates
};

}  // namespace

TEST(allows_pinch_magnification) {
    Viewer v;
    CHECK(v.view.allowsMagnification);
}

TEST(starts_without_an_image) {
    Viewer v;
    CHECK(!v.view.hasImage);
}

TEST(large_image_opens_scaled_to_fit) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    CHECK(v.view.hasImage);
    CHECK(test::nearlyEqual(v.view.magnification, v.fitFor(4000, 3000)));
    CHECK(v.view.magnification < 1.0);
}

TEST(small_image_opens_at_actual_size_not_enlarged) {
    Viewer v;
    [v.view setImage:test::makeNSImage(400, 300)];
    CHECK(test::nearlyEqual(v.view.magnification, 1.0));
}

TEST(small_image_is_centered) {
    Viewer v;
    [v.view setImage:test::makeNSImage(400, 300)];
    NSRect visible = v.visible();
    // The visible area is wider/taller than the image; the image sits in the middle.
    CHECK(test::nearlyEqual(NSMidX(visible), 200.0, 0.5));
    CHECK(test::nearlyEqual(NSMidY(visible), 150.0, 0.5));
}

TEST(fitted_image_is_centered_along_the_short_axis) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 1000)];  // very wide: fitted by width
    NSRect visible = v.visible();
    CHECK(test::nearlyEqual(NSMidX(visible), 2000.0, 1.0));
    CHECK(test::nearlyEqual(NSMidY(visible), 500.0, 1.0));
}

TEST(zoom_in_and_out_step_by_25_percent) {
    Viewer v;
    [v.view setImage:test::makeNSImage(400, 300)];
    [v.view zoomIn];
    CHECK(test::nearlyEqual(v.view.magnification, 1.25));
    [v.view zoomIn];
    CHECK(test::nearlyEqual(v.view.magnification, 1.5625));
    [v.view zoomOut];
    [v.view zoomOut];
    [v.view zoomOut];
    CHECK(test::nearlyEqual(v.view.magnification, 0.8));
}

TEST(actual_size_is_100_percent) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    [v.view zoomToActualSize];
    CHECK(test::nearlyEqual(v.view.magnification, 1.0));
}

TEST(zoom_to_fit_returns_to_the_fitted_size) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    [v.view zoomToActualSize];
    [v.view zoomToFit];
    CHECK(test::nearlyEqual(v.view.magnification, v.fitFor(4000, 3000)));
}

TEST(stays_fitted_while_the_window_resizes) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    [v.view setFrameSize:NSMakeSize(500, 400)];
    CHECK(test::nearlyEqual(v.view.magnification, v.fitFor(4000, 3000)));
    [v.view setFrameSize:NSMakeSize(1200, 900)];
    CHECK(test::nearlyEqual(v.view.magnification, v.fitFor(4000, 3000)));
}

TEST(other_zooms_stop_following_the_window_size) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    [v.view zoomIn];
    CGFloat zoomed = v.view.magnification;
    [v.view setFrameSize:NSMakeSize(500, 400)];
    CHECK(test::nearlyEqual(v.view.magnification, zoomed));
}

TEST(pinch_zoom_stops_following_the_window_size) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    CGFloat fitted = v.view.magnification;
    [NSNotificationCenter.defaultCenter postNotificationName:NSScrollViewWillStartLiveMagnifyNotification
                                                      object:v.view];
    [v.view setFrameSize:NSMakeSize(500, 400)];
    CHECK(test::nearlyEqual(v.view.magnification, fitted));
}

TEST(new_image_resets_to_fit) {
    Viewer v;
    [v.view setImage:test::makeNSImage(4000, 3000)];
    [v.view zoomToActualSize];
    [v.view setImage:test::makeNSImage(3000, 3000)];
    CHECK(test::nearlyEqual(v.view.magnification, v.fitFor(3000, 3000)));
}

TEST(clearing_the_image) {
    Viewer v;
    [v.view setImage:test::makeNSImage(400, 300)];
    [v.view setImage:nil];
    CHECK(!v.view.hasImage);
}
