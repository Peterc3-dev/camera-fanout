# camera-fanout

Share one Linux webcam across multiple programs at once, using ffmpeg and v4l2loopback.

## What it does

Linux only lets one process open `/dev/video0` at a time. `camera-fanout` works around
that by reading the real webcam once and copying ("fanning out") its frames into three
v4l2loopback virtual devices (`/dev/video10`, `/dev/video11`, `/dev/video12`), so several
tools can each open their own virtual camera simultaneously.

Two scripts:

- **`fanout.sh`** — loads the `v4l2loopback` module if needed, then runs a background
  ffmpeg process that reads `/dev/video0` (MJPEG, 640x480@30) and writes raw YUYV422
  frames to the three virtual devices. Manages a PID file at `/tmp/camera-fanout.pid`
  and logs to `/tmp/camera-fanout.log`.
- **`env.sh`** — meant to be `source`d by other camera tools. If the fanout is running,
  it claims the next free virtual device (via a `/tmp/vcam-claim-*` lockfile) and exports
  `VCAM_DEVICE` / `VCAM_INDEX`. If the fanout isn't running, it falls back to
  `/dev/video0`.

## Status

Working personal utility, single machine. Device numbers, resolution (640x480), and
framerate (30) are hardcoded near the top of `fanout.sh`. The three virtual-device paths
are likewise hardcoded and assume `v4l2loopback` is configured to create
`/dev/video{10,11,12}`. Not packaged or generalized beyond that setup.

## Requirements

- Linux with the `v4l2loopback` kernel module installed
- `ffmpeg`
- `v4l2-ctl` (from `v4l-utils`) for the `status` output
- `sudo` access to run `modprobe v4l2loopback`
- A real camera at `/dev/video0`

`v4l2loopback` should be configured to create three devices at `/dev/video10`,
`/dev/video11`, and `/dev/video12` (typically via `/etc/modprobe.d/v4l2loopback.conf`).
If the devices come up at different numbers, edit the `VCAMS` array in `fanout.sh`.

## Usage

```bash
./fanout.sh            # start the fanout (loads the module if needed)
./fanout.sh status     # show fanout / module / device status
./fanout.sh stop       # stop the fanout and clean up claim locks
./fanout.sh restart    # stop then start
```

In another camera tool, pick a virtual device automatically:

```bash
source /path/to/camera-fanout/env.sh
# now use "$VCAM_DEVICE" (e.g. /dev/video11) or "$VCAM_INDEX"
```

## Notes / limitations

- Resolution, framerate, real-camera path, and the three virtual-device paths are all
  hardcoded in `fanout.sh`.
- The fanout decodes MJPEG once and writes raw YUYV422 to each device (one decode, three
  copies); there is no per-device transcoding.
- `env.sh` claims at most three devices; once all three are taken it falls back to sharing
  `/dev/video10`.
- Uses `notify-send` for a desktop notification on start if available (optional).
