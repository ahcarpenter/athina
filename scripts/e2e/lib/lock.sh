#!/usr/bin/env bash
# The harness's two locks: one on-screen session at a time across every
# checkout on this Mac, and one run at a time from each checkout.
# Sourced by scripts/e2e/athina-e2e and by its tests; never run on its own.
# Kept to bash 3 so the tests can drive it with the stock /bin/bash.
#
# A run clicks, types, moves focus, reads the menu bar, and captures the
# screen, and so does every other checkout's run: two at once collide, and
# each reports the other's clicks as its own failures. So every command that
# touches the screen or the shared warm home takes the screen lock first: run
# for each scenario, and a scenario that needs a quiet Mac only once input is
# idle, so other checkouts' runs go between scenarios and none waits on
# someone typing.
#
# A run also builds its checkout's app bundle and drive tool, before it takes
# the screen lock so no other checkout waits on the build, and then runs from
# them. A second run from the same checkout would build over a bundle the first
# is running from, so every command that builds first takes that checkout's
# lock and keeps it to the end. Runs from other checkouts never wait on it.
# The checkout lock always comes first, so a run under a screen lock a parent
# already holds, such as a hand-held lockf, takes it only if it is free.
#
# Each lock is a flock(2) on one file, taken with /usr/bin/lockf on a file
# descriptor this shell keeps open, so it never outlasts the harness process:
# a pass, a failure, an interrupt, and a kill -9 all give it back,
# and a holder that died leaves nothing stale behind. The screen lock is the
# file lanes wrap runs in by hand
# (`lockf -k "$HOME/Library/Caches/athina-e2e/screen.lock" ...`), so a
# hand-wrapped run and a harness run exclude each other too.
#
# A lock is named by the prefix of its variables, SCREEN_LOCK or CHECKOUT_LOCK:
# the file, then _HOLDER, _FD, _LABEL, _STATE, and _OWNER, read through
# lock_var, which shellcheck cannot follow.
# shellcheck disable=SC2034

# Machine-wide on purpose, so ATHINA_E2E_CACHE does not move it; the override
# is for the tests.
SCREEN_LOCK="${ATHINA_E2E_SCREEN_LOCK:-$HOME/Library/Caches/athina-e2e/screen.lock}"
# Who holds it, for whoever is waiting: written when the lock is taken.
SCREEN_LOCK_HOLDER="$SCREEN_LOCK.holder"
# The descriptor the lock lives on. Anything started in the background closes
# both locks' (`8>&- 9>&-`), so a helper that outlives a killed run cannot keep
# either lock.
SCREEN_LOCK_FD=9
# How the lock is named to whoever is waiting.
SCREEN_LOCK_LABEL="screen lock"
# 1 once this process took the lock, 2 when a parent holds it for us.
SCREEN_LOCK_STATE=0
# The process that has the lock file open: this one, or the parent holding it.
SCREEN_LOCK_OWNER=""

# Beside the bundle it keeps, so each checkout has its own.
CHECKOUT_LOCK="${ROOT:-$PWD}/build/athina-e2e.lock"
CHECKOUT_LOCK_HOLDER="$CHECKOUT_LOCK.holder"
CHECKOUT_LOCK_FD=8
CHECKOUT_LOCK_LABEL="checkout lock"
CHECKOUT_LOCK_STATE=0
CHECKOUT_LOCK_OWNER=""

lock_say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# One of a lock's variables: `lock_var SCREEN_LOCK _FD`, or the file itself
# with no suffix.
lock_var() {
	local name="$1${2:-}"
	printf '%s' "${!name}"
}

lock_set() { printf -v "$1$2" '%s' "$3"; }

# The commands that take the screen lock for as long as they run: those that
# launch the app or change the shared warm home. run takes it for each
# scenario instead, so other checkouts' runs can go between them. list,
# doctor, and journal touch none of them and never wait.
screen_lock_needed() {
	case "$1" in
	warm | clean) return 0 ;;
	*) return 1 ;;
	esac
}

# The commands that build the checkout's app bundle and drive tool and run
# from them.
checkout_lock_needed() {
	case "$1" in
	run | warm) return 0 ;;
	*) return 1 ;;
	esac
}

