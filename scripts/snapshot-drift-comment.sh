#!/usr/bin/env bash
# Posts the full UI snapshot gate's drift on its pull request as one comment,
# updated in place on every later run: each drifted snapshot's approved image,
# this run's render and their difference, inline (docs/ci.md "UI snapshot
# baselines"). merge-checks.yml runs it once every shard has finished.
#
# Usage: scripts/snapshot-drift-comment.sh <reports>
#   <reports> holds the shards' ui-snapshot-report-shard-<k> artifacts, one
#   folder each, as actions/download-artifact lays them out.
#
# Reads GH_TOKEN (a token that can push and comment), GITHUB_REPOSITORY,
# PR_NUMBER, HEAD_SHA (the pull request's head), SHARDS_RESULT (the shards'
# result) and RUN_URL (this run).
#
# A comment's image must be at a public address, and an artifact needs a login
# to fetch, so the images go in a commit of their own, pushed over
# refs/ui-snapshots-drift/pr-<number>: a ref outside refs/heads, which a clone
# never fetches and no branch list shows, replaced on each run, so it holds
# only the pull request's latest drift. The comment reads them through
# raw.githubusercontent.com at that commit, so each version of it shows its
# own run's images.
set -euo pipefail

REPORTS="${1:?usage: scripts/snapshot-drift-comment.sh <reports>}"
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${PR_NUMBER:?}" "${HEAD_SHA:?}" "${SHARDS_RESULT:?}" "${RUN_URL:?}"

# The first line of the comment, by which a later run finds it.
MARKER='<!-- ui-snapshots-drift -->'
REF="refs/ui-snapshots-drift/pr-$PR_NUMBER"
# GitHub refuses a comment over 65,536 characters; past this many, the rest
# of the drifted snapshots are named without their images.
BUDGET=60000

comment_id="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$MARKER\"))) | .id")"
comment_id="${comment_id%%$'\n'*}"

# Each drifted snapshot is a folder of the report holding before.png (its
# approved image), after.png (this run's render) or both, and diff.png when
# both have one size.
drifted=()
while IFS= read -r dir; do
  drifted+=("$dir")
done < <(find "$REPORTS" -mindepth 3 -maxdepth 3 -type d -path '*/report/*' | awk -F / '{ print $NF "\t" $0 }' | sort | cut -f 2-)

post() {
  local body="$1"
  if [ -n "$comment_id" ]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" -F "body=@$body" >/dev/null
  else
    gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -F "body=@$body" >/dev/null
  fi
}

body="$(mktemp)"
head="${HEAD_SHA:0:7}"

if [ "${#drifted[@]}" -eq 0 ]; then
  # Nothing drifted. A comment an earlier run left is brought up to date, so
  # it never shows a drift that is gone, and the images it showed go; with
  # none, there is nothing to say.
  [ -n "$comment_id" ] || exit 0
  gh api -X DELETE "repos/$GITHUB_REPOSITORY/git/$REF" >/dev/null 2>&1 || true
  {
    echo "$MARKER"
    echo "### UI snapshot drift"
    echo
    if [ "$SHARDS_RESULT" = success ]; then
      echo "No snapshot drifts from its baseline at $head ([run]($RUN_URL))."
    else
      echo "No snapshot drifted from its baseline at $head, but the gate did not pass; its [run]($RUN_URL) says why."
    fi
  } >"$body"
  post "$body"
  exit 0
fi

# The images, in a commit of their own with no parent, one folder a snapshot.
images="$(mktemp -d)"
git -C "$images" init -q
for dir in "${drifted[@]}"; do
  mkdir "$images/$(basename "$dir")"
  cp "$dir"/*.png "$images/$(basename "$dir")/"
done
git -C "$images" add -A
git -C "$images" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -q -m "UI snapshot drift of pull request #$PR_NUMBER at $HEAD_SHA"
commit="$(git -C "$images" rev-parse HEAD)"
git -C "$images" push -q --force "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git" "HEAD:$REF"

raw="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$commit"
# One image at a third of the comment's width, a link to it at real size, or
# a dash for a side the snapshot does not have (a new one has no approved
# image, a removed one no render).
cell() {
  local name="$1" file="$2" alt="$3"
  if [ -f "$images/$name/$file" ]; then
    printf '<a href="%s/%s/%s"><img src="%s/%s/%s" alt="%s" width="250"></a>' \
      "$raw" "$name" "$file" "$raw" "$name" "$file" "$alt"
  else
    printf '-'
  fi
}

{
  echo "$MARKER"
  echo "### UI snapshot drift"
  echo
  if [ "${#drifted[@]}" -eq 1 ]; then drift="1 snapshot drifts from its baseline"; else drift="${#drifted[@]} snapshots drift from their baselines"; fi
  echo "$drift at $head ([run]($RUN_URL)). Changed pixels are red in the difference; select an image for its real size. When the change means it, run \`make approve\` and commit the images it takes (docs/ci.md \"UI snapshot baselines\")."
} >"$body"
unlisted=()
for dir in "${drifted[@]}"; do
  name="$(basename "$dir")"
  section="$(printf '\n#### %s\n\n| Approved | This run | Difference |\n| :-: | :-: | :-: |\n| %s | %s | %s |' \
    "\`$name\`" "$(cell "$name" before.png "$name approved")" "$(cell "$name" after.png "$name this run")" \
    "$(cell "$name" diff.png "$name difference")")"
  if [ "$(($(wc -c <"$body") + ${#section}))" -gt "$BUDGET" ]; then
    unlisted+=("\`$name\`")
  else
    echo "$section" >>"$body"
  fi
done
if [ "${#unlisted[@]}" -gt 0 ]; then
  {
    echo
    echo "Too many to show here, and in the run's report artifacts: ${unlisted[*]}"
  } >>"$body"
fi
post "$body"
