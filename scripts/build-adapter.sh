#!/bin/bash
# Builds vendor/mediaremote-adapter/MediaRemoteAdapter.framework with CommandLineTools clang (no cmake needed).
# Mirrors the upstream CMakeLists.txt: the adapter sources as an ObjC ARC dylib with default symbol visibility
# (the Perl script dlsym()s its exported functions), linked against Foundation, AppKit, UniformTypeIdentifiers,
# wrapped as a versioned framework (Versions/A) and ad-hoc signed. The framework is only loaded by
#   /usr/bin/perl vendor/mediaremote-adapter/bin/mediaremote-adapter.pl <framework> stream|send N|seek MICROS
# and is never linked into LJ Display. Output is gitignored; `make app` runs this and copies the result.
set -euo pipefail
cd "$(dirname "$0")/../vendor/mediaremote-adapter"

NAME=MediaRemoteAdapter
FW="$NAME.framework"
VER=0.1.0
OBJ=build/obj
SOURCES=(
  src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m src/adapter/now_playing.m
  src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m src/adapter/shuffle.m src/adapter/speed.m
  src/adapter/stream.m src/adapter/test.m src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m
)

rm -rf build "$FW"
# Never leave intermediates (or a half-built framework) behind on failure.
trap 'status=$?; rm -rf build; if [ $status -ne 0 ]; then rm -rf "$FW"; fi' EXIT
mkdir -p "$OBJ" "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"

objs=()
for src in "${SOURCES[@]}"; do
  o="$OBJ/$(echo "$src" | tr '/' '_').o"
  clang -c -x objective-c -fobjc-arc -fvisibility=default -O2 -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 -Iinclude -Isrc "$src" -o "$o"
  objs+=("$o")
done

clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -install_name "@rpath/$FW/Versions/A/$NAME" \
  -current_version "$VER" -compatibility_version 0.1 \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  "${objs[@]}" -o "$FW/Versions/A/$NAME"

cp include/MediaRemoteAdapter.h "$FW/Versions/A/Headers/"
cat > "$FW/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.vandenbe.$NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VER</string>
</dict>
</plist>
EOF
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/$NAME "$FW/$NAME"
ln -s Versions/Current/Resources "$FW/Resources"
ln -s Versions/Current/Headers "$FW/Headers"

codesign --force --deep --sign - "$FW"
echo "built vendor/mediaremote-adapter/$FW"
