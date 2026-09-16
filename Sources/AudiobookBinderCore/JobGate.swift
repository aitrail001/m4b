import Foundation

/// Mutually exclusive library jobs. A scan and a build cannot start together.
/// A new scan is allowed while another scan is running (it cancels the previous).
/// Cleanup excludes scan, build, and a second cleanup.
public enum JobGate {
    public static let cannotBuildWhileScanning = "Cannot build while a scan is running."
    public static let cannotScanWhileBuilding = "Cannot scan while a build is running."
    public static let cannotScanWhileCleaningUp = "Cannot scan while source cleanup is running."
    public static let cannotBuildWhileCleaningUp = "Cannot build while source cleanup is running."
    public static let cannotCleanupWhileScanning = "Cannot trash sources while a scan is running."
    public static let cannotCleanupWhileBuilding = "Cannot trash sources while a build is running."
    public static let cannotCleanupWhileCleaningUp = "Cannot trash sources while cleanup is already running."

    public static func canStartBuild(
        isScanning: Bool,
        isBuilding: Bool = false,
        isCleaningUp: Bool = false
    ) -> Bool {
        !isScanning && !isBuilding && !isCleaningUp
    }

    /// `isScanning` is accepted so callers can pass current flags. It does not
    /// block: a newer scan supersedes an in-flight one. Cleanup does block.
    public static func canStartScan(
        isBuilding: Bool,
        isScanning: Bool = false,
        isCleaningUp: Bool = false
    ) -> Bool {
        _ = isScanning
        return !isBuilding && !isCleaningUp
    }

    public static func canStartCleanup(
        isScanning: Bool,
        isBuilding: Bool,
        isCleaningUp: Bool
    ) -> Bool {
        !isScanning && !isBuilding && !isCleaningUp
    }

    /// Closing the last window must not kill a cleanup that already renamed a hold.
    public static func shouldTerminateAfterLastWindowClosed(isCleaningUp: Bool) -> Bool {
        !isCleaningUp
    }

    /// Cmd-Q waits until cleanup restores or finishes the held source.
    public static func shouldPostponeTermination(isCleaningUp: Bool) -> Bool {
        isCleaningUp
    }

    public enum CleanupQuitAction: Equatable, Sendable {
        case none
        case replyToTerminate
        case terminate
    }

    /// After cleanup, finish a postponed Cmd-Q, or quit if the last window
    /// already closed while a hold was in progress.
    public static func cleanupQuitAction(
        postponeTerminate: Bool,
        lastWindowClosedDuringCleanup: Bool
    ) -> CleanupQuitAction {
        if postponeTerminate { return .replyToTerminate }
        if lastWindowClosedDuringCleanup { return .terminate }
        return .none
    }
}
