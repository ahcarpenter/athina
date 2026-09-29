# Releasing

Athina's releases go out directly, as a download from outside the App Store:
signed with a Developer ID, notarized by Apple, with no App Sandbox and no App
Review; until the Developer ID exists, CI releases them unsigned instead (see
[Unsigned releases](#unsigned-releases)). `make release` (`scripts/release.sh`) does all of it, on the owner's
Mac or in CI, whose release workflow runs it on every push to main and
publishes a release for each version tag, which release-please makes (see
[Each release](#each-release) and [CI](#ci)):

1. Builds the Release configuration for Apple silicon and Intel in one binary,
   without the end-to-end harness's control API, and fails if the binary
   carries any of it (`scripts/check-no-control-api.sh`, see [The control API](e2e.md#the-control-api)).
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
   as `Athina-<version>.zip` holding the stapled app, with the SHA-256 of
   both in `Athina-<version>-checksums.txt` (`shasum -a 256 -c` checks them).
5. Verifies what people download: `codesign --verify --deep --strict`, the
   hardened runtime flag and the exact entitlements, that the app inside the
   disk image and the zip is the one signed (the same code directory hash) and
   still verifies there, and Gatekeeper's
   `spctl` assessment of the app and the disk image as notarized Developer ID.
6. Keeps `Athina-<version>.dSYM.zip`, the debug symbols of exactly that binary,
   for reading crash reports, and Apple's notary logs.
7. Writes `Athina-<version>-notes.md`: the version and build, install steps,
   any notes written by hand in `docs/release-notes/<version>.md` as they are,
   headings included, then the Conventional Commit titles since the previous
   release's tag, grouped as breaking changes, features, bug fixes,
   performance and reverts (the other types, such as `docs`, `ci` or
   `refactor`, are left out, as release-please leaves them out), and the
   SHA-256 of both downloads. It only reads `docs/`, never writes there.

Everything lands in `build/release`. The version is set in one place,
`Resources/Info.plist`: `CFBundleShortVersionString` is what people see
(1.2.3), `CFBundleVersion` a whole number that grows with every release. Every
build carries both, and the release names its files and notes from them.

## Once, before the first signed release

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

For a release from CI, the same account also sets the secrets in [CI's
secrets](#cis-secrets).

## Each release

release-please (`.github/workflows/release-please.yml`, configured by
`release-please-config.json` and `.release-please-manifest.json`) keeps one
release pull request open, `chore(release): <version>`, and updates it on every
push to main from the Conventional Commit titles since the last release. It
proposes the next version: a `feat` raises the minor version and a `fix` or
`perf` the patch, and a breaking change (`type!:`) the major version, or,
before 1.0.0, the minor version. It sets that version as
`CFBundleShortVersionString` in `Resources/Info.plist` and in the manifest,
and the workflow then raises `CFBundleVersion` on the same branch to one more
than main's, so every release has a higher build number. Its entry in
`CHANGELOG.md`, which release-please writes and nobody edits, lists the
titles by the headings the release notes use (a breaking change of a type the
notes leave out, such as `refactor!:`, also appears under that type).

1. When Athina is ready to release, read the release pull request: the
   version and its `CHANGELOG.md` entry. Anything more to say to the people
   using Athina goes, if you like, in `docs/release-notes/<version>.md`
   (`## What's new`, say), merged to main first, and is set before the titles
   in the notes the build writes. To release a version other than the one
   proposed, such as 1.0.0, set `"release-as": "1.0.0"` in
   `release-please-config.json` in a pull request, and take it out again
   after that release.
2. Close and reopen the release pull request, then take it through the merge
   queue like any other ([Continuous integration](ci.md)). GitHub runs no
   workflow for what the workflow's own `GITHUB_TOKEN` does, so a pull request
   release-please opened or pushed to has no checks until a person reopens
   it, which runs them all on its head; do it again after any later push to
   main has updated it. release-please can open the pull request only while
   the repository's Settings > Actions > General > Workflow permissions allows
   GitHub Actions to create and approve pull requests.
3. Once it lands, the next run of the workflow tags its commit `v<version>`
   and makes the GitHub Release, with its changelog entry as the notes, then
   calls the release workflow for the tag, which builds and verifies, adds
   the download's files to that release and gives it the notes the build
   wrote in place of the changelog entry (see [CI](#ci)).

The tag is what the next release's build number has to exceed and what
stops a version being built twice. Pushing a version tag by hand still
releases, as below, but raising the version by hand leaves release-please's
manifest behind, so a release goes through the release pull request.

To release from the Mac instead, or to rehearse one first:

1. From a clean checkout of the version's commit:

   ```sh
   ATHINA_NOTARY_PROFILE=athina-notary make release
   ```

   `ATHINA_RELEASE_IDENTITY=<name or SHA-1>` chooses the identity when the
   keychain holds more than one Developer ID Application identity; with one,
   it is found. The release refuses a worktree with changes, a version whose
   tag already points at another commit, and a build number no higher than
   the last release's.
2. Check the release build itself end to end, in replay as always:
   `ATHINA_E2E_APP=build/release/Athina.app scripts/e2e/athina-e2e run all`.
   That covers the real-screen tier; step 1's check proves the build carries
   no control API, so each API-tier scenario reports `skip`, and the API tier
   runs on the development build of the same commit
   (`scripts/e2e/athina-e2e run all` without `ATHINA_E2E_APP`).
3. To publish it yourself, make a GitHub Release of the disk image and the
   zip, for anyone who prefers it, with the checksums file and the debug
   symbols, and `Athina-<version>-notes.md` as its notes, then push the
   version's tag on that commit (`git tag v0.2.0 && git push origin v0.2.0`);
   CI then puts its own build's files in that release in place of yours, and
   leaves your notes.

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
missing identity or profile) in the notes, and exits 1, or 0 with
`ATHINA_RELEASE_ALLOW_SKIPS=1`, as CI builds without its secrets. Without an
identity the notes open with how to open an unsigned release (see [Unsigned
releases](#unsigned-releases)); with an identity but no profile they are
marked "Not for distribution". A profile that is set but does not work, or an identity that is named
but missing, fails before anything is built.

## CI

`.github/workflows/release.yml` runs `make release` on GitHub's `macos-26`
runner:

- **On every push to main**, beside the whole suite that `ci.yml` and
  `snapshots.yml` run there ([Continuous integration](ci.md)), so the
  artifact a release would ship is proven on every merge. With the secrets
  below it signs and notarizes; without them it builds signed ad hoc, as
  above, passes, and the job summary names the missing secrets. The job
  summary shows the notes, and the `release-build` artifact holds everything
  in `build/release` but `Athina.app` itself, which the disk image and the
  zip hold.
- **For a version tag** (`v1.2.3`), one release-please made, for which
  `.github/workflows/release-please.yml` calls this workflow, or one pushed by
  hand, it first checks that the tag is
  `v` and the version `Resources/Info.plist` sets, on a commit on main. Then
  it builds and verifies, and publishes a GitHub Release named `Athina
  <version>` with the disk image, the zip, the checksums file and the debug
  symbols, its notes `Athina-<version>-notes.md` without their title line.
  It releases in one of two modes, by the secrets below:
  - **Signed**, with every secret: signed with the Developer ID, notarized
    and stapled, as `make release` does with the identity and the profile.
  - **Unsigned**, with none: signed ad hoc, not notarized, and its notes say
    so at the top (see [Unsigned releases](#unsigned-releases)). This is how
    Athina releases until the Developer ID exists; setting the secrets
    switches every later release to signed, with no other change.

  With only some of the secrets it fails, so a half-configured signing setup
  never ships an unsigned release unnoticed.

A release that already exists for the tag gets the files, replacing any of
the same name. One made by hand keeps its own notes, so it works as it is;
one release-please made, which creates the release and its tag from the
Conventional Commit titles, takes `Athina-<version>-notes.md` in place of its
changelog entry, so an unsigned release still opens with how to open it.
release-please's tag is pushed with the
workflow's own `GITHUB_TOKEN`, which starts no workflow, so the release-please
workflow calls this one for it rather than a tag push starting it, and needs
no other token.

### Unsigned releases

An unsigned release is the same build as a signed one, signed ad hoc with the
bundle-identifier requirement a development build has ([Code
signing](#code-signing)), and not notarized. Its notes open with what someone
downloading it has to do:

- **Open it the first time**, and after each update: Gatekeeper refuses an
  app Apple has not notarized, so they open Athina, choose Done, then choose
  Open Anyway next to it in System Settings > Privacy & Security and confirm.
- **Allow the key again after each update**: the keychain trusts an ad-hoc
  app by its exact binary, so each new version asks once to read the saved
  API key (Always Allow). Screen Recording and Accessibility carry over,
  since the grant is recorded against the bundle identifier, which every
  version meets; they hold for the first signed release too ([A released copy
  and your data, grants, and key](#a-released-copy-and-your-data-grants-and-key)).

### CI's secrets

The owner sets these in the repository's Settings > Secrets and variables >
Actions, or with `gh secret set <name>`, which asks for the value so it stays
out of the shell's history, from what [Once, before the first
signed release](#once-before-the-first-signed-release) made. The workflow puts them in a
keychain made for the run and deletes it at the end.

| Secret | What it holds | How to make it |
| --- | --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | the Developer ID Application certificate and its private key, as a base64 .p12 | the backup .p12 from step 2 (Keychain Access > My Certificates, the `Developer ID Application` item, File > Export Items, with a password), then `base64 -i Athina.p12 \| gh secret set DEVELOPER_ID_CERTIFICATE` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12's password | the password given at export |
| `NOTARY_APPLE_ID` | the Apple ID releases go out under | the one from step 1 |
| `NOTARY_TEAM_ID` | the team ID | the ten characters in parentheses in the identity's name |
| `NOTARY_PASSWORD` | an app-specific password for that Apple ID | a new one made as in step 3, named for CI so it can be revoked alone |

The run stores the notary credentials as it starts, and Apple checks them
then, so a wrong one fails before anything is built.

## A released copy and your data, grants, and key

A released copy is the same app as a development build: bundle identifier
`com.ahcarpenter.athina`, no sandbox, so the same
`~/Library/Application Support/athina`, the same preferences and the same
keychain item. It shares the live journal, settings and bill with `make
run-live`, so do not run both: `make run-live` refuses to start while a live
Athina runs,
wherever it was installed.

- **Grants.** A grant made to a released copy is recorded against its Developer
  ID requirement, so every later release keeps it. Grants made earlier to an
  ad-hoc development build, recorded against the bundle identifier alone,
  hold for a released copy too; the reverse does not, and an ad-hoc build
  then reports the permission missing ([Code signing](#code-signing)). Once the Developer ID
  certificate is in the keychain, `make build` signs development builds with
  it as well when it is the identity `scripts/bundle.sh` picks (the first
  Apple Development or Developer ID Application one the keychain lists), or
  when `ATHINA_SIGN_IDENTITY` names it, so both meet one requirement.
- **The key.** The login keychain trusts a Developer ID app by its team rather
  than its exact binary, so a released copy asks once, Always Allow, to read a
  key a development build saved, and later releases do not ask.

Athina ships only this way, not through the App Store, whose App Sandbox
would move the app's data into a container, so the data move and the grants
above work as written.

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
is signed by `make release` instead (see [Releasing](#releasing)).

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
