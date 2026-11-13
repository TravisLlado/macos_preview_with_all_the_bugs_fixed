// In-memory thumbnail cache keyed by file path (ThumbnailCache).

#include "TestSupport.h"
#include "ThumbnailCache.h"

namespace {

CGImageRef makeImage() {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(nullptr, 4, 4, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

}  // namespace

TEST(empty_cache_finds_nothing) {
    ThumbnailCache cache;
    CHECK(cache.find("/a.jpg") == nullptr);
}

TEST(stores_thumbnails_by_path) {
    ThumbnailCache cache;
    CGImageRef a = makeImage();
    CGImageRef b = makeImage();
    cache.insert("/a.jpg", a);
    cache.insert("/b.jpg", b);
    CHECK(cache.find("/a.jpg") == a);
    CHECK(cache.find("/b.jpg") == b);
    CHECK(cache.find("/c.jpg") == nullptr);
    CGImageRelease(a);
    CGImageRelease(b);
}

TEST(only_one_request_per_path_at_a_time) {
    ThumbnailCache cache;
    CHECK(cache.beginRequest("/a.jpg"));
    CHECK(!cache.beginRequest("/a.jpg"));  // already pending
    CHECK(cache.beginRequest("/b.jpg"));   // other paths unaffected
}

TEST(no_new_request_once_cached) {
    ThumbnailCache cache;
    CGImageRef a = makeImage();
    CHECK(cache.beginRequest("/a.jpg"));
    cache.insert("/a.jpg", a);
    CHECK(!cache.beginRequest("/a.jpg"));
    CGImageRelease(a);
}

TEST(failures_are_remembered_and_not_retried) {
    ThumbnailCache cache;
    CHECK(cache.beginRequest("/broken.jpg"));
    cache.insert("/broken.jpg", nullptr);
    CHECK(cache.find("/broken.jpg") == nullptr);
    CHECK(!cache.beginRequest("/broken.jpg"));
}

TEST(cancelled_requests_can_be_made_again) {
    ThumbnailCache cache;
    CHECK(cache.beginRequest("/a.jpg"));
    cache.cancelRequest("/a.jpg");
    CHECK(cache.beginRequest("/a.jpg"));
}

TEST(clear_forgets_thumbnails_and_pending_requests) {
    ThumbnailCache cache;
    CGImageRef a = makeImage();
    cache.insert("/a.jpg", a);
    CHECK(cache.beginRequest("/b.jpg"));
    cache.clear();
    CHECK(cache.find("/a.jpg") == nullptr);
    CHECK(cache.beginRequest("/a.jpg"));
    CHECK(cache.beginRequest("/b.jpg"));
    CGImageRelease(a);
}

TEST(retains_while_cached_and_releases_on_replace_and_clear) {
    CGImageRef a = makeImage();
    CGImageRef b = makeImage();
    CFIndex baseA = CFGetRetainCount(a);
    CFIndex baseB = CFGetRetainCount(b);
    {
        ThumbnailCache cache;
        cache.insert("/x.jpg", a);
        CHECK_EQ(CFGetRetainCount(a), baseA + 1);
        cache.insert("/x.jpg", b);  // replaces a
        CHECK_EQ(CFGetRetainCount(a), baseA);
        CHECK_EQ(CFGetRetainCount(b), baseB + 1);
        cache.clear();
        CHECK_EQ(CFGetRetainCount(b), baseB);
        cache.insert("/y.jpg", a);
    }  // destructor releases
    CHECK_EQ(CFGetRetainCount(a), baseA);
    CGImageRelease(a);
    CGImageRelease(b);
}
