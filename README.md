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

## Tests

```sh
cmake --build build
ctest --test-dir build --output-on-failure
```

The unit tests live in `tests/` and use a tiny built-in assertion helper (no Xcode or
third-party frameworks). The app tests open real windows briefly while they run. They
never touch your Trash: the system trash call is replaced with a fake during tests.
Run a single test program directly, optionally filtered by name, e.g.
`./build/tests/test_app trash`.

## Usage

- **File → Open…** (Cmd-O) and choose one or more images, or a folder. Exactly the chosen images open in a new window; a folder brings in all of its images. A single image fills the window; with several, a thumbnail sidebar is shown. Images that are already open in another window are not opened again.
- Click a thumbnail or use the up/down arrow keys to switch images.
- **File → Move to Trash** (Cmd-Delete) moves the image selected in the sidebar to the Trash.
- **Edit → Undo** (Cmd-Z) puts a trashed image back; **Redo** (Shift-Cmd-Z) trashes it again.
- **View** menu: Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Zoom to Fit (Cmd 9). Pinch to zoom on a trackpad.
- In Finder, select one or more images and use **Open With → PreviewViewer** (or drop them on the Dock icon) to view exactly those images.

See [docs/PLAN.md](docs/PLAN.md) for the development plan and progress.
