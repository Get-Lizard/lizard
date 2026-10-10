#!/bin/zsh
# Exports SVG/PNG brand assets (docs/brand, website/assets) from App/Views/Brand/LizardBrand.swift.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
rm -f "$ROOT/website/assets/splash.png"
xcrun swiftc -parse-as-library -target arm64-apple-macosx26.0 -swift-version 6 \
  "$ROOT/App/Views/Brand/LizardBrand.swift" "$ROOT/scripts/export-brand.swift" -o "$OUT/export-brand"
"$OUT/export-brand" "$ROOT"
rm -rf "$OUT"
