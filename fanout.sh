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

REAL_CAM="/dev/video0"
VCAMS=(/dev/video10 /dev/video11 /dev/video12)
PIDFILE="/tmp/camera-fanout.pid"
LOGFILE="/tmp/camera-fanout.log"

# Resolution and framerate for the fanout.  640x480@30 is a good balance:
# fast enough for ML tools, low CPU overhead for 3-way tee.
WIDTH=640
HEIGHT=480
FPS=30

GREEN=$'\e[38;2;80;255;130m'
DIM=$'\e[38;2;120;220;160m'
RED=$'\e[38;2;255;80;80m'
RESET=$'\e[0m'

log() { printf '%s[fanout]%s %s\n' "$GREEN" "$RESET" "$*"; }
err() { printf '%s[fanout]%s %s\n' "$RED" "$RESET" "$*" >&2; }

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
        if pkill -f "ffmpeg.*v4l2loopback\|ffmpeg.*video10" 2>/dev/null; then
            log "Killed stray ffmpeg fanout process."
        else
            log "No fanout running."
        fi
    fi
    # Clean up virtual-camera claim locks
    rm -f /tmp/vcam-claim-video1{0,1,2} 2>/dev/null
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
            "Fanout active: $REAL_CAM -> 3 virtual cameras" 2>/dev/null || true
    else
        err "ffmpeg exited immediately. Check $LOGFILE"
        rm -f "$PIDFILE"
        tail -5 "$LOGFILE" >&2
        exit 1
    fi
}

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
