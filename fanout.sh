#!/usr/bin/env bash
# Camera fanout — reads /dev/video0 and fans it out to v4l2loopback virtual
# devices so multiple tools can use the webcam simultaneously.
#
# Virtual devices: /dev/video10, /dev/video11, /dev/video12
# Format: MJPG passthrough (no transcode) for minimal latency.
#
# Usage:
#   ./fanout.sh          — start fanout (loads module if needed)
#   ./fanout.sh stop     — kill running fanout
#   ./fanout.sh status   — show status

set -euo pipefail

# Overridable via environment:
#   FANOUT_REAL_CAM  source camera            (default /dev/video0)
#   FANOUT_VCAMS     space-separated sinks    (default /dev/video10 /dev/video11 /dev/video12)
#   FANOUT_WIDTH / FANOUT_HEIGHT / FANOUT_FPS (default 640 / 480 / 30)
#   FANOUT_RUN_DIR   pid/log/lock directory   (default: see _fanout_resolve_run_dir)
# env.sh reads the same FANOUT_VCAMS / FANOUT_RUN_DIR, so export them for both.
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

REAL_CAM="${FANOUT_REAL_CAM:-/dev/video0}"
read -r -a VCAMS <<< "${FANOUT_VCAMS:-/dev/video10 /dev/video11 /dev/video12}"
RUN_DIR="$(_fanout_resolve_run_dir)"
PIDFILE="$RUN_DIR/camera-fanout.pid"
LOGFILE="$RUN_DIR/camera-fanout.log"

# Resolution and framerate for the fanout.  640x480@30 is a good balance:
# fast enough for ML tools, low CPU overhead for 3-way tee.
WIDTH="${FANOUT_WIDTH:-640}"
HEIGHT="${FANOUT_HEIGHT:-480}"
FPS="${FANOUT_FPS:-30}"

GREEN=$'\e[38;2;80;255;130m'
DIM=$'\e[38;2;120;220;160m'
RED=$'\e[38;2;255;80;80m'
RESET=$'\e[0m'

log() { printf '%s[fanout]%s %s\n' "$GREEN" "$RESET" "$*"; }
err() { printf '%s[fanout]%s %s\n' "$RED" "$RESET" "$*" >&2; }

# Private per-user runtime dir.  Refuse a pre-existing dir owned by someone else
# (relevant for the /tmp fallback, which is world-writable).
ensure_run_dir() {
    mkdir -p -m 700 "$RUN_DIR"
    if [ ! -O "$RUN_DIR" ] || [ -L "$RUN_DIR" ]; then
        err "$RUN_DIR is not a directory owned by $(id -un); refusing to use it"
        exit 1
    fi
}

load_module() {
    if ! grep -q v4l2loopback /proc/modules 2>/dev/null; then
        log "Loading v4l2loopback module..."
        sudo modprobe v4l2loopback
        sleep 0.5
    fi

    # Verify virtual devices appeared
    local missing=0
    for dev in "${VCAMS[@]}"; do
        if [ ! -e "$dev" ]; then
            err "Expected $dev but it does not exist after modprobe"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        err "Module loaded but virtual devices missing. Check /etc/modprobe.d/v4l2loopback.conf"
        exit 1
    fi
    log "Virtual devices ready: ${VCAMS[*]}"
}

stop_fanout() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping fanout (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            # Wait for it to actually exit
            for _ in $(seq 1 20); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -9 "$pid" 2>/dev/null || true
            log "Stopped."
        else
            log "PID $pid not running (stale pidfile)."
        fi
        rm -f "$PIDFILE"
    else
        # Also try to find by process name
        if pkill -f "^ffmpeg .*-f v4l2 ${VCAMS[0]}( |$)" 2>/dev/null; then
            log "Killed stray ffmpeg fanout process."
        else
            log "No fanout running."
        fi
    fi
    # Clean up virtual-camera claim locks, but only those whose claimant is
    # gone: a tool still holding a device keeps its claim across a restart.
    # Hold claim.lock (shared with env.sh) so a tool reclaiming a stale claim
    # at the same moment cannot have its fresh claim removed here.
    local fd=""
    if ! command -v flock >/dev/null 2>&1; then
        err "flock not found (util-linux); cleaning claim locks without serialisation"
    elif ! { exec {fd}>>"$RUN_DIR/claim.lock"; } 2>/dev/null; then
        err "cannot open $RUN_DIR/claim.lock; cleaning claim locks without serialisation"
        fd=""
    elif ! flock -w "${FANOUT_LOCK_TIMEOUT:-2}" "$fd"; then
        # A stale claim left behind is harmless: env.sh reclaims it.
        err "timed out waiting for claim.lock; leaving claim locks for env.sh to reclaim"
        exec {fd}>&-
        return 0
    fi
    clean_claims
    if [ -n "$fd" ]; then exec {fd}>&-; fi
}

