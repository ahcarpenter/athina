#!/usr/bin/env bash
# `make lint`, which CI's lint job runs as it stands: the Swift style check
# (scripts/swift-format.sh lint) and then every relative link and anchor in the
# Markdown (scripts/check-links.swift). The links are checked after a style
# failure too, so both are reported at once. Ends in one summary line; a
# failing check prints its own findings and summary instead.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
status=0
style="$(scripts/swift-format.sh lint)" || status=1
links="$(scripts/check-links.swift)" || status=1
[ "$status" -eq 0 ] || exit 1
style="${style#lint: passed, }"
links="${links#links: passed, }"
echo "lint: passed, the style of ${style% files} Swift files and ${links% files} Markdown files"
