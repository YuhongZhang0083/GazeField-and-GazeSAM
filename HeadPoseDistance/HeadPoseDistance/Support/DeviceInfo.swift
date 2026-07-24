import Foundation
import UIKit

/// Non-identifying device information recorded in session metadata.
enum DeviceInfo {

    /// Hardware model identifier, e.g. "iPhone15,2" (or an architecture
    /// string on the simulator).
    static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    static var systemVersion: String {
        UIDevice.current.systemVersion
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "1.0") (\(build ?? "1"))"
    }
}
