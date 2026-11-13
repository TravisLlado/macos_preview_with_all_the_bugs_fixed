// Folder listing and sorting (ImageList).

#include "ImageList.h"
#include "TestSupport.h"

#include <filesystem>

#include <sys/attr.h>
#include <sys/time.h>
#include <unistd.h>

namespace fs = std::filesystem;
using imagelist::collectImages;
using imagelist::hasImageExtension;
using imagelist::listImages;
using imagelist::naturalCompare;
using imagelist::sortByFilename;
using imagelist::sortImages;
using imagelist::SortOrder;

static std::vector<std::string> filenames(const std::vector<std::string>& paths) {
    std::vector<std::string> names;
    for (const std::string& p : paths) names.push_back(fs::path(p).filename().string());
    return names;
}

static std::string join(const std::vector<std::string>& items) {
    std::string out;
    for (const std::string& s : items) out += (out.empty() ? "" : ",") + s;
    return out;
}

// --- Supported extensions -------------------------------------------------

TEST(recognizes_all_ten_supported_extensions) {
    for (const char* ext : {"jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"}) {
        CHECK(hasImageExtension(std::string("photo.") + ext));
    }
}

TEST(extension_match_is_case_insensitive) {
    CHECK(hasImageExtension("IMG_0001.JPG"));
    CHECK(hasImageExtension("a.HeIc"));
    CHECK(hasImageExtension("b.TIFF"));
}

TEST(rejects_other_files) {
    CHECK(!hasImageExtension("notes.txt"));
    CHECK(!hasImageExtension("photo.jpg.txt"));
    CHECK(!hasImageExtension("jpg"));          // no extension at all
    CHECK(!hasImageExtension(".jpg"));         // only an extension
    CHECK(!hasImageExtension("raw.cr3"));      // camera RAW is not (yet) supported
    CHECK(!hasImageExtension("movie.mov"));
}

// --- Natural sort ---------------------------------------------------------

TEST(natural_sort_orders_numbers_by_value) {
    CHECK(naturalCompare("img2", "img10") < 0);
    CHECK(naturalCompare("img10", "img2") > 0);
    CHECK(naturalCompare("img9.jpg", "img10.jpg") < 0);
    CHECK(naturalCompare("IMG_0099", "IMG_0100") < 0);
}

TEST(natural_sort_ignores_letter_case) {
    CHECK_EQ(naturalCompare("IMG2", "img2"), 0);
    CHECK(naturalCompare("apple", "Banana") < 0);
}

TEST(natural_sort_treats_leading_zeros_as_the_same_number) {
    CHECK_EQ(naturalCompare("img002", "img2"), 0);
}

TEST(natural_sort_handles_numbers_too_long_for_an_integer) {
    CHECK(naturalCompare("img99999999999999999999", "img100000000000000000000") < 0);
}

TEST(natural_sort_puts_a_prefix_first) {
    CHECK(naturalCompare("img", "img1") < 0);
    CHECK(naturalCompare("img1", "img1a") < 0);
}

TEST(sort_by_filename_ignores_the_folder) {
    std::vector<std::string> paths = {"/a/img10.jpg", "/z/img2.jpg", "/m/img1.jpg"};
    sortByFilename(paths);
    CHECK_EQ(join(paths), std::string("/m/img1.jpg,/z/img2.jpg,/a/img10.jpg"));
}

TEST(sort_by_filename_removes_duplicates) {
    std::vector<std::string> paths = {"/a/x.jpg", "/a/y.jpg", "/a/x.jpg"};
    sortByFilename(paths);
    CHECK_EQ(join(paths), std::string("/a/x.jpg,/a/y.jpg"));
}

TEST(sort_by_filename_breaks_ties_deterministically) {
    std::vector<std::string> a = {"/d/img1.jpg", "/d/img01.jpg", "/d/IMG1.jpg"};
    std::vector<std::string> b = {"/d/IMG1.jpg", "/d/img1.jpg", "/d/img01.jpg"};
    sortByFilename(a);
    sortByFilename(b);
    CHECK_EQ(join(a), join(b));
}

// --- Folder listing -------------------------------------------------------

TEST(list_images_filters_hidden_and_non_image_files) {
    std::string dir = test::makeTempDir();
    for (const char* name : {"img10.jpg", "img2.JPG", "img1.png", "a.txt", ".hidden.jpg", "._img5.jpg",
                             "noext", "photo.webp"}) {
        test::touch(dir + "/" + name);
    }
    fs::create_directory(dir + "/folder.jpg");  // a folder named like an image
    test::touch(dir + "/folder.jpg/inner.jpg");  // not listed: listing is not recursive

    CHECK_EQ(join(filenames(listImages(dir))), std::string("img1.png,img2.JPG,img10.jpg,photo.webp"));
    fs::remove_all(dir);
}

TEST(list_images_of_missing_folder_is_empty) {
    CHECK(listImages("/nonexistent/folder/for/sure").empty());
}

