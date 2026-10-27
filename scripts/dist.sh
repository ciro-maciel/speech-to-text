#!/bin/bash
# Every installer bumps the patch version, builds, packs a .dmg, has Apple notarize it, and
# installs it in /Applications.
#   scripts/dist.sh
#
# Notarization reads the keychain profile "notary" (xcrun notarytool store-credentials
# notary --key <AuthKey.p8> --key-id <id> --issuer <issuer>, once per Mac); without it the
# .dmg is signed but not notarized, which is enough on the Mac that built it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IFS=. read -r MAJOR MINOR PATCH < "$ROOT/VERSION"
VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
echo "$VERSION" > "$ROOT/VERSION"

"$ROOT/scripts/build.sh"
APP="$ROOT/dist/Speech to Text.app"
DMG="$ROOT/dist/Speech-to-Text-$VERSION-macos.dmg"
"$ROOT/scripts/release/dmg-mac.sh" "$APP" "$DMG" "Speech to Text by Ciro Cesar Maciel $VERSION"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1 || true)"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
    echo "Notarizing ${DMG}…"
    xcrun notarytool submit "$DMG" --keychain-profile notary --wait --timeout 20m | tee "$ROOT/dist/notary.txt"
    grep -q "status: Accepted" "$ROOT/dist/notary.txt" || { echo "notarization was not accepted" >&2; exit 1; }
    xcrun stapler staple "$DMG" >/dev/null
else
    echo "warning: no notarytool profile \"notary\": the .dmg is signed, not notarized" >&2
fi

# Install from the packed image, the same bytes someone downloading it gets.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" >/dev/null
pkill -x speech-to-text >/dev/null 2>&1 || true
rm -rf "/Applications/Speech to Text.app"
cp -R "$MOUNT/Speech to Text.app" /Applications/
hdiutil detach "$MOUNT" >/dev/null
open -a "/Applications/Speech to Text.app"
echo "Installed /Applications/Speech to Text.app ($VERSION) from $DMG"
