#!/usr/bin/env bash
# Build, sign, notarize, and package a direct-download release of Athina: the
# route outside the App Store, with no App Sandbox and no App Review.
#
# Usage: scripts/release.sh   (or `make release`)
#
# Apple credentials are never committed; two environment variables name them
# (README "Releasing" has the one-time steps that create both):
#
#   ATHINA_RELEASE_IDENTITY  the Developer ID Application identity to sign with,
#                            by its name or SHA-1; by default the only one in the
#                            keychain
#   ATHINA_NOTARY_PROFILE    the `xcrun notarytool store-credentials` keychain
#                            profile to submit with
#
# Writes to build/release: Athina.app, Athina-<version>.dmg (the app beside a
# link to Applications), Athina-<version>.zip, Athina-<version>.dSYM.zip for
# crash reports, and Athina-<version>-notes.md, the notes written by hand and
# committed in docs/release-notes/<version>.md set among this build's version
# and checksums. The version is Resources/Info.plist's own, the one place it is
# set. Nothing under docs/ is ever written here, only read.
#
# Without a Developer ID identity or a notary profile it still runs every step
# that needs no Apple credentials (the hardened runtime build, signed ad-hoc,
# the disk image and zip, and every check that needs no Apple service), names
# each step it skipped and why, and exits 1: what it built is for checking, not
# for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
APP="$OUT/Athina.app"
INFO="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/Athina.entitlements"
BUNDLE_ID="com.ahcarpenter.athina"
PLIST_BUDDY=/usr/libexec/PlistBuddy

SKIPPED=()

say() { printf 'release: %s\n' "$*" >&2; }
ok() { say "ok    $*"; }
skip() {
	SKIPPED+=("$1 ($2)")
	say "skip  $1 ($2)"
}
fail() {
	say "FAILED: $*"
	exit 1
}

cd "$ROOT"

# --- The version --------------------------------------------------------------

VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$INFO")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	fail "CFBundleShortVersionString in Resources/Info.plist is \"$VERSION\", not a version like 1.2.3"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] ||
	fail "CFBundleVersion in Resources/Info.plist is \"$BUILD\", not a whole number"
TAG="v$VERSION"
DMG="$OUT/Athina-$VERSION.dmg"
ZIP="$OUT/Athina-$VERSION.zip"
DSYM_ZIP="$OUT/Athina-$VERSION.dSYM.zip"
NOTES="$OUT/Athina-$VERSION-notes.md"
WRITTEN_NOTES="docs/release-notes/$VERSION.md"
say "Athina $VERSION (build $BUILD)"

# A released version is never built again from other code: a copy that says
# 0.1.0 has to be the 0.1.0 people downloaded.
if tagged="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" &&
	[ "$tagged" != "$(git rev-parse HEAD)" ]; then
	fail "Athina $VERSION was already released from ${tagged:0:12} (tag $TAG); raise CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist"
fi
# The release before this one, whose build number this one has to exceed,
# since macOS and notarization order copies of one app by it.
PREVIOUS_TAG="$(git tag --merged HEAD --list 'v[0-9]*' --sort=-v:refname | grep -vxF "$TAG" | head -n 1 || true)"
if [ -n "$PREVIOUS_TAG" ]; then
	previous_build="$(git show "$PREVIOUS_TAG:Resources/Info.plist" | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
	[[ "$previous_build" =~ ^[0-9]+$ ]] || previous_build=0
	[ "$BUILD" -gt "$previous_build" ] ||
		fail "CFBundleVersion is $BUILD, but $PREVIOUS_TAG was build $previous_build; raise it in Resources/Info.plist"
fi

# --- The signing identity and the notary profile ------------------------------

# Only ever read: the identities the keychain can sign code with. The keychain
# itself is left alone.
identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -F '"Developer ID Application: ' || true)"
IDENTITY=""
IDENTITY_NAME=""
if [ -n "${ATHINA_RELEASE_IDENTITY:-}" ]; then
	line="$(awk -v want="$ATHINA_RELEASE_IDENTITY" '
		{ name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name) }
		$2 == want || name == want { print; exit }' <<<"$identities")"
	[ -n "$line" ] ||
		fail "ATHINA_RELEASE_IDENTITY is \"$ATHINA_RELEASE_IDENTITY\", but no valid Developer ID Application identity by that name or SHA-1 is in the keychain (security find-identity -v -p codesigning lists them)"
	IDENTITY="$(awk '{ print $2 }' <<<"$line")"
	IDENTITY_NAME="$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<<"$line")"
