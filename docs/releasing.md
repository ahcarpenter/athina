# Releasing

The first releases go out directly, as a download from outside the App Store:
signed with a Developer ID, notarized by Apple, with no App Sandbox and no App
Review. `make release` (`scripts/release.sh`) does all of it:

1. Builds the Release configuration for Apple silicon and Intel in one binary,
   without the end-to-end harness's control API, and fails if the binary
   carries any of it (`scripts/check-no-control-api.sh`, see The control API).
2. Signs it under the hardened runtime, which notarization requires, with a
   secure timestamp and `Resources/Athina.entitlements`, whose comments say
   why each entitlement is there (only `device.audio-input` today, for the
   talk-back microphone). Athina embeds no library yet; the libraries it will
   load from `Contents/Frameworks`, such as the local speech models' runtime
   (whisper.cpp for Whisper and Parakeet), are signed first with the same
   identity, so library validation loads them.
3. Submits the app to Apple's notary service, waits for the verdict, and
   staples the ticket to it.
4. Packages it as `Athina-<version>.dmg`, the app beside a link to
   Applications, signs the disk image, notarizes it, and staples it too; and
   as `Athina-<version>.zip` holding the stapled app.
5. Verifies what people download: `codesign --verify --deep --strict`, the
   hardened runtime flag and the exact entitlements, that the app inside the
   disk image and the zip is the one signed (the same code directory hash) and
   still verifies there, and Gatekeeper's
   `spctl` assessment of the app and the disk image as notarized Developer ID.
6. Keeps `Athina-<version>.dSYM.zip`, the debug symbols of exactly that binary,
   for reading crash reports, and Apple's notary logs.
7. Writes `Athina-<version>-notes.md`: the version and build, install steps,
   the notes written by hand in `docs/release-notes/<version>.md` as they are,
   headings included, and the SHA-256 of both downloads. Without that file it
   puts a marked placeholder in their place and names the file to create. It
   only reads `docs/`, never writes there.

Everything lands in `build/release`. The version is set in one place,
`Resources/Info.plist`: `CFBundleShortVersionString` is what people see
(1.2.3), `CFBundleVersion` a whole number that grows with every release. Every
build carries both, and the release names its files and notes from them.

## Once, before the first release

These need the owner's Apple account, so only the owner can do them. Nothing they
create goes in the repository.

1. Join the Apple Developer Program at developer.apple.com, with the Apple ID
   releases go out under.
2. Create a Developer ID Application certificate: Xcode > Settings > Accounts,
   select the team, Manage Certificates, then + > Developer ID Application
   (only the account holder can). Xcode puts it and its private key in the
   login keychain. Export a backup (.p12) and keep it somewhere safe: a lost
   private key means a new certificate. `security find-identity -v -p
   codesigning` then lists `Developer ID Application: <name> (<team ID>)`.
3. Make an app-specific password at account.apple.com > Sign-In and Security >
   App-Specific Passwords, and store it for the notary service under a profile
   name of your choosing:

   ```sh
   xcrun notarytool store-credentials athina-notary --apple-id <Apple ID> --team-id <team ID>
   ```

   It asks for the password and keeps it in the login keychain; `make release`
   names the profile, never the password.

## Each release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`, write what changed for the people using Athina in
   `docs/release-notes/<version>.md` (`## What's new`, say), and commit both
   (`chore(release): 0.2.0`). The notes live there, not in `build/release`,
   which every `make release` replaces.
2. From a clean checkout of that commit:

   ```sh
   ATHINA_NOTARY_PROFILE=athina-notary make release
   ```

   `ATHINA_RELEASE_IDENTITY=<name or SHA-1>` chooses the identity when the
   keychain holds more than one Developer ID Application identity; with one,
   it is found. The release refuses a worktree with changes, a version whose
   tag already points at another commit, and a build number no higher than
   the last release's.
3. Check the release build itself end to end, in replay as always:
   `ATHINA_E2E_APP=build/release/Athina.app scripts/e2e/athina-e2e run all`.
   That covers the real-screen tier; step 1's check proves the build carries
   no control API, so each API-tier scenario reports `skip`, and the API tier
   runs on the development build of the same commit
   (`scripts/e2e/athina-e2e run all` without `ATHINA_E2E_APP`).
