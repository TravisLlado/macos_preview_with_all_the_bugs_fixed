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

- [x] **Phase 2 – Folder loading**
  - File → Open shows an NSOpenPanel for choosing a folder.
  - C++ code lists image files by extension (jpg, jpeg, png, heic, heif, tif, tiff, gif, webp, bmp), case-insensitive, sorted by filename using natural sort (img2 before img10).

- [x] **Phase 3 – Main viewer**
  - NSImageView inside an NSScrollView with allowsMagnification = YES (pinch-zoom works).
  - Load full images with ImageIO, honoring EXIF orientation.
  - View menu: Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Zoom to Fit (Cmd 9).
  - New images open at zoom-to-fit. Center the image when it is smaller than the view.

- [x] **Phase 4 – Sidebar**
  - View-based NSTableView inside an NSScrollView, one row per image: thumbnail with the filename centered below it, like classic Preview.
  - Selecting a row shows that image in the viewer. Up/down arrow keys change the selection.
  - First image is selected automatically after opening a folder.

- [x] **Phase 5 – Background thumbnails**
  - Generate thumbnails with CGImageSourceCreateThumbnailAtIndex (max dimension 256px, kCGImageSourceCreateThumbnailWithTransform = true) on a background dispatch queue.
  - Show a placeholder until each thumbnail is ready; update the row on the main thread.
  - Cache thumbnails in memory keyed by file path. Only request thumbnails for visible or nearly visible rows.
  - Opening a folder of 1000+ images must not freeze the UI.

- [x] **Phase 6 – Polish**
  - Persist window frame and sidebar width between launches.
  - Support opening a single image from Finder (Open With, or dragging onto the Dock icon): load its containing folder and select that file. Add the needed document types to Info.plist.
  - *Revised after Phase 6:* each set of opened images gets its own window (the empty launch window is reused for the first set). The sidebar is hidden only when a window shows exactly one image (the empty launch window shows it); there is no user control for it. Finder can deliver one multi-file Open With as several requests, so requests arriving within 0.3 s are combined into one set. Closing the last window quits.
  - *Revised after Phase 6:* a file is never open in two windows. Opening a set leaves out images already open elsewhere (compared by canonical path); if all are already open, the window with the first one comes to the front.
  - *Revised after Phase 6:* nothing is remembered between launches (window frame and sidebar width persistence removed).
  - *Revised after Phase 6:* opening files (File → Open with multiple selection, Finder Open With, Dock drops) shows exactly the chosen images, not their whole folder. Choosing a folder still shows all of its images.

## Notes for future sessions

All six phases are complete.

- The app target and bundle are named `PreviewViewer` (`build/PreviewViewer.app`).
- Source layout (`src/`):
  - `main.mm`, `AppDelegate.mm`: app startup, menu bar, window list, File → Open,
    Finder "Open With" / Dock drops (`openImagesAtURLs:` picks or creates the window).
  - `MainWindowController.mm`: one window: split view, sidebar table, thumbnail
    requests, opening images (`openURLs:` takes any mix of files and folders).
  - `ImageScrollView.mm`: magnifiable viewer, centering clip view, zoom commands.
  - `ImageList.cpp` (C++): extension filter, natural sort, `collectImages` (folders →
    images, canonical paths, dedupe).
  - `ImageLoading.cpp` (C++): ImageIO decode with EXIF orientation (full size and thumbnails).
  - `ThumbnailCache.cpp` (C++): main-thread cache keyed by file path.
- Guiding rule: behave like macOS Preview, minimally. Where this plan and Preview
  disagree, follow Preview. The app keeps no state between launches.
- Behavior choices worth knowing:
  - Zoom to Fit never enlarges past 100%, so small images show at actual size, centered.
    The viewer stays fitted while the window resizes until another zoom is chosen.
  - The thumbnail cache is cleared whenever a new set of images is opened.
  - Opened images are sorted together by filename (natural sort), even across folders.
  - Info.plist claims the image types at `LSHandlerRank` `Alternate` (listed in
    Open With, not the default handler).
