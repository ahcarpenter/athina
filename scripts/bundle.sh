#!/usr/bin/env bash
# Build Mentor.app from the SwiftPM binary: no Xcode project needed.
#
# Usage: scripts/bundle.sh [debug|release]
#
# Signing: uses $MENTOR_SIGN_IDENTITY when set, otherwise the first
# "Apple Development" or "Developer ID Application" identity in the keychain,
# otherwise an ad-hoc signature ("-"). macOS ties Screen Recording and
# Accessibility grants to the signing identity; with an ad-hoc signature the
# grant is tied to the exact binary, so a rebuild can make macOS ask again.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Mentor.app"
BIN="$ROOT/.build/$CONFIG/Mentor"

cd "$ROOT"
swift build -c "$CONFIG" --product Mentor

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mentor"

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
sed "s/__BUILD_NUMBER__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

identity="${MENTOR_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Apple Development|Developer ID Application' \
    | head -n1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
if [ -z "$identity" ]; then
  identity="-"
  echo "bundle: no code-signing identity found, signing ad-hoc (grants may not survive rebuilds)" >&2
else
  echo "bundle: signing with \"$identity\"" >&2
fi

codesign --force --sign "$identity" \
  --identifier com.ahcarpenter.mentor \
  --entitlements "$ROOT/Resources/Mentor.entitlements" \
  --timestamp=none \
  "$APP"
codesign --verify --deep --strict "$APP"
echo "bundle: $APP"
