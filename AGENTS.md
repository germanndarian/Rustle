# Rustle

Autumn leaves on the Mac desktop: a native macOS menu-bar app (Swift, AppKit, SpriteKit, AVFoundation), macOS 14+, plus a website in `site/` that runs the same leaves in the browser. README.md has the features, the menu and every debug switch.

## Layout

- `Package.swift`: one executable target `Rustle` at `Sources/Rustle`. No test target.
- `Sources/Rustle/`: `main.swift`, `AppDelegate.swift` (menu), `LeafScene.swift` (simulation), `LeafArt.swift` and `ToolArt.swift` (all art drawn in code), `Tools.swift` (rake, blower), `CrunchAudio.swift` (live synthesized sound), `WindowTracker.swift` (window ledges), `Overlay.swift`, `PowerMonitor.swift`, `Preferences.swift`.
- `Resources/`: `Info.plist`, `AppIcon.icns`.
- `scripts/make-icon.swift`: draws the icon.
- `build.sh`: builds `build/Rustle.app`, optionally a dmg, a universal binary or an install.
- `site/`: the website (`index.html`, `assets/`). `.github/workflows/pages.yml` deploys it to GitHub Pages.

## Commands

Confirmed (run in this repo):

- `swift build`: debug build, about a second when warm. This is the quick check.
- `./build.sh`: release build, ad-hoc signed `build/Rustle.app`. Takes several minutes from a cold start.

Not run (expensive or they change the machine):

- `./build.sh --dmg`: also writes `build/Rustle.dmg`. Not run.
- `./build.sh --universal`: arm64 and x86_64. Not run.
- `./build.sh --install`: quits a running Rustle, replaces `/Applications/Rustle.app` and opens it. Not run. Never run it unasked.
- `swift scripts/make-icon.swift`: regenerates `Resources/AppIcon.icns`. Not run.

There are no tests and no linter. A clean `swift build` is the check.

## Running the app

Launch `build/Rustle.app/Contents/MacOS/Rustle` directly to use the debug environment variables (`RUSTLE_DEBUG`, `RUSTLE_SNAPSHOT`, `RUSTLE_PREFILL`, `RUSTLE_FAKE_CURSOR`, `RUSTLE_FAKE_WINDOWS`, `RUSTLE_FAKE_TOOL`, `RUSTLE_CRUMBLE_FAST`, `RUSTLE_GUST_AT`, `RUSTLE_CLEAR_AT`), listed in README.md. Settings also work as arguments, e.g. `-leafFall heavy -breeze gusty`. This is not run in agent sessions: it covers the real desktop with leaves.

## Conventions

- Keep it small and native: no third-party packages, no new permissions (window frames need no Screen Recording permission, so don't read window titles).
- All art is drawn in code, and the crunch is synthesized live, never replayed clips. Keep both.
- When the menu or a behavior changes, update README.md and the page in `site/` to match.
- `build/` and `.build/` are git-ignored.
- No Claude attribution anywhere in the repo.
