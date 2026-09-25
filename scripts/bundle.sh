#!/usr/bin/env bash
# Build Athina.app from the SwiftPM binary: no Xcode project needed.
#
# Usage: scripts/bundle.sh [debug|release] [--universal] [--out <dir>] [--no-sign] [--no-control]
#
#   --universal   build for Apple silicon and Intel in one binary, as a release does
#   --out <dir>   put Athina.app in <dir> instead of build/
#   --no-sign     leave the bundle unsigned, for scripts/release.sh to sign
#   --no-control  leave out the end-to-end harness's control API, as a release
#                 does; every other bundle is a development one and carries it
#                 (the ControlAPI package trait, README "The control API")
#
# The version is Resources/Info.plist's own (CFBundleShortVersionString and
# CFBundleVersion), copied as it is: the one place either number is set
# (README "Releasing").
#
# Signing: uses $ATHINA_SIGN_IDENTITY when set, otherwise the first
# "Apple Development" or "Developer ID Application" identity in the keychain,
# otherwise an ad-hoc signature ("-"). macOS ties Screen Recording and
# Accessibility grants to the app's designated code requirement. An ad-hoc
# signature's default requirement is the hash of the exact binary, so every
# rebuild would invalidate the grants; the ad-hoc path therefore sets an
# explicit requirement on the bundle identifier, which every rebuild satisfies.
# This is the development signature: no hardened runtime and no timestamp. A
# release is signed by scripts/release.sh instead.
set -euo pipefail

CONFIG="release"
UNIVERSAL=0
SIGN=1
CONTROL=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build"
while [ "$#" -gt 0 ]; do
  case "$1" in
    debug|release) CONFIG="$1"; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    --out) [ "$#" -ge 2 ] || { echo "bundle: --out needs a directory" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --no-sign) SIGN=0; shift ;;
    --no-control) CONTROL=0; shift ;;
    *) echo "usage: scripts/bundle.sh [debug|release] [--universal] [--out <dir>] [--no-sign] [--no-control]" >&2; exit 2 ;;
  esac
done
APP="$OUT_DIR/Athina.app"

build_args=(-c "$CONFIG" --product Athina)
if [ "$CONTROL" = 1 ]; then build_args+=(--traits ControlAPI); fi
if [ "$UNIVERSAL" = 1 ]; then build_args+=(--arch arm64 --arch x86_64); fi

cd "$ROOT"
swift build "${build_args[@]}"
BIN="$(swift build "${build_args[@]}" --show-bin-path)/Athina"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Athina"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# The menu bar mark, one template PDF per variant, built from
# Resources/Mark/AthinaOwl.svg by `make mark`, as the icon above is from
# AthinaMark.svg. Both are committed, so a plain build needs nothing but the
# repository.
cp "$ROOT"/Resources/Mark/MenuBarMark-*.pdf "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$SIGN" = 0 ]; then
  echo "bundle: $APP (unsigned)"
  exit 0
fi

identity="${ATHINA_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Apple Development|Developer ID Application' \
    | head -n1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
requirement_args=()
if [ -z "$identity" ]; then
  identity="-"
  requirement_args=(--requirements '=designated => identifier "com.ahcarpenter.athina"')
  echo "bundle: no code-signing identity found, signing ad-hoc with a bundle-identifier requirement" >&2
else
  echo "bundle: signing with \"$identity\"" >&2
fi

codesign --force --sign "$identity" \
  --identifier com.ahcarpenter.athina \
  --entitlements "$ROOT/Resources/Athina.entitlements" \
  --timestamp=none \
  "${requirement_args[@]}" \
  "$APP"
codesign --verify --deep --strict "$APP"
echo "bundle: $APP"
