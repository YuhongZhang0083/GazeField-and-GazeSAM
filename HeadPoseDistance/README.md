# HeadPoseDistance — Phase 1

A native iPhone experimental measurement tool that:

1. Measures the user's face/head distance from the iPhone (TrueDepth + ARKit).
2. Estimates real-time head orientation (yaw, pitch, roll).
3. Displays **one fixed red fixation dot** at the exact center of the screen.
4. Records head movement while the user continuously looks at the center dot.
5. Guides the user through 8 directional head movements (up, down, left,
   right, and the four diagonals) — instructions only, never extra targets.
6. Exports the recorded distance and head-pose data as CSV and JSON.

**Phase 1 deliberately contains no eye-gaze estimation of any kind** — no
pupil/iris segmentation, no gaze rays, no gaze calibration, no gaze maps or
heat maps, no `leftEyeTransform`/`rightEyeTransform` analysis, no ML models,
and no network communication. All processing happens on-device.

---

## Requirements

- Xcode 16 or later (project uses the Xcode 16 file-system-synchronized
  project format).
- iOS 17.0+ deployment target.
- **A physical iPhone with a front TrueDepth camera** (Face ID models).
  The project compiles for the iOS Simulator, but AR face tracking and
  TrueDepth measurement require a compatible physical iPhone; the app shows a
  clear message when face tracking is unsupported.
- Portrait orientation only, iPhone only.

## Project layout

```
HeadPoseDistance/
├── HeadPoseDistance.xcodeproj          ← open this in Xcode
├── HeadPoseDistance/                   ← app sources
│   ├── HeadPoseDistanceApp.swift       ← @main entry
│   ├── AppState.swift                  ← app/measurement stage enums
│   ├── Configuration/MeasurementConfig.swift   ← ALL thresholds/parameters
│   ├── Support/    (MathSupport, Statistics, DeviceInfo)
│   ├── AR/ARFaceTrackingManager.swift  ← owns ARSession, delegate
│   ├── Geometry/   (FaceTransformCalculator, HeadPoseEstimator)
│   ├── Depth/      (TrueDepthDistanceEstimator, ScreenDistanceCalibrator)
│   ├── Filtering/DistanceFilter.swift  ← median + EMA filters
│   ├── Calibration/NeutralPoseCalibrator.swift
│   ├── Motion/DeviceMotionMonitor.swift ← Core Motion phone stability
│   ├── Validation/SampleValidator.swift
│   ├── Protocol/   (GuidanceTypes ← shared state/transition/IO + RecordingMode,
│   │                GuidedMovementController ← 8-spoke state machine,
│   │                CoverageGrid ← (yaw, pitch) field coverage tracking,
│   │                FreeExplorationController ← coverage-driven state machine,
│   │                HeadDirectionTarget, FaceAlignmentEvaluator,
│   │                RecordingProtocolController ← phase vocabulary)
│   ├── Visualization/ (VirtualHeadView ← generic 3D head, VirtualHeadOrientation)
│   ├── Preview/    (CameraPreviewRenderer — debug view only, off by default)
│   ├── Recording/SessionRecorder.swift
│   ├── Models/     (MeasurementSample, SessionMetadata, SessionSummary)
│   ├── Export/     (CSVExporter, JSONExporter)
│   ├── Pipeline/   (MeasurementPipeline, MeasurementSnapshot)
│   ├── ViewModels/MeasurementViewModel.swift
│   └── Views/      (ContentView, DeviceCheck, Instructions, Measurement,
│                    Results, Debug, CalibrationSheet)
└── HeadPoseDistanceTests/              ← XCTest unit tests (no device needed)
```

---

## Beginner guide: open, sign, and run on your iPhone

You do not need prior iOS development experience.

1. **Open the project.** Double-click `HeadPoseDistance.xcodeproj`, or in
   Xcode choose *File → Open…* and select that file.
2. **Select the app target.** In the left sidebar click the blue
   *HeadPoseDistance* project icon, then under *TARGETS* click
   *HeadPoseDistance*.
3. **Open Signing & Capabilities.** Click the *Signing & Capabilities* tab at
   the top of the editor.
4. **Enable automatic signing.** Check *Automatically manage signing*.
5. **Select a Personal Team.** In the *Team* dropdown pick your Apple ID team
   (e.g. "Your Name (Personal Team)"). If none exists: *Xcode → Settings →
   Accounts → "+" → Apple ID*, sign in, then return here.
