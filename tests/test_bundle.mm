// The built app bundle: Info.plist settings and code signature.

#import <Foundation/Foundation.h>

#include "TestSupport.h"

#include <array>
#include <cstdio>
#include <memory>

namespace {

NSDictionary* infoPlist() {
    NSString* path = [@APP_BUNDLE_PATH stringByAppendingPathComponent:@"Contents/Info.plist"];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

std::string run(const std::string& command) {
    std::string output;
    std::array<char, 512> buffer;
    std::unique_ptr<FILE, int (*)(FILE*)> pipe(popen(command.c_str(), "r"), pclose);
    while (pipe && fgets(buffer.data(), buffer.size(), pipe.get())) output += buffer.data();
    return output;
}

std::string str(id value) {
    return [value isKindOfClass:NSString.class] ? std::string([value UTF8String]) : std::string("(missing)");
}

}  // namespace

TEST(bundle_identity) {
    NSDictionary* info = infoPlist();
    REQUIRE(info != nil);
    CHECK_EQ(str(info[@"CFBundleIdentifier"]), std::string("com.local.previewviewer"));
    CHECK_EQ(str(info[@"CFBundleExecutable"]), std::string("PreviewViewer"));
    CHECK_EQ(str(info[@"CFBundleName"]), std::string("PreviewViewer"));
    CHECK_EQ(str(info[@"CFBundlePackageType"]), std::string("APPL"));
    CHECK_EQ(str(info[@"NSPrincipalClass"]), std::string("NSApplication"));
}

TEST(requires_macos_13) {
    CHECK_EQ(str(infoPlist()[@"LSMinimumSystemVersion"]), std::string("13.0"));
}

TEST(listed_in_open_with_for_supported_images_but_not_the_default) {
    NSArray* types = infoPlist()[@"CFBundleDocumentTypes"];
    REQUIRE(types.count == 1);
    NSDictionary* type = types[0];
    CHECK_EQ(str(type[@"CFBundleTypeRole"]), std::string("Viewer"));
    CHECK_EQ(str(type[@"LSHandlerRank"]), std::string("Alternate"));
    NSSet* expected = [NSSet setWithArray:@[ @"public.jpeg", @"public.png", @"public.heic", @"public.heif",
                                              @"public.tiff", @"com.compuserve.gif", @"org.webmproject.webp",
                                              @"com.microsoft.bmp" ]];
    CHECK([[NSSet setWithArray:type[@"LSItemContentTypes"]] isEqualToSet:expected]);
}

TEST(not_sandboxed) {
    std::string entitlements = run("codesign -d --entitlements - '" APP_BUNDLE_PATH "' 2>&1");
    CHECK(entitlements.find("app-sandbox") == std::string::npos);
}
