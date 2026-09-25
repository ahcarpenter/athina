#!/usr/bin/env bash
# Fails when a binary carries the end-to-end harness's control API.
#
# The API exists only in development builds: the ControlAPI package trait,
# which scripts/bundle.sh turns on for the development bundle, compiles it in,
# and a release or App Store build must never carry it (README "The control
# API"). Every build that has it carries the protocol's name, which is what
# this looks for; ReleaseCheckTests runs this on a binary holding
# ControlProtocol.name and on one without it.
#
# Usage: scripts/check-no-control-api.sh <binary>
# Exit: 0 it carries none, 1 it carries the control API, 2 bad usage.
set -euo pipefail

MARKER="com.ahcarpenter.athina.control-api/1"

[ "$#" -eq 1 ] || { echo "usage: scripts/check-no-control-api.sh <binary>" >&2; exit 2; }
[ -f "$1" ] || { echo "check-no-control-api: no file at $1" >&2; exit 2; }
if LC_ALL=C grep -q -a -F "$MARKER" "$1"; then
	echo "check-no-control-api: $1 carries the control API; build it without the ControlAPI trait" >&2
	exit 1
fi
echo "no control API in $1"