elif [ -n "$identities" ]; then
	[ "$(wc -l <<<"$identities" | tr -d ' ')" = 1 ] ||
		fail "several Developer ID Application identities are in the keychain; set ATHINA_RELEASE_IDENTITY to the name or SHA-1 of one:"$'\n'"$identities"
	IDENTITY="$(awk '{ print $2 }' <<<"$identities")"
	IDENTITY_NAME="$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<<"$identities")"
fi
NO_IDENTITY="no Developer ID Application identity in the keychain; set ATHINA_RELEASE_IDENTITY"

PROFILE="${ATHINA_NOTARY_PROFILE:-}"
NOTARIZE=0
if [ -z "$IDENTITY" ]; then
	NO_NOTARY="Apple notarizes only a Developer ID signature, skipped above"
elif [ -z "$PROFILE" ]; then
	NO_NOTARY="ATHINA_NOTARY_PROFILE is not set to a notarytool keychain profile"
else
	if ! xcrun --find notarytool >/dev/null 2>&1 || ! xcrun --find stapler >/dev/null 2>&1; then
		fail "notarytool and stapler come with Xcode, and xcrun cannot find them"
	fi
	# Fail now, not after a build: a profile that cannot be used is a setup
	# mistake, not a step to skip.
	if ! err="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 >/dev/null)"; then
		fail "ATHINA_NOTARY_PROFILE is \"$PROFILE\", but notarytool cannot use it: ${err:-no reason given}. Store it with: xcrun notarytool store-credentials \"$PROFILE\" --apple-id <Apple ID> --team-id <team ID>"
	fi
	NOTARIZE=1
fi

if [ -n "$IDENTITY" ]; then
	say "signing with \"$IDENTITY_NAME\""
	# A distributed copy has to be exactly a commit anyone can check out.
	[ -z "$(git status --porcelain)" ] ||
		fail "the worktree has changes; a release is built from a commit, so commit or set them aside first"
else
	say "signing ad-hoc: $NO_IDENTITY"
fi

# --- Build --------------------------------------------------------------------

if pgrep -f "$APP/Contents/MacOS/Athina" >/dev/null 2>&1; then
	fail "an Athina is running from $APP; quit it before building over it"
fi
rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d "$OUT/.work-XXXXXX")"
MOUNT=""
cleanup() {
	if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true; fi
	rm -rf "$WORK"
}
trap cleanup EXIT

# Universal, so it runs on every Mac that runs macOS 26, Intel ones included.
scripts/bundle.sh release --universal --out "$OUT" --no-sign
BIN_DIR="$(swift build -c release --product Athina --arch arm64 --arch x86_64 --show-bin-path)"
archs="$(lipo -archs "$APP/Contents/MacOS/Athina")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] ||
	fail "the binary is built for \"$archs\", not arm64 and x86_64"
