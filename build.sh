#!/bin/bash
# Builds Rustle.app (and optionally a .dmg) into build/.
#   ./build.sh              native architecture
#   ./build.sh --universal  Apple silicon + Intel
#   ./build.sh --dmg        also package build/Rustle.dmg
#   ./build.sh --install    copy it to /Applications (findable with Spotlight) and open it
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=()
DMG=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
        --dmg) DMG=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Rustle"

APP=build/Rustle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rustle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ $DMG == 1 ]]; then
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/Rustle.dmg
    hdiutil create -quiet -volname Rustle -srcfolder "$STAGE" -ov -format UDZO build/Rustle.dmg
    rm -rf "$STAGE"
    echo "Built build/Rustle.dmg"
fi

if [[ $INSTALL == 1 ]]; then
    # Quit a running copy first so the new one can take its place.
    osascript -e 'tell application id "io.github.germanndarian.Rustle" to quit' >/dev/null 2>&1 || true
    pkill -x Rustle 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Rustle.app
    ditto "$APP" /Applications/Rustle.app
    mdimport /Applications/Rustle.app 2>/dev/null || true
    open /Applications/Rustle.app
    echo "Installed /Applications/Rustle.app"
fi