6. **Change the bundle identifier.** Replace
   `com.example.HeadPoseDistance` with something unique to you, e.g.
   `com.yourname.HeadPoseDistance`. (Free personal teams require a unique ID.)
7. **Connect your iPhone with a cable.** Unlock the phone.
8. **Trust the Mac on the iPhone.** If the phone asks "Trust This Computer?",
   tap *Trust* and enter your passcode.
9. **Enable Developer Mode on the iPhone** (iOS 16+): *Settings → Privacy &
   Security → Developer Mode → On*, then restart the phone and confirm.
10. **Select the iPhone as the run destination.** In Xcode's toolbar device
    menu (next to the scheme name *HeadPoseDistance*), pick your physical
    iPhone (not a simulator).
11. **Press ⌘R** (or the ▶ button). The first run may pause with an
    "Untrusted Developer" message on the phone — fix via *Settings → General →
    VPN & Device Management → your Apple ID → Trust*.
12. **Allow camera permission** when the app asks. The app uses the front
    TrueDepth camera only to measure face distance and head orientation.
13. **Find exported data.** After a recording, tap *Generate CSV + JSON* on
    the results screen, then use the share buttons to AirDrop, save to Files,
    or email the `.csv` / `.json` files. Files are also written to the app's
    temporary directory and shared via the standard iOS share sheet.

### Command-line build (optional)

