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

    func testCannotStartBuildWhileCleaningUp() {
        XCTAssertFalse(JobGate.canStartBuild(isScanning: false, isBuilding: false, isCleaningUp: true))
        XCTAssertFalse(JobGate.canStartBuild(isScanning: true, isBuilding: false, isCleaningUp: true))
    }

    func testCannotStartScanWhileCleaningUp() {
        XCTAssertFalse(JobGate.canStartScan(isBuilding: false, isCleaningUp: true))
        XCTAssertFalse(JobGate.canStartScan(isBuilding: false, isScanning: true, isCleaningUp: true))
    }

    func testCanStartScanWhileAlreadyScanningWhenNotCleaningUp() {
        XCTAssertTrue(JobGate.canStartScan(isBuilding: false, isScanning: true, isCleaningUp: false))
    }

    func testCannotStartCleanupWhenAnyJobIsRunning() {
        XCTAssertFalse(JobGate.canStartCleanup(isScanning: true, isBuilding: false, isCleaningUp: false))
        XCTAssertFalse(JobGate.canStartCleanup(isScanning: false, isBuilding: true, isCleaningUp: false))
        XCTAssertFalse(JobGate.canStartCleanup(isScanning: false, isBuilding: false, isCleaningUp: true))
    }

    func testCanStartCleanupWhenIdle() {
        XCTAssertTrue(JobGate.canStartCleanup(isScanning: false, isBuilding: false, isCleaningUp: false))
    }

    func testCleanupBlockedReasons() {
        XCTAssertEqual(
            JobGate.cannotScanWhileCleaningUp,
            "Cannot scan while source cleanup is running."
        )
        XCTAssertEqual(
            JobGate.cannotBuildWhileCleaningUp,
            "Cannot build while source cleanup is running."
        )
        XCTAssertEqual(
            JobGate.cannotCleanupWhileScanning,
            "Cannot trash sources while a scan is running."
        )
        XCTAssertEqual(
            JobGate.cannotCleanupWhileBuilding,
            "Cannot trash sources while a build is running."
        )
        XCTAssertEqual(
            JobGate.cannotCleanupWhileCleaningUp,
            "Cannot trash sources while cleanup is already running."
        )
    }
}
