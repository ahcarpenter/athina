#!/usr/bin/env bash
# One on-screen harness session at a time across every checkout on this Mac.
# Sourced by scripts/e2e/athina-e2e and by its tests; never run on its own.
# Kept to bash 3 so the tests can drive it with the stock /bin/bash.
#
# A run clicks, types, moves focus, reads the menu bar, and captures the
# screen, and so does every other checkout's run: two at once collide, and
# each reports the other's clicks as its own failures. So every command that
# touches the screen or the shared warm home first takes one exclusive lock.
#
# The lock is a flock(2) on one file, taken with /usr/bin/lockf on a file
# descriptor this shell keeps open, so it lasts exactly as long as the harness
# process does: a pass, a failure, an interrupt, and a kill -9 all give it back,
# and a holder that died leaves nothing stale behind. It is the file lanes wrap
# runs in by hand (`lockf -k "$HOME/Library/Caches/athina-e2e/screen.lock" ...`),
# so a hand-wrapped run and a harness run exclude each other too.

# Machine-wide on purpose, so ATHINA_E2E_CACHE does not move it; the override
# is for the tests.
SCREEN_LOCK="${ATHINA_E2E_SCREEN_LOCK:-$HOME/Library/Caches/athina-e2e/screen.lock}"
# Who holds it, for whoever is waiting: written when the lock is taken.
SCREEN_LOCK_HOLDER="$SCREEN_LOCK.holder"
# The descriptor the lock lives on. Anything started in the background closes
# it (`9>&-`), so a helper that outlives a killed run cannot keep the lock.
SCREEN_LOCK_FD=9
# 1 once this process took the lock, 2 when a parent holds it for us.
SCREEN_LOCK_STATE=0
# The process that has the lock file open: this one, or the parent holding it.
SCREEN_LOCK_OWNER=""

screen_lock_say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# The commands that launch the app, drive input, or change the shared warm
# home. list, doctor, and journal touch none of them and never wait.
screen_lock_needed() {
	case "$1" in
	run | warm | clean) return 0 ;;
	*) return 1 ;;
	esac
}

# Every pid with the lock file open: the holder, and any harness still waiting
# for it (a waiter opens the file before it blocks).
screen_lock_openers() { lsof -t -- "$SCREEN_LOCK" 2>/dev/null || true; }

# Is `item` one of the lines of `list`? Without a pipe into grep -q, which
# under the harness's pipefail can read as a miss when grep stops reading early.
list_contains() {
	case "
$1
" in
	*"
$2
"*) return 0 ;;
	*) return 1 ;;
	esac
}

# A pid and each of its parents, up to but not including launchd.
process_ancestry() {
	local pid="$1"
	while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
		echo "$pid"
		pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
	done
}

# The first pid of the ancestry (one per line) that has the lock file open
# (one per line), or nothing. A parent with the file open holds the lock: a
# waiter cannot have a child running. This is what keeps a run from waiting on
# itself, whether the parent is a hand-held `lockf -k` or a harness that
# already holds it.
first_holding_ancestor() {
	local ancestry="$1" openers="$2" pid
	for pid in $ancestry; do
		if list_contains "$openers" "$pid"; then
			echo "$pid"
			return 0
		fi
	done
	return 1
}

# The holder file, one key=value per line.
screen_lock_holder_field() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# The openers that hold the lock rather than wait for it, other than this
# process and its children (a child inherits the descriptor), and not the
# child of another opener: one pid per process tree, among those still running.
foreign_openers() {
	local openers="$1" self="$2" pid parent
	for pid in $openers; do
		parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
		# Gone since lsof looked: a command substitution of this shell's, most
		# often.
		[ -n "$parent" ] || continue
		list_contains "$(process_ancestry "$pid")" "$self" && continue
		# Another harness still waiting: its lockf child is queued for the lock.
		pgrep -P "$pid" -x lockf >/dev/null 2>&1 && continue
		list_contains "$openers" "$parent" && continue
		echo "$pid"
	done
}

# Does the holder file describe a process that has the lock file open now?
# One left behind by a run that is gone does not.
screen_lock_holder_current() {
	local owner
	owner="$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" owner)"
	[ -n "$owner" ] && list_contains "$1" "$owner"
}

