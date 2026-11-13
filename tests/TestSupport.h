#pragma once

// A deliberately tiny test framework (no dependencies), plus helpers shared by
// the test programs: temporary folders and generated test images.
//
//   TEST(name) { CHECK(x); CHECK_EQ(a, b); REQUIRE(y); }
//
// Each test program links TestMain.cpp, which runs every TEST in the file.
// Pass a substring as the first argument to run only matching tests.

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <sstream>
#include <string>
#include <vector>

namespace test {

struct Case {
    const char* name;
    void (*fn)();
};

inline std::vector<Case>& registry() {
    static std::vector<Case> cases;
    return cases;
}

inline int& failureCount() {
    static int count = 0;
    return count;
}

struct Registrar {
    Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

inline void fail(const char* file, int line, const std::string& message) {
    std::fprintf(stderr, "    FAIL %s:%d: %s\n", std::filesystem::path(file).filename().c_str(), line,
                 message.c_str());
    ++failureCount();
}

template <class T>
std::string describe(const T& value) {
    std::ostringstream out;
    out << value;
    return out.str();
}

template <class A, class B>
bool checkEqual(const A& actual, const B& expected, const char* actualText, const char* expectedText,
                const char* file, int line) {
    if (actual == expected) {
        return true;
    }
    fail(file, line,
         std::string(actualText) + " == " + expectedText + "  (got " + describe(actual) + ", expected " +
             describe(expected) + ")");
    return false;
}

inline int runAll(int argc, char** argv) {
    const char* filter = argc > 1 ? argv[1] : nullptr;
    int run = 0, failedTests = 0;
    for (const Case& c : registry()) {
        if (filter && !std::strstr(c.name, filter)) {
            continue;
        }
        int before = failureCount();
        c.fn();
        bool ok = failureCount() == before;
        std::printf("%s %s\n", ok ? "  ok  " : "  FAIL", c.name);
        std::fflush(stdout);
        ++run;
        failedTests += ok ? 0 : 1;
    }
    std::printf("%d tests, %d failed\n", run, failedTests);
    return failedTests == 0 ? 0 : 1;
}

// ---- Temporary folders ---------------------------------------------------

// A new empty folder under $TMPDIR. The path is returned exactly as created
// (on macOS $TMPDIR lives under /var, a symlink to /private/var), so it is
// *not* canonical; use canonical() for paths the app reports.
inline std::string makeTempDir() {
    std::string pattern = (std::filesystem::temp_directory_path() / "PreviewViewerTests-XXXXXX").string();
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back('\0');
    if (!mkdtemp(buffer.data())) {
        std::perror("mkdtemp");
        std::abort();
    }
    return buffer.data();
}

inline std::string canonical(const std::string& path) {
    return std::filesystem::canonical(path).string();
}

inline void touch(const std::string& path, const std::string& contents = "") {
    FILE* f = std::fopen(path.c_str(), "w");
    if (f) {
        std::fputs(contents.c_str(), f);
        std::fclose(f);
    }
}

// ---- Test images ---------------------------------------------------------

// Writes a w x h test image: light background, a red block in the top-left
// third, a blue bar along the bottom tenth. `type` is a UTI such as
// "public.jpeg"; `orientation` is the EXIF orientation tag (1 = upright).
inline bool writeTestImage(const std::string& path, const char* type, int w, int h, int orientation = 1) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(nullptr, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, 0.9, 0.9, 0.8, 1);
    CGContextFillRect(context, CGRectMake(0, 0, w, h));
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, h - h / 3.0, w / 3.0, h / 3.0));  // CG origin is bottom-left
    CGContextSetRGBFillColor(context, 0, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, w, h / 10.0));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8*>(path.data()), static_cast<CFIndex>(path.size()), false);
    CFStringRef uti = CFStringCreateWithCString(nullptr, type, kCFStringEncodingUTF8);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, uti, 1, nullptr);
    bool ok = false;
    if (destination) {
        CFNumberRef orientationNumber = CFNumberCreate(nullptr, kCFNumberIntType, &orientation);
        const void* keys[] = {kCGImagePropertyOrientation};
        const void* values[] = {orientationNumber};
        CFDictionaryRef props = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        CGImageDestinationAddImage(destination, image, props);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(props);
        CFRelease(orientationNumber);
        CFRelease(destination);
    }
    CFRelease(uti);
    CFRelease(url);
    CGImageRelease(image);
    return ok;
}

struct RGB {
    int r, g, b;
};

// Color of pixel (x, y), with (0, 0) at the top-left of the displayed image.
inline RGB pixelAt(CGImageRef image, int x, int y) {
    int w = static_cast<int>(CGImageGetWidth(image));
    int h = static_cast<int>(CGImageGetHeight(image));
    std::vector<unsigned char> data(static_cast<size_t>(w) * h * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(data.data(), w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    const unsigned char* p = &data[(static_cast<size_t>(y) * w + x) * 4];  // row 0 is the top row
    return {p[0], p[1], p[2]};
}

inline bool isRed(RGB c) { return c.r > 180 && c.g < 90 && c.b < 90; }
inline bool isBlue(RGB c) { return c.b > 180 && c.r < 90 && c.g < 90; }

}  // namespace test

#define TEST(name)                                            \
    static void name();                                       \
    static test::Registrar name##_registrar(#name, name);     \
    static void name()

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) test::fail(__FILE__, __LINE__, "CHECK(" #cond ")"); \
    } while (0)

#define REQUIRE(cond)                                                     \
    do {                                                                  \
        if (!(cond)) {                                                    \
            test::fail(__FILE__, __LINE__, "REQUIRE(" #cond ")");         \
            return;                                                       \
        }                                                                 \
    } while (0)

#define CHECK_EQ(actual, expected) test::checkEqual((actual), (expected), #actual, #expected, __FILE__, __LINE__)
