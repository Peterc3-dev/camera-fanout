#!/usr/bin/env bash
# Source this from camera tools to auto-select a virtual device when fanout is running.
#
# Assigns VCAM_DEVICE to the next available virtual camera (default
# /dev/video{10,11,12}, override with FANOUT_VCAMS="dev1 dev2 ...").
# If fanout is not running, falls back to FANOUT_REAL_CAM (default /dev/video0).
#
# Runtime files (pidfile, claim locks) live in FANOUT_RUN_DIR, which defaults
# to ${XDG_RUNTIME_DIR:-/tmp}/camera-fanout-<uid>.  fanout.sh uses the same rule.
#
# Usage in tool start.sh:
#   source ~/tools/camera-fanout/env.sh
#   # then use $VCAM_DEVICE or $VCAM_INDEX

_fanout_run_dir="${FANOUT_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/camera-fanout-$(id -u)}"
_fanout_pidfile="$_fanout_run_dir/camera-fanout.pid"

_fanout_running() {
    [ -f "$_fanout_pidfile" ] && kill -0 "$(cat "$_fanout_pidfile" 2>/dev/null)" 2>/dev/null
}

# Try to claim lockfile $1 for this shell ($$).  A lock whose recorded PID is
# no longer alive (claimant crashed or was SIGKILLed) is reclaimed once.
_fanout_claim() {
    local lock="$1" owner
    if (set -C; echo $$ > "$lock") 2>/dev/null; then
        return 0
    fi
    owner=$(cat "$lock" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    # Stale lock.  Re-check the content right before removing it to narrow the
    # window in which another claimant could have reclaimed it first.
    [ "$(cat "$lock" 2>/dev/null)" = "$owner" ] || return 1
    rm -f "$lock" 2>/dev/null
    (set -C; echo $$ > "$lock") 2>/dev/null
}

if _fanout_running; then
    # Pick a virtual device that isn't already claimed by a live tool.
    _claimed=false
    for _dev in ${FANOUT_VCAMS:-/dev/video10 /dev/video11 /dev/video12}; do
        _lock="$_fanout_run_dir/vcam-claim-$(basename "$_dev")"
        if _fanout_claim "$_lock"; then
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
