#!/usr/bin/env bash
#
# publish-mac.sh — puts a built release on blob.ciromaciel.click.
#
#   scripts/release/publish-mac.sh <dir>
#
# <dir> is what scripts/release/build-mac.sh wrote: the notarized .dmg and the signed
# update archive (.app.tar.gz + .sig). Run by .github/workflows/release.yml, only when
# the version in package.json is newer than the published one.
#
# In the R2 bucket (blob.ciromaciel.click), under tools/speech-to-text/:
#
#   <version>/Speech-to-Text-<version>-macos.dmg            every release, kept, immutable
#   <version>/Speech-to-Text-<version>-macos.app.tar.gz     what installed apps update from
#   latest/Speech-to-Text-macos.dmg                         the fixed link the site points to
#   install.sh                                              the one-line installer
#   latest.json                                             what installed apps check — last
#
# latest.json is the Tauri updater manifest. It goes up last, after everything it names,
# so an app never sees a version whose files aren't there yet. It lists macOS on Apple
# Silicon only: that is the only build published. A version not greater than the
# published one is refused: bump package.json first.
#
# Needs aws (CLI), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and CLOUDFLARE_ACCOUNT_ID.
# PREFIX overrides the folder, for a dry run (tools/speech-to-text-test).

set -euo pipefail

DIR="$1"
BUCKET="${BUCKET:-ciromaciel-blob}"
PREFIX="${PREFIX:-tools/speech-to-text}"
PUBLIC="https://blob.ciromaciel.click"
BASE="$PUBLIC/$PREFIX"
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$HERE/../../package.json" | head -1)"
NOTES="${RELEASE_NOTES:-Speech to Text $VERSION}"
NAME="Speech-to-Text"

fail() { echo "✗ $1" >&2; exit 1; }

DMG="$DIR/$NAME-$VERSION-macos.dmg"
UPDATE="$DIR/$NAME-$VERSION-macos.app.tar.gz"
for f in "$DMG" "$UPDATE" "$UPDATE.sig"; do [ -f "$f" ] || fail "missing $f"; done
hdiutil imageinfo "$DMG" >/dev/null 2>&1 || fail "$DMG is not a disk image"

PUBLISHED="$(curl -sf "$BASE/latest.json" | sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' | head -1 || true)"
if [ -n "$PUBLISHED" ]; then
    HIGHEST="$(printf '%s\n%s\n' "$PUBLISHED" "$VERSION" | sort -V | tail -1)"
    if [ "$VERSION" = "$PUBLISHED" ] || [ "$HIGHEST" != "$VERSION" ]; then
        fail "version $VERSION is not greater than the published $PUBLISHED — bump package.json"
    fi
fi
echo "Publishing Speech to Text $VERSION (published: ${PUBLISHED:-none}) to $BASE"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
ENDPOINT="https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
put() { # put <file> <key> <content-type> <cache-control>
    aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" --endpoint-url "$ENDPOINT" --only-show-errors \
        --content-type "$3" --cache-control "$4"
    echo "  ↑ $PREFIX/$2"
}
KEEP="public, max-age=31536000, immutable"
FRESH="public, max-age=300"

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
# The signature is base64: no character in it needs escaping.
printf '{\n  "version": "%s",\n  "notes": "%s",\n  "pub_date": "%s",\n  "platforms": {\n    "darwin-aarch64": {\n      "signature": "%s",\n      "url": "%s"\n    }\n  }\n}\n' \
    "$VERSION" "$NOTES" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(tr -d '\n' <"$UPDATE.sig")" \
    "$BASE/$VERSION/$NAME-$VERSION-macos.app.tar.gz" >"$MANIFEST"

bash -n "$HERE/install-mac.sh" || fail "install-mac.sh does not parse"

put "$DMG"              "$VERSION/$NAME-$VERSION-macos.dmg"          application/x-apple-diskimage "$KEEP"
put "$UPDATE"           "$VERSION/$NAME-$VERSION-macos.app.tar.gz"   application/gzip              "$KEEP"
put "$DMG"              "latest/$NAME-macos.dmg"                     application/x-apple-diskimage "$FRESH"
put "$HERE/install-mac.sh" "install.sh"                              "text/plain; charset=utf-8"   "$FRESH"
put "$MANIFEST"         "latest.json"                                application/json              "public, max-age=60"

# What a person gets is what was built: the fixed link serves these bytes.
WANT="$(stat -f %z "$DMG")"
GOT="$(curl -sfI "$BASE/latest/$NAME-macos.dmg?v=$VERSION" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')"
[ "$GOT" = "$WANT" ] || fail "latest/$NAME-macos.dmg has $GOT bytes online, $WANT here"

echo "✓ Speech to Text $VERSION published — $BASE/latest.json"
echo "  curl -fsSL $BASE/install.sh | bash"