# Every pid with the lock file open: the holder, and any harness still waiting
# for it (a waiter opens the file before it blocks).
lock_openers() { lsof -t -- "$(lock_var "$1")" 2>/dev/null || true; }

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
lock_holder_field() {
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

# Does the lock's holder file describe a process that has the lock file open
# now? One left behind by a run that is gone does not.
lock_holder_current() {
	local owner
	owner="$(lock_holder_field "$(lock_var "$1" _HOLDER)" owner)"
	[ -n "$owner" ] && list_contains "$2" "$owner"
}

# The one line a waiter prints: who holds the lock, from the holder file when
# it is current, or from the process table when the holder is a hand-held
# lockf.
lock_holder_line() {
	local lock="$1" openers="$2" holder pid
	holder="$(lock_var "$lock" _HOLDER)"
	if lock_holder_current "$lock" "$openers"; then
		printf 'held by %s running "%s" (pid %s) since %s\n' \
			"$(lock_holder_field "$holder" checkout)" \
			"$(lock_holder_field "$holder" what)" \
			"$(lock_holder_field "$holder" pid)" \
			"$(lock_holder_field "$holder" since)"
		return 0
	fi
	local described=""
	for pid in $(foreign_openers "$openers" "$$"); do
		described="$described${described:+; }pid $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-160)"
	done
	printf 'held outside the harness (%s)\n' "${described:-no process has it open any more}"
}

# Free, or who holds it, without taking it: for doctor.
lock_status() {
	local file
	file="$(lock_var "$1")"
	if [ ! -e "$file" ] || /usr/bin/lockf -s -k -t 0 "$file" true 2>/dev/null; then
		echo free
	else
		lock_holder_line "$1" "$(lock_openers "$1")"
	fi
}

# Say what this run is doing now, for the next waiter. `run all` calls it for
# each scenario it starts.
lock_note() {
	local lock="$1" what="$2" holder tmp
	[ "$(lock_var "$lock" _STATE)" != 0 ] || return 0
	holder="$(lock_var "$lock" _HOLDER)"
	tmp="$holder.$$"
	{
		printf 'owner=%s\n' "$(lock_var "$lock" _OWNER)"
		printf 'pid=%s\n' "$$"
		printf 'checkout=%s\n' "${ROOT:-$PWD}"
		printf 'what=%s\n' "$what"
		printf 'since=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$tmp" && mv -f "$tmp" "$holder"
}

# Take the lock, waiting for it as long as it takes, or up to `timeout` seconds
# when one is given. Returns 75 (EX_TEMPFAIL, as lockf does) when it gave up.
lock_acquire() {
	local lock="$1" what="$2" timeout="${3:-}" file fd label openers ancestor
	file="$(lock_var "$lock")"
	fd="$(lock_var "$lock" _FD)"
	label="$(lock_var "$lock" _LABEL)"
	if [ -n "$timeout" ] && ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
		lock_say "--lock-timeout takes a whole number of seconds, not $timeout"
		return 64
	fi
	mkdir -p "$(dirname "$file")"
	openers="$(lock_openers "$lock")"
	if ancestor="$(first_holding_ancestor "$(process_ancestry $$)" "$openers")"; then
		lock_set "$lock" _STATE 2
		lock_set "$lock" _OWNER "$ancestor"
		lock_say "the $label is already held by pid $ancestor, which started this run"
		# A harness above this one has already said who holds it; a hand-held
		# lockf has not, so this run says it for the next waiter.
		lock_holder_current "$lock" "$openers" || lock_note "$lock" "$what"
		return 0
	fi
	eval "exec $fd>>\"\$file\""
	if ! /usr/bin/lockf -t 0 "$fd" 2>/dev/null; then
		lock_say "waiting for the $label $file, $(lock_holder_line "$lock" "$(lock_openers "$lock")")"
		local status=0 waiter started=$SECONDS
		# In the background with a trap, so a run stopped while it waits takes
		# its lockf down with it rather than leave one queued for the lock. It
		# waits on a copy of the lock's descriptor and, like every helper,
		# closes both locks' own (`8>&- 9>&-`).
		if [ -n "$timeout" ]; then
			/usr/bin/lockf -t "$timeout" 7 7>&"$fd" 8>&- 9>&- 2>/dev/null &
		else
			/usr/bin/lockf 7 7>&"$fd" 8>&- 9>&- 2>/dev/null &
		fi
		waiter=$!
		# shellcheck disable=SC2064 # the pid is known now, and must be then
		trap "kill $waiter 2>/dev/null; exit 130" INT
		# shellcheck disable=SC2064
		trap "kill $waiter 2>/dev/null; exit 143" TERM HUP
		wait "$waiter" || status=$?
		trap - INT TERM HUP
		if [ "$status" != 0 ]; then
			eval "exec $fd>&-"
			if [ "$status" = 75 ]; then
				lock_say "gave up on the $label after ${timeout}s; still $(lock_holder_line "$lock" "$(lock_openers "$lock")")"
			else
				lock_say "could not take the $label $file (lockf exited $status)"
			fi
			return "$status"
		fi
		lock_say "took the $label after $((SECONDS - started))s"
	else
		lock_say "took the $label, which was free"
	fi
	lock_set "$lock" _STATE 1
	lock_set "$lock" _OWNER "$$"
	lock_note "$lock" "$what"
	return 0
}

# Take the lock once the keyboard and mouse have been quiet for `need` seconds,
# as the command `idle` prints them, waiting up to `limit` seconds for that
# (900 unless given). A run that needs a quiet Mac waits for one before it
# holds the screen, so no other checkout waits behind it while someone is at
# the Mac. When input came back while the lock was being waited for, the lock
# is given back and the wait for quiet starts again; a lock a parent holds
# cannot be given back, so it is kept. Returns 75, as a lock wait that gave up
# does, when the Mac never went quiet.
lock_acquire_when_idle() {
	local lock="$1" what="$2" timeout="$3" need="$4" idle="$5" limit="${6:-900}" label status waited seconds
	label="$(lock_var "$lock" _LABEL)"
	while :; do
		waited=0
		while :; do
			seconds="$("$idle")"
			[ "${seconds:-0}" -ge "$need" ] && break
			if [ "$waited" -ge "$limit" ]; then
				lock_say "input never went idle for ${need}s in ${limit}s, so the $label was not taken"
				return 75
			fi
			[ "$waited" = 0 ] && lock_say "waiting for ${need}s of idle input before taking the $label"
			sleep 1
			waited=$((waited + 1))
		done
		lock_say "input idle for ${seconds}s"
		status=0
		lock_acquire "$lock" "$what" "$timeout" || status=$?
		[ "$status" = 0 ] || return "$status"
		seconds="$("$idle")"
		if [ "${seconds:-0}" -ge "$need" ] || [ "$(lock_var "$lock" _STATE)" != 1 ]; then
			return 0
		fi
		lock_release "$lock"
		lock_say "input came back while this run waited for the $label (idle ${seconds}s); gave it back until the Mac is quiet again"
	done
}

# Take this checkout's lock, which comes before the screen lock. Under a screen
# lock a parent holds, it is taken only if it is free: a run from this checkout
# that holds it and waits for the screen would wait on this one for ever, and
# this one on it.
checkout_lock_acquire() {
	local what="$1" timeout="${2:-}" above
	if above="$(first_holding_ancestor "$(process_ancestry $$)" "$(lock_openers SCREEN_LOCK)")"; then
		lock_say "the screen lock is held by pid $above, which started this run, so the checkout lock is taken only if it is free"
		timeout=0
	fi
	lock_acquire CHECKOUT_LOCK "$what" "$timeout"
}

# Give the lock back early. Exiting does the same, whatever the exit; this
# only also removes the holder file, so the next waiter reads no stale one.
lock_release() {
	local lock="$1" holder fd
	[ "$(lock_var "$lock" _STATE)" = 1 ] || return 0
	holder="$(lock_var "$lock" _HOLDER)"
	fd="$(lock_var "$lock" _FD)"
	[ "$(lock_holder_field "$holder" pid)" = "$$" ] && rm -f "$holder"
	eval "exec $fd>&-"
	lock_set "$lock" _STATE 0
	return 0
}

# Both, in the order opposite to the one they are taken in.
locks_release() {
	lock_release SCREEN_LOCK
	lock_release CHECKOUT_LOCK
}
