#!/usr/bin/env bash
# UI snapshot gates: render every snapshot the way CI does, compare the
# renders with the approved set, and approve a drift from the renders CI made
# (docs/ci.md "UI snapshot baselines" and "UI snapshot smoke test").
#
# Usage: scripts/snapshots.sh <command>
#   gate [<k>/<n>]  what CI runs: render twice, fail unless the two renders
#                   are the same picture, then fail on any drift from the
#                   baselines; with k/n, only the snapshots CI shard k of n
#                   renders and compares (SnapshotShard, in Sources/SnapshotDiff)
#   smoke [<k>/<n>] what CI's ui-snapshots-smoke runs: draw every snapshot in
#                   the test process with swift-snapshot-testing and fail on any
#                   drift from its reference image; with k/n, only the snapshots
#                   shard k of n draws, by the SnapshotShard table the full gate
#                   splits by (CI runs it whole, on one runner)
#   smoke-local [<base>]
#                   what local validation runs: draw the smoke set on this Mac
#                   at HEAD and at <base> (by default HEAD's merge-base with
#                   origin/main) and report every screen that changed, was
#                   added or was removed; fails only when a snapshot could not
#                   be drawn
#   checkpoints [<athina-e2e option> ...]
#                   what CI's e2e-api job runs: every API-tier scenario of the
#                   end-to-end harness, twice, failing unless both runs pass and
#                   their checkpoints are the same pictures, then on any drift of
#                   a checkpoint from its baseline in Tests/Checkpoints; the
#                   options go to `athina-e2e run`, as CI's --launch open does
#   approve         what `make approve` runs: every approval below, each
#                   from the newest completed, non-cancelled run of HEAD that
#                   publishes it; all three are fetched and checked before any
#                   approved image changes, and when one has no run to take,
#                   nothing changes and it fails naming each one missing
#   baselines-approve [<run>]
#                   make the baselines match the renders of merge-checks run
#                   <run>, every shard's together, by default HEAD's newest
#   smoke-approve [<run>]
#                   make the smoke test's references match the set CI run <run>
#                   published for every snapshot, by default HEAD's newest
#   checkpoints-approve [<run>]
#                   make Tests/Checkpoints match the checkpoints CI run <run>
#                   took, by default HEAD's newest
#
# Output lands in build/snapshots: render-first/ and render-again/ hold the two
# renders; render/ holds the first once both finished and agree, with
# source-tree naming the git tree they were made from, and is what CI uploads
# for baselines-approve, with shard naming the shard it holds when there is one;
# report/index.html shows each drifted snapshot before, after, and
# where it changed, and determinism/ the same for two renders that did not match.
#
# The checkpoints' output lands in build/checkpoints, laid out as the
# snapshots' is: render-first/ and render-again/, render/ (with source-tree)
# once both runs passed and agree, report/ and determinism/, and runs/ holding
# each run's evidence.
#
# The smoke test's output lands in build/snapshots-smoke: references/ holds the
# set approving takes, every matching snapshot's reference and every other
# one's new render, with source-tree and shard as above, once every snapshot
# the run draws has rendered;
# drift/ holds the reference, the render and the difference of each snapshot
# that drifted; summary.md names them.
#
# smoke-local writes the same to build/snapshots-smoke-local/pass-<n>, one
# folder a pass, with the base commit's render as each reference, and
# summary.md; it keeps the base renders in
# ~/Library/Caches/athina-snapshots-smoke/<commit>, so every later run off the
# same base draws only HEAD.
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
CHECKPOINT_BASELINES="$ROOT/Tests/Checkpoints"
CHECKPOINTS_OUT="$ROOT/build/checkpoints"
APP="${ATHINA_APP:-$ROOT/build/Athina.app}"

SMOKE_LOCAL_OUT="$ROOT/build/snapshots-smoke-local"
SMOKE_CACHE="$HOME/Library/Caches/athina-snapshots-smoke"
# The longest a smoke test run may take, its build included, before it counts
# as hung.
SMOKE_TIME_LIMIT=1800

die() { echo "snapshots: $*" >&2; exit 2; }