# The one line a waiter prints: who holds the lock, from the holder file when
# it is current, or from the process table when the holder is a hand-held
# lockf.
screen_lock_holder_line() {
	local openers="$1" pid
	if screen_lock_holder_current "$openers"; then
		printf 'held by %s running "%s" (pid %s) since %s\n' \
			"$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" checkout)" \
			"$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" what)" \
			"$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" pid)" \
			"$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" since)"
		return 0
	fi
	local described=""
	for pid in $(foreign_openers "$openers" "$$"); do
		described="$described${described:+; }pid $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-160)"
	done
	printf 'held outside the harness (%s)\n' "${described:-no process has it open any more}"
}

# Free, or who holds it, without taking it: for doctor.
screen_lock_status() {
	if [ ! -e "$SCREEN_LOCK" ] || /usr/bin/lockf -s -k -t 0 "$SCREEN_LOCK" true 2>/dev/null; then
		echo free
	else
		screen_lock_holder_line "$(screen_lock_openers)"
	fi
}

# Say what this run is doing now, for the next waiter. `run all` calls it for
# each scenario it starts.
screen_lock_note() {
	[ "$SCREEN_LOCK_STATE" != 0 ] || return 0
	local tmp="$SCREEN_LOCK_HOLDER.$$"
	{
		printf 'owner=%s\n' "$SCREEN_LOCK_OWNER"
		printf 'pid=%s\n' "$$"
		printf 'checkout=%s\n' "${ROOT:-$PWD}"
		printf 'what=%s\n' "$1"
		printf 'since=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$tmp" && mv -f "$tmp" "$SCREEN_LOCK_HOLDER"
}

# Take the lock, waiting for it as long as it takes, or up to `timeout` seconds
# when one is given. Returns 75 (EX_TEMPFAIL, as lockf does) when it gave up.
screen_lock_acquire() {
	local what="$1" timeout="${2:-}" openers ancestor
	if [ -n "$timeout" ] && ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
		screen_lock_say "--lock-timeout takes a whole number of seconds, not $timeout"
		return 64
	fi
	mkdir -p "$(dirname "$SCREEN_LOCK")"
	openers="$(screen_lock_openers)"
	if ancestor="$(first_holding_ancestor "$(process_ancestry $$)" "$openers")"; then
		SCREEN_LOCK_STATE=2
		SCREEN_LOCK_OWNER="$ancestor"
		screen_lock_say "the screen lock is already held by pid $ancestor, which started this run"
		# A harness above this one has already said who holds it; a hand-held
		# lockf has not, so this run says it for the next waiter.
		screen_lock_holder_current "$openers" || screen_lock_note "$what"
		return 0
	fi
	exec 9>>"$SCREEN_LOCK"
	if ! /usr/bin/lockf -t 0 "$SCREEN_LOCK_FD" 2>/dev/null; then
		screen_lock_say "waiting for the screen lock $SCREEN_LOCK, $(screen_lock_holder_line "$(screen_lock_openers)")"
		local status=0 waiter
		# In the background with a trap, so a run stopped while it waits takes
		# its lockf down with it rather than leave one queued for the lock.
		if [ -n "$timeout" ]; then
			/usr/bin/lockf -t "$timeout" "$SCREEN_LOCK_FD" 2>/dev/null &
		else
			/usr/bin/lockf "$SCREEN_LOCK_FD" 2>/dev/null &
		fi
		waiter=$!
		# shellcheck disable=SC2064 # the pid is known now, and must be then
		trap "kill $waiter 2>/dev/null; exit 130" INT
		# shellcheck disable=SC2064
		trap "kill $waiter 2>/dev/null; exit 143" TERM HUP
		wait "$waiter" || status=$?
		trap - INT TERM HUP
		if [ "$status" != 0 ]; then
			exec 9>&-
			if [ "$status" = 75 ]; then
				screen_lock_say "gave up on the screen lock after ${timeout}s; still $(screen_lock_holder_line "$(screen_lock_openers)")"
			else
				screen_lock_say "could not take the screen lock $SCREEN_LOCK (lockf exited $status)"
			fi
			return "$status"
		fi
	fi
	SCREEN_LOCK_STATE=1
	SCREEN_LOCK_OWNER="$$"
	screen_lock_note "$what"
	return 0
}

# Give the lock back early. Exiting does the same, whatever the exit; this
# only also removes the holder file, so the next waiter reads no stale one.
screen_lock_release() {
	[ "$SCREEN_LOCK_STATE" = 1 ] || return 0
	[ "$(screen_lock_holder_field "$SCREEN_LOCK_HOLDER" pid)" = "$$" ] && rm -f "$SCREEN_LOCK_HOLDER"
	exec 9>&-
	SCREEN_LOCK_STATE=0
	return 0
}
