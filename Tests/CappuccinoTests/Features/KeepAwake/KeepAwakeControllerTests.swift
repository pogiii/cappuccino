import XCTest
@testable import Cappuccino

final class KeepAwakeControllerTests: XCTestCase {
    func testStartsWithoutRequestsOrPowerAssertions() {
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)

        XCTAssertFalse(keepAwake.isAwake)
        XCTAssertEqual(sleep.starts, 0)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testOnlyFirstAcquisitionAndLastReleaseChangePower() throws {
        for releaseFirstOwnerFirst in [true, false] {
            let sleep = FakeSleep()
            let keepAwake = KeepAwakeController(sleep: sleep)
            let first = KeepAwakeController.RequestID()
            let second = KeepAwakeController.RequestID()
            try keepAwake.acquire(first)
            try keepAwake.acquire(second)

            XCTAssertTrue(keepAwake.isAwake)
            XCTAssertEqual(sleep.starts, 1)

            try keepAwake.release(releaseFirstOwnerFirst ? first : second)
            XCTAssertTrue(keepAwake.isAwake)
            XCTAssertTrue(sleep.isActive)
            XCTAssertEqual(sleep.stops, 0)

            try keepAwake.release(releaseFirstOwnerFirst ? second : first)
            XCTAssertFalse(keepAwake.isAwake)
            XCTAssertFalse(sleep.isActive)
            XCTAssertEqual(sleep.stops, 1)
        }
    }

    func testDuplicateRequestsAndReleasesAreIdempotent() throws {
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let request = KeepAwakeController.RequestID()
        try keepAwake.acquire(request)
        try keepAwake.acquire(request)
        try keepAwake.release(request)
        try keepAwake.release(request)

        XCTAssertEqual(sleep.starts, 1)
        XCTAssertEqual(sleep.stops, 1)
        XCTAssertFalse(keepAwake.isAwake)

        try keepAwake.acquire(request)
        XCTAssertTrue(keepAwake.isAwake)
        XCTAssertEqual(sleep.starts, 2)
        try keepAwake.release(request)
    }

    func testUnknownRequestCannotReleaseAnotherOwner() throws {
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let owner = KeepAwakeController.RequestID()
        try keepAwake.acquire(owner)
        try keepAwake.release(KeepAwakeController.RequestID())

        XCTAssertTrue(keepAwake.isAwake)
        XCTAssertEqual(sleep.stops, 0)
        try keepAwake.release(owner)
    }

    func testFailedAcquisitionRequiresCleanupBeforeAcceptingWork() throws {
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let request = KeepAwakeController.RequestID()
        sleep.startError = TestError.failed

        XCTAssertThrowsError(try keepAwake.acquire(request))
        XCTAssertFalse(keepAwake.isAwake)
        // Simulate partial platform acquisition despite the thrown error.
        XCTAssertTrue(sleep.isActive)
        sleep.startError = nil
        XCTAssertThrowsError(try keepAwake.acquire(request))
        XCTAssertEqual(sleep.starts, 1)

        sleep.stopError = TestError.failed
        XCTAssertThrowsError(try keepAwake.release(request))
        sleep.stopError = nil
        try keepAwake.release(request)
        XCTAssertFalse(sleep.isActive)

        try keepAwake.acquire(request)
        XCTAssertTrue(keepAwake.isAwake)
        try keepAwake.release(request)
    }

    func testFailedReleaseRetainsOwnerForCleanupAndBlocksAcquisition() throws {
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let owner = KeepAwakeController.RequestID()
        let other = KeepAwakeController.RequestID()
        try keepAwake.acquire(owner)
        sleep.stopError = TestError.failed

        XCTAssertThrowsError(try keepAwake.release(owner))
        XCTAssertFalse(keepAwake.isAwake)
        XCTAssertThrowsError(try keepAwake.acquire(other))
        try keepAwake.release(other)
        XCTAssertEqual(sleep.stops, 1)

        sleep.stopError = nil
        try keepAwake.release(owner)
        XCTAssertFalse(sleep.isActive)
        try keepAwake.acquire(other)
        XCTAssertTrue(keepAwake.isAwake)
        try keepAwake.release(other)
    }
}

private enum TestError: Error { case failed }

private final class FakeSleep: SleepPrevention {
    var startError: Error?
    var stopError: Error?
    var starts = 0
    var stops = 0
    var isActive = false

    func start() throws {
        starts += 1
        isActive = true
        if let startError { throw startError }
    }

    func stop() throws {
        stops += 1
        if let stopError { throw stopError }
        isActive = false
    }
}
