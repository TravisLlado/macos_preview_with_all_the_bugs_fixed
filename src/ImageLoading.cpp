#include "ImageLoading.h"

#include <ImageIO/ImageIO.h>

#include <algorithm>

namespace {

int intProperty(CFDictionaryRef dict, CFStringRef key) {
    int value = 0;
    auto number = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, key));
    if (number) {
        CFNumberGetValue(number, kCFNumberIntType, &value);
    }
    return value;
}

// Longer side of the stored (un-rotated) image, in pixels; 0 if unknown.
int pixelSizeOf(CGImageSourceRef source) {
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    if (!props) {
        return 0;
    }
    int size = std::max(intProperty(props, kCGImagePropertyPixelWidth),
                        intProperty(props, kCGImagePropertyPixelHeight));
    CFRelease(props);
    return size;
}

}  // namespace

namespace imageio {

CGImageRef createImage(const std::string& path, int maxPixelSize) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8*>(path.data()), static_cast<CFIndex>(path.size()), false);
    if (!url) {
        return nullptr;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) {
        return nullptr;
    }

    // For a full-size image, ask for a "thumbnail" as large as the image
    // itself: this is the simplest way to get ImageIO to apply the EXIF
    // orientation transform for us.
    if (maxPixelSize <= 0) {
        maxPixelSize = pixelSizeOf(source);
    }

    CGImageRef image = nullptr;
    if (maxPixelSize > 0) {
        CFNumberRef sizeNumber = CFNumberCreate(nullptr, kCFNumberIntType, &maxPixelSize);
        const void* keys[] = {
            kCGImageSourceCreateThumbnailFromImageAlways,  // ignore small embedded previews
            kCGImageSourceCreateThumbnailWithTransform,    // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately,  // decode now, on this thread
        };
        const void* values[] = {kCFBooleanTrue, kCFBooleanTrue, sizeNumber, kCFBooleanTrue};
        CFDictionaryRef options =
            CFDictionaryCreate(nullptr, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                               &kCFTypeDictionaryValueCallBacks);
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, options);
        CFRelease(options);
        CFRelease(sizeNumber);
    }
    CFRelease(source);
    return image;
}

}  // namespace imageio
