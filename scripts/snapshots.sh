#!/usr/bin/env bash
# UI snapshot baselines: render every snapshot the way CI does, compare the
# renders with the approved set in Tests/Snapshots, and approve a drift from
# the renders CI made (README "UI snapshot baselines").
#
# Usage: scripts/snapshots.sh <command>
#   render <dir>    render every snapshot into <dir>, light and dark
#   check           render here and compare with the baselines; advisory, since
#                   a Mac on another macOS renders differently from the runner
#   gate            what CI runs: render twice, fail unless the two renders
#                   are the same picture, then fail on any drift from the baselines
#   approve [<run>] make the baselines match the renders of CI run <run>, by
#                   default the newest CI run of this checkout's HEAD commit
#
# Output lands in build/snapshots: render/ and render-again/ hold the renders,
# report/index.html shows each drifted snapshot before, after, and where it
# changed, and determinism/ the same for two renders that did not match.
#
# ATHINA_APP names the app to render with (build/Athina.app by default).
# Exit: 0 match (or advisory), 1 drift or renders that differ, 2 bad usage or
# a step that could not run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINES="$ROOT/Tests/Snapshots"
OUT="$ROOT/build/snapshots"
APP="${ATHINA_APP:-$ROOT/build/Athina.app}"

die() { echo "snapshots: $*" >&2; exit 2; }

diff_tool() {
  (cd "$ROOT" && swift build -c release --product snapshot-diff >&2) || die "could not build snapshot-diff"
  "$ROOT/.build/release/snapshot-diff" "$@"
}

# Renders in UTC and US English, with scroll bars always shown as on the
# runner, whatever this Mac is set to: every clock time, date and number a
# view formats then reads the same on every machine. The -Apple* arguments
# reach the app's own preferences for this launch only and change no setting.
render() {
  local dir="$1"
  [ -x "$APP/Contents/MacOS/Athina" ] || die "no app at $APP; run make build first"
  rm -rf "$dir"
  TZ=UTC "$APP/Contents/MacOS/Athina" --snapshot "$dir" \
    -AppleLocale en_US -AppleLanguages '(en-US)' -AppleICUForce24HourTime NO -AppleShowScrollBars Always
}

command="${1:-}"
case "$command" in
  render)
    [ "$#" -eq 2 ] || die "usage: scripts/snapshots.sh render <dir>"
    render "$2"
    ;;

  check)
    render "$OUT/render"
    echo "snapshots: advisory. The baselines are rendered on the CI runner; this Mac runs macOS $(sw_vers -productVersion), so fonts, glass and controls can differ here without any change to the app."
    # A Retina Mac renders at 2x; each render is scaled down to the runner's
    # 1x before comparing, so what differs is layout and colour, not scale.
    diff_tool compare "$BASELINES" "$OUT/render" \
      --report "$OUT/report" --heading "UI snapshots on this Mac (advisory)" --advisory --match-scale
    ;;

  gate)
    render "$OUT/render"
    render "$OUT/render-again"
    # Two renders of one build must be the same picture, by the rule the
    # baselines are held to, or a baseline could never be trusted to hold still.
    if ! diff_tool compare "$OUT/render" "$OUT/render-again" \
      --report "$OUT/determinism" --heading "Two renders of one build that differ"; then
      echo "snapshots: two renders of the same build differ; the renderer is not deterministic (see build/snapshots/determinism)" >&2
      exit 1
    fi
    diff_tool compare "$BASELINES" "$OUT/render" \
      --report "$OUT/report" --heading "UI snapshots against the approved baselines"
    ;;

  approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh approve [<run id>]"
    command -v gh >/dev/null || die "approving needs the GitHub CLI (gh) to fetch the runner's renders"
    run="${2:-}"
    head="$(git -C "$ROOT" rev-parse HEAD)"
    if [ -z "$run" ]; then
      run="$(gh run list --workflow ci.yml --commit "$head" --status completed --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
      [ -n "$run" ] || die "no finished CI run of HEAD ($head); push it and let CI finish, or name a run"
    fi
    run_head="$(gh run view "$run" --json headSha --jq .headSha)"
    [ "$run_head" = "$head" ] || die "CI run $run rendered $run_head, not HEAD ($head); approving it would bake another commit's UI into these baselines"
    rm -rf "$OUT/approved-run"
    gh run download "$run" --name ui-snapshots --dir "$OUT/approved-run" \
      || die "CI run $run has no ui-snapshots artifact to approve"
    diff_tool approve "$BASELINES" "$OUT/approved-run"
    echo "snapshots: review the changed images (git status Tests/Snapshots), then commit them with the change that caused them"
    ;;

  *)
    die "usage: scripts/snapshots.sh render <dir> | check | gate | approve [<run id>]"
    ;;
esac
