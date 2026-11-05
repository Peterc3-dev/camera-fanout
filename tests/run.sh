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

# 11. Claimants racing for the same stale lock: exactly one wins.  Each waits
# on a barrier file so they hit the reclaim path together; repeat a few rounds.
echo "$FAKE_PID" > "$FANOUT_RUN_DIR/camera-fanout.pid"   # test 9 removed it
race_round() { # n
    local n="$1" i dead winners
    sleep 0.01 & dead=$!; wait "$dead" 2>/dev/null
    echo "$dead" > "$FANOUT_RUN_DIR/vcam-claim-video10"
    rm -f "$SCRATCH/go" "$SCRATCH"/race.*
    for i in $(seq 1 "$n"); do
        FANOUT_VCAMS=/dev/video10 bash -c "
            while [ ! -e '$SCRATCH/go' ]; do :; done
            source '$HERE/env.sh'
            if [ \"\$(cat '$FANOUT_RUN_DIR/vcam-claim-video10' 2>/dev/null)\" = \$\$ ]; then echo won; else echo lost; fi
            sleep 1" > "$SCRATCH/race.$i" 2>/dev/null &
    done
    sleep 0.3; touch "$SCRATCH/go"; wait
    winners=$(cat "$SCRATCH"/race.* | grep -c '^won$')
    echo "$winners"
}
race_ok=yes
for r in 1 2 3 4 5; do w=$(race_round 6); [ "$w" = 1 ] || { race_ok="no (round $r: $w winners)"; break; }; done
check "stale-lock race has exactly one winner" yes "$race_ok"
rm -f "$FANOUT_RUN_DIR"/vcam-claim-*

# 11b. Claiming actually waits on claim.lock (the race above is too narrow to
# reproduce reliably unlocked, so prove serialisation directly).
sleep 0.01 & dead=$!; wait "$dead" 2>/dev/null
echo "$dead" > "$FANOUT_RUN_DIR/vcam-claim-video10"
flock "$FANOUT_RUN_DIR/claim.lock" sleep 1 & HOLD=$!
sleep 0.2
FANOUT_VCAMS=/dev/video10 FANOUT_LOCK_TIMEOUT=5 bash -c "source '$HERE/env.sh'; sleep 1.5" & CL=$!
sleep 0.4
check "claim waits while claim.lock held" "$dead" "$(cat "$FANOUT_RUN_DIR/vcam-claim-video10")"
wait "$HOLD"; sleep 0.3
check "claim proceeds once claim.lock released" "$CL" "$(cat "$FANOUT_RUN_DIR/vcam-claim-video10")"
wait "$CL"; rm -f "$FANOUT_RUN_DIR"/vcam-claim-*

# 12. Missing flock: claim still works, with a warning
mkdir -p "$SCRATCH/noflock"; for t in bash cat id basename sed; do ln -sf "$(command -v $t)" "$SCRATCH/noflock/$t"; done
out=$(PATH="$SCRATCH/noflock" bash -c "source '$HERE/env.sh'; echo \$VCAM_DEVICE" 2>"$SCRATCH/noflock.err")
check "no flock: still claims" "/dev/video10" "$out"
check "no flock: warns" yes "$(grep -q 'flock not found' "$SCRATCH/noflock.err" && echo yes || echo no)"

# 13. fanout.sh stop honours claim.lock: skips cleanup on timeout, cleans
# after the holder releases, and still cleans when flock is missing.
rm -f "$FANOUT_RUN_DIR/camera-fanout.pid"
echo 999999 > "$FANOUT_RUN_DIR/vcam-claim-video12"
flock "$FANOUT_RUN_DIR/claim.lock" sleep 1 & HOLD=$!
sleep 0.2
FANOUT_LOCK_TIMEOUT=0.2 bash "$HERE/fanout.sh" stop >/dev/null 2>"$SCRATCH/stop.err"; rc=$?
check "stop under held lock exits 0" "0" "$rc"
check "stop under held lock leaves claims" "present" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video12" ] && echo present || echo absent)"
check "stop under held lock warns" yes "$(grep -q 'timed out' "$SCRATCH/stop.err" && echo yes || echo no)"
wait "$HOLD"
bash "$HERE/fanout.sh" stop >/dev/null 2>&1
check "stop cleans once lock free" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video12" ] && echo present || echo absent)"
echo 999999 > "$FANOUT_RUN_DIR/vcam-claim-video12"
for t in rm seq sleep mkdir dirname printf grep; do ln -sf "$(command -v $t)" "$SCRATCH/noflock/$t"; done
ln -sf "$SCRATCH/bin/pkill" "$SCRATCH/noflock/pkill"
PATH="$SCRATCH/noflock" bash "$HERE/fanout.sh" stop >/dev/null 2>"$SCRATCH/stop.err"; rc=$?
check "stop without flock exits 0" "0" "$rc"
check "stop without flock cleans" "absent" "$([ -e "$FANOUT_RUN_DIR/vcam-claim-video12" ] && echo present || echo absent)"
check "stop without flock warns" yes "$(grep -q 'flock not found' "$SCRATCH/stop.err" && echo yes || echo no)"

# 14. Runtime-dir resolution: with XDG_RUNTIME_DIR unset, both scripts use an
# owned /run/user/<uid> (faked via FANOUT_TEST_RUN_USER_BASE) and agree.
uid=$(id -u)
mkdir -p -m 700 "$SCRATCH/runuser/$uid"
want="$SCRATCH/runuser/$uid/camera-fanout-$uid"
env -u FANOUT_RUN_DIR -u XDG_RUNTIME_DIR FANOUT_TEST_RUN_USER_BASE="$SCRATCH/runuser" \
    PATH="$SCRATCH/nobin" bash "$HERE/fanout.sh" status >/dev/null 2>&1
check "fanout.sh uses /run/user/<uid> without XDG" "present" "$([ -d "$want" ] && echo present || echo absent)"
out=$(env -u FANOUT_RUN_DIR -u XDG_RUNTIME_DIR FANOUT_TEST_RUN_USER_BASE="$SCRATCH/runuser" \
    bash -c "source '$HERE/env.sh'; echo \$_fanout_run_dir")
check "env.sh matches fanout.sh without XDG" "$want" "$out"
out=$(env -u FANOUT_RUN_DIR XDG_RUNTIME_DIR="$SCRATCH/xdg" FANOUT_TEST_RUN_USER_BASE="$SCRATCH/runuser" \
    bash -c "source '$HERE/env.sh'; echo \$_fanout_run_dir")
check "XDG_RUNTIME_DIR wins over /run/user" "$SCRATCH/xdg/camera-fanout-$uid" "$out"
out=$(env -u FANOUT_RUN_DIR -u XDG_RUNTIME_DIR FANOUT_TEST_RUN_USER_BASE="$SCRATCH/missing" \
    bash -c "source '$HERE/env.sh'; echo \$_fanout_run_dir")
check "no /run/user/<uid> falls back to /tmp" "/tmp/camera-fanout-$uid" "$out"
mkdir -p "$SCRATCH/linkuser"; ln -s "$SCRATCH/runuser/$uid" "$SCRATCH/linkuser/$uid"
out=$(env -u FANOUT_RUN_DIR -u XDG_RUNTIME_DIR FANOUT_TEST_RUN_USER_BASE="$SCRATCH/linkuser" \
    bash -c "source '$HERE/env.sh'; echo \$_fanout_run_dir")
check "symlinked /run/user/<uid> ignored" "/tmp/camera-fanout-$uid" "$out"
check "resolver identical in both scripts" yes \
    "$(diff <(sed -n '/^_fanout_resolve_run_dir()/,/^}/p' "$HERE/env.sh") <(sed -n '/^_fanout_resolve_run_dir()/,/^}/p' "$HERE/fanout.sh") >/dev/null && echo yes || echo no)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
