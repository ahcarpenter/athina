# Code style

Every Swift file follows [Google's Swift Style Guide](https://google.github.io/swift/),
Apple's API Design Guidelines included. The part a tool can apply is
`.swift-format`, the configuration for the swift-format that ships with
Xcode, so nothing needs installing: two-space indents, a 100-column limit,
line wrapping in one direction, and the guide's naming, documentation and
programming-practice rules that swift-format checks. `make format` rewrites
every Swift file to it, `make lint` fails on anything it would change and on
every rule it can only report, and CI runs `make lint` on every pull request
and every push to `main`.

A newer swift-format can format the same code differently, so the one CI runs
is pinned: `.xcode-version` names the Xcode every CI job runs, and so the
swift-format it ships with, as `xcodebuild -version` prints it (26.6 today:
Swift 6.3.3, swift-format 6.3.0). The `lint` job selects that Xcode by its
exact path, as every job does (see [Continuous integration](ci.md)), and prints the
Swift and swift-format versions that ran. `make format` and `make lint` read the same file and warn when the
selected Xcode is another; `DEVELOPER_DIR=<path to that Xcode.app>`
runs either with the pinned one. Xcode 27.0's swift-format, which reports its
version as `main`, formats this code identically today.

To move the pin, once the `macos-26` image lists the new Xcode (its
[readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
names each path):

1. Write the new version into `.xcode-version`.
2. Run `make format` and `make lint` with that Xcode, and fix what the linter
   reports.
3. Commit the pin and any reformatting together as one `style` commit, so
   every commit lints clean with the swift-format it pins.

`make lint` cannot see every rule. By hand, and in review:

- Every public declaration gets a `///` comment that opens with a
  one-sentence summary; the linter asks for it, the words are yours. A
  comment that repeats the name says nothing: define the term instead.
- A parameterized attribute (`@Environment(...)`, `@Suite(...)`) goes on its
  own line above its declaration.
- A call with one closure argument, last, passes it as a trailing closure
  (except in an `if`, `guard` or `while` condition); a call with several
  closure arguments passes them all inside the parentheses, labeled, with no
  trailing closure. SwiftUI's `Button(action:label:)`,
  `Section(content:header:)` and the like are written that way; only an API
  whose body is unlabeled after a defaulted argument, such as
  `withKnownIssue`, keeps its trailing closures.
- A wrapped list, conditions included, puts every element on its own line;
  swift-format keeps those breaks but does not add them.
- Initializers, and functions that share a name, sit next to each other.
- A string that runs past 100 columns is wrapped as a multi-line string
  literal with `\` at each line end, which leaves the string itself as it was.
- Outside tests, a force unwrap, force cast or `try!` carries a comment
  saying why it cannot fail, unless the line alone makes that plain.
- Each file imports every module it uses by name (Foundation and
  CoreGraphics too, not through AppKit or SwiftUI), and nothing else.

## Rebasing a branch across the reformat

The reformat is one commit on `main` that changes nothing but formatting, the
first of the commits named in `.git-blame-ignore-revs`, which `git blame` skips
once `git config blame.ignoreRevsFile .git-blame-ignore-revs` is set (GitHub
reads it itself); the others are the style commits after it. The commit before
it adds `.swift-format` and `make format`. A branch started earlier formats
itself with them first and then crosses the reformat, so that only real
changes conflict:

```sh
git fetch origin
reformat=$(git show origin/main:.git-blame-ignore-revs | grep -v '^#' | grep . | head -n1)
# 0. Stop unless main holds that very commit and the branch forked from main
#    no later than the commit before it: an empty $reformat stops every step.
if ! git merge-base --is-ancestor "$reformat" origin/main; then
  echo "Stop: origin/main does not contain the reformat commit $reformat." >&2
  reformat=
elif ! git merge-base --is-ancestor "$(git merge-base HEAD origin/main)" "$reformat~1"; then
  echo "Stop: this branch forked from main after $reformat~1; see below." >&2
  reformat=
fi
# 1. Catch up to just before the reformat, resolving real conflicts as usual.
git rebase "${reformat:?}~1"
# 2. Format every commit of the branch where it stands.
git rebase --exec 'make format && git commit -a --amend --no-edit --allow-empty' "${reformat:?}~1"
# 3. Cross the reformat. Both sides are formatted now, so every conflict is
#    formatting the branch already has right: -X theirs keeps the branch side.
git rebase -X theirs "${reformat:?}"
# 4. Carry on to the tip of main, resolving real conflicts as usual.
: "${reformat:?}" && git rebase origin/main
: "${reformat:?}" && make lint
```

The reformat keeps its id on `main` only because the change that brought it
landed as a merge commit; a squash or rebase merge gives it a new one, and
`.git-blame-ignore-revs` would then name a commit `main` does not have, which
step 0 catches. Run the steps one at a time: each must finish cleanly before
the next begins.

Step 0 also stops a branch that forked from `main` after the commit before the
reformat: steps 1 and 2 would carry `main`'s own later commits back onto an
older base, and step 4 would replay them onto a `main` that already has them.
Such a branch takes the short way instead, resolving conflicts as usual:

```sh
git rebase origin/main
make format
git commit -a -m "style(athina): format the branch to Google's Swift style"
make lint
```

`-X theirs` in step 3 is safe only because step 1 settled every real conflict
and the reformat commit holds nothing but formatting; replaying `main`'s own
two commits before it this way reproduces the reformat's tree exactly. A branch
with a merge commit in it is flattened by a rebase; give every step
`--rebase-merges` instead.
