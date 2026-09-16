#!/usr/bin/env bash
# Build Mentor.app from the SwiftPM binary: no Xcode project needed.
#
# Usage: scripts/bundle.sh [debug|release]
#
# Signing: uses $MENTOR_SIGN_IDENTITY when set, otherwise the first
# "Apple Development" or "Developer ID Application" identity in the keychain,
# otherwise an ad-hoc signature ("-"). macOS ties Screen Recording and
# Accessibility grants to the app's designated code requirement. An ad-hoc
# signature's default requirement is the hash of the exact binary, so every
# rebuild would invalidate the grants; the ad-hoc path therefore sets an
# explicit requirement on the bundle identifier, which every rebuild satisfies.
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
# The menu bar mark, one template PDF per variant, built from
# Resources/Mark/MentorOwl.svg by `make mark`, as the icon above is from
# MentorMark.svg. Both are committed, so a plain build needs nothing but the
# repository.
cp "$ROOT"/Resources/Mark/MenuBarMark-*.pdf "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

identity="${MENTOR_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Apple Development|Developer ID Application' \
    | head -n1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
requirement_args=()
if [ -z "$identity" ]; then
  identity="-"
  requirement_args=(--requirements '=designated => identifier "com.ahcarpenter.mentor"')
  echo "bundle: no code-signing identity found, signing ad-hoc with a bundle-identifier requirement" >&2
else
  echo "bundle: signing with \"$identity\"" >&2
fi

codesign --force --sign "$identity" \
  --identifier com.ahcarpenter.mentor \
  --entitlements "$ROOT/Resources/Mentor.entitlements" \
  --timestamp=none \
  "${requirement_args[@]}" \
  "$APP"
codesign --verify --deep --strict "$APP"
echo "bundle: $APP"
