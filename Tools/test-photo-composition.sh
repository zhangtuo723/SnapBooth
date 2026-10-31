#!/bin/bash
set -euo pipefail

# Optional argument: Assets.car from a Mac Catalyst build. Without one, copy
# source frame PNGs as ordinary bundle resources. No simulator/device is used.
project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/snapbooth-photo-composition.XXXXXX)
test_app="$test_dir/PhotoCompositionTests.app"
resources="$test_app/Contents/Resources"
executable="$test_app/Contents/MacOS/PhotoCompositionTests"
mkdir -p "$resources" "$test_app/Contents/MacOS" "$test_dir/images"

cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.snapbooth.photo-composition-tests</string>
<key>CFBundleExecutable</key><string>PhotoCompositionTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [Mac-Catalyst-Assets.car]" >&2
    exit 2
elif [[ $# -eq 1 ]]; then
    cp "$1" "$resources/Assets.car"
else
    for asset in FrameChineseFoil FrameFloralPhoto FrameInvitation FrameBlush FrameGarden FrameCelebration; do
        cp "$project_dir/SnapBooth/Assets.xcassets/$asset.imageset/frame.png" "$resources/$asset.png"
    done
fi

sdk=$(xcrun --sdk macosx --show-sdk-path)
architecture=$(uname -m)
xcrun swiftc -sdk "$sdk" -target "$architecture-apple-ios17.0-macabi" \
    -F "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -L "$sdk/System/iOSSupport/usr/lib" \
    "$project_dir/SnapBooth/StandardPrintGeometry.swift" \
    "$project_dir/SnapBooth/PrintLayoutRenderer.swift" \
    "$project_dir/Tests/PhotoCompositionTests.swift" \
    -o "$executable"

echo "Composition test artifacts: $test_dir"
"$executable" "$test_dir/images"
