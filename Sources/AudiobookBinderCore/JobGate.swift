import Foundation

/// Mutually exclusive library jobs. A scan and a build cannot start together.
/// A new scan is allowed while another scan is running (it cancels the previous).
public enum JobGate {
    public static let cannotBuildWhileScanning = "Cannot build while a scan is running."
    public static let cannotScanWhileBuilding = "Cannot scan while a build is running."

    public static func canStartBuild(isScanning: Bool, isBuilding: Bool = false) -> Bool {
        !isScanning && !isBuilding
    }

    /// `isScanning` is accepted so callers can pass current flags. It does not
    /// block: a newer scan supersedes an in-flight one.
    public static func canStartScan(isBuilding: Bool, isScanning: Bool = false) -> Bool {
        switch (isBuilding, isScanning) {
        case (true, _):
            return false
        case (false, _):
            return true
        }
    }
}
