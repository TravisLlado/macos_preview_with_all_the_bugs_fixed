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

- **File → Open…** (Cmd-O) and choose a folder. Its images appear in the sidebar.
- Click a thumbnail or use the up/down arrow keys to switch images.
- **View** menu: Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Zoom to Fit (Cmd 9). Pinch to zoom on a trackpad.
- In Finder, use **Open With → PreviewViewer** on an image (or drop one on the Dock icon) to open its folder with that image selected.

See [docs/PLAN.md](docs/PLAN.md) for the development plan and progress.
