# Unit tests. Each test program runs every TEST in its source file; ctest runs
# all of them:   cmake --build build && ctest --test-dir build --output-on-failure

function(pv_add_test name)
    add_executable(${name} ${ARGN} TestMain.cpp)
    target_link_libraries(${name} PRIVATE PreviewViewerCore)
    add_test(NAME ${name} COMMAND ${name})
endfunction()

# Plain C++ logic.
pv_add_test(test_imagelist test_imagelist.cpp)
pv_add_test(test_imageloading test_imageloading.cpp)
pv_add_test(test_thumbnailcache test_thumbnailcache.cpp)

# AppKit: these open real (briefly visible) windows.
pv_add_test(test_viewer test_viewer.mm)
pv_add_test(test_app test_app.mm)
set_tests_properties(test_app PROPERTIES TIMEOUT 120)

# The built app bundle: Info.plist and code signature.
pv_add_test(test_bundle test_bundle.mm)
add_dependencies(test_bundle PreviewViewer)
target_compile_definitions(test_bundle PRIVATE
    APP_BUNDLE_PATH="$<TARGET_BUNDLE_DIR:PreviewViewer>")
