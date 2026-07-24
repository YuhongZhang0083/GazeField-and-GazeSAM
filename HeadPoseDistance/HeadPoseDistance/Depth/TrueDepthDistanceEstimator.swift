import Foundation
import AVFoundation
import CoreVideo

/// Result of sampling the TrueDepth depth map over a central-face region of
/// interest (ROI).
///
/// The measured region: a square of (2r+1) x (2r+1) depth pixels centered on
/// the ARKit face-reference origin projected into the depth map. The face
/// reference origin sits approximately at the center of the head behind the
/// nose bridge, so its image projection lands on the nose / mid-face area.
/// The reported value is therefore "distance from the front camera to the
/// central face surface (nose region)".
struct DepthROIStatistics {
    /// Robust (median) surface distance over valid ROI pixels, in meters.
    /// Nil when no valid pixels were found.
    var medianMeters: Double?
    var validPixelCount: Int
    var totalPixelCount: Int
    var validRatio: Double {
        totalPixelCount > 0 ? Double(validPixelCount) / Double(totalPixelCount) : 0
    }
    /// ROI origin and size in depth-map pixel coordinates.
    var roiOriginX: Int
    var roiOriginY: Int
    var roiWidth: Int
    var roiHeight: Int
    /// Projected face-reference point in full-resolution captured-image pixels.
    var projectedImageX: Double
    var projectedImageY: Double
    var depthMapWidth: Int
    var depthMapHeight: Int
    var pixelFormatDescription: String
    /// True when the ROI median agrees with the ARKit head-reference forward
    /// depth within the configured tolerance. False means the projection may
    /// have missed the face; the value must not be trusted.
    var consistentWithHeadReference: Bool?
}

/// Reads per-pixel TrueDepth data (ARFrame.capturedDepthData) and produces a
/// robust central-face surface distance.
///
/// Coordinate-mapping assumptions (flagged for physical verification):
/// 1. The projected point supplied by the caller is in captured-image pixel
///    coordinates (sensor-native landscape orientation, origin top-left),
///    as returned by `ARCamera.projectPoint(_:orientation:viewportSize:)`
///    with `.landscapeRight` and viewport = `camera.imageResolution`.
/// 2. The depth map is aligned with the captured image and differs only by
///    resolution, so image coordinates scale linearly into depth-map
///    coordinates.
/// If these assumptions fail on a device, the consistency check against the
/// ARKit forward depth rejects the value instead of fabricating a distance.
enum TrueDepthDistanceEstimator {

    /// Pure valid-value filter, unit-testable without a device.
    /// Rejects NaN, infinity, zero, negatives, and values outside
    /// [minValidDistanceMeters, maxValidDistanceMeters].
    static func filterValidDepthValues(_ values: [Float],
                                       minMeters: Double,
                                       maxMeters: Double) -> [Double] {
        values.compactMap { v in
            guard v.isFinite, v > 0 else { return nil }
            let d = Double(v)
            guard d >= minMeters, d <= maxMeters else { return nil }
            return d
        }
    }

    /// Robust aggregation of valid ROI depth values (trimmed median).
    static func robustDepth(_ validValues: [Double]) -> Double? {
        Statistics.trimmedMedian(validValues, trimFraction: 0.1)
    }

    /// Samples the depth map around the projected face point.
    ///
    /// - Parameters:
    ///   - depthData: `ARFrame.capturedDepthData`.
    ///   - projectedImagePoint: face-reference point in captured-image pixels.
    ///   - imageResolution: `camera.imageResolution` (full captured image).
    ///   - headReferenceForwardDepth: |z| of the camera-relative face
    ///     translation, used for the consistency check.
    ///   - config: thresholds and ROI size.
    /// - Returns: nil when the depth map cannot be read or the projection is
    ///   outside the map (surface distance is then reported as unavailable).
    static func sampleFaceRegion(depthData: AVDepthData,
                                 projectedImagePoint: CGPoint,
                                 imageResolution: CGSize,
                                 headReferenceForwardDepth: Double?,
                                 config: MeasurementConfig) -> DepthROIStatistics? {
        // Convert to 32-bit float metric depth if needed.
        let floatDepth: AVDepthData
        if depthData.depthDataType == kCVPixelFormatType_DepthFloat32 {
            floatDepth = depthData
        } else {
            floatDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }

        let map = floatDepth.depthDataMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0,
              imageResolution.width > 0, imageResolution.height > 0 else { return nil }

        let px = Double(projectedImagePoint.x)
        let py = Double(projectedImagePoint.y)
        guard px.isFinite, py.isFinite else { return nil }

        // Scale image pixels -> depth-map pixels (assumption 2 above).
        let dx = px * Double(width) / Double(imageResolution.width)
        let dy = py * Double(height) / Double(imageResolution.height)
        let cx = Int(dx.rounded())
        let cy = Int(dy.rounded())
        guard cx >= 0, cx < width, cy >= 0, cy < height else { return nil }

        let r = max(1, config.depthROIRadiusPixels)
        let x0 = max(0, cx - r)
        let x1 = min(width - 1, cx + r)
        let y0 = max(0, cy - r)
        let y1 = min(height - 1, cy + r)

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

        var rawValues: [Float] = []
        rawValues.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for yy in y0...y1 {
            let row = base.advanced(by: yy * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for xx in x0...x1 {
                rawValues.append(row[xx])
            }
        }

        let valid = filterValidDepthValues(rawValues,
                                           minMeters: config.minValidDistanceMeters,
                                           maxMeters: config.maxValidDistanceMeters)
        let median = robustDepth(valid)

        var consistent: Bool?
        if let median, let forward = headReferenceForwardDepth {
            consistent = abs(median - forward) <= config.depthConsistencyToleranceMeters
        }

        let formatDescription = "DepthFloat32 (\(width)x\(height))"

        return DepthROIStatistics(medianMeters: median,
                                  validPixelCount: valid.count,
                                  totalPixelCount: rawValues.count,
                                  roiOriginX: x0,
                                  roiOriginY: y0,
                                  roiWidth: x1 - x0 + 1,
                                  roiHeight: y1 - y0 + 1,
                                  projectedImageX: px,
                                  projectedImageY: py,
                                  depthMapWidth: width,
                                  depthMapHeight: height,
                                  pixelFormatDescription: formatDescription,
                                  consistentWithHeadReference: consistent)
    }
}
