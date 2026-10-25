#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/Cappuccino.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Cappuccino" "$app/Contents/MacOS/Cappuccino"
cp Support/Info.plist "$app/Contents/Info.plist"

mkdir -p "$app/Contents/Resources"
xcrun actool Assets/app.icon \
    --compile "$app/Contents/Resources" \
    --output-format human-readable-text \
    --output-partial-info-plist build/icon-info.plist \
    --app-icon app \
    --include-all-app-icons \
    --target-device mac \
    --minimum-deployment-target 13.0 \
    --platform macosx

# Ad-hoc signing needs no developer account. Set SIGNING_IDENTITY to a local
# Apple Development identity for more stable Accessibility grants across builds.
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$app" "$app"
