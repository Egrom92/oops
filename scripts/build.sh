#!/bin/bash
# Builds build/Layout Converter.app and signs it with a local certificate (created once by setup-signing.sh).
# The signature stays the same between builds, so macOS keeps the Accessibility permission after updates.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Layout Converter.app"
IDENTITY="Layout Converter Local Signing"

swift build -c release --product LayoutConverter
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LayoutConverter "$APP/Contents/MacOS/LayoutConverter"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    ./scripts/setup-signing.sh
fi
security unlock-keychain -p layoutconverter-local-signing "$HOME/Library/Keychains/layoutconverter-signing.keychain-db"
codesign --force --options runtime --sign "$IDENTITY" --identifier local.layoutconverter "$APP"
codesign --verify "$APP"
echo "Built $APP"
