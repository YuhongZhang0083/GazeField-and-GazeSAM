import Foundation

/// Complete JSON export: session metadata, configuration, neutral
/// calibration, summary statistics, and the selected samples. Contains no
/// images and no biometric face geometry.
struct SessionExportDocument: Codable {
    var metadata: SessionMetadata
    var configuration: MeasurementConfig
    var headPoseConvention: HeadPoseConvention
    var neutralCalibration: NeutralPose?
    var summary: SessionSummary
    var samples: [MeasurementSample]
    /// Present only in debug exports.
    var rejectedSamples: [MeasurementSample]?
    /// Guided-protocol stage transitions with reasons (additive field).
    var stageTransitions: [GuidedMovementController.StageTransition]?
}

enum JSONExporter {

    static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                  negativeInfinity: "-inf",
                                                                  nan: "nan")
        return enc
    }

    static func data(for document: SessionExportDocument) throws -> Data {
        try encoder().encode(document)
    }

    static func document(for session: RecordedSession,
                         includeRejected: Bool,
                         convention: HeadPoseConvention = .default) -> SessionExportDocument {
        SessionExportDocument(metadata: session.metadata,
                              configuration: session.configuration,
                              headPoseConvention: convention,
                              neutralCalibration: session.neutralPose,
                              summary: session.summary,
                              samples: session.acceptedSamples,
                              rejectedSamples: includeRejected ? session.rejectedSamples : nil,
                              stageTransitions: session.stageTransitions.isEmpty
                                  ? nil : session.stageTransitions)
    }

    static func write(session: RecordedSession,
                      includeRejected: Bool,
                      to directory: URL,
                      filename: String) throws -> URL {
        let doc = document(for: session, includeRejected: includeRejected)
        let url = directory.appendingPathComponent(filename)
        try data(for: doc).write(to: url, options: .atomic)
        return url
    }
}
