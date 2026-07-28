#!/usr/bin/env python3
"""Real-time dual-stream capture from Project Aria glasses: RGB world view +
eye-tracking (pupil) camera image, previewed live and optionally recorded.

This is the capture foundation for Phase 2 (gaze-field generation): it grabs
the two streams the gaze model needs — the front RGB view and the IR eye
image — with per-frame hardware timestamps so they can later be aligned to
the iPhone HeadPoseDistance protocol (known fixation target + head pose +
distance) that already produces validated ground truth.

It deliberately does NO gaze/pupil inference — that's the next script. Here we
only stream, show, and (optionally) record clean, timestamped video.

Usage
-----
    # live preview over USB (default profile streams both RGB + EyeTrack)
    python aria_dual_stream.py --interface usb

    # preview + record both streams to ./captures/<session>/
    python aria_dual_stream.py --interface usb --record

    # Wi-Fi streaming to a known device IP
    python aria_dual_stream.py --interface wifi --device-ip 192.168.1.42 --record

Hotkeys (in the preview windows): 'r' toggle recording, ESC / 'q' quit.

Requirements: projectaria_client_sdk (`import aria.sdk`), opencv-python, numpy.
The Aria glasses must be paired and streaming-enabled (same as the existing
realtime_hu scripts, which this mirrors).
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
import threading
import time
from datetime import datetime, timezone
from queue import Empty, Full, Queue

import cv2
import numpy as np

import aria.sdk as aria


# --------------------------------------------------------------------------- #
# Per-stream recorder: an mp4 for quick viewing + a CSV of true frame
# timestamps (the mp4 fps is only nominal — exact timing lives in the CSV).
# --------------------------------------------------------------------------- #
class StreamRecorder:
    def __init__(self, name: str, out_dir: str, nominal_fps: float):
        self.name = name
        self.out_dir = out_dir
        self.nominal_fps = nominal_fps
        self._writer: cv2.VideoWriter | None = None
        self._size: tuple[int, int] | None = None  # (w, h)
        self._csv_file = open(os.path.join(out_dir, f"{name}_frames.csv"), "w", newline="")
        self._csv = csv.writer(self._csv_file)
        self._csv.writerow(["frame_index", "capture_timestamp_ns", "host_recv_unix_s",
                            "width", "height"])
        self._frame_index = 0
        self._queue: "Queue[tuple[int, float, np.ndarray]]" = Queue(maxsize=120)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._drain, name=f"rec-{name}", daemon=True)
        self._thread.start()

    def submit(self, capture_ts_ns: int, frame_bgr: np.ndarray) -> None:
        """Called from the SDK callback thread. Never blocks streaming: if the
        writer falls behind, drop the oldest frame rather than stall."""
        try:
            self._queue.put_nowait((capture_ts_ns, time.time(), frame_bgr))
        except Full:
            try:
                self._queue.get_nowait()
                self._queue.put_nowait((capture_ts_ns, time.time(), frame_bgr))
            except (Empty, Full):
                pass

    def _drain(self) -> None:
        while not (self._stop.is_set() and self._queue.empty()):
            try:
                ts_ns, host_s, frame = self._queue.get(timeout=0.2)
            except Empty:
                continue
            h, w = frame.shape[:2]
            if self._writer is None:
                self._size = (w, h)
                fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                path = os.path.join(self.out_dir, f"{self.name}.mp4")
                self._writer = cv2.VideoWriter(path, fourcc, self.nominal_fps, (w, h))
            if (w, h) != self._size:            # guard against a resolution change
                frame = cv2.resize(frame, self._size)
            self._writer.write(frame)
            self._csv.writerow([self._frame_index, ts_ns if ts_ns is not None else "",
                               f"{host_s:.6f}", w, h])
            self._frame_index += 1

    def close(self) -> int:
        self._stop.set()
        self._thread.join(timeout=5)
        if self._writer is not None:
            self._writer.release()
        self._csv_file.flush()
        self._csv_file.close()
        return self._frame_index


# --------------------------------------------------------------------------- #
# Streaming observer: keeps the latest frame of each stream for display and,
# when recording, forwards every frame to its recorder.
# --------------------------------------------------------------------------- #
class DualStreamObserver:
    def __init__(self):
        self._lock = threading.Lock()
        self.latest_rgb: np.ndarray | None = None
        self.latest_eye: np.ndarray | None = None
        self.rgb_count = 0
        self.eye_count = 0
        # Windowed FPS: count frames within a ~1 s window, then divide.
        self._win = {"rgb": [0, time.time()], "eye": [0, time.time()]}
        self.rgb_fps = 0.0
        self.eye_fps = 0.0
        self._printed_shapes = False

        self._rec_lock = threading.Lock()
        self._rgb_rec: StreamRecorder | None = None
        self._eye_rec: StreamRecorder | None = None

    # -- recording control (called from the main thread) --
    def set_recorders(self, rgb_rec, eye_rec):
        with self._rec_lock:
            self._rgb_rec, self._eye_rec = rgb_rec, eye_rec

    # -- SDK callback (called from the streaming thread) --
    def on_image_received(self, image: np.ndarray, record) -> None:
        cam_id = getattr(record, "camera_id", None)
        ts_ns = getattr(record, "capture_timestamp_ns", None)

        if cam_id == aria.CameraId.Rgb:
            bgr = self._rgb_to_bgr_upright(image)
            with self._lock:
                if self.rgb_count == 0:
                    print(f"[first frame] RGB received, shape={image.shape}")
                self.latest_rgb = bgr
                self.rgb_count += 1
                self.rgb_fps = self._tick("rgb")
            with self._rec_lock:
                if self._rgb_rec is not None:
                    self._rgb_rec.submit(ts_ns, bgr)

        elif cam_id == aria.CameraId.EyeTrack:
            eye = image[..., 0] if image.ndim == 3 else image      # ET is grayscale
            eye_bgr = cv2.cvtColor(eye, cv2.COLOR_GRAY2BGR)
            with self._lock:
                if self.eye_count == 0:
                    print(f"[first frame] Eye received, shape={image.shape}")
                self.latest_eye = eye_bgr
                self.eye_count += 1
                self.eye_fps = self._tick("eye")
            with self._rec_lock:
                if self._eye_rec is not None:
                    self._eye_rec.submit(ts_ns, eye_bgr)

        if not self._printed_shapes and self.latest_rgb is not None and self.latest_eye is not None:
            print(f"[shapes] RGB {self.latest_rgb.shape}  Eye {self.latest_eye.shape}")
            self._printed_shapes = True

    @staticmethod
    def _rgb_to_bgr_upright(rgb: np.ndarray) -> np.ndarray:
        if rgb.ndim == 3 and rgb.shape[2] == 3:
            bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        elif rgb.ndim == 2:
            bgr = cv2.cvtColor(rgb, cv2.COLOR_GRAY2BGR)
        else:
            bgr = rgb.copy()
        # Same orientation the existing realtime_hu scripts use for Aria RGB.
        bgr = cv2.rotate(bgr, cv2.ROTATE_90_COUNTERCLOCKWISE)
        bgr = cv2.rotate(bgr, cv2.ROTATE_180)
        return bgr

    def _tick(self, which: str) -> float:
        """Windowed frames-per-second for one stream. Call once per frame."""
        w = self._win[which]
        w[0] += 1
        now = time.time()
        dt = now - w[1]
        if dt >= 1.0:
            fps = w[0] / dt
            w[0], w[1] = 0, now
            return fps
        return self.rgb_fps if which == "rgb" else self.eye_fps

    def snapshot(self):
        with self._lock:
            return (self.latest_rgb, self.latest_eye, self.rgb_count, self.eye_count,
                    self.rgb_fps, self.eye_fps)


# --------------------------------------------------------------------------- #
# Device / streaming lifecycle
# --------------------------------------------------------------------------- #
def connect_and_stream(args):
    device_client = aria.DeviceClient()
    client_config = aria.DeviceClientConfig()
    if args.device_ip:
        client_config.ip_v4_address = args.device_ip
    device_client.set_client_config(client_config)

    def _connect():
        """(Re)connect and (re)apply the streaming config; returns the trio."""
        device = device_client.connect()
        sm = device.streaming_manager
        sc = sm.streaming_client
        cfg = aria.StreamingConfig()
        cfg.profile_name = args.profile
        if args.interface == "usb":
            cfg.streaming_interface = aria.StreamingInterface.Usb
        elif args.interface == "wifi-softap":
            cfg.streaming_interface = aria.StreamingInterface.WifiSoftAp
        else:  # "wifi" == station mode (glasses on the same Wi-Fi network)
            cfg.streaming_interface = aria.StreamingInterface.WifiStation
        cfg.security_options.use_ephemeral_certs = True
        sm.streaming_config = cfg
        return device, sm, sc

    device, streaming_manager, streaming_client = _connect()

    # A previous run that didn't stop cleanly leaves the device's on-device
    # recording/streaming pipeline wedged (the first "(9) Failed to start
    # recording"). After that, start_streaming "succeeds" at the manager level
    # but no sensor frames are ever published -> the 0-frames symptom. Clear
    # BOTH a lingering recording and stream before (re)starting.
    try:
        print(f"[device] recording_state={device.recording_manager.recording_state} "
              f"streaming_state={streaming_manager.streaming_state}")
    except Exception as exc:                                      # noqa: BLE001
        print(f"[device] state query failed: {exc}")
    try:
        device.recording_manager.stop_recording()
        print("[device] cleared a lingering on-device recording")
    except Exception:
        pass
    try:
        streaming_manager.stop_streaming()
    except Exception:
        pass
    time.sleep(0.5)

    print(f"Starting streaming: profile='{args.profile}' interface={args.interface.upper()} "
          "(takes ~15 s) ...")
    last_err = None
    for attempt in range(1, 4):
        try:
            if attempt > 1:
                print(f"[streaming] reconnecting before retry {attempt}/3 ...")
                try:
                    device_client.disconnect(device)
                except Exception:
                    pass
                time.sleep(0.5)
                device, streaming_manager, streaming_client = _connect()
            print(f"[streaming] start attempt {attempt}/3 ...")
            streaming_manager.start_streaming()
            last_err = None
            break
        except RuntimeError as exc:                               # noqa: PERF203
            last_err = exc
            print(f"[streaming] attempt {attempt} failed: {exc} "
                  f"(state={streaming_manager.streaming_state})")
            try:
                streaming_manager.stop_streaming()
            except Exception:
                pass
            time.sleep(1.5)
    if last_err is not None:
        raise RuntimeError(f"Failed to start streaming after 3 attempts: {last_err}")
    print(f"Streaming state: {streaming_manager.streaming_state}")

    observer = DualStreamObserver()
    streaming_client.set_streaming_client_observer(observer)

    sub = streaming_client.subscription_config
    sub.subscriber_data_type = aria.StreamingDataType.Rgb | aria.StreamingDataType.EyeTrack
    sub.message_queue_size[aria.StreamingDataType.Rgb] = 1        # freshest world frame
    sub.message_queue_size[aria.StreamingDataType.EyeTrack] = 2   # don't drop pupil frames
    streaming_client.subscription_config = sub
    streaming_client.subscribe()

    return device_client, device, streaming_manager, streaming_client, observer


def teardown(device_client, device, streaming_manager, streaming_client):
    for step in (
        lambda: streaming_client.unsubscribe(),
        lambda: streaming_manager.stop_streaming(),
        lambda: device_client.disconnect(device),
    ):
        try:
            step()
        except Exception as exc:                                  # noqa: BLE001
            print(f"[teardown] {exc}")


# --------------------------------------------------------------------------- #
# Recording session helpers
# --------------------------------------------------------------------------- #
def start_recording(base_out: str):
    session = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = os.path.join(base_out, session)
    os.makedirs(out_dir, exist_ok=True)
    rgb_rec = StreamRecorder("rgb", out_dir, nominal_fps=30.0)
    eye_rec = StreamRecorder("eye", out_dir, nominal_fps=30.0)
    # A small manifest to make later iPhone<->Aria alignment explicit.
    with open(os.path.join(out_dir, "session.json"), "w") as f:
        import json
        json.dump({
            "session": session,
            "started_host_unix_s": time.time(),
            "note": "Aria dual-stream capture. Align with iPhone HeadPoseDistance "
                    "export via capture_timestamp_ns / host clock.",
        }, f, indent=2)
    print(f"[REC] recording -> {out_dir}")
    return out_dir, rgb_rec, eye_rec


def stop_recording(out_dir, rgb_rec, eye_rec):
    n_rgb = rgb_rec.close()
    n_eye = eye_rec.close()
    print(f"[REC] stopped. wrote rgb={n_rgb} frames, eye={n_eye} frames -> {out_dir}")


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Aria dual-stream (RGB + eye) live capture.")
    ap.add_argument("--interface", choices=["usb", "wifi", "wifi-softap"], default="usb",
                    help="usb; wifi = glasses on your Wi-Fi (station); "
                         "wifi-softap = glasses' own access point.")
    ap.add_argument("--profile", default="profile5",
                    help="Streaming profile that includes RGB + EyeTrack. profile5 is the "
                         "one your realtime_hu runs use and that actually delivers frames on "
                         "this device; profile18 starts the manager but publishes no data.")
    ap.add_argument("--device-ip", default=None, help="Aria IP for Wi-Fi streaming.")
    ap.add_argument("--record", action="store_true", help="Start recording immediately.")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "captures"))
    ap.add_argument("--no-display", action="store_true", help="Record only, no preview windows.")
    args = ap.parse_args()

    device_client, device, streaming_manager, streaming_client, observer = connect_and_stream(args)

    recording = False
    out_dir = rgb_rec = eye_rec = None
    if args.record:
        out_dir, rgb_rec, eye_rec = start_recording(args.outdir)
        observer.set_recorders(rgb_rec, eye_rec)
        recording = True

    if not args.no_display:
        cv2.namedWindow("Aria RGB (world)", cv2.WINDOW_NORMAL)
        cv2.namedWindow("Aria Eye (pupil)", cv2.WINDOW_NORMAL)

    print("Streaming. Hotkeys: 'r' toggle recording, ESC/'q' quit.")
    last_report = time.time()
    start_wait = time.time()
    warned_no_frames = False
    try:
        while True:
            rgb, eye, rgb_n, eye_n, rgb_fps, eye_fps = observer.snapshot()

            if not args.no_display:
                if rgb is not None:
                    disp = rgb
                    if recording:
                        cv2.circle(disp, (28, 28), 12, (0, 0, 255), -1)  # REC dot
                    cv2.imshow("Aria RGB (world)", disp)
                if eye is not None:
                    cv2.imshow("Aria Eye (pupil)", eye)
                key = cv2.waitKey(1) & 0xFF
            else:
                time.sleep(0.05)
                key = 255

            if key in (27, ord("q")):
                break
            if key == ord("r"):
                if recording:
                    observer.set_recorders(None, None)
                    stop_recording(out_dir, rgb_rec, eye_rec)
                    recording = False
                else:
                    out_dir, rgb_rec, eye_rec = start_recording(args.outdir)
                    observer.set_recorders(rgb_rec, eye_rec)
                    recording = True

            if time.time() - last_report >= 2.0:
                print(f"[stream] rgb={rgb_n} ({rgb_fps:.1f} fps)  "
                      f"eye={eye_n} ({eye_fps:.1f} fps)  recording={recording}")
                last_report = time.time()

            # Watchdog: streaming started but no frames are being delivered.
            if (not warned_no_frames and rgb_n == 0 and eye_n == 0
                    and time.time() - start_wait > 6.0):
                warned_no_frames = True
                print("\n" + "=" * 70)
                print("NO FRAMES after 6 s, although streaming started. Most likely:")
                print("  1) The pairing request was not APPROVED in the Aria companion")
                print("     app. Re-run `aria auth pair` and TAP APPROVE on your phone.")
                print("  2) Stale certs — delete ~/.aria/streaming-certs/ephemeral and")
                print("     re-pair, or restart the glasses (hold power ~8 s) and retry.")
                print("  3) Wrong profile — try a different --profile "
                      "(profile5 carries RGB+EyeTrack).")
                print("Frames still 0 means the device isn't delivering decryptable data.")
                print("=" * 70 + "\n")
    except KeyboardInterrupt:
        pass
    finally:
        if recording:
            observer.set_recorders(None, None)
            stop_recording(out_dir, rgb_rec, eye_rec)
        if not args.no_display:
            cv2.destroyAllWindows()
        teardown(device_client, device, streaming_manager, streaming_client)
        print("Done.")


if __name__ == "__main__":
    sys.exit(main())
