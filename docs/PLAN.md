# Development Plan

Implement one phase at a time. After each phase: build, launch the app to verify
it runs, fix any errors, commit, push, and check off the phase here.

## Technical constraints

- Objective-C++ (.mm) with AppKit for all UI; C++17 for non-UI logic (file listing, sorting, caching).
- CMake with `MACOSX_BUNDLE` producing a .app bundle. No Xcode project.
- Info.plist template: bundle ID `com.local.previewviewer`, minimum macOS 13.
- No App Sandbox. ARC (`-fobjc-arc`). No third-party dependencies.
- Links AppKit, ImageIO, CoreGraphics, UniformTypeIdentifiers.
- Build/run: `cmake -B build && cmake --build build && open build/PreviewViewer.app`

## Phases

- [x] **Phase 1 – Skeleton**
  - App delegate creating one resizable window with an NSSplitView: sidebar left (~200px default), main pane right.
  - Standard menu bar: app menu with Quit (Cmd-Q), File menu with Open (Cmd-O), View menu (filled in later), Window menu.

- [ ] **Phase 2 – Folder loading**
  - File → Open shows an NSOpenPanel for choosing a folder.
  - C++ code lists image files by extension (jpg, jpeg, png, heic, heif, tif, tiff, gif, webp, bmp), case-insensitive, sorted by filename using natural sort (img2 before img10).

- [ ] **Phase 3 – Main viewer**
  - NSImageView inside an NSScrollView with allowsMagnification = YES (pinch-zoom works).
  - Load full images with ImageIO, honoring EXIF orientation.
  - View menu: Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Zoom to Fit (Cmd 9).
  - New images open at zoom-to-fit. Center the image when it is smaller than the view.

- [ ] **Phase 4 – Sidebar**
  - View-based NSTableView inside an NSScrollView, one row per image: thumbnail with the filename centered below it, like classic Preview.
  - Selecting a row shows that image in the viewer. Up/down arrow keys change the selection.
  - First image is selected automatically after opening a folder.

- [ ] **Phase 5 – Background thumbnails**
  - Generate thumbnails with CGImageSourceCreateThumbnailAtIndex (max dimension 256px, kCGImageSourceCreateThumbnailWithTransform = true) on a background dispatch queue.
  - Show a placeholder until each thumbnail is ready; update the row on the main thread.
  - Cache thumbnails in memory keyed by file path. Only request thumbnails for visible or nearly visible rows.
  - Opening a folder of 1000+ images must not freeze the UI.

- [ ] **Phase 6 – Polish**
  - Persist window frame and sidebar width between launches.
  - Support opening a single image from Finder (Open With, or dragging onto the Dock icon): load its containing folder and select that file. Add the needed document types to Info.plist.

## Notes for future sessions

- The app target and bundle are named `PreviewViewer` (`build/PreviewViewer.app`).
