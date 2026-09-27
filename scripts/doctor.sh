#!/usr/bin/env bash
# `make doctor`: says what this Mac is missing to build, test and check
# Athina, one line per requirement (CONTRIBUTING.md "Requirements"), then runs the
# end-to-end harness's own doctor for the grants, the drive tool and the warm
# home. Changes nothing but building the harness's drive tool. Ends in one
# summary line, and exits 1 when anything is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
missing=0

report() { printf '%-16s %s\n' "$1" "$2"; }
lack() {
	report "$1" "missing: $2"
	missing=$((missing + 1))
}

xcode="$(xcodebuild -version 2>/dev/null | head -n1)"
want="Xcode $(cat "$ROOT/.xcode-version")"
if [ -z "$xcode" ]; then
	lack xcode "no Xcode selected (xcode-select -s /Applications/Xcode.app)"
elif [ "$xcode" != "$want" ]; then
	report xcode "$xcode (CI lints with $want, whose swift-format may format differently)"
else
	report xcode "$xcode"
fi
if command -v swift >/dev/null; then
	report swift "$(swift --version 2>/dev/null | head -n1)"
else
	lack swift "install Xcode's command line tools"
fi

# The harness needs bash 4 or newer first on PATH; macOS ships 3.2 as /bin/bash.
bash_path="$(command -v bash)"
bash_major="$("$bash_path" -c "echo \${BASH_VERSINFO[0]}" 2>/dev/null || echo 0)"
if [ "$bash_major" -ge 4 ]; then
	report bash "$bash_path ($("$bash_path" -c "echo \$BASH_VERSION"))"
else
	lack bash "bash 4 or newer first on PATH for the e2e harness (brew install bash); $bash_path is ${bash_major}"
fi
if command -v gh >/dev/null; then
	if gh auth status >/dev/null 2>&1; then
		report gh "$(command -v gh), signed in"
	else
		lack gh "signed in (gh auth login): the approve targets download CI's renders"
	fi
else
	lack gh "the approve targets download CI's renders with it (brew install gh)"
fi

echo
if [ "$bash_major" -ge 4 ]; then
	"$ROOT/scripts/e2e/athina-e2e" doctor || e2e=1
else
	echo "e2e doctor skipped: it needs bash 4"
fi
echo
if [ "$missing" -eq 0 ] && [ "${e2e:-0}" -eq 0 ]; then
	echo "doctor: passed, this Mac has everything make needs"
	exit 0
fi
echo "doctor: failed, ${missing} tool(s) missing${e2e:+ and the e2e harness lacks something above}; each line marked missing says how to get it" >&2
exit 1
