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

See [docs/PLAN.md](docs/PLAN.md) for the development plan and progress.
