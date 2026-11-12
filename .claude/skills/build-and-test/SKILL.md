---
name: build-and-test
description: Build, compile, check or package Rustle. Use when asked to build, run swift build, make Rustle.app, check that it compiles, try a debug switch (RUSTLE_DEBUG, RUSTLE_PREFILL, RUSTLE_FAKE_CURSOR), or make a dmg.
---

# Build and test Rustle

Swift package, macOS 14+, one executable target `Rustle` in `Sources/Rustle`. The project has no test target, so a clean build is the check.

## Confirmed commands

- `swift build` : debug build, the quick compile check. Confirmed.
- `./build.sh` : release build, ad-hoc signed `build/Rustle.app`. Confirmed; it takes several minutes.

## Not run (expensive or they change the machine)

- `./build.sh --dmg` : also builds `build/Rustle.dmg`. Not run.
- `./build.sh --universal` : arm64 and x86_64. Not run.
- `./build.sh --install` : quits Rustle, replaces `/Applications/Rustle.app` and opens it. Never run it unasked.
- `swift scripts/make-icon.swift` : regenerates `Resources/AppIcon.icns`. Not run.

## Trying the app

Launch the built binary directly with the debug variables from README.md, e.g. `RUSTLE_DEBUG=1 build/Rustle.app/Contents/MacOS/Rustle`. Leaves fall over the real desktop, so say so before launching it.

## Steps

1. Run `swift build` after every Swift change and read the errors only (`2>&1 | grep -E "error:|warning:|Build complete"`).
2. Run `./build.sh` only when the app bundle itself is needed.
3. `build/` and `.build/` are git-ignored; don't commit them.
