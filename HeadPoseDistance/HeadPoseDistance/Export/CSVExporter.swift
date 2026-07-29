import Foundation

/// Writes samples as CSV — one row per sample. The clean export contains
/// accepted samples only; the debug export appends rejected samples too.
/// Transform matrices are exported in the JSON document only (48 extra
/// columns would make the CSV unwieldy); all scalar fields are included here.
enum CSVExporter {

    static let header: [String] = [
        "timestamp_unix",
        "ar_frame_timestamp",
        "session_elapsed_s",
        "protocol_phase",
        "translation_x_m",
        "translation_y_m",
        "translation_z_m",
        "forward_depth_m",
        "head_reference_distance_m",
        "truedepth_surface_raw_m",
        "truedepth_surface_median_filtered_m",
        "truedepth_surface_ema_filtered_m",
        "estimated_screen_to_face_m",
        "distance_deviation_from_baseline_m",
        "quaternion_x",
        "quaternion_y",
        "quaternion_z",
        "quaternion_w",
        "raw_yaw_deg",
        "raw_pitch_deg",
        "raw_roll_deg",
        "relative_yaw_deg",
        "relative_pitch_deg",
        "relative_roll_deg",
        "head_angular_velocity_deg_per_s",
        "phone_rotation_rate_rad_per_s",
        "phone_acceleration_g",
        "phone_attitude_change_deg",
        "truedepth_valid_pixel_count",
        "truedepth_valid_pixel_ratio",
        "tracking_valid",
        "phone_stable",
        "distance_stable",
        "sample_valid",
        "confidence",
        "rejection_reasons",
        // Coverage columns, appended so existing parsers that index the
        // original 36 columns keep working. Empty in eight-spoke mode.
        "coverage_fraction",
        "coverage_cell_column",
        "coverage_cell_row"
    ]

    /// Locale-independent numeric formatting ("." decimal separator).
    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }

    static func format(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    static func format(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    static func row(for s: MeasurementSample) -> [String] {
        [
            format(s.timestampUnix),
            format(s.arFrameTimestamp),
            format(s.sessionElapsedSeconds),
            s.protocolPhase,
            format(s.translationX),
            format(s.translationY),
            format(s.translationZ),
            format(s.forwardDepthMeters),
            format(s.headReferenceDistanceMeters),
            format(s.trueDepthSurfaceRawMeters),
            format(s.trueDepthSurfaceMedianFilteredMeters),
            format(s.trueDepthSurfaceEMAFilteredMeters),
            format(s.estimatedScreenToFaceMeters),
            format(s.distanceDeviationFromBaselineMeters),
            format(s.quaternionX),
            format(s.quaternionY),
            format(s.quaternionZ),
            format(s.quaternionW),
            format(s.rawYawDegrees),
            format(s.rawPitchDegrees),
            format(s.rawRollDegrees),
            format(s.relativeYawDegrees),
            format(s.relativePitchDegrees),
            format(s.relativeRollDegrees),
            format(s.headAngularVelocityDegPerSec),
            format(s.phoneRotationRateMagnitudeRadPerSec),
            format(s.phoneAccelerationMagnitudeG),
            format(s.phoneAttitudeChangeDegrees),
            format(s.trueDepthValidPixelCount),
            format(s.trueDepthValidPixelRatio),
            format(s.trackingValid),
            format(s.phoneStable),
            format(s.distanceStable),
            format(s.sampleValid),
            format(s.confidence),
            s.rejectionReasons.joined(separator: ";"),
            format(s.coverageFraction),
            format(s.coverageCellColumn),
            format(s.coverageCellRow)
        ]
    }

    static func csvString(samples: [MeasurementSample]) -> String {
        var lines = [header.joined(separator: ",")]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples {
            lines.append(row(for: sample).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the CSV to a file and returns its URL.
    static func write(samples: [MeasurementSample],
                      to directory: URL,
                      filename: String) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try csvString(samples: samples).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
