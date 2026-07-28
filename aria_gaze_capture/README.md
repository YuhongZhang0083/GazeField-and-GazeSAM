# Aria gaze capture (Phase 2)

Real-time capture from Project Aria glasses for gaze-field generation — the eye
channel that complements the iPhone **HeadPoseDistance** protocol (which already
provides validated ground truth: a known on-screen fixation target + head pose +
face distance, sign conventions confirmed on device).

## `aria_dual_stream.py`

Streams and (optionally) records **two** synchronized Aria streams:

- **RGB world view** (`Aria RGB (world)`)
- **Eye-tracking / pupil image** (`Aria Eye (pupil)`) — the IR eye camera frame

It does no gaze/pupil inference yet — it only streams, previews, and records
clean, per-frame-timestamped video. Pupil detection + gaze-field fitting come in
the next scripts (can reuse `../../realtime_hu/` FastSAM/ONNX pupil models).

### Environment

Runs in the existing `aria_py311` conda env (has `aria.sdk`, `opencv`, `numpy`):

```bash
conda activate aria_py311
```

### Run

```bash
# live preview over USB (default profile5 carries both RGB + EyeTrack)
python aria_dual_stream.py --interface usb

# preview + record both streams
python aria_dual_stream.py --interface usb --record

# glasses on your Wi-Fi network (station mode)
python aria_dual_stream.py --interface wifi --device-ip 192.168.1.42 --record
```

Hotkeys in the preview windows: **`r`** toggle recording, **ESC/`q`** quit.

### Confirmed on device (2026-07-24, profile5)

- **RGB**: `1408×1408×3`, ~20 fps
- **Eye**: `480×1280` grayscale, ~20 fps — a **single stereo frame with both eyes
  side by side** (≈`480×640` per eye). Split at the horizontal midpoint for
  left/right pupil processing.

### Troubleshooting: "participant discovered" but 0 frames

Streaming starts (`StreamingState.Streaming`, "DDS participant discovered") but
`rgb=0 eye=0`. Almost always a **network path** problem, not the code/device:

- **VPN (Tailscale) hijacks the route.** `route -n get 192.168.42.129` shows
  `interface: en0` (the VPN) instead of the USB interface. Tailscale also
  breaks DHCP on the USB interface, leaving it on a `169.254.x` link-local
  address. **Fix:** turn the VPN off (System Settings → Network → VPN & Filters,
  and quit the Tailscale menu-bar app), then put the USB interface on the
  glasses' subnet:
  ```bash
  sudo ifconfig <enXXX> inet 192.168.42.2 netmask 255.255.255.0 up
  sudo route delete 192.168.42.129 2>/dev/null
  sudo route add -host 192.168.42.129 -interface <enXXX>
  route -n get 192.168.42.129 | grep interface   # -> <enXXX>, not en0
  ```
  Find `<enXXX>` with `ifconfig | grep -B4 "192.168.42\|169.254" | grep '^en'`
  (the name changes on replug — macOS spawns Aria 13, 14, 15… services).
- **Wrong profile.** `profile18` starts the manager but publishes no data on
  this device — use **`profile5`** (the default here).
- Firewall: fine to leave off; the working setup has it disabled.

### Output (per recording session)

`captures/<UTC-timestamp>/`:

| File | Contents |
|---|---|
| `rgb.mp4`, `eye.mp4` | the two streams (nominal 30 fps for playback) |
| `rgb_frames.csv`, `eye_frames.csv` | per-frame `capture_timestamp_ns` (Aria hardware clock) + host receive time — the ground truth for timing |
| `session.json` | session id + host start time + alignment note |

The `.mp4` fps is only nominal; **exact timing lives in the `*_frames.csv`**
(`capture_timestamp_ns`). Recording never blocks streaming — if a writer falls
behind it drops the oldest frame rather than stalling the pupil stream.

## Next steps

1. **Sync to the iPhone protocol** — align `capture_timestamp_ns` (and host
   clock) to the HeadPoseDistance CSV so every eye frame carries a known
   fixation target + head pose + distance. Simplest bridge: start the iPhone
   recording and this capture from a shared cue and align on host wall-clock;
   refine with the hardware timestamps.
2. **Pupil extraction** — per-eye pupil centre from `eye.mp4` (reuse the
   FastSAM/ONNX pupil pipeline in `../../realtime_hu/`).
3. **Gaze-target grid** — extend the iPhone protocol from centre-only fixation
   to a screen grid so the dataset spans the gaze field, not one point.
4. **Fit the gaze field** — map `(pupil, head pose, distance) → screen point`.
