import XCTest
@testable import Cappuccino

final class CapsLockLEDControllerTests: XCTestCase {
    func testUnusedControllerDoesNotWriteAndStartupRepairIsExplicitAndIdempotent() {
        let led = TestCapsLockLED()
        var controller: CapsLockLEDController? = CapsLockLEDController(led: led)
        controller = nil
        XCTAssertTrue(led.writes.isEmpty)

        controller = CapsLockLEDController(led: led)
        controller?.activate()
        controller?.activate()
        controller?.stop()
        XCTAssertEqual(led.writes, ["Auto"])
    }

    func testOnMonitorsAtProvenIntervalWithoutRewritingHealthyLED() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        rig.controller.setOn(true)
        rig.scheduler.tick()
        rig.scheduler.tick()

        XCTAssertEqual(rig.output.writes, ["On"])
        XCTAssertEqual(rig.scheduler.intervals, [0.25])
        XCTAssertEqual(rig.output.reads, 2)
        XCTAssertNil(rig.controller.message)
    }

    func testCompetingResetIsRecoveredAndOffHasNoPolling() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        rig.output.states = [.off]
        rig.scheduler.tick()
        XCTAssertEqual(rig.output.writes, ["On", "On"])

        rig.controller.setOn(false)
        let reads = rig.output.reads
        rig.scheduler.tick()
        rig.controller.setOn(false)
        XCTAssertEqual(rig.scheduler.activeCount, 0)
        XCTAssertEqual(rig.output.reads, reads)
        XCTAssertEqual(rig.output.writes, ["On", "On", "Auto"])
    }

    func testSpacedResetsHaveNoLifetimeLimitOrProbeExpiry() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        for _ in 0..<20 {
            rig.clock.now += 11
            rig.output.states = [.off]
            rig.scheduler.tick()
        }
        XCTAssertTrue(rig.output.isOn)
        XCTAssertEqual(rig.output.writes.filter { $0 == "On" }.count, 21)
        XCTAssertEqual(rig.scheduler.activeCount, 1)
        XCTAssertNil(rig.controller.message)
    }

    func testBurstLimitDegradesAndExplicitRetryRestarts() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        for _ in 0..<9 {
            rig.clock.now += 0.25
            rig.output.states = [.off]
            rig.scheduler.tick()
        }
        XCTAssertEqual(rig.output.writes.filter { $0 == "On" }.count, 9)
        XCTAssertEqual(rig.output.writes.last, "Auto")
        XCTAssertEqual(rig.scheduler.activeCount, 0)
        XCTAssertNotNil(rig.controller.message)
        let writes = rig.output.writes
        rig.scheduler.tick()
        rig.controller.setOn(true)
        XCTAssertEqual(rig.output.writes, writes, "Failure must not silently auto-retry")

        rig.controller.retry()
        XCTAssertTrue(rig.output.isOn)
        XCTAssertEqual(rig.scheduler.activeCount, 1)
        XCTAssertNil(rig.controller.message)
    }

    func testRollingWindowExpiresOldWritesAtBoundary() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        for _ in 0..<8 {
            rig.output.states = [.off]
            rig.scheduler.tick()
        }
        rig.clock.now = 10
        rig.output.states = [.off]
        rig.scheduler.tick()
        XCTAssertTrue(rig.output.isOn)
        XCTAssertNil(rig.controller.message)
    }

    func testUnreadableAndRejectedRecoveryStopBeforeCleanup() {
        for failure in ["unknown", "empty", "read", "write"] {
            let rig = LEDTestRig()
            rig.controller.setOn(true)
            switch failure {
            case "unknown": rig.output.states = [.unknown]
            case "empty": rig.output.states = []
            case "read": rig.output.readError = TestLEDError.failed
            default:
                rig.output.states = [.off]
                rig.output.onError = TestLEDError.failed
            }
            rig.scheduler.tick()
            XCTAssertEqual(rig.scheduler.activeCount, 0, failure)
            XCTAssertEqual(rig.output.writes.last, "Auto", failure)
            XCTAssertNotNil(rig.controller.message, failure)
        }
    }

    func testFailedAcquisitionAlsoRestoresAndDoesNotMonitor() {
        let rig = LEDTestRig()
        rig.output.onError = TestLEDError.failed
        rig.controller.setOn(true)
        XCTAssertEqual(rig.output.writes, ["On", "Auto"])
        XCTAssertEqual(rig.scheduler.activeCount, 0)
        XCTAssertNotNil(rig.controller.message)
    }

    func testFailedCleanupBlocksReacquisitionUntilExplicitRetryCanRestore() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        rig.output.restoreError = TestLEDError.failed
        rig.controller.setOn(false)
        rig.controller.setOn(true)
        XCTAssertEqual(rig.output.writes.filter { $0 == "On" }.count, 1)
        XCTAssertEqual(rig.scheduler.activeCount, 0)
        XCTAssertNotNil(rig.controller.message)

        rig.output.restoreError = nil
        rig.controller.retry()
        XCTAssertEqual(Array(rig.output.writes.suffix(2)), ["Auto", "On"])
        XCTAssertNil(rig.controller.message)
    }

    func testOldCallbacksCannotReassertAfterOffOrRestart() {
        let rig = LEDTestRig()
        rig.controller.setOn(true)
        let old = rig.scheduler.tasks[0].action
        rig.controller.stop()
        rig.output.states = [.off]
        old()
        XCTAssertEqual(rig.output.writes, ["On", "Auto"])

        rig.controller.setOn(true)
        rig.output.states = [.off]
        old()
        XCTAssertEqual(rig.output.writes, ["On", "Auto", "On"])
        rig.scheduler.tick()
        XCTAssertTrue(rig.output.isOn)
    }

    func testDestructionStopsMonitoringBeforeRestoring() {
        let led = TestCapsLockLED()
        let scheduler = LEDTestScheduler()
        var controller: CapsLockLEDController? = CapsLockLEDController(
            led: led, schedule: scheduler.schedule
        )
        controller?.setOn(true)
        controller = nil
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(led.writes, ["On", "Auto"])
        scheduler.tasks[0].action()
        XCTAssertEqual(led.writes, ["On", "Auto"])
    }
}
