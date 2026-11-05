#!/usr/bin/env bash
# Source this from camera tools to auto-select a virtual device when fanout is running.
#
# Assigns VCAM_DEVICE to the next available virtual camera from /dev/video{10,11,12}.
# If fanout is not running, falls back to /dev/video0.
#
# Usage in tool start.sh:
#   source ~/tools/camera-fanout/env.sh
#   # then use $VCAM_DEVICE or $VCAM_INDEX

_fanout_running() {
    [ -f /tmp/camera-fanout.pid ] && kill -0 "$(cat /tmp/camera-fanout.pid)" 2>/dev/null
}

if _fanout_running; then
    # Pick a virtual device that isn't already claimed by another tool.
    # Claim by creating a lockfile. Stale locks cleaned on fanout stop.
    _claimed=false
    for _dev in /dev/video10 /dev/video11 /dev/video12; do
        _lock="/tmp/vcam-claim-$(basename "$_dev")"
        if (set -C; echo $$ > "$_lock") 2>/dev/null; then
            export VCAM_DEVICE="$_dev"
            export VCAM_INDEX="${_dev##/dev/video}"
            _claimed=true
            # Clean up lock on exit
            # Chain onto any existing EXIT trap instead of replacing it
            _prev_exit_trap=$(trap -p EXIT | sed "s/^trap -- '\\(.*\\)' EXIT$/\\1/; s/'\\\\''/'/g")
            trap "rm -f '$_lock' 2>/dev/null${_prev_exit_trap:+; $_prev_exit_trap}" EXIT
            break
        fi
    done
    if [ "$_claimed" = false ]; then
        # All 3 claimed — fall back to video10 (shared)
        export VCAM_DEVICE="/dev/video10"
        export VCAM_INDEX="10"
    fi
else
    export VCAM_DEVICE="/dev/video0"
    export VCAM_INDEX="0"
fi
