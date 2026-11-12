cmake_minimum_required(VERSION 3.20)

# Must be set before project() to take effect.
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")

project(PreviewViewer LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

add_executable(PreviewViewer MACOSX_BUNDLE
    src/main.mm
    src/AppDelegate.mm
    src/MainWindowController.mm
    src/ImageScrollView.mm
    src/ImageList.cpp
    src/ImageLoading.cpp
    src/ThumbnailCache.cpp
)

set_target_properties(PreviewViewer PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist.in"
)

target_compile_options(PreviewViewer PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    -Wall -Wextra
)

target_link_libraries(PreviewViewer PRIVATE
    "-framework AppKit"
    "-framework ImageIO"
    "-framework CoreGraphics"
    "-framework UniformTypeIdentifiers"
)