[ "$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] &&
	[ "$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] ||
	fail "the bundle's Info.plist does not carry version $VERSION (build $BUILD)"
ok "universal Release build ($archs), version $VERSION (build $BUILD)"

# The debug symbols of exactly this binary, for reading crash reports from the
# people running it.
[ -d "$BIN_DIR/Athina.dSYM" ] || fail "no debug symbols at $BIN_DIR/Athina.dSYM"
[ "$(xcrun dwarfdump --uuid "$BIN_DIR/Athina.dSYM" | awk '{ print $2 }' | sort)" = \
	"$(xcrun dwarfdump --uuid "$APP/Contents/MacOS/Athina" | awk '{ print $2 }' | sort)" ] ||
	fail "the debug symbols at $BIN_DIR/Athina.dSYM are not this binary's"
ditto -c -k --keepParent "$BIN_DIR/Athina.dSYM" "$DSYM_ZIP"
ok "debug symbols $(basename "$DSYM_ZIP")"

# --- Sign ---------------------------------------------------------------------

# The hardened runtime always, since notarization requires it, and a secure
# timestamp with Developer ID, since notarization requires that too; an ad-hoc
# signature cannot carry one.
sign_args=(--force --options runtime)
if [ -n "$IDENTITY" ]; then
	sign_args+=(--sign "$IDENTITY" --timestamp)
else
	sign_args+=(--sign - --timestamp=none)
fi
entitlements="$ENTITLEMENTS"

# Nested code first, inside out, each with the same signature as the app, so
# library validation accepts it. Athina embeds none yet; this covers the
# libraries it will load from Contents/Frameworks, such as the local speech
# models' runtime (whisper.cpp for Whisper and Parakeet), with no further change.
nested=()
if [ -d "$APP/Contents/Frameworks" ]; then
	while IFS= read -r -d '' item; do nested+=("$item"); done < <(
		find "$APP/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0)
fi
for item in ${nested[@]+"${nested[@]}"}; do
	codesign "${sign_args[@]}" "$item"
done
if [ "${#nested[@]}" -gt 0 ] && [ -z "$IDENTITY" ]; then
	# Library validation loads only libraries signed by the process's own team,
	# and an ad-hoc signature has none, so this local build would refuse its own
	# libraries. It alone turns library validation off; a Developer ID release
	# never does.
	entitlements="$WORK/adhoc.entitlements"
	cp "$ENTITLEMENTS" "$entitlements"
	"$PLIST_BUDDY" -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements" >/dev/null
	say "the bundle nests ${#nested[@]} library(s), which library validation refuses under an ad-hoc signature, so this ad-hoc build alone disables it"
fi

app_args=(--identifier "$BUNDLE_ID" --entitlements "$entitlements")
if [ -z "$IDENTITY" ]; then
	# As scripts/bundle.sh does, so the Screen Recording and Accessibility grants
	# of a development build hold for this one too (README "Code signing").
	app_args+=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi
codesign "${sign_args[@]}" "${app_args[@]}" "$APP"

err="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" ||
	fail "codesign --verify --deep --strict rejects $APP: $err"
details="$(codesign -dvvv "$APP" 2>&1)"
grep -q "^Identifier=$BUNDLE_ID\$" <<<"$details" || fail "the signature's identifier is not $BUNDLE_ID"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" ||
	fail "the signature does not carry the hardened runtime"
# What is signed in is exactly the entitlements file, nothing more.
[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - -)" = \
	"$(plutil -convert xml1 -o - "$entitlements")" ] ||
	fail "the signed entitlements differ from $(basename "$entitlements")"
if [ -n "$IDENTITY" ]; then
	grep -q '^Authority=Developer ID Application: ' <<<"$details" || fail "the signature is not a Developer ID one"
	grep -q '^Timestamp=' <<<"$details" || fail "the signature has no secure timestamp"
	ok "signed with Developer ID, hardened runtime, secure timestamp; codesign --verify --deep --strict passes"
else
	ok "signed ad-hoc with the hardened runtime; codesign --verify --deep --strict passes"
	skip "sign with Developer ID and a secure timestamp" "$NO_IDENTITY"
fi
CDHASH="$(sed -n 's/^CDHash=//p' <<<"$details")"

# --- Notarize the app ---------------------------------------------------------

# Submits one file, waits for Apple's verdict, and keeps Apple's log beside the
# release, warnings included, whether or not it was accepted.
notarize() {
	local file="$1" label="$2" result status id
	result="$WORK/notary-$label.json"
	say "submitting $(basename "$file") to Apple's notary service and waiting for the verdict"
	xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 2h \
		--output-format json >"$result" 2>"$WORK/notary-$label.err" || true
	status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
	id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
	if [ -n "$id" ]; then
		xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-$label-log.json" >/dev/null 2>&1 || true
	fi
	if [ "$status" != Accepted ]; then
		sed 's/^/  /' "$WORK/notary-$label.err" >&2 || true
		fail "Apple did not accept the $label (status: ${status:-no answer}, submission ${id:-none}); its log is $OUT/notary-$label-log.json"
	fi
	ok "notarized the $label (submission $id)"
}

if [ "$NOTARIZE" = 1 ]; then
	ditto -c -k --keepParent "$APP" "$WORK/Athina-notarize.zip"
	notarize "$WORK/Athina-notarize.zip" app
	if ! xcrun stapler staple -q "$APP" || ! xcrun stapler validate -q "$APP"; then
		fail "could not staple the notarization ticket to $APP"
	fi
	ok "stapled the ticket to Athina.app"
else
	skip "notarize and staple the app" "$NO_NOTARY"
fi

# --- The disk image and the zip -----------------------------------------------

# What a person sees on opening the image: the app, and a link to drag it onto.
stage="$WORK/dmg"
mkdir -p "$stage"
ditto "$APP" "$stage/Athina.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Athina $VERSION" -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$DMG"
ok "disk image $(basename "$DMG")"

if [ -n "$IDENTITY" ]; then
	codesign --force --sign "$IDENTITY" --timestamp "$DMG"
	codesign --verify --strict "$DMG" || fail "codesign --verify rejects $DMG"
	ok "signed the disk image with Developer ID"
else
	skip "sign the disk image" "$NO_IDENTITY"
fi

if [ "$NOTARIZE" = 1 ]; then
	notarize "$DMG" "disk image"
	if ! xcrun stapler staple -q "$DMG" || ! xcrun stapler validate -q "$DMG"; then
		fail "could not staple the notarization ticket to $DMG"
	fi
	ok "stapled the ticket to the disk image"
else
	skip "notarize and staple the disk image" "$NO_NOTARY"
fi

# The zip carries the stapled app; a zip itself cannot hold a ticket.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ok "zip $(basename "$ZIP")"

# --- Verify what people download ----------------------------------------------

# The app a download holds is the one just signed, byte for byte, and still
# verifies once it has been through the image or the zip.
verify_copy() {
	local copy="$1" where="$2" err
	err="$(codesign --verify --deep --strict "$copy" 2>&1)" ||
		fail "codesign --verify --deep --strict rejects the app in $where: $err"
	[ "$(codesign -dvvv "$copy" 2>&1 | sed -n 's/^CDHash=//p')" = "$CDHASH" ] ||
		fail "the app in $where is not the one signed"
	if [ "$NOTARIZE" = 1 ]; then
		xcrun stapler validate -q "$copy" || fail "the app in $where carries no notarization ticket"
	fi
}

hdiutil verify -quiet "$DMG" || fail "hdiutil verify rejects $DMG"
# Mounted out of sight: -nobrowse keeps it out of the Finder and off the desktop.
MOUNT="$WORK/mount"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" ||
	fail "could not mount $DMG"
entries="$(cd "$MOUNT" && find . -mindepth 1 -maxdepth 1 ! -name '.*' | sort | tr '\n' ' ')"
[ "$entries" = "./Applications ./Athina.app " ] || fail "the disk image holds \"$entries\", not Athina.app and Applications"
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = /Applications ] ||
	fail "Applications in the disk image is not a link to /Applications"
verify_copy "$MOUNT/Athina.app" "the disk image"
hdiutil detach -quiet "$MOUNT" || fail "could not unmount $DMG"
MOUNT=""
ditto -x -k "$ZIP" "$WORK/unzipped"
verify_copy "$WORK/unzipped/Athina.app" "the zip"
ok "the disk image and the zip hold the signed app, which still verifies"

if [ "$NOTARIZE" = 1 ]; then
	assessment="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" ||
		fail "Gatekeeper rejects the app: $assessment"
	grep -q 'source=Notarized Developer ID' <<<"$assessment" || fail "Gatekeeper does not see a notarized app: $assessment"
	assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1)" ||
		fail "Gatekeeper rejects the disk image: $assessment"
	grep -q 'source=Notarized Developer ID' <<<"$assessment" || fail "Gatekeeper does not see a notarized disk image: $assessment"
	ok "Gatekeeper accepts the app and the disk image as notarized Developer ID"
else
	skip "Gatekeeper assessment with spctl" "it accepts only a notarized Developer ID signature"
fi

# --- Release notes ------------------------------------------------------------

# What changed is written by hand and committed with the version, outside
# build/release, which every run replaces; the facts of this build go around it.
if [ -f "$WRITTEN_NOTES" ]; then
	written="$(cat "$WRITTEN_NOTES")"
else
	written="## What's new"$'\n\n'"TODO: write this release's notes in $WRITTEN_NOTES and commit them before releasing."
	say "no release notes for $VERSION: create $WRITTEN_NOTES and commit it before releasing"
fi
{
	printf '# Athina %s (build %s)\n\n' "$VERSION" "$BUILD"
	if [ "${#SKIPPED[@]}" -gt 0 ]; then
		printf '**Not for distribution.** This build skipped:\n\n'
		printf -- '- %s\n' "${SKIPPED[@]}"
		printf '\n'
	fi
	printf 'Requires macOS 26 or later, on Apple silicon or Intel.\n\n'
	printf '## Install\n\n'
	printf 'Open %s and drag Athina onto Applications, or unzip %s into Applications.\n\n' "\`$(basename "$DMG")\`" "\`$(basename "$ZIP")\`"
	printf '%s\n\n' "$written"
	printf '## Checksums (SHA-256)\n\n```\n'
	(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")")
	printf '```\n\nBuilt from %s%s.\n' "$(git rev-parse HEAD)" \
		"$([ -z "$(git status --porcelain)" ] || echo ', with uncommitted changes')"
} >"$NOTES"
ok "release notes $(basename "$NOTES")"

# --- Summary ------------------------------------------------------------------

say "built in $OUT:"
for file in "$APP" "$DMG" "$ZIP" "$DSYM_ZIP" "$NOTES"; do say "  $(basename "$file")"; done
if [ "${#SKIPPED[@]}" -gt 0 ]; then
	say "skipped ${#SKIPPED[@]} step(s) that need Apple credentials:"
	for line in "${SKIPPED[@]}"; do say "  - $line"; done
	say "every other step passed; this build is for checking, not for distribution (README \"Releasing\")"
	exit 1
fi
say "Athina $VERSION is signed, notarized, stapled, and verified; publish $(basename "$DMG") and tag it: git tag $TAG"
