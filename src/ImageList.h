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

enum class SortOrder {
    Name,          // natural filename order (sortByFilename)
    DateCreated,   // file creation date, oldest first
    DateModified,  // file modification date, oldest first
};

// Sorts full paths by `order`; equal dates fall back to filename order.
// Duplicates are removed. Files whose dates cannot be read sort first.
void sortImages(std::vector<std::string>& paths, SortOrder order);

// Full paths of the image files directly inside `directory` (not recursive,
// hidden files skipped), sorted with sortByFilename.
// Returns an empty list if the directory cannot be read.
std::vector<std::string> listImages(const std::string& directory);

// The images to show for a set of opened paths: each folder contributes the
// images directly inside it, each file is kept as-is. Every path is resolved
// to its canonical form (symlinks, "/tmp" vs "/private/tmp") so the same file
// always has the same path; the result is sorted with sortByFilename, without
// duplicates.
std::vector<std::string> collectImages(const std::vector<std::string>& paths);

}  // namespace imagelist
