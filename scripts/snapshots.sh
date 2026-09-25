#!/usr/bin/env bash
# UI snapshot gates: render every snapshot the way CI does, compare the
# renders with the approved set, and approve a drift from the renders CI made
# (README "UI snapshot baselines" and "UI snapshot smoke test").
#
# Usage: scripts/snapshots.sh <command>
#   gate [<k>/<n>]  what CI runs: render twice, fail unless the two renders
#                   are the same picture, then fail on any drift from the
#                   baselines; with k/n, only the snapshots CI shard k of n
#                   renders and compares (SnapshotShard, in Sources/SnapshotDiff)
#   approve [<run>] make the baselines match the renders of CI run <run>, every
#                   shard's together, by default the newest CI run of this
#                   checkout's HEAD commit
#   smoke [<k>/<n>] what CI's ui-snapshots-smoke runs: draw every snapshot in
#                   the test process with swift-snapshot-testing and fail on any
#                   drift from its reference image; with k/n, only the snapshots
#                   CI shard k of n draws, by the same SnapshotShard table
#   smoke-approve [<run>]
#                   make the smoke test's references match the sets CI run <run>
#                   published, every shard's together, by default the newest CI
#                   run of HEAD
#
# Output lands in build/snapshots: render-first/ and render-again/ hold the two
# renders; render/ holds the first once both finished and agree, with
# source-tree naming the git tree they were made from, and is what CI uploads
# for approve, with shard naming the shard it holds when there is one;
# report/index.html shows each drifted snapshot before, after, and
# where it changed, and determinism/ the same for two renders that did not match.
#
# The smoke test's output lands in build/snapshots-smoke: references/ holds the
# set approving takes, every matching snapshot's reference and every other
# one's new render, with source-tree and shard as above, once every snapshot
# the run draws has rendered;
# drift/ holds the reference, the render and the difference of each snapshot
# that drifted; summary.md names them.
#
# ATHINA_APP names the app to render with (build/Athina.app by default).
# Exit: 0 match, 1 drift or renders that differ, 2 bad usage or a step that
# could not run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINES="$ROOT/Tests/Snapshots"
OUT="$ROOT/build/snapshots"
SMOKE_REFERENCES="$ROOT/Tests/UISnapshotsSmokeTests/__Snapshots__/UISnapshotsSmokeTests"
SMOKE_OUT="$ROOT/build/snapshots-smoke"
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
  TZ=UTC "$APP/Contents/MacOS/Athina" --snapshot "$dir" ${render_shard[@]+"${render_shard[@]}"} \
    -AppleLocale en_US -AppleLanguages '(en-US)' -AppleICUForce24HourTime NO -AppleShowScrollBars Always \
    || die "could not render every snapshot into $dir"
}

