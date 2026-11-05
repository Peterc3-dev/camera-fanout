#!/usr/bin/env bash
# Source this from camera tools to auto-select a virtual device when fanout is running.
#
# Assigns VCAM_DEVICE to the next available virtual camera (default
# /dev/video{10,11,12}, override with FANOUT_VCAMS="dev1 dev2 ...").
# If fanout is not running, falls back to FANOUT_REAL_CAM (default /dev/video0).
#
# Runtime files (pidfile, claim locks) live in the directory chosen by
# _fanout_resolve_run_dir below (FANOUT_RUN_DIR, XDG_RUNTIME_DIR, /run/user/<uid>,
# then /tmp).  fanout.sh uses the same rule.
#
# Usage in tool start.sh:
#   source ~/tools/camera-fanout/env.sh
#   # then use $VCAM_DEVICE or $VCAM_INDEX

# Runtime-dir resolution.  Kept byte-identical in env.sh and fanout.sh (env.sh
# is sourced from arbitrary tools, so it cannot reliably locate a shared helper
# file); change both together.  Order: FANOUT_RUN_DIR; else
# $XDG_RUNTIME_DIR/camera-fanout-<uid>; else /run/user/<uid>/camera-fanout-<uid>
# when /run/user/<uid> is a real directory owned by this user (cron and system
# units often lack XDG_RUNTIME_DIR); else /tmp/camera-fanout-<uid>.
# FANOUT_TEST_RUN_USER_BASE replaces /run/user and exists only for tests.
_fanout_resolve_run_dir() {
    local uid base
    uid=$(id -u)
    if [ -n "${FANOUT_RUN_DIR:-}" ]; then
        printf '%s\n' "$FANOUT_RUN_DIR"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        printf '%s\n' "$XDG_RUNTIME_DIR/camera-fanout-$uid"
    else
        base="${FANOUT_TEST_RUN_USER_BASE:-/run/user}/$uid"
        if [ -d "$base" ] && [ ! -L "$base" ] && [ -O "$base" ]; then
            printf '%s\n' "$base/camera-fanout-$uid"
        else
            printf '%s\n' "/tmp/camera-fanout-$uid"
        fi
    fi
}

_fanout_run_dir="$(_fanout_resolve_run_dir)"
_fanout_pidfile="$_fanout_run_dir/camera-fanout.pid"

_fanout_running() {
    [ -f "$_fanout_pidfile" ] && kill -0 "$(cat "$_fanout_pidfile" 2>/dev/null)" 2>/dev/null
}

# Serialise check-and-claim / stale-reclaim across tools with flock(1) on
# $_fanout_run_dir/claim.lock (fanout.sh stop takes the same lock).  Waits up
# to FANOUT_LOCK_TIMEOUT seconds (default 2).  If flock is missing or the wait
# times out, warn and fall back to the unlocked (narrowly racy) claim.
_fanout_claim_locked() {
    local fd rc
    if ! command -v flock >/dev/null 2>&1; then
        echo "camera-fanout: flock not found (util-linux); claiming without serialisation" >&2
        _fanout_claim "$@"
        return
    fi
    if ! { exec {fd}>>"$_fanout_run_dir/claim.lock"; } 2>/dev/null; then
        echo "camera-fanout: cannot open $_fanout_run_dir/claim.lock; claiming without serialisation" >&2
        _fanout_claim "$@"
        return
    fi
    if flock -w "${FANOUT_LOCK_TIMEOUT:-2}" "$fd"; then
        _fanout_claim "$@"; rc=$?
    else
        echo "camera-fanout: timed out waiting for claim.lock; claiming without serialisation" >&2
        _fanout_claim "$@"; rc=$?
    fi
    exec {fd}>&-
    return "$rc"
}

# Try to claim lockfile $1 for this shell ($$).  A lock whose recorded PID is
# no longer alive (claimant crashed or was SIGKILLed) is reclaimed once.
# Callers should go through _fanout_claim_locked.
_fanout_claim() {
    local lock="$1" owner
    if (set -C; echo $$ > "$lock") 2>/dev/null; then
        return 0
    fi
    owner=$(cat "$lock" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    # Stale lock.  Under claim.lock no other claimant can interleave here; the
    # re-check below still narrows the window in the unlocked fallback.
    [ "$(cat "$lock" 2>/dev/null)" = "$owner" ] || return 1
    rm -f "$lock" 2>/dev/null
    (set -C; echo $$ > "$lock") 2>/dev/null
}

if _fanout_running; then
    # Pick a virtual device that isn't already claimed by a live tool.
    _claimed=false
    for _dev in ${FANOUT_VCAMS:-/dev/video10 /dev/video11 /dev/video12}; do
        _lock="$_fanout_run_dir/vcam-claim-$(basename "$_dev")"
        if _fanout_claim_locked "$_lock"; then
            export VCAM_DEVICE="$_dev"
            export VCAM_INDEX="${_dev##/dev/video}"
            _claimed=true
            # Clean up lock on exit.
            # Chain onto any existing EXIT trap instead of replacing it
            _prev_exit_trap=$(trap -p EXIT | sed "s/^trap -- '\\(.*\\)' EXIT$/\\1/; s/'\\\\''/'/g")
            trap "rm -f '$_lock' 2>/dev/null${_prev_exit_trap:+; $_prev_exit_trap}" EXIT
            break
        fi
    done
    if [ "$_claimed" = false ]; then
        # All claimed — fall back to the first virtual device (shared)
        read -r _dev _ <<< "${FANOUT_VCAMS:-/dev/video10}"
        export VCAM_DEVICE="$_dev"
        export VCAM_INDEX="${_dev##/dev/video}"
    fi
else
    export VCAM_DEVICE="${FANOUT_REAL_CAM:-/dev/video0}"
    export VCAM_INDEX="${VCAM_DEVICE##/dev/video}"
fi
