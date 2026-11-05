#!/usr/bin/env bash
# Camera-free tests for env.sh claim logic, stale-lock reclaim and EXIT-trap
# chaining.  Uses a scratch FANOUT_RUN_DIR and a fake "fanout" PID.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

export FANOUT_RUN_DIR="$SCRATCH/run"
export FANOUT_VCAMS="/dev/video10 /dev/video11 /dev/video12"
mkdir -p "$FANOUT_RUN_DIR"

pass=0; fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   - $1";
    else fail=$((fail+1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

# 1. Fanout not running -> real cam
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "fallback to real cam when fanout down" "/dev/video0" "$out"

# Fake a running fanout
sleep 300 & FAKE_PID=$!
echo "$FAKE_PID" > "$FANOUT_RUN_DIR/camera-fanout.pid"

# 2. First claim gets video10 and the lock is removed on exit
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE; cat '$FANOUT_RUN_DIR/vcam-claim-video10'")
check "first claim gets video10" "/dev/video10" "$(echo "$out" | head -1)"
[ -n "$(echo "$out" | sed -n 2p)" ] && check "lock held while running" yes yes || check "lock held while running" yes no
check "lock removed on exit" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video10" ] && echo present || echo absent)"

# 3. Live claimant blocks the device; next claim gets video11
sleep 300 & LIVE=$!
echo "$LIVE" > "$FANOUT_RUN_DIR/vcam-claim-video10"
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "live claim respected" "/dev/video11" "$out"

# 4. Stale lock (dead PID) is reclaimed
kill "$LIVE"; wait "$LIVE" 2>/dev/null
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "stale lock reclaimed" "/dev/video10" "$out"
check "stale lock cleaned after reclaimer exit" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video10" ] && echo present || echo absent)"

# 5. Empty (half-written) lock is treated as stale
: > "$FANOUT_RUN_DIR/vcam-claim-video10"
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "empty lock reclaimed" "/dev/video10" "$out"

# 6. All claimed by live processes -> shared fallback to first device
sleep 300 & L1=$!
for d in 10 11 12; do echo "$L1" > "$FANOUT_RUN_DIR/vcam-claim-video$d"; done
out=$(bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "all claimed falls back to first" "/dev/video10" "$out"
kill "$L1"; wait "$L1" 2>/dev/null
rm -f "$FANOUT_RUN_DIR"/vcam-claim-*

# 7. Existing EXIT trap (with quotes) is chained, not replaced
out=$(bash -c "trap 'echo \"prev it'\\''s ran\"' EXIT; source '$HERE/env.sh'; echo \$VCAM_DEVICE")
check "trap chain: claim" "/dev/video10" "$(echo "$out" | head -1)"
check "trap chain: previous trap ran" "prev it's ran" "$(echo "$out" | tail -1)"
check "trap chain: lock removed" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video10" ] && echo present || echo absent)"

# 8. Positional params of the sourcing shell are untouched
out=$(bash -c "set -- a b; source '$HERE/env.sh'; echo \"\$*\"")
check "positional params preserved" "a b" "$out"

# 9. fanout.sh stop removes only dead claimants' locks (no camera needed)
sleep 300 & L2=$!
echo "$L2" > "$FANOUT_RUN_DIR/vcam-claim-video11"
echo 999999 > "$FANOUT_RUN_DIR/vcam-claim-video12"
rm -f "$FANOUT_RUN_DIR/camera-fanout.pid"
PATH="$SCRATCH/bin:$PATH"; mkdir -p "$SCRATCH/bin"; printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/bin/pkill"; chmod +x "$SCRATCH/bin/pkill"
bash "$HERE/fanout.sh" stop >/dev/null
check "stop keeps live claim" "present" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video11" ] && echo present || echo absent)"
check "stop removes dead claim" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video12" ] && echo present || echo absent)"
kill "$L2"; wait "$L2" 2>/dev/null

# 10. status survives missing v4l2-ctl
mkdir -p "$SCRATCH/nobin"; for t in bash cat grep id mkdir dirname printf; do ln -sf "$(command -v $t)" "$SCRATCH/nobin/$t"; done
PATH="$SCRATCH/nobin" bash "$HERE/fanout.sh" status >/dev/null 2>&1; rc=$?
check "status without v4l2-ctl exits 0" "0" "$rc"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
