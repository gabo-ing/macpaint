#!/bin/bash
# Builds Paint.app (universal arm64 + x86_64 if both compile) into ./build
set -e
cd "$(dirname "$0")"
APP="build/Paint.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

for arch in arm64 x86_64; do
  if swiftc -O -swift-version 5 -target "$arch-apple-macos15.0" -framework AppKit \
       Sources/*.swift -o "build/tmp/Paint-$arch" 2>build/tmp/err-$arch.txt; then
    echo "built $arch"
  else
    echo "skipped $arch:"; head -20 build/tmp/err-$arch.txt
    [ "$arch" = "arm64" ] && exit 1
  fi
done

bins=$(ls build/tmp/Paint-* )
lipo -create $bins -output "$APP/Contents/MacOS/Paint"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/tmp
codesign --force --sign - "$APP"
echo "OK -> $(pwd)/$APP"
