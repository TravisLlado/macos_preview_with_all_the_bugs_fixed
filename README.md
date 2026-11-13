# macos_preview_with_all_the_bugs_fixed

A minimal image viewer for macOS, modeled on classic Preview.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- CMake 3.20 or later (`brew install cmake`)

## Build and run

```sh
cmake -B build
cmake --build build
open build/PreviewViewer.app
```

## Usage

- **File → Open…** (Cmd-O) and choose one or more images, or a folder. Exactly the chosen images open in a new window; a folder brings in all of its images. A single image fills the window; with several, a thumbnail sidebar is shown. Images that are already open in another window are not opened again.
- Click a thumbnail or use the up/down arrow keys to switch images.
- **View** menu: Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Zoom to Fit (Cmd 9). Pinch to zoom on a trackpad.
- In Finder, select one or more images and use **Open With → PreviewViewer** (or drop them on the Dock icon) to view exactly those images.

See [docs/PLAN.md](docs/PLAN.md) for the development plan and progress.
