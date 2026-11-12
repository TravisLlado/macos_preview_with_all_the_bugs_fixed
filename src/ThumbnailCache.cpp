#include "ThumbnailCache.h"

ThumbnailCache::~ThumbnailCache() {
    clear();
}

CGImageRef ThumbnailCache::find(const std::string& path) const {
    auto it = images_.find(path);
    return it == images_.end() ? nullptr : it->second;
}

void ThumbnailCache::insert(const std::string& path, CGImageRef image) {
    pending_.erase(path);
    CGImageRetain(image);  // CGImageRetain/Release accept nullptr
    auto [it, inserted] = images_.emplace(path, image);
    if (!inserted) {
        CGImageRelease(it->second);
        it->second = image;
    }
}

bool ThumbnailCache::beginRequest(const std::string& path) {
    if (images_.count(path) != 0) {
        return false;
    }
    return pending_.insert(path).second;
}

void ThumbnailCache::cancelRequest(const std::string& path) {
    pending_.erase(path);
}

void ThumbnailCache::clear() {
    for (auto& entry : images_) {
        CGImageRelease(entry.second);
    }
    images_.clear();
    pending_.clear();
}