4. Publish the disk image (and the zip, for anyone who prefers it) with
   `Athina-<version>-notes.md` as its notes, and tag the commit:
   `git tag v0.2.0 && git push origin v0.2.0`. The tag is what the next
   release's build number has to exceed and what stops a version being built
   twice.

There are no automatic updates yet: a new version is downloaded and dragged
over the old one.

Without the identity or the profile, `make release` still runs every step
that needs no Apple credentials: the hardened runtime build, signed ad-hoc
with the same bundle-identifier requirement a development build has, the disk
image and zip, and every check that needs no Apple service. (Library
validation loads only libraries signed by the app's own team, which an ad-hoc
signature lacks, so once the bundle embeds libraries, such as the local speech
models' runtime, that local build alone turns library validation off; a
Developer ID release never does.) It names each step it skipped and why (the
missing identity or profile), marks the notes "Not for distribution", and
exits 1. A profile that is set but does not work, or an identity that is named
but missing, fails before anything is built.

## A released copy and your data, grants, and key

A released copy is the same app as a development build: bundle identifier
`com.ahcarpenter.athina`, no sandbox, so the same
`~/Library/Application Support/athina`, the same preferences and the same
keychain item. It shares the live journal, settings and bill with `make
run-live`, so do not run both: `make run-live` refuses to start while a live
Athina runs,
wherever it was installed.

- **Coming from Mentor.** The move of `~/Library/Application Support/mentor`,
  the preferences and the key (Coming from Mentor) runs on the first live
  launch of whichever Athina comes first, released or development, and only
  once.
- **Grants.** A grant made to a released copy is recorded against its Developer
  ID requirement, so every later release keeps it. Grants made earlier to an
  ad-hoc development build, recorded against the bundle identifier alone,
  hold for a released copy too; the reverse does not, and an ad-hoc build
  then reports the permission missing (Code signing). Once the Developer ID
  certificate is in the keychain, `make build` signs development builds with
  it as well when it is the identity `scripts/bundle.sh` picks (the first
  Apple Development or Developer ID Application one the keychain lists), or
  when `ATHINA_SIGN_IDENTITY` names it, so both meet one requirement.
- **The key.** The login keychain trusts a Developer ID app by its team rather
  than its exact binary, so a released copy asks once, Always Allow, to read a
  key a development build saved, and later releases do not ask.

The App Store is a separate route: it needs the App Sandbox, which moves the
app's data into a container, and App Review. None of that applies here, so
the data move and the grants above work as written.

## Code signing

The bundle script signs with `$ATHINA_SIGN_IDENTITY` if set, otherwise with the
first Apple Development or Developer ID Application identity in the keychain,
otherwise ad-hoc. macOS ties Screen Recording and Accessibility grants to the
app's designated code requirement, recorded when the grant is made. An ad-hoc
signature's default requirement is the hash of the exact binary, so a plain
ad-hoc rebuild silently invalidates both grants: System Settings still shows
the switches on, toggling them does not help, and the TCC daemon logs
"Failed to match existing code requirement". The ad-hoc path therefore signs
with an explicit requirement on the bundle identifier
(`identifier "com.ahcarpenter.athina"`), which every rebuild satisfies, so a
grant made once stays valid. The trade-off is that any ad-hoc binary claiming
that identifier would inherit the grants, which is acceptable on a development
machine and is exactly what a development certificate fixes. This is the
development signature, without the hardened runtime or a timestamp; a release
is signed by `make release` instead (see Releasing).

The keychain is stricter than TCC: for an app that is not Apple-signed it
trusts a keychain item's readers by the hash of the exact binary, so the
first time a rebuilt ad-hoc Athina reads the API key, macOS can show its
"Athina wants to access key" prompt. The app reads the key off the main
thread and keeps sensing behind the prompt, but makes no live call until it
is answered. Always Allow adds that build to the item's list; Deny leaves the
loop without a key until the next launch. A replay never reads the key, so it
never shows the prompt. A development certificate makes this go away too.

