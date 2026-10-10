#!/bin/sh
# Build Headroom.app (release, ad-hoc signed).
# Usage: ./build.sh [run]            universal binary (arm64 + x86_64), what the DMG ships
#        ARCH=native ./build.sh run  current architecture only; faster and skips lipo
#        SCRATCH=<dir> ./build.sh     put SwiftPM's scratch directory elsewhere (default .build)
set -e
APP=Headroom
BUNDLE=build/$APP.app
if [ "${ARCH:-universal}" = "native" ]; then
  ARCHS=""
else
  # Universal binary so the direct-download build runs on Apple silicon and Intel Macs.
  ARCHS="--arch arm64 --arch x86_64"
fi
SCRATCH_OPT=""
[ -n "${SCRATCH:-}" ] && SCRATCH_OPT="--scratch-path $SCRATCH"
swift build -c release $ARCHS $SCRATCH_OPT
BIN=$(swift build -c release $ARCHS $SCRATCH_OPT --show-bin-path)
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Info.plist "$BUNDLE/Contents/"
cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/"
# How agents that find the app can use its command line tool.
cp Assets/AGENTS.md "$BUNDLE/Contents/Resources/"
codesign --force --deep --sign - "$BUNDLE"
echo "==> $BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/$APP"))"
[ "$1" = "run" ] && open "$BUNDLE" || true