command="${1:-}"
case "$command" in
  gate)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh gate [<k>/<n>]"
    shard="${2:-}"
    render_shard=()
    diff_shard=()
    if [ -n "$shard" ]; then
      render_shard=(--snapshot-shard "$shard")
      diff_shard=(--shard "$shard")
    fi
    rm -rf "$OUT/render" "$OUT/report" "$OUT/determinism"
    render "$OUT/render-first"
    render "$OUT/render-again"
    # Two renders of one build must be the same picture, by the rule the
    # baselines are held to, or a baseline could never be trusted to hold still.
    status=0
    diff_tool agree "$OUT/render-first" "$OUT/render-again" --report "$OUT/determinism" ${diff_shard[@]+"${diff_shard[@]}"} || status=$?
    if [ "$status" -eq 1 ]; then
      echo "snapshots: two renders of the same build differ; the renderer is not deterministic (see build/snapshots/determinism)" >&2
    fi
    [ "$status" -eq 0 ] || exit "$status"
    rm -rf "$OUT/determinism"
    git -C "$ROOT" rev-parse 'HEAD^{tree}' > "$OUT/render-first/source-tree"
    [ -z "$shard" ] || echo "$shard" > "$OUT/render-first/shard"
    mv "$OUT/render-first" "$OUT/render"
    diff_tool compare "$BASELINES" "$OUT/render" --report "$OUT/report" ${diff_shard[@]+"${diff_shard[@]}"}
    ;;

  approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh approve [<run id>]"
    command -v gh >/dev/null || die "approving needs the GitHub CLI (gh) to fetch the runner's renders"
    run="${2:-}"
    head="$(git -C "$ROOT" rev-parse HEAD)"
    tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
    if [ -z "$run" ]; then
      run="$(gh run list --workflow merge-checks.yml --commit "$head" --status completed --limit 20 --json databaseId,conclusion --jq 'map(select(.conclusion != "skipped")) | .[0].databaseId // empty')" \
        || die "could not list the merge-checks runs of HEAD ($head)"
      [ -n "$run" ] || die "no finished merge-checks run of HEAD ($head); push it with the merge-checks label on its pull request and let the run finish, or name a run"
    fi
    # Each shard uploads the renders of its own snapshots as
    # ui-snapshots-shard-<k>; approving takes them all together, and only
    # when every shard's are there, since a missing shard's snapshots would
    # read as removed and have their baselines deleted.
    rm -rf "$OUT/approved-run" "$OUT/approved-shards"
    gh run download "$run" --pattern 'ui-snapshots-shard-*' --dir "$OUT/approved-shards" \
      || die "could not download the renders of CI run $run"
    first="$(cat "$OUT/approved-shards/ui-snapshots-shard-1/shard" 2>/dev/null)" \
      || die "CI run $run has no renders from shard 1 to approve; a shard publishes them only when both its renders finished and agree"
    count="${first#*/}"
    mkdir -p "$OUT/approved-run"
    for k in $(seq 1 "$count"); do
      dir="$OUT/approved-shards/ui-snapshots-shard-$k"
      [ "$(cat "$dir/shard" 2>/dev/null)" = "$k/$count" ] \
        || die "CI run $run has no renders from shard $k of $count to approve; a shard publishes them only when both its renders finished and agree"
      run_tree="$(cat "$dir/source-tree" 2>/dev/null)" \
        || die "shard $k of CI run $run does not name the source tree it rendered, so its renders cannot be matched to HEAD"
      [ "$run_tree" = "$tree" ] \
        || die "CI run $run rendered source tree $run_tree, not HEAD's ($tree), and approving it would bake another tree's UI into these baselines; a pull request's run renders the branch merged with main, so merge or rebase onto main, push, and approve the run CI makes of that"
      cp "$dir"/*.png "$OUT/approved-run/"
    done
    extra="$(find "$OUT/approved-shards" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    [ "$extra" -eq "$count" ] || die "CI run $run has renders from $extra shards, not $count"
    diff_tool approve "$BASELINES" "$OUT/approved-run"
    echo "snapshots: review the changed images (git status Tests/Snapshots), then commit them with the change that caused them"
    ;;

  smoke)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh smoke [<k>/<n>]"
    shard="${2:-}"
    rm -rf "$SMOKE_OUT"
    mkdir -p "$SMOKE_OUT"
    # SNAPSHOT_ARTIFACTS keeps swift-snapshot-testing's own copy of each
    # failing render in this checkout rather than the temporary folder; the
    # test reads the shard from UI_SNAPSHOTS_SMOKE_SHARD, since swift test
    # passes a test no arguments.
    status=0
    (cd "$ROOT" && SNAPSHOT_ARTIFACTS="$SMOKE_OUT/artifacts" UI_SNAPSHOTS_SMOKE_SHARD="$shard" \
      swift test --traits UISnapshotsSmoke --filter UISnapshotsSmokeTests) || status=1
    if [ -d "$SMOKE_OUT/references" ]; then
      git -C "$ROOT" rev-parse 'HEAD^{tree}' > "$SMOKE_OUT/references/source-tree"
      if [ -n "$shard" ]; then echo "$shard" > "$SMOKE_OUT/references/shard"; fi
    fi
    {
      echo "## UI snapshot smoke test${shard:+, shard $shard}"
      echo
      if [ -d "$SMOKE_OUT/drift" ] && [ -n "$(ls -A "$SMOKE_OUT/drift")" ]; then
        echo "Drifted from its reference, or has none yet (the shard's ui-snapshots-smoke-report artifact holds each one's images):"
        echo
        for snapshot in "$SMOKE_OUT"/drift/*; do echo "- \`$(basename "$snapshot")\`"; done
      elif [ "$status" -eq 0 ]; then
        echo "Every snapshot matches its reference."
      else
        echo "No snapshot drifted, but the test failed; see its output."
      fi
    } > "$SMOKE_OUT/summary.md"
    exit "$status"
    ;;

  smoke-approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh smoke-approve [<run id>]"
    command -v gh >/dev/null || die "approving needs the GitHub CLI (gh) to fetch the runner's renders"
    run="${2:-}"
    head="$(git -C "$ROOT" rev-parse HEAD)"
    tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
    if [ -z "$run" ]; then
      run="$(gh run list --workflow ci.yml --commit "$head" --status completed --limit 1 --json databaseId --jq '.[0].databaseId // empty')" \
        || die "could not list the CI runs of HEAD ($head)"
      [ -n "$run" ] || die "no finished CI run of HEAD ($head); push it and let CI finish, or name a run"
    fi
    # Each shard uploads the set for its own snapshots as
    # ui-snapshots-smoke-shard-<k>; approving takes them all together, and only
    # when every shard's is there, since a missing shard's snapshots would read
    # as removed and have their references deleted.
    rm -rf "$SMOKE_OUT/approved-run" "$SMOKE_OUT/approved-shards"
    gh run download "$run" --pattern 'ui-snapshots-smoke-shard-*' --dir "$SMOKE_OUT/approved-shards" \
      || die "could not download the sets of CI run $run"
    first="$(cat "$SMOKE_OUT/approved-shards/ui-snapshots-smoke-shard-1/shard" 2>/dev/null)" \
      || die "CI run $run has no set from shard 1 to approve; a shard publishes one only once every snapshot it draws has rendered"
    count="${first#*/}"
    mkdir -p "$SMOKE_OUT/approved-run"
    for k in $(seq 1 "$count"); do
      dir="$SMOKE_OUT/approved-shards/ui-snapshots-smoke-shard-$k"
      [ "$(cat "$dir/shard" 2>/dev/null)" = "$k/$count" ] \
        || die "CI run $run has no set from shard $k of $count to approve; a shard publishes one only once every snapshot it draws has rendered"
      run_tree="$(cat "$dir/source-tree" 2>/dev/null)" \
        || die "shard $k of CI run $run does not name the source tree it rendered, so its renders cannot be matched to HEAD"
      [ "$run_tree" = "$tree" ] \
        || die "CI run $run rendered source tree $run_tree, not HEAD's ($tree), and approving it would bake another tree's UI into the references; a pull request's run renders the branch merged with main, so merge or rebase onto main, push, and approve the run CI makes of that"
      cp "$dir"/*.png "$SMOKE_OUT/approved-run/"
    done
    extra="$(find "$SMOKE_OUT/approved-shards" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    [ "$extra" -eq "$count" ] || die "CI run $run has sets from $extra shards, not $count"
    # The shards' sets together are every reference the test compares, so they
    # replace the folder whole: a matching snapshot's file comes back byte for
    # byte and shows no change, and a removed snapshot's reference goes.
    mkdir -p "$SMOKE_REFERENCES"
    find "$SMOKE_REFERENCES" -name '*.png' -delete
    cp "$SMOKE_OUT"/approved-run/*.png "$SMOKE_REFERENCES/"
    echo "snapshots: review the changed images (git status Tests/UISnapshotsSmokeTests), then commit them with the change that caused them"
    ;;

  *)
    die "usage: scripts/snapshots.sh gate [<k>/<n>] | approve [<run id>] | smoke [<k>/<n>] | smoke-approve [<run id>]"
    ;;
esac
