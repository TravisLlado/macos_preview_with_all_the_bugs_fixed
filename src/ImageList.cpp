#include "ImageList.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <system_error>

namespace fs = std::filesystem;

namespace {

const std::array<const char*, 10> kImageExtensions = {
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp",
};

bool isDigit(char c) { return c >= '0' && c <= '9'; }

int lower(char c) { return std::tolower(static_cast<unsigned char>(c)); }

}  // namespace

namespace imagelist {

bool hasImageExtension(const std::string& filename) {
    size_t dot = filename.rfind('.');
    if (dot == std::string::npos || dot == 0) {
        return false;
    }
    std::string ext = filename.substr(dot + 1);
    for (char& c : ext) {
        c = static_cast<char>(lower(c));
    }
    return std::find(kImageExtensions.begin(), kImageExtensions.end(), ext) != kImageExtensions.end();
}

int naturalCompare(const std::string& a, const std::string& b) {
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        if (isDigit(a[i]) && isDigit(b[j])) {
            // Compare whole digit runs by numeric value without converting
            // (so arbitrarily long numbers work): skip leading zeros, then a
            // longer run is larger, and equal-length runs compare digit by digit.
            size_t startA = i, startB = j;
            while (i < a.size() && isDigit(a[i])) ++i;
            while (j < b.size() && isDigit(b[j])) ++j;
            while (startA + 1 < i && a[startA] == '0') ++startA;
            while (startB + 1 < j && b[startB] == '0') ++startB;
            size_t lenA = i - startA, lenB = j - startB;
            if (lenA != lenB) {
                return lenA < lenB ? -1 : 1;
            }
            int c = a.compare(startA, lenA, b, startB, lenB);
            if (c != 0) {
                return c < 0 ? -1 : 1;
            }
        } else {
            int ca = lower(a[i]), cb = lower(b[j]);
            if (ca != cb) {
                return ca < cb ? -1 : 1;
            }
            ++i;
            ++j;
        }
    }
    if (i < a.size()) return 1;
    if (j < b.size()) return -1;
    return 0;
}

void sortByFilename(std::vector<std::string>& paths) {
    // Extract each filename once rather than on every comparison.
    std::vector<std::pair<std::string, std::string>> entries;  // (filename, path)
    entries.reserve(paths.size());
    for (std::string& path : paths) {
        std::string name = fs::path(path).filename().string();
        entries.emplace_back(std::move(name), std::move(path));
    }
    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
        int c = naturalCompare(a.first, b.first);
        return c != 0 ? c < 0 : a.second < b.second;  // tie-break ("img01" vs "img1") for a stable order
    });

    paths.clear();
    for (auto& entry : entries) {
        if (paths.empty() || paths.back() != entry.second) {  // drop duplicates
            paths.push_back(std::move(entry.second));
        }
    }
}

std::vector<std::string> listImages(const std::string& directory) {
    std::vector<std::string> paths;
    std::error_code ec;
    for (fs::directory_iterator it(directory, ec), end; !ec && it != end; it.increment(ec)) {
        std::string name = it->path().filename().string();
        if (name.empty() || name[0] == '.') {
            continue;  // hidden files, including macOS "._" metadata files
        }
        std::error_code typeEc;
        if (!it->is_regular_file(typeEc) || !hasImageExtension(name)) {
            continue;
        }
        paths.push_back(it->path().string());
    }
    sortByFilename(paths);
    return paths;
}

std::vector<std::string> collectImages(const std::vector<std::string>& paths) {
    auto canonical = [](const std::string& path) {
        std::error_code ec;
        fs::path resolved = fs::canonical(path, ec);
        return ec ? path : resolved.string();
    };

    std::vector<std::string> images;
    for (const std::string& input : paths) {
        std::string path = canonical(input);
        std::error_code ec;
        if (fs::is_directory(path, ec)) {
            for (const std::string& image : listImages(path)) {
                images.push_back(canonical(image));
            }
        } else {
            images.push_back(path);
        }
    }
    sortByFilename(images);
    return images;
}

}  // namespace imagelist