If a grant was made against an older build (the app shows a permission as
missing although System Settings shows it on), remove the stale record and
grant again:

```sh
tccutil reset Accessibility com.ahcarpenter.athina
tccutil reset ScreenCapture com.ahcarpenter.athina
```

## A sandboxed build

The same binary can run in the App Sandbox, which a Mac App Store edition
needs; the Xcode project's `Athina App Store` target builds it, signed with
`Resources/Athina.app-store.entitlements` (see The Xcode project). At launch
`RuntimeEnvironment` reads the process's own `com.apple.security.app-sandbox`
entitlement, which the direct and development builds carry set to false, so
they run exactly as described everywhere else in this README. A sandboxed run
differs in three ways:

- Its files are in its container, its preferences domain and its keychain
  service are its own bundle identifier rather than `com.ahcarpenter.athina`
  (`AppPaths`), so it never shares preferences or a key with the direct build.
- It moves nothing from Mentor, neither files, preferences nor the API key
  (see Coming from Mentor), since all three are out of its reach, and says so
  once in the log.
- `--replay` and `--settings` may name only a path inside its container or its
  own bundle, and `--record`, `--snapshot` and a clock request's reply
  (`scripts/advance-clock.sh`) only one inside its container. Anything else is
  refused with one line naming the path and where it could have been.
- `--control` is refused whatever it names: a sandboxed Athina never serves
  the control API, even one built from the development bundle.

## The Xcode project

The Mac App Store route needs what only an Xcode project gives: automatic
signing with provisioning profiles, archiving, and uploading to App Store
Connect. `project.yml` is its committed spec, and `make xcodeproj` generates
`Athina.xcodeproj` from it with XcodeGen, pinned by version in
`Tools/XcodeGenTool` (its `Package.resolved` is committed), which SwiftPM
builds on first use, so nothing is installed and every Mac generates the
same project. The generated project is not committed, so no `project.pbxproj`
is ever merged by hand: change `project.yml` and regenerate. Opening the
project in Xcode starts with `make xcodeproj`, then `open Athina.xcodeproj`;
run it again after changing `project.yml` or adding or removing a source file.
The tools package is not part of the app's package, so `make build`, `make
test`, `scripts/bundle.sh`, `make release` and CI never fetch or build XcodeGen.
CI does not generate or archive the project: that check left CI until the App
Store release flow brings it back as part of that flow.

The project has one target, `Athina App Store`, and a scheme of the same name
whose Archive action builds Release. It compiles `Sources/Athina` against the
package's `AthinaCore` and `SnapshotDiff`, linking the frameworks the package's
`Athina` target does (a dependency or framework added to one goes in the other
too, except the `ControlAPI`-conditional `AthinaControl`, which the App Store
build never carries; see The control API), bundles the same icon and menu bar
marks `scripts/bundle.sh` does, and signs with
`Resources/Athina.app-store.entitlements` (the App Sandbox, `network.client`,
and the microphone keys of both the hardened runtime, `device.audio-input`,
and the sandbox, `device.microphone`). Its Info.plist is `Resources/Info.plist`
with `CFBundleIdentifier` rewritten at build time to the target's
`PRODUCT_BUNDLE_IDENTIFIER`, so the version and every other key are still set
in one place. That id is set only in `project.yml`, and is the development id
`com.ahcarpenter.athina.appstore.dev` until the permanent App Store id is
chosen, which can never change once a build is uploaded. Signing is automatic
and `DEVELOPMENT_TEAM` is left empty: until a team id is filled in there, the
target signs to run locally, as `xcodebuild` or Xcode builds and archives it;
with one, Xcode signs with that
team's Apple Development certificate and Product > Archive feeds the
Organizer's App Store Connect upload. The built app is sandboxed, so it keeps
its files in its own container and runs as A sandboxed build describes. The
App Store build is archived and uploaded through this project, while the
direct Developer ID release keeps `scripts/release.sh` (see Releasing); the
earlier plan to package the App Store build from the package build with
`productbuild` and `altool` is superseded.
