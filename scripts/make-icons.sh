#!/bin/zsh
# Renders App/Assets.xcassets icons from App/Views/Brand/LizardBrand.swift.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$ROOT/App/Assets.xcassets/AppIcon.appiconset" "$ROOT/App/Assets.xcassets/MenuBarIcon.imageset" "$ROOT/docs/brand"
xcrun swiftc -parse-as-library -target arm64-apple-macosx26.0 -swift-version 6 \
  "$ROOT/App/Views/Brand/LizardBrand.swift" "$ROOT/App/Views/Intro/SplashView.swift" "$ROOT/scripts/render-brand.swift" -o "$OUT/render-brand"
"$OUT/render-brand" "$ROOT"
rm -rf "$OUT"