# Runs the smoke test in the package at <root>: in UTC, as `--snapshot` renders,
# comparing with the images in <against> when that is set and writing to <out>
# when that is. Stopped, the whole process group, after SMOKE_TIME_LIMIT.
smoke_test() {
  local root="$1" shard="$2" against="$3" out="$4" waited=0 pid
  set -m
  (cd "$root" && TZ=UTC SNAPSHOT_ARTIFACTS="${out:-$root/build/snapshots-smoke}/artifacts" \
    UI_SNAPSHOTS_SMOKE_SHARD="$shard" UI_SNAPSHOTS_SMOKE_AGAINST="$against" \
    UI_SNAPSHOTS_SMOKE_OUTPUT="$out" \
    swift test --traits UISnapshotsSmoke --filter UISnapshotsSmokeTests) &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$SMOKE_TIME_LIMIT" ]; then
      echo "snapshots: the smoke test in $root ran past ${SMOKE_TIME_LIMIT}s; stopping it" >&2
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

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

# Approving takes the images CI made of HEAD, in two steps: fetch_<kind> finds
# the run, downloads what it published and checks that it is HEAD's own,
# changing nothing in the checkout, and apply_<kind> writes it into the approved
# set. `approve` fetches every kind before it applies any. Each fetch step says
# every failure through die, never through set -e, since `approve` runs it in a
# subshell on the left of ||, where set -e does not apply.

need_gh() {
  command -v gh >/dev/null || die "approving needs the GitHub CLI (gh) to fetch the images CI made"
}

# Prints the newest completed run of <workflow> for HEAD that was neither
# cancelled nor skipped, or dies naming <what> it was wanted for and <hint> on
# how to get one.
newest_run() {
  local workflow="$1" what="$2" hint="$3" head run going
  head="$(git -C "$ROOT" rev-parse HEAD)" || die "no HEAD commit"
  run="$(gh run list --workflow "$workflow" --commit "$head" --status completed --limit 20 --json databaseId,conclusion \
    --jq 'map(select(.conclusion != "skipped" and .conclusion != "cancelled")) | .[0].databaseId // empty')" \
    || die "could not list the $workflow runs of HEAD ($head)"
  if [ -z "$run" ]; then
    going="$(gh run list --workflow "$workflow" --commit "$head" --limit 20 --json databaseId,status \
      --jq 'map(select(.status != "completed")) | .[0].databaseId // empty' 2>/dev/null)" || going=""
    [ -z "$going" ] || die "the $workflow run of HEAD ($head) to take $what from, run $going, has not finished; wait for it"
    die "no finished $workflow run of HEAD ($head) to take $what from; $hint"
  fi
  echo "$run"
}

head_tree() {
  git -C "$ROOT" rev-parse 'HEAD^{tree}' || die "no HEAD tree"
}

# The ui-snapshots baselines, from merge-checks run <run> or HEAD's newest.
fetch_baselines() {
  local run="${1:-}" tree first count k dir run_tree extra
  need_gh
  if [ -z "$run" ]; then
    run="$(newest_run merge-checks.yml "the ui-snapshots baselines" \
      "push it with the merge-checks label on its pull request and let the run finish")" || exit 2
  fi
  tree="$(head_tree)" || exit 2
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
  mkdir -p "$OUT/approved-run" || die "could not make $OUT/approved-run"
  for k in $(seq 1 "$count"); do
    dir="$OUT/approved-shards/ui-snapshots-shard-$k"
    [ "$(cat "$dir/shard" 2>/dev/null)" = "$k/$count" ] \
      || die "CI run $run has no renders from shard $k of $count to approve; a shard publishes them only when both its renders finished and agree"
    run_tree="$(cat "$dir/source-tree" 2>/dev/null)" \
      || die "shard $k of CI run $run does not name the source tree it rendered, so its renders cannot be matched to HEAD"
    [ "$run_tree" = "$tree" ] \
      || die "CI run $run rendered source tree $run_tree, not HEAD's ($tree), and approving it would bake another tree's UI into these baselines; a pull request's run renders the branch merged with main, so merge or rebase onto main, push, and approve the run CI makes of that"
    cp "$dir"/*.png "$OUT/approved-run/" || die "could not copy the renders of shard $k of CI run $run"
  done
  extra="$(find "$OUT/approved-shards" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$extra" -eq "$count" ] || die "CI run $run has renders from $extra shards, not $count"
}

apply_baselines() {
  diff_tool approve "$BASELINES" "$OUT/approved-run"
  echo "snapshots: review the changed images (git status Tests/Snapshots), then commit them with the change that caused them"
}

# The ui-snapshots-smoke references, from CI run <run> or HEAD's newest.
fetch_smoke() {
  local run="${1:-}" tree run_tree
  need_gh
  if [ -z "$run" ]; then
    run="$(newest_run ci.yml "the ui-snapshots-smoke references" "push it and let CI finish")" || exit 2
  fi
  tree="$(head_tree)" || exit 2
  # CI's one smoke runner uploads the set for every snapshot as
  # ui-snapshots-smoke-set, only once every snapshot has rendered. A set
  # naming a shard holds only that shard's snapshots, and approving it would
  # delete every other reference as removed, so it is refused.
  rm -rf "$SMOKE_OUT/approved-run" "$SMOKE_OUT/approved-set"
  gh run download "$run" --name ui-snapshots-smoke-set --dir "$SMOKE_OUT/approved-set" \
    || die "CI run $run has no ui-snapshots-smoke-set to approve; the smoke job publishes one only once every snapshot has rendered"
  [ ! -f "$SMOKE_OUT/approved-set/shard" ] \
    || die "CI run $run published the set of shard $(cat "$SMOKE_OUT/approved-set/shard") only, not every snapshot's"
  run_tree="$(cat "$SMOKE_OUT/approved-set/source-tree" 2>/dev/null)" \
    || die "CI run $run does not name the source tree it rendered, so its renders cannot be matched to HEAD"
  [ "$run_tree" = "$tree" ] \
    || die "CI run $run rendered source tree $run_tree, not HEAD's ($tree), and approving it would bake another tree's UI into the references; a pull request's run renders the branch merged with main, so merge or rebase onto main, push, and approve the run CI makes of that"
  mkdir -p "$SMOKE_OUT/approved-run" || die "could not make $SMOKE_OUT/approved-run"
  cp "$SMOKE_OUT"/approved-set/*.png "$SMOKE_OUT/approved-run/" || die "CI run $run published a smoke set with no images"
}

apply_smoke() {
  # The set is every reference the test compares, so it replaces the folder
  # whole: a matching snapshot's file comes back byte for byte and shows no
  # change, and a removed snapshot's reference goes.
  mkdir -p "$SMOKE_REFERENCES"
  find "$SMOKE_REFERENCES" -name '*.png' -delete
  cp "$SMOKE_OUT"/approved-run/*.png "$SMOKE_REFERENCES/"
  echo "snapshots: review the changed images (git status Tests/UISnapshotsSmokeTests), then commit them with the change that caused them"
}

# The e2e-api checkpoints, from CI run <run> or HEAD's newest.
fetch_checkpoints() {
  local run="${1:-}" tree run_tree
  need_gh
  if [ -z "$run" ]; then
    run="$(newest_run ci.yml "the e2e-api checkpoints" "push it and let CI finish")" || exit 2
  fi
  tree="$(head_tree)" || exit 2
  rm -rf "$CHECKPOINTS_OUT/approved-run"
  # The job publishes its checkpoints only once both runs passed and agree.
  gh run download "$run" --name checkpoints --dir "$CHECKPOINTS_OUT/approved-run" \
    || die "CI run $run has no checkpoints to approve; its e2e-api job publishes them only once both runs of the API tier passed and took the same pictures"
  run_tree="$(cat "$CHECKPOINTS_OUT/approved-run/source-tree" 2>/dev/null)" \
    || die "CI run $run does not name the source tree its checkpoints were taken from, so they cannot be matched to HEAD"
  [ "$run_tree" = "$tree" ] \
    || die "CI run $run took its checkpoints of source tree $run_tree, not HEAD's ($tree), and approving them would bake another tree's UI into the baselines; a pull request's run tests the branch merged with main, so merge or rebase onto main, push, and approve the run CI makes of that"
}

apply_checkpoints() {
  diff_tool approve "$CHECKPOINT_BASELINES" "$CHECKPOINTS_OUT/approved-run"
  echo "snapshots: review the changed images (git status Tests/Checkpoints), then commit them with the change that caused them"
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

  checkpoints)
    shift
    rm -rf "$CHECKPOINTS_OUT"
    # Each run takes every API-tier scenario four at a time, and a scenario that
    # fails fails the gate: its checkpoints may be missing or of another state.
    for pass in first again; do
      "$ROOT/scripts/e2e/athina-e2e" run --tier api --jobs 4 --out "$CHECKPOINTS_OUT/runs/$pass" \
        --checkpoints "$CHECKPOINTS_OUT/render-$pass" "$@" all \
        || { echo "snapshots: an API-tier scenario failed (see build/checkpoints/runs/$pass), so its checkpoints are not compared" >&2; exit 1; }
    done
    status=0
    diff_tool agree "$CHECKPOINTS_OUT/render-first" "$CHECKPOINTS_OUT/render-again" --report "$CHECKPOINTS_OUT/determinism" || status=$?
    if [ "$status" -eq 1 ]; then
      echo "snapshots: two runs of the same build took different checkpoints (see build/checkpoints/determinism)" >&2
    fi
    [ "$status" -eq 0 ] || exit "$status"
    rm -rf "$CHECKPOINTS_OUT/determinism"
    git -C "$ROOT" rev-parse 'HEAD^{tree}' > "$CHECKPOINTS_OUT/render-first/source-tree"
    mv "$CHECKPOINTS_OUT/render-first" "$CHECKPOINTS_OUT/render"
    diff_tool compare "$CHECKPOINT_BASELINES" "$CHECKPOINTS_OUT/render" --report "$CHECKPOINTS_OUT/report"
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
    smoke_test "$ROOT" "$shard" "" "" || status=1
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

  approve)
    [ "$#" -eq 1 ] || die "usage: scripts/snapshots.sh approve"
    # Every kind is fetched, each from its own run, before any is applied, so
    # a kind with no run to take leaves every approved set as it was.
    missing=()
    ( fetch_baselines ) || missing+=("the ui-snapshots baselines (Tests/Snapshots): scripts/snapshots.sh baselines-approve")
    ( fetch_smoke ) || missing+=("the smoke references (Tests/UISnapshotsSmokeTests): scripts/snapshots.sh smoke-approve")
    ( fetch_checkpoints ) || missing+=("the e2e-api checkpoints (Tests/Checkpoints): scripts/snapshots.sh checkpoints-approve")
    if [ "${#missing[@]}" -gt 0 ]; then
      {
        echo "snapshots: approved nothing; ${#missing[@]} of 3 approvals have no run of HEAD to take, for the reasons above:"
        for approval in "${missing[@]}"; do echo "  - $approval"; done
        echo "snapshots: once each has its run, make approve again; to take only some, run their own commands (each takes a run id too)"
      } >&2
      exit 2
    fi
    apply_baselines
    apply_smoke
    apply_checkpoints
    ;;

  baselines-approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh baselines-approve [<run id>]"
    fetch_baselines "${2:-}"
    apply_baselines
    ;;

  smoke-approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh smoke-approve [<run id>]"
    fetch_smoke "${2:-}"
    apply_smoke
    ;;

  checkpoints-approve)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh checkpoints-approve [<run id>]"
    fetch_checkpoints "${2:-}"
    apply_checkpoints
    ;;

  smoke-local)
    [ "$#" -le 2 ] || die "usage: scripts/snapshots.sh smoke-local [<base commit>]"
    started=$(date +%s)
    if [ -n "${2:-}" ]; then
      base="$(git -C "$ROOT" rev-parse --verify "${2}^{commit}")" || die "no commit $2"
    else
      base="$(git -C "$ROOT" merge-base HEAD origin/main)" || die "no merge-base of HEAD and origin/main"
    fi
    cache="$SMOKE_CACHE/$base"
    # A few details, such as a dark switch's knob or a text field laid out a
    # point off, settle one of two ways in one process and hold it through
    # every draw there. So the base is drawn in several processes and a
    # snapshot matches when it matches any of their sets, and one that differs
    # from all of them is drawn again in fresh processes, changed only when it
    # differs in every one of the passes.
    sets=3
    passes=3
    compared=1
    if ! git -C "$ROOT" show "$base:Tests/UISnapshotsSmokeTests/UISnapshotsSmokeTests.swift" 2>/dev/null \
      | grep -q UI_SNAPSHOTS_SMOKE_ONLY; then
      # A base from before this mode cannot draw its set for comparing, so
      # HEAD is drawn alone, which still fails on a snapshot it cannot draw.
      compared=0
    elif [ ! -f "$cache/complete" ]; then
      # The base's own sources, from git archive rather than a worktree, so
      # nothing is added to the repository every checkout shares.
      mkdir -p "$SMOKE_CACHE"
      work="$(mktemp -d "$SMOKE_CACHE/base.XXXXXX")"
      trap 'rm -rf "$work"' EXIT
      git -C "$ROOT" archive "$base" | tar -x -C "$work" || die "could not unpack $base"
      mkdir -p "$work/none" "$work/sets"
      echo "snapshots: drawing the smoke set of the base, $base, in $sets processes, once for this base"
      for k in $(seq 1 "$sets"); do
        smoke_test "$work" "" "$work/none" "$work/out" \
          || { echo "snapshots: the base, $base, could not draw every snapshot" >&2; exit 1; }
        mv "$work/out/references" "$work/sets/$k"
      done
      touch "$work/sets/complete"
      # Another run may have drawn the same base meanwhile; either will do.
      [ -f "$cache/complete" ] || { rm -rf "$cache"; mv "$work/sets" "$cache"; }
    fi
    rm -rf "$SMOKE_LOCAL_OUT"
    mkdir -p "$SMOKE_LOCAL_OUT/none"
    against="$SMOKE_LOCAL_OUT/none"
    if [ "$compared" -eq 1 ]; then
      against="$(seq -f "$cache/%g" -s : 1 "$sets")"
    fi
    status=0
    smoke_test "$ROOT" "" "$against" "$SMOKE_LOCAL_OUT/pass-1" || status=1
    drawn="$SMOKE_LOCAL_OUT/pass-1/references"
    changed=()
    added=()
    removed=()
    last="$SMOKE_LOCAL_OUT/pass-1"
    if [ "$status" -eq 0 ] && [ "$compared" -eq 1 ]; then
      for snapshot in "$SMOKE_LOCAL_OUT"/pass-1/drift/*; do
        [ -d "$snapshot" ] || continue
        if [ -f "$snapshot/reference.png" ]; then
          changed+=("$(basename "$snapshot")")
        else
          added+=("$(basename "$snapshot")")
        fi
      done
      for file in "$cache"/1/*.png; do
        [ -f "$drawn/$(basename "$file")" ] || removed+=("$(basename "$file" .png)")
      done
      pass=1
      while [ "${#changed[@]}" -gt 0 ] && [ "$pass" -lt "$passes" ]; do
        pass=$((pass + 1))
        last="$SMOKE_LOCAL_OUT/pass-$pass"
        only="$(IFS=,; echo "${changed[*]}")"
        UI_SNAPSHOTS_SMOKE_ONLY="$only" smoke_test "$ROOT" "" "$against" "$last" || { status=1; break; }
        still=()
        for name in "${changed[@]}"; do
          [ -d "$last/drift/$name" ] && still+=("$name")
        done
        changed=(${still[@]+"${still[@]}"})
      done
    fi
    {
      echo "## UI smoke screens on this Mac, HEAD against $base"
      echo
      if [ "$status" -ne 0 ]; then
        echo "HEAD could not draw every snapshot; see the test output."
      elif [ "$compared" -eq 0 ]; then
        echo "HEAD drew all $(find "$drawn" -name '*.png' | wc -l | tr -d ' ') snapshots. The base comes from before this comparison, so there is nothing to compare them with."
      else
        echo "Changed: ${#changed[@]}, added: ${#added[@]}, removed: ${#removed[@]}, of $(find "$drawn" -name '*.png' | wc -l | tr -d ' ') drawn."
        [ "$((${#changed[@]} + ${#added[@]} + ${#removed[@]}))" -eq 0 ] || echo
        for name in ${changed[@]+"${changed[@]}"}; do
          echo "- changed \`$name\`: base $last/drift/$name/reference.png, HEAD $last/drift/$name/failure.png, difference $last/drift/$name/difference.png"
        done
        for name in ${added[@]+"${added[@]}"}; do
          echo "- added \`$name\`: HEAD $SMOKE_LOCAL_OUT/pass-1/drift/$name/failure.png"
        done
        for name in ${removed[@]+"${removed[@]}"}; do
          echo "- removed \`${name#snapshot.}\`: base $cache/1/$name.png"
        done
      fi
      echo
      echo "Took $(($(date +%s) - started)) s."
    } > "$SMOKE_LOCAL_OUT/summary.md"
    cat "$SMOKE_LOCAL_OUT/summary.md"
    exit "$status"
    ;;

  *)
    die "usage: scripts/snapshots.sh gate [<k>/<n>] | smoke [<k>/<n>] | smoke-local [<base commit>] | checkpoints [<athina-e2e option> ...] | approve | baselines-approve [<run id>] | smoke-approve [<run id>] | checkpoints-approve [<run id>]"
    ;;
esac
