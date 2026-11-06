#!/bin/bash
# Builds dist/LJ Display.app: release build, bundle layout, ad-hoc signature.
#   LJ Display.app/Contents/MacOS/LJDisplay
#   LJ Display.app/Contents/Info.plist                         (vn.kahn.ljdisplay, LSUIElement)
#   LJ Display.app/Contents/Resources/LJDisplay_LJUI.bundle/    (fonts, monkey.png; found by LJResources)
#   LJ Display.app/Contents/Resources/mediaremote-adapter/      (bin/mediaremote-adapter.pl, MediaRemoteAdapter.framework,
#                                                                LICENSE; found by NowPlayingSource.locateAdapter)
set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
APP="dist/LJ Display.app"

scripts/build-adapter.sh

swift build -c release --product LJDisplay \
  -Xswiftc -F$FW -Xlinker -F$FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LJDisplay" "$APP/Contents/MacOS/LJDisplay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$BIN/LJDisplay_LJUI.bundle" "$APP/Contents/Resources/"
MRA="$APP/Contents/Resources/mediaremote-adapter"
mkdir -p "$MRA/bin"
cp vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$MRA/bin/"
cp vendor/mediaremote-adapter/LICENSE "$MRA/LICENSE"
ditto vendor/mediaremote-adapter/MediaRemoteAdapter.framework "$MRA/MediaRemoteAdapter.framework"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep -s - "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "built $APP"