// --- Collecting opened files and folders -----------------------------------

TEST(collect_expands_folders_and_keeps_files) {
    std::string dir = test::makeTempDir();
    fs::create_directory(dir + "/sub");
    test::touch(dir + "/sub/b2.jpg");
    test::touch(dir + "/sub/b10.jpg");
    test::touch(dir + "/a1.png");
    std::vector<std::string> result = collectImages({dir + "/sub", dir + "/a1.png"});
    CHECK_EQ(join(filenames(result)), std::string("a1.png,b2.jpg,b10.jpg"));
    fs::remove_all(dir);
}

TEST(collect_returns_canonical_paths) {
    // $TMPDIR is under /var, which is a symlink to /private/var.
    std::string dir = test::makeTempDir();
    test::touch(dir + "/x.jpg");
    std::vector<std::string> result = collectImages({dir + "/x.jpg"});
    REQUIRE(result.size() == 1);
    CHECK_EQ(result[0], test::canonical(dir + "/x.jpg"));
    fs::remove_all(dir);
}

TEST(collect_treats_the_same_file_via_different_paths_as_one) {
    std::string dir = test::makeTempDir();
    fs::create_directory(dir + "/real");
    test::touch(dir + "/real/x.jpg");
    test::touch(dir + "/real/y.jpg");
    fs::create_directory_symlink(dir + "/real", dir + "/link");
    std::vector<std::string> result =
        collectImages({dir + "/real/x.jpg", dir + "/link/x.jpg", dir + "/link", dir + "/real/x.jpg"});
    CHECK_EQ(join(filenames(result)), std::string("x.jpg,y.jpg"));
    fs::remove_all(dir);
}

TEST(collect_keeps_explicitly_chosen_files_even_if_unreadable) {
    // Files chosen directly are passed through; they show a placeholder later.
    std::vector<std::string> result = collectImages({"/nonexistent/missing.jpg"});
    CHECK_EQ(result.size(), size_t(1));
}

// --- Sort By (name, creation date, modification date) -----------------------

static void setDates(const std::string& path, time_t created, time_t modified) {
    // Modification time first: on APFS an mtime earlier than the creation time
    // also moves the creation time back.
    struct timeval times[2] = {{modified, 0}, {modified, 0}};  // access, modification
    utimes(path.c_str(), times);
    struct attrlist attrs = {};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_CRTIME;
    struct timespec createdTime = {created, 0};
    setattrlist(path.c_str(), &attrs, &createdTime, sizeof createdTime, 0);
}

// Three files whose name, creation and modification orders all differ.
static std::string datedFolder() {
    std::string dir = test::makeTempDir();
    test::touch(dir + "/b.jpg");
    test::touch(dir + "/a.jpg");
    test::touch(dir + "/c.jpg");
    setDates(dir + "/a.jpg", 1000000300, 1000000100);  // created last,   modified first
    setDates(dir + "/b.jpg", 1000000100, 1000000200);  // created first,  modified second
    setDates(dir + "/c.jpg", 1000000200, 1000000300);  // created second, modified last
    return dir;
}

TEST(sort_by_name) {
    std::string dir = datedFolder();
    std::vector<std::string> paths = {dir + "/c.jpg", dir + "/a.jpg", dir + "/b.jpg"};
    sortImages(paths, SortOrder::Name);
    CHECK_EQ(join(filenames(paths)), std::string("a.jpg,b.jpg,c.jpg"));
    fs::remove_all(dir);
}

TEST(sort_by_date_created_oldest_first) {
    std::string dir = datedFolder();
    std::vector<std::string> paths = {dir + "/a.jpg", dir + "/b.jpg", dir + "/c.jpg"};
    sortImages(paths, SortOrder::DateCreated);
    CHECK_EQ(join(filenames(paths)), std::string("b.jpg,c.jpg,a.jpg"));
    fs::remove_all(dir);
}

TEST(sort_by_date_modified_oldest_first) {
    std::string dir = datedFolder();
    std::vector<std::string> paths = {dir + "/c.jpg", dir + "/b.jpg", dir + "/a.jpg"};
    sortImages(paths, SortOrder::DateModified);
    CHECK_EQ(join(filenames(paths)), std::string("a.jpg,b.jpg,c.jpg"));
    fs::remove_all(dir);
}

TEST(equal_dates_fall_back_to_name_order) {
    std::string dir = test::makeTempDir();
    for (const char* name : {"img10.jpg", "img2.jpg", "img1.jpg"}) {
        test::touch(dir + "/" + name);
        setDates(dir + "/" + name, 1000000000, 1000000000);
    }
    std::vector<std::string> paths = {dir + "/img10.jpg", dir + "/img2.jpg", dir + "/img1.jpg"};
    sortImages(paths, SortOrder::DateModified);
    CHECK_EQ(join(filenames(paths)), std::string("img1.jpg,img2.jpg,img10.jpg"));
    fs::remove_all(dir);
}
