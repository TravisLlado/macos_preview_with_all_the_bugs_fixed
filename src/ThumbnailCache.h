#pragma once

// In-memory thumbnail cache keyed by file path. Plain C++17.
// Not thread-safe: use it from the main thread only (thumbnails are decoded
// elsewhere and handed to insert() on the main thread).

#include <CoreGraphics/CoreGraphics.h>

#include <string>
#include <unordered_map>
#include <unordered_set>

class ThumbnailCache {
public:
    ThumbnailCache() = default;
    ~ThumbnailCache();
    ThumbnailCache(const ThumbnailCache&) = delete;
    ThumbnailCache& operator=(const ThumbnailCache&) = delete;

    // The cached thumbnail (not retained for the caller), or nullptr if not
    // cached yet or if decoding failed.
    CGImageRef find(const std::string& path) const;

    // Stores a thumbnail (retained), or nullptr to remember that decoding
    // failed so it is not retried. Also clears the path's pending flag.
    void insert(const std::string& path, CGImageRef image);

    // Marks `path` as being generated. Returns false if it is already cached
    // or already pending, i.e. no new request should be started.
    bool beginRequest(const std::string& path);

    // Clears the pending flag without caching anything (request abandoned).
    void cancelRequest(const std::string& path);

    // Releases every thumbnail and forgets pending requests.
    void clear();

private:
    std::unordered_map<std::string, CGImageRef> images_;
    std::unordered_set<std::string> pending_;
};
