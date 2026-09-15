import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testSyncPublicReleaseGlobCleanup() throws {
        try runZshFixture("scripts/test-sync-glob.sh")
    }

    func testReleasePipelineGates() throws {
        try runZshFixture("scripts/test-release-gates.sh")
    }

    private func runZshFixture(_ relativePath: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: script.path),
            "missing \(script.path)"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", script.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, err)
    }
}
