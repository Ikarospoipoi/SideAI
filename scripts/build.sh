#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/build/SideAI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SideAI "$app/Contents/MacOS/SideAI"
if [[ ! -f Resources/AppIcon.icns || scripts/make_icon.swift -nt Resources/AppIcon.icns ]]; then
    swift scripts/make_icon.swift build/SideAI.iconset
    iconutil -c icns build/SideAI.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf '\nBuilt: %s\n' "$app"
