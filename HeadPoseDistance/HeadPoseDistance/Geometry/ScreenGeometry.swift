import Foundation
import CoreGraphics

/// Where the face *should* sit, in the user's frame, expressed as an offset
/// from the TrueDepth camera's optical axis.
struct ExpectedFaceOffset: Equatable {
    /// + = the user's right.
    var userRightMeters: Double
    /// + = up.
    var userUpMeters: Double

    static let zero = ExpectedFaceOffset(userRightMeters: 0, userUpMeters: 0)
}

/// Physical screen geometry, used to convert the on-screen fixation dot into a
/// real-world offset from the camera axis.
///
/// ## Why this exists
///
/// The fixation dot is deliberately **not** at the camera: it sits at
/// `dotAnchorYFraction` (0.26) of the screen height, a few centimetres below
/// the TrueDepth camera. A participant whose eye is correctly on the dot's
/// normal axis is therefore *below the camera axis by that same distance*.
///
/// Before this type existed, `FaceAlignmentEvaluator` measured setup alignment
/// from the camera axis, so a correctly positioned participant read as several
/// centimetres too low and was told to "Move up" — pushing them onto the camera
/// axis, where the gaze to the dot is angled downward. That defeats the point of
/// the neutral pose, which is supposed to be a *straight-ahead* gaze.
///
/// ## Accuracy
///
/// Two inputs are approximations: points-per-inch (derived from the display
/// scale rather than a per-model table) and the camera's position within the
/// display. Both are small compared with the quantity being corrected:
///
/// - dot-to-camera distance is ~230 pt ≈ 3.8 cm;
/// - points-per-inch is within ~4% across all Face ID iPhones at a given scale;
/// - camera position is uncertain by ~±10 pt ≈ ±1.6 mm (~4%).
///
/// So the correction is accurate to a few millimetres against a
/// `lateralOffsetToleranceMeters` of 5 cm — comfortably good enough, and vastly
/// better than the 0 it replaces.
struct ScreenGeometry: Equatable {

    /// Usable display width in points.
    var widthPoints: Double
    /// Display scale (2 or 3 on current iPhones).
    var scale: Double
    /// Fixation-dot centre in GLOBAL display points (y measured from the top of
    /// the display, not the safe area).
    var dotCenterGlobal: CGPoint
    /// Vertical position of the TrueDepth camera centre in the same global
    /// point coordinates.
    var cameraCenterYPoints: Double
    /// Horizontal offset of the camera from the screen centreline, in points;
    /// positive = right of centre.
    ///
    /// The camera is **not** on the phone's centreline. Inside the notch /
    /// Dynamic Island the Face ID sensors and the front camera sit side by side,
    /// and ARKit's face anchor is expressed in the *front camera's* frame — so a
    /// face centred on the screen reads as offset toward the opposite side.
    var cameraCenterXOffsetPoints: Double = 0

    /// Points per inch for a display of this scale.
    ///
    /// Face ID iPhones are ~460 ppi at @3x (÷3 ≈ 153 pt/in) and ~326 ppi at @2x
    /// (÷2 = 163 pt/in). Individual models vary by a few percent (the 12 mini is
    /// 476 ppi → 159 pt/in); at the millimetre scale this correction operates on,
    /// that spread does not matter, so no per-model table is kept.
    static func pointsPerInch(scale: Double) -> Double {
        scale >= 2.5 ? 153.3 : 163.0
    }

    private static let inchesPerMeter = 39.3700787

    var pointsPerMeter: Double {
        Self.pointsPerInch(scale: scale) * Self.inchesPerMeter
    }

    /// Horizontal camera position: the screen centreline plus the module's
    /// off-centre offset.
    var cameraCenterXPoints: Double { widthPoints / 2 + cameraCenterXOffsetPoints }

    /// Offset from the camera axis at which a face is on the dot's normal axis,
    /// i.e. looking straight ahead at the dot.
    ///
    /// The dot is below the camera, so the expected vertical offset is
    /// **negative** (the face sits lower than the camera axis). Horizontally the
    /// dot is centred but the camera is not, so the expected offset is the
    /// negative of the camera's own off-centre offset.
    var expectedFaceOffset: ExpectedFaceOffset {
        guard scale > 0, widthPoints > 0, pointsPerMeter > 0,
              dotCenterGlobal.x.isFinite, dotCenterGlobal.y.isFinite else {
            return .zero
        }
        // Screen-right as the user sees it is the user's right, since they are
        // facing the screen.
        let rightPoints = Double(dotCenterGlobal.x) - cameraCenterXPoints
        // UIKit y grows downward, so a dot below the camera is a positive delta;
        // "up" is the negative of that.
        let downPoints = Double(dotCenterGlobal.y) - cameraCenterYPoints
        return ExpectedFaceOffset(userRightMeters: rightPoints / pointsPerMeter,
                                  userUpMeters: -downPoints / pointsPerMeter)
    }
}