```bash
# Compile check without signing (simulator):
xcodebuild -project HeadPoseDistance.xcodeproj -scheme HeadPoseDistance \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# Compile check against the device SDK:
xcodebuild -project HeadPoseDistance.xcodeproj -scheme HeadPoseDistance \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# Unit tests (simulator; no TrueDepth hardware needed):
xcodebuild -project HeadPoseDistance.xcodeproj -scheme HeadPoseDistance \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

---

## How a session works

1. **Device Check** — verifies `ARFaceTrackingConfiguration.isSupported` and
   camera permission. Unsupported devices see:
   *"This device does not support the required TrueDepth face tracking."*
2. **Instructions** — stand/stationary-phone/30–60 cm/look-at-dot guidance,
   then *Begin Measurement*.
3. **Live Measurement** — the red center dot appears with live values.
4. **Neutral Capture** — *Capture Neutral Pose*: ~2 s of samples while the
   head is still; robust (quaternion-aware) aggregation; rejected if the
   head/phone moved or distance drifted.
5. **Head-Movement Recording** — pick a protocol with the segmented control,
   then *Start … Recording*. Both are **pose-driven**: progress is earned by
   the measured pose, never by a timer.
   - **Free Explore** (default) — move the head freely until a coverage grid
     over the (yaw, pitch) field is filled. This is the protocol the gaze-field
     fit needs; see "Free-exploration protocol" below.
   - **8-Spoke** — the original sequence
     (center → up → center → down → … → lower-right → complete). Sparse in
     the interior, so it is kept as a **validation / comparison** set rather
     than as training data.

   Pause/Resume/Stop/Restart available in both. The dot never moves; all
   guidance sits in a fixed ring around it.
6. **Session Results** — summary statistics and lightweight native traces
   (distance, yaw, pitch, roll over time).
7. **Data Export** — CSV (accepted samples; optional debug CSV including
   rejected samples) and JSON (metadata + configuration + neutral calibration
   + summary + samples) via the share sheet.
8. **Debug View** (wrench icon) — raw transforms, quaternions, depth-map
   internals, ROI, Core Motion values, validity decision, and an optional
   front-camera preview (never saved).

## Free-exploration protocol (default)

### Why the eight spokes were not enough

The eight-spoke protocol returns to neutral between every direction, so
roughly 40–50% of its samples land in one blob at (0, 0), and the eight
targets are reached along eight radial lines with nothing in between.

That is invisible in the final heatmap, which is what makes it dangerous.
`adaptive_kernel_convolution_heatmaps.py` masks to the **convex hull** of the
samples — the octagon through the eight tips — and inflates its kernel where
density is low (`--sigma-min 3` → `--sigma-max 22`). In the empty wedges the
kernel pins to 22°, so those regions get filled with a near-global average and
render as a smooth, confident field where nothing was measured. The
`--center-density-penalty` flag already in that script exists to patch the
other half of the same problem.

It also hurts the fit, not just the picture: the polynomial and manifold gaze
models have `yaw·pitch` cross terms, but on the four axis spokes one of the two
is ~0, and on the four diagonals `|yaw| = |pitch|`. The entire interaction
structure ends up estimated from four collinear directions.

### Measure coverage, don't prescribe a path

The first attempt at a fix was a guided spiral: an Archimedean path traversed
at constant tangential speed, which gives uniform areal density *if followed
accurately*. It was removed. Asking someone to match the orientation of a
translucent 3D head — in peripheral vision, while holding fixation — turned out
to be an interface people could not read, and no amount of rewording fixed it.

Measuring coverage directly is both easier to perform and a **stronger
guarantee**. A path gives uniform density only when tracked well; the grid
requires every cell in the field to hold at least `coverageSamplesPerCell`
usable samples before the session can finish. There is nothing to match, aim
at, or interpret: the participant moves, and the grid says what is missing.

### The task

> Keep your eyes on the red dot. Slowly circle your nose around it, making each
> circle a little wider. Keep going until the grid is full.

That is the whole protocol. No target, no pacing, no fixed order.

### The grid

`CoverageGrid` bins neutral-relative (yaw, pitch) into a 7 × 5 grid over an
elliptical field — 22° yaw × 16° pitch. The field is elliptical because
comfortable eye-in-head range is narrower vertically, so a symmetric field
would lose fixation at the top and bottom; the four corner cells fall outside
the ellipse, leaving **31 required cells** with centres ~6° apart in yaw, fine
enough for the heatmap kernel to interpolate between them.

- A cell needs `coverageSamplesPerCell` (12, ≈0.2 s at 60 Hz) samples before it
  counts. That dwell requirement stops a fast swing through a cell from
  claiming it on one or two frames.
- Samples only count while the protocol is unpaused (face tracked, phone still,
  distance and lateral position inside their bands) **and** head speed is below
  `guidedMaxAngularVelocityDegPerSec`. Rushing therefore makes the grid fill
  more slowly, not faster.
- Poses slightly past full amplitude are clamped into the edge cell; poses far
  outside are ignored, so the coverage claim stays honest.
- Cells outside the ellipse are never required but are still counted — extra
  data is never discarded.
- The session ends at `coverageCompletionFraction` (0.92), not 1.0: the most
  extreme cells are unreachable for some people and demanding all of them would
  stall indefinitely. Stopping early is safe — coverage is exported per sample.

`CoverageGridTests` pins the behaviour that matters, including two negative
tests that encode the original problem: centre-only movement leaves coverage
below 5%, and a dense eight-spoke pattern cannot reach the completion
threshold, because the wedges stay empty.

### Reading the grid without breaking fixation

The grid sits at the bottom of the screen, far from the dot, and squares fill
green as they are visited with a thin white outline marking where the head is
now — so it reads as a map, not an abstract meter.

Glancing at it does break fixation, which matters because every sample's value
depends on the eyes being on the dot. Two mitigations: a **haptic tick fires
each time a square completes**, so progress can be felt without looking at all;
and the caption retires after `explorationInstructionSeconds` rather than
standing next to the fixation target. Residual contamination is episodic rather
than systematic, and once Aria eye frames are aligned a glance to the bottom of
the screen is a large, obvious pupil excursion that can be dropped offline.

### Export

Free-exploration sessions add three columns, appended after the original 36 so
existing parsers keep working (empty in eight-spoke mode):

| Column | Meaning |
|---|---|
| `coverage_fraction` | fraction of the required field covered at this sample |
| `coverage_cell_column` | which cell the pose fell in (empty if outside the field) |
| `coverage_cell_row` | " |

The per-sample cell lets the offline pipeline **recompute coverage
independently** instead of trusting the app's own count.
`SessionMetadata.recordingMode` (`free_exploration` / `eight_spoke`) makes every
export self-describing.

## Guided protocol: pose-driven state machine

Stage progression is controlled by `GuidedMovementController`, a pure,
unit-tested state machine. **No stage ever advances because a timer expired**
— every transition is caused by the measured neutral-relative pose, and every
transition is recorded (with its reason) and exported in the session JSON as
`stageTransitions`.

Per directional stage (up, down, left, right, and the four diagonals):

    instructingDirection ──movement started──▶ movingTowardTarget
    movingTowardTarget ──target angle reached──▶ holdingTargetPose
    holdingTargetPose ──left the zone──▶ movingTowardTarget      (hold resets)
    holdingTargetPose ──held targetHoldSeconds──▶ returningToNeutral
    returningToNeutral ──within centerTolerance──▶ holdingNeutral
    holdingNeutral ──held neutralHoldSeconds──▶ next stage / complete

plus automatic pause states that suspend progression (and demote any
in-progress hold, so paused time never counts as held time):

| Pause | Trigger | Resume |
|---|---|---|
| `pausedForTracking` | face not tracked | face tracked again |
| `pausedForPhoneMotion` | excessive phone motion | motion subsides |
| `pausedForDistance` | face out of the fixed bounds: \|distance deviation\| > `guidedDistanceBandMeters`, or lateral drift beyond `lateralOffsetToleranceMeters`, for `distancePauseEnterSeconds` | back inside (`guidedDistanceExitBandMeters` + within lateral bound) for `distancePauseExitSeconds` (hysteresis — no flicker) |

**Holding the neutral position.** At neutral capture the app fixes the
baseline: the **head-reference distance** (head-centre origin, which is stable
under head rotation — unlike the TrueDepth surface distance, which swings as
the nose moves) and the neutral **face position** (camera-space x/y). During
the turning phase every sample is checked against those fixed bounds:

- **Distance** — deviation from the neutral head-reference distance beyond
  `distanceDeviationRejectMeters` (4 cm) rejects the sample and, at the same
  band, pauses progression with "move closer / move farther". A softer warn
  band (~2 cm) down-weights confidence without rejecting.
- **Lateral / vertical** — displacement of the face from its neutral position
  beyond `lateralDeviationRejectMeters` (5 cm) rejects the sample and pauses
  with "move left / right / up / down". The bounds are anchored to the neutral
  face position, so a participant who naturally sits off the camera axis is
  still "centred".

So a stage can only complete while the face is held at the neutral distance
and position; drift is corrected and the drifted samples are discarded.

Corrective feedback (non-blocking): wrong direction, moving too fast
(`guidedMaxAngularVelocityDegPerSec`), off-axis drift. A generous per-stage
timeout (`stageTimeoutSeconds`, default 30 s) is a **failure/retry** path
only: it records a `stage_timeout` transition and restarts the stage — it
never auto-completes anything.

Key thresholds (all in `MeasurementConfig`): `targetAngleDegrees` 20°,
`targetHoldSeconds` 1.2 s, `neutralHoldSeconds` 0.8 s,
`centerToleranceDegrees` 5°, `maxOffAxisDegrees` 12°,
`wrongDirectionThresholdDegrees` 8°, `guidedDistanceBandMeters` 4 cm,
`lateralOffsetToleranceMeters` 5 cm.

## Dot-anchored guidance (no camera video)

The normal measurement workflow shows **no live camera image** — the optional
camera preview lives only in the developer debug view (wrench icon) and is
disabled by default. The fixation dot is anchored in the **upper third of the
screen** (`dotAnchorYFraction`, default 0.30), close to the TrueDepth camera:
fixating there keeps the gaze line near the camera axis (better tracking, no
downward eye posture) and the dot's true position is recorded in the session
metadata. Everything is **concentric with that dot**, back to front:

1. Black background.
2. **Virtual head + head-position boundary**, centered on the dot
   (`CenteredHeadBoundary`). A generic procedurally-built 3D head (SceneKit
   ellipsoid skull + nose and ear hints — no ARKit face geometry, no camera
   texture, nothing identifying, nothing persisted)
   rotates in real time with the neutral-relative yaw/pitch/roll
   (`VirtualHeadOrientation`, mirror semantics), shifts with the measured
   lateral face offset, scales with distance deviation, and fades to a ghost
   state when tracking is lost. A **fixed dashed oval** hugs it (head fills
   ~77% of its frame at the neutral distance): keep the head inside the oval
   at the right size and it turns green. Because the head sits *directly under
   the dot*, the participant fixates the dot and their head representation is
   right there — it is NOT parked elsewhere on the screen (an earlier layout
   put it at the top, which pulled gaze upward and biased the neutral pitch
   baseline). Dimmed during recording so the dot dominates.
3. **Center guidance ring**, arranged AROUND the dot/oval so the participant
   never shifts gaze: a hold-progress ring encircling the oval, one
   directional arrow at a fixed radial position (head-movement direction,
   never gaze direction; four inward chevrons for return-to-center), and one
   short instruction line just below ("Slowly turn your head left", "Hold",
   "Return to center", "Move more slowly", "Phone moved — hold it still").
   The alignment cue ("Move closer / farther / left / right / up / down")
   sits just above the oval. Every element has a fixed position; only colour,
   text, and ring fill change.
4. **The single fixed red dot**, topmost, overlaid on the head's center at the
   upper-third anchor. Its position depends only on screen geometry — never
   on guidance state.
5. **Bottom bar** (far from the dot): 8-arrow completion checklist,
   `Stage n of 8`, elapsed time, accepted/rejected counts, controls. The dense
   numeric readout panel appears only during pre-recording setup.

Haptics: a light tap when the head first enters the target zone (hold
started), a success buzz when a stage genuinely completes — feedback that
needs no glance away from the dot.

## Distance definitions (displayed separately, never merged)

| Value | Meaning |
|---|---|
| **Head reference distance** | `‖translation(cameraFromFace)‖` — camera optical center to the ARKit face reference origin (inside the head, near the nose bridge). NOT the skin surface. |
| **Forward depth** | `abs(z)` of the same translation — depth along the camera's optical axis. |
| **TrueDepth face-surface distance** | Robust (trimmed-median) depth over a configurable ROI of `ARFrame.capturedDepthData`, centered on the projected face-reference point (central face / nose area). Valid pixels are finite, positive, and inside the configured 0.15–1.0 m range; the count and ratio of valid pixels are recorded. |
| **Estimated screen-to-face distance** | `surface − cameraBehindScreenOffset`. Offset defaults to 0 → labeled *"Estimated screen distance — uncalibrated"*. After the optional one-point ruler calibration (ruler icon) it is labeled *"Estimated screen-to-face distance — calibrated offset"*. |

Raw values are never overwritten; the median-filter (window 5) and EMA
(α = 0.2) outputs are separate named fields.

## Head-pose conventions

- Orientation is carried internally as quaternions / rotation matrices; Euler
  angles are presentation-only. Neutral-relative rotation is computed by
  rotation composition: `relative = inverse(neutralRotation) * currentRotation`
  (never by subtracting Euler angles).
- Euler decomposition: `R = Ry(yaw) · Rx(pitch) · Rz(roll)` (intrinsic
  yaw → pitch → roll), degrees, wrapped to [−180°, 180°).
- **User-facing sign convention**: +yaw = head turns toward the user's RIGHT;
  +pitch = head rotates UP; +roll = head tilts toward the RIGHT shoulder.
- Raw SDK-derived angles and user-convention angles are kept as two separate
  sets; the sign mapping lives only in `HeadPoseConvention`
  (`Geometry/HeadPoseEstimator.swift`).

## Physical-device validation checklist

Run on a Face ID iPhone and verify:

1. [ ] App launches on a compatible iPhone.
2. [ ] Camera permission prompt appears with the expected text.
3. [ ] The center red dot does not move — through neutral capture and the
       entire recording.
4. [ ] Face tracking becomes valid ("Face Tracked" chip turns green).
5. [ ] Head reference distance changes when moving closer/farther.
6. [ ] TrueDepth surface distance is available (Debug view: depth map
       dimensions non-zero, valid-pixel count high, "Consistent w/ head ref: yes").
7. [ ] Holding still produces reasonably stable readings (< ~1 cm jitter).
8. [ ] Turning the head right changes relative yaw consistently (expected: positive).
9. [ ] Turning left produces the opposite yaw sign.
10. [ ] Looking up changes relative pitch consistently (expected: positive).
11. [ ] Looking down produces the opposite pitch sign.
12. [ ] Tilting the head toward a shoulder changes relative roll
        (expected: + toward right shoulder).
13. [ ] Returning to neutral brings relative yaw/pitch/roll near 0°.
14. [ ] Moving the phone triggers the phone-motion warning and marks samples.
15. [ ] CSV and JSON exports open correctly (Numbers/Excel; any JSON viewer).

**Important:** the yaw/pitch/roll *sign conventions* (items 8–12) rest on the
documented assumption about ARKit's face-anchor axis directions and MUST be
verified on a physical device. If a sign is inverted, flip the corresponding
multiplier in `HeadPoseConvention` (one isolated place) — nothing else.

## Assumptions that must be verified on hardware

1. **Face-anchor axes** — assumed +X out the face's right side, +Y up, +Z out
   the nose (right-handed). Drives the default sign multipliers
   (yaw +1, pitch −1, roll −1).
2. **Depth-map ↔ image mapping** — the projected face point (via
   `ARCamera.projectPoint(_:orientation:.landscapeRight:viewportSize:)` with
   the full `imageResolution`) is assumed to scale linearly into depth-map
   pixels (aligned, lower resolution). A per-frame consistency check against
   the ARKit forward depth (±10 cm, configurable) rejects the surface value
   rather than fabricating one if this mapping is wrong.
3. **Debug preview orientation** — the preview rotates the captured image 90°
   CW for portrait; it is a debug convenience and may appear mirrored.
4. **`capturedDepthData` cadence** — TrueDepth frames arrive at a lower rate
   (~15 Hz) than ARKit frames (~60 Hz); samples without fresh depth carry
   `truedepth_unavailable` and reduced confidence, by design.

## Known accuracy limitations

- The head-reference distance measures to ARKit's face origin *inside* the
  head — expect it to read a few cm longer than a ruler-to-nose measurement.
- TrueDepth absolute depth accuracy is typically around ±1 cm in the
  30–60 cm range but varies with lighting, angle, and device.
- The screen-to-face estimate is only as good as the one-point offset
  calibration; uncalibrated values are camera-relative, not screen-relative.
- During large head rotations the depth ROI may partially leave the face;
  the valid-pixel ratio and the consistency check are recorded per sample so
  such frames can be filtered in analysis.
- Phone-motion gating uses configurable thresholds
  (`MeasurementConfig`); small hand tremor is tolerated ("minor"), so a
  tripod/stand is recommended for best data.

## Privacy

- All processing is on-device. Nothing is transmitted.
- No RGB/IR images, depth-map images, face meshes, or biometric templates are
  ever saved or exported — only the numerical measurements listed in
  `MeasurementSample` plus anonymous session metadata (UUID, device model,
  iOS version, screen geometry, configuration).

## Unit tests

`HeadPoseDistanceTests` covers: matrix inversion/composition, camera-relative
face transform, translation extraction, Euclidean distance, screen-offset
arithmetic, quaternion normalization, relative quaternions, known
yaw/pitch/roll rotations, Euler extraction, angle wrapping, quaternion angular
difference, median filter, EMA, neutral-pose aggregation (incl. quaternion
sign-flip handling), valid depth-value filtering, robust ROI aggregation,
sample validation, confidence scoring, CSV formatting, JSON round-trip,
head-direction target geometry (unit vectors, axis projection, off-axis
rejection, center tolerance), and camera-preview geometry (portrait rotation,
selfie mirroring, aspect-fill). None of the tests require TrueDepth hardware;
run them with **⌘U** or the `xcodebuild … test` command above.

New in the guided-protocol update: `GuidedMovementControllerTests` (no
time-based advancement, direction/diagonal detection, wrong-direction and
too-fast feedback, hold requirement, return-to-neutral requirement,
tracking/distance/phone-motion pauses, distance hysteresis, transition
reasons, retry-on-timeout, completion only after all eight stages, sample
phase labeling), `VirtualHeadOrientationTests` (mirror-convention mapping),
and `FaceAlignmentTests` (distance band, lateral cues, cue priority,
stage-transition JSON round-trip).

New in the free-exploration update:

- `CoverageGridTests` — required-cell count over the elliptical field, cell
  mapping orientation (yaw right, pitch up), rejection of poses outside the
  field, overshoot clamping, the dwell requirement, completion reported exactly
  once per cell, non-required cells counted but never reported, and the two
  negative tests that encode the original problem: **centre-only movement stays
  below 5% coverage**, and **a dense eight-spoke pattern cannot reach the
  completion threshold**.
- `FreeExplorationControllerTests` — a stationary head never completes however
  long it runs, fast movement accrues no coverage (with the too-fast cue so the
  participant knows why), current-cell reporting, full coverage → return →
  complete, tracking/phone-motion/distance/lateral pauses, `explore` labelling
  of paused samples, large timestamp gaps not fabricating coverage, and the
  caption rules (names a body part, never says "follow" or "outline", retires
  after its window).

Current status: **158 tests, all passing** (Xcode 26.6, iOS 26.5 simulator).
