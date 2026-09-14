import XCTest
@testable import AudiobookBinderCore

final class JobGateTests: XCTestCase {
    func testCannotStartBuildWhileScanning() {
        XCTAssertFalse(JobGate.canStartBuild(isScanning: true))
        XCTAssertFalse(JobGate.canStartBuild(isScanning: true, isBuilding: false))
    }

    func testCanStartBuildWhenIdle() {
        XCTAssertTrue(JobGate.canStartBuild(isScanning: false, isBuilding: false))
    }

    func testCannotStartBuildWhileBuilding() {
        XCTAssertFalse(JobGate.canStartBuild(isScanning: false, isBuilding: true))
    }

    func testCannotStartScanWhileBuilding() {
        XCTAssertFalse(JobGate.canStartScan(isBuilding: true))
        XCTAssertFalse(JobGate.canStartScan(isBuilding: true, isScanning: false))
    }

    func testCanStartScanWhileAlreadyScanning() {
        XCTAssertTrue(JobGate.canStartScan(isBuilding: false, isScanning: true))
        XCTAssertTrue(JobGate.canStartScan(isBuilding: false, isScanning: false))
    }

    func testBlockedReasons() {
        XCTAssertEqual(
            JobGate.cannotBuildWhileScanning,
            "Cannot build while a scan is running."
        )
        XCTAssertEqual(
            JobGate.cannotScanWhileBuilding,
            "Cannot scan while a build is running."
        )
    }
}