clean_claims() {
    local lock owner
    for lock in "$RUN_DIR"/vcam-claim-*; do
        [ -e "$lock" ] || continue
        owner=$(cat "$lock" 2>/dev/null || true)
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$lock"
        fi
    done
}

show_status() {
    echo
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        log "Fanout RUNNING (PID $(cat "$PIDFILE"))"
    else
        log "Fanout NOT running"
    fi

    echo
    log "Module status:"
    if grep -q v4l2loopback /proc/modules 2>/dev/null; then
        printf '  %sv4l2loopback loaded%s\n' "$GREEN" "$RESET"
    else
        printf '  %sv4l2loopback NOT loaded%s\n' "$RED" "$RESET"
    fi

    echo
    log "Video devices:"
    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        printf '  %sv4l2-ctl not installed (v4l-utils); cannot list devices%s\n' "$RED" "$RESET"
        echo
        return 0
    fi
    v4l2-ctl --list-devices 2>&1 | while IFS= read -r line; do
        printf '  %s%s%s\n' "$DIM" "$line" "$RESET"
    done
    echo
}

start_fanout() {
    # Kill any existing fanout
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        log "Fanout already running (PID $(cat "$PIDFILE")). Restarting..."
        stop_fanout
    fi

    # Ensure module is loaded
    load_module

    # Check real camera exists and is accessible
    if [ ! -e "$REAL_CAM" ]; then
        err "Real camera $REAL_CAM does not exist"
        exit 1
    fi

    # Build ffmpeg command:
    # - Read from real camera as MJPG (hardware-compressed, no CPU decode needed)
    # - Output raw copy to each virtual device via v4l2 output
    #
    # We use -codec copy for zero-transcode passthrough when possible.
    # However, v4l2loopback sinks need rawvideo (YUV/RGB), so we decode MJPG
    # once and write raw YUV420P to each virtual device. This is still very
    # cheap — one decode, three memcpys.
    local cmd=(
        ffmpeg -hide_banner -loglevel warning
        -f v4l2
        -input_format mjpeg
        -video_size "${WIDTH}x${HEIGHT}"
        -framerate "$FPS"
        -i "$REAL_CAM"
    )

    # Each output: decode to YUV420P and write to virtual device
    for dev in "${VCAMS[@]}"; do
        cmd+=(
            -codec:v rawvideo
            -pix_fmt yuyv422
            -f v4l2
            "$dev"
        )
    done

    log "Starting fanout: $REAL_CAM -> ${VCAMS[*]}"
    log "Format: MJPG ${WIDTH}x${HEIGHT}@${FPS}fps -> YUYV422 raw"
    log "Log: $LOGFILE"

    # Run in background
    "${cmd[@]}" >> "$LOGFILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDFILE"

    # Give it a moment to start
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        log "Fanout started (PID $pid)"
        notify-send -a "Camera Fanout" \
            "Fanout active: $REAL_CAM -> ${#VCAMS[@]} virtual cameras" 2>/dev/null || true
    else
        err "ffmpeg exited immediately. Check $LOGFILE"
        rm -f "$PIDFILE"
        tail -5 "$LOGFILE" >&2
        exit 1
    fi
}

ensure_run_dir

case "${1:-start}" in
    start)  start_fanout ;;
    stop)   stop_fanout ;;
    status) show_status ;;
    restart)
        stop_fanout
        sleep 0.5
        start_fanout
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        exit 1
        ;;
esac
