#!/bin/bash
# Builds build/Oops.app and signs it with a local certificate (created once by setup-signing.sh).
# The signature stays the same between builds, so macOS keeps the Accessibility permission after updates.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Oops.app"
IDENTITY="Layout Converter Local Signing"   # the old name on purpose: same signature, permissions kept

swift build -c release --product Oops
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Oops "$APP/Contents/MacOS/Oops"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    ./scripts/setup-signing.sh
fi
security unlock-keychain -p layoutconverter-local-signing "$HOME/Library/Keychains/layoutconverter-signing.keychain-db"
codesign --force --options runtime --sign "$IDENTITY" --identifier local.layoutconverter "$APP"
codesign --verify "$APP"
echo "Built $APP"
