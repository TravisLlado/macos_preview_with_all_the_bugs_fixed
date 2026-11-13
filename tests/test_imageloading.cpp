// Image decoding (ImageLoading): EXIF orientation, thumbnails, failures.

#include "ImageLoading.h"
#include "TestSupport.h"

#include <algorithm>
#include <filesystem>

namespace fs = std::filesystem;

namespace {

struct Image {
    CGImageRef ref = nullptr;
    explicit Image(CGImageRef r) : ref(r) {}
    ~Image() { CGImageRelease(ref); }
    int width() const { return static_cast<int>(CGImageGetWidth(ref)); }
    int height() const { return static_cast<int>(CGImageGetHeight(ref)); }
};

std::string tempImage(const char* name, const char* type, int w, int h, int orientation = 1) {
    static std::string dir = test::makeTempDir();
    std::string path = dir + "/" + name;
    if (!test::writeTestImage(path, type, w, h, orientation)) {
        std::fprintf(stderr, "could not write %s\n", path.c_str());
    }
    return path;
}

}  // namespace

TEST(decodes_full_size_upright_image) {
    Image img(imageio::createImage(tempImage("up.jpg", "public.jpeg", 400, 300)));
    REQUIRE(img.ref);
    CHECK_EQ(img.width(), 400);
    CHECK_EQ(img.height(), 300);
    CHECK(test::isRed(test::pixelAt(img.ref, 20, 20)));    // red block top-left
    CHECK(test::isBlue(test::pixelAt(img.ref, 200, 295))); // blue bar along the bottom
}

TEST(applies_exif_orientation_rotate_90) {
    // Orientation 6: stored landscape, displayed rotated 90° clockwise.
    Image img(imageio::createImage(tempImage("rot90.jpg", "public.jpeg", 400, 300, 6)));
    REQUIRE(img.ref);
    CHECK_EQ(img.width(), 300);
    CHECK_EQ(img.height(), 400);
    CHECK(test::isRed(test::pixelAt(img.ref, 280, 20)));   // red block now top-right
    CHECK(test::isBlue(test::pixelAt(img.ref, 5, 200)));   // blue bar now on the left
}

TEST(applies_exif_orientation_rotate_180) {
    Image img(imageio::createImage(tempImage("rot180.jpg", "public.jpeg", 400, 300, 3)));
    REQUIRE(img.ref);
    CHECK_EQ(img.width(), 400);
    CHECK_EQ(img.height(), 300);
    CHECK(test::isRed(test::pixelAt(img.ref, 380, 280)));  // red block now bottom-right
    CHECK(test::isBlue(test::pixelAt(img.ref, 200, 5)));   // blue bar now on top
}

TEST(thumbnail_longest_side_is_at_most_256) {
    Image img(imageio::createImage(tempImage("big.jpg", "public.jpeg", 6000, 4000), 256));
    REQUIRE(img.ref);
    CHECK_EQ(std::max(img.width(), img.height()), 256);
    CHECK(img.width() > img.height());  // aspect ratio kept
}

TEST(thumbnail_applies_exif_orientation) {
    Image img(imageio::createImage(tempImage("rot90_thumb.jpg", "public.jpeg", 4000, 3000, 6), 256));
    REQUIRE(img.ref);
    CHECK_EQ(img.height(), 256);
    CHECK(img.width() < img.height());
}

TEST(thumbnail_never_enlarges_small_images) {
    Image img(imageio::createImage(tempImage("tiny.png", "public.png", 100, 50), 256));
    REQUIRE(img.ref);
    CHECK_EQ(img.width(), 100);
    CHECK_EQ(img.height(), 50);
}

TEST(decodes_each_writable_format) {
    // WebP can be read by ImageIO but not written, so it has no generated sample.
    const char* types[][2] = {{"a.png", "public.png"},        {"a.heic", "public.heic"},
                              {"a.tiff", "public.tiff"},      {"a.gif", "com.compuserve.gif"},
                              {"a.bmp", "com.microsoft.bmp"}, {"a.jpeg", "public.jpeg"}};
    for (auto& t : types) {
        Image img(imageio::createImage(tempImage(t[0], t[1], 64, 48)));
        if (!img.ref) {
            test::fail(__FILE__, __LINE__, std::string("could not decode ") + t[0]);
            continue;
        }
        CHECK_EQ(img.width(), 64);
    }
}

TEST(broken_or_missing_files_return_null) {
    std::string dir = test::makeTempDir();
    test::touch(dir + "/broken.jpg", "this is not an image");
    CHECK(imageio::createImage(dir + "/broken.jpg") == nullptr);
    CHECK(imageio::createImage(dir + "/broken.jpg", 256) == nullptr);
    CHECK(imageio::createImage(dir + "/missing.jpg") == nullptr);
    fs::remove_all(dir);
}
