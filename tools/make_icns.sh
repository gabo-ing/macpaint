#!/bin/bash
# Regenerates AppIcon.icns from tools/make_icon.swift
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
swiftc -O tools/make_icon.swift -o "$T/mk" && "$T/mk" "$T/icon.png"
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
cp "$T/icon.png" /Users/gabo/.claude/jobs/0b9cb7aa/tmp/icon_preview.png 2>/dev/null || true
rm -rf "$T"
echo "wrote AppIcon.icns"
