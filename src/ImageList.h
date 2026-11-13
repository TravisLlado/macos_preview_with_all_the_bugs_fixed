#pragma once

// Folder listing and filename sorting. Plain C++17, no AppKit.

#include <string>
#include <vector>

namespace imagelist {

// True if the filename ends in a supported image extension (case-insensitive):
// jpg, jpeg, png, heic, heif, tif, tiff, gif, webp, bmp.
bool hasImageExtension(const std::string& filename);

// Natural ("human") comparison: digit runs compare by numeric value, so
// "img2" < "img10". Letters compare case-insensitively.
// Returns <0, 0, or >0 like strcmp.
int naturalCompare(const std::string& a, const std::string& b);

// Sorts full paths by filename with naturalCompare (full path breaks ties)
// and removes duplicates.
void sortByFilename(std::vector<std::string>& paths);

// Full paths of the image files directly inside `directory` (not recursive,
// hidden files skipped), sorted with sortByFilename.
// Returns an empty list if the directory cannot be read.
std::vector<std::string> listImages(const std::string& directory);

}  // namespace imagelist
