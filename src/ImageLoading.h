#pragma once

// Image decoding with ImageIO. Plain C++17; safe to call from any thread.

#include <CoreGraphics/CoreGraphics.h>

#include <string>

namespace imageio {

// Decodes the first image in the file at `path`, rotated/flipped according to
// its EXIF orientation. If `maxPixelSize` > 0 the result is scaled down so its
// longer side is at most that many pixels (a thumbnail); if 0 the image is
// decoded at full resolution.
//
// Returns a +1 reference the caller must CGImageRelease, or nullptr on failure.
CGImageRef createImage(const std::string& path, int maxPixelSize = 0);

}  // namespace imageio
