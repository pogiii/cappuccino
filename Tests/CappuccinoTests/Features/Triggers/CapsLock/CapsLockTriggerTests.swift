import XCTest
@testable import Cappuccino

final class CapsLockTriggerTests: XCTestCase {
    func testStartupIsOffAndDoesNotPreventSleep() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()

        XCTAssertEqual(controller.state, CapsLockState(isRunning: true))
        XCTAssertEqual(keyboard.indicator, false)
        XCTAssertEqual(sleep.starts, 0)
    }

    func testKeyboardAndMenuUseTheSameTransitions() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        keyboard.onCapsLockChange?(true)

        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, true)

        controller.toggle()
        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
    }

    func testRepeatedEventsAndStartAreIdempotent() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.start()
        keyboard.onCapsLockChange?(true)
        keyboard.onCapsLockChange?(true)

        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertEqual(sleep.starts, 1)
    }

    func testPowerFailureNeverPublishesAwake() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        sleep.startError = TestError.failed
        var published: [CapsLockState] = []
        controller.onStateChange = { published.append($0) }
        controller.toggle()

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
        XCTAssertNotNil(controller.state.message)
        XCTAssertFalse(published.contains { $0.isOn })
    }

    func testIndicatorFailureRollsBackSleepPrevention() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        keyboard.indicatorError = TestError.failed
        controller.toggle()

        XCTAssertEqual(sleep.starts, 1)
        XCTAssertFalse(sleep.isActive)
        XCTAssertFalse(controller.state.isRunning)
        XCTAssertNotNil(controller.state.message)
    }

    func testPermissionFailureCleansUpAndCanBeRetried() {
        let (controller, keyboard, sleep) = makeController()
        keyboard.startError = TestError.failed
        controller.start()

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.stops, 1)

        keyboard.startError = nil
        controller.start()
        XCTAssertTrue(controller.state.isRunning)
        XCTAssertNil(controller.state.message)
    }

    func testKeyboardInterruptionStopsAwakeMode() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        keyboard.onFailure?(TestError.failed)

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
    }

    func testStopCleansUpAndIgnoresLateKeyboardEvents() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.stop()
        keyboard.onCapsLockChange?(true)

        XCTAssertEqual(controller.state, CapsLockState())
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
    }

    func testReleaseFailureIsVisibleAndRetriedBeforeRestart() {
        let (controller, _, sleep) = makeController()
        controller.start()
        controller.toggle()
        sleep.stopError = TestError.failed
        controller.stop()

        XCTAssertNotNil(controller.state.message)
        controller.start()
        XCTAssertFalse(controller.state.isRunning)

        sleep.stopError = nil
        controller.start()
        XCTAssertTrue(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
    }

    func testKeyboardCleanupFailureIsVisibleButStillReleasesPower() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        keyboard.stopError = TestError.failed
        controller.stop()

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
        XCTAssertNotNil(controller.state.message)
    }

    func testManualOffAndStopDoNotReleaseAnotherRequest() throws {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let other = KeepAwakeController.RequestID()
        try keepAwake.acquire(other)
        let trigger = CapsLockTrigger(keyboard: keyboard, keepAwake: keepAwake)
        trigger.start()

        XCTAssertTrue(keepAwake.isAwake)
        XCTAssertFalse(trigger.state.isOn)
        XCTAssertFalse(keyboard.indicator)
        trigger.toggle()
        trigger.toggle()
        trigger.stop()

        XCTAssertTrue(keepAwake.isAwake)
        XCTAssertTrue(sleep.isActive)
        XCTAssertFalse(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 1)
        try keepAwake.release(other)
        XCTAssertFalse(sleep.isActive)
    }

    func testAnotherRequestEndingDoesNotCancelManualRequest() throws {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        let trigger = CapsLockTrigger(keyboard: keyboard, keepAwake: keepAwake)
        trigger.start()
        trigger.toggle()
        let other = KeepAwakeController.RequestID()
        try keepAwake.acquire(other)
        try keepAwake.release(other)

        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertTrue(sleep.isActive)
        trigger.stop()
        XCTAssertFalse(sleep.isActive)
    }

    func testDroppingTriggerCleansUpWithoutReleasingAnotherRequest() throws {
        for hasOtherRequest in [false, true] {
            let keyboard = FakeKeyboard()
            let sleep = FakeSleep()
            let keepAwake = KeepAwakeController(sleep: sleep)
            let other = KeepAwakeController.RequestID()
            if hasOtherRequest { try keepAwake.acquire(other) }
            var trigger: CapsLockTrigger? = CapsLockTrigger(
                keyboard: keyboard, keepAwake: keepAwake
            )
            trigger?.start()
            trigger?.toggle()
            XCTAssertTrue(keyboard.indicator)
            if hasOtherRequest { sleep.stopError = TestError.failed }
            trigger = nil

            XCTAssertFalse(keyboard.indicator)
            XCTAssertEqual(keepAwake.isAwake, hasOtherRequest)
            XCTAssertEqual(sleep.isActive, hasOtherRequest)
            XCTAssertEqual(sleep.stops, hasOtherRequest ? 0 : 1)
            sleep.stopError = nil
            try keepAwake.release(other)
            XCTAssertFalse(sleep.isActive)
            XCTAssertEqual(sleep.stops, 1)
        }
    }

    func testDroppingTriggerWithFailedReleaseAllowsReplacementToRetryCleanup() {
        for retryWhileFailing in [false, true] {
            let keyboard = FakeKeyboard()
            let sleep = FakeSleep()
            let keepAwake = KeepAwakeController(sleep: sleep)
            var trigger: CapsLockTrigger? = CapsLockTrigger(
                keyboard: keyboard, keepAwake: keepAwake
            )
            trigger?.start()
            trigger?.toggle()
            sleep.stopError = TestError.failed
            trigger = nil

            XCTAssertFalse(keyboard.indicator)
            XCTAssertFalse(keepAwake.isAwake)
            XCTAssertTrue(sleep.isActive)
            XCTAssertEqual(sleep.stops, 1)

            let replacementKeyboard = FakeKeyboard()
            let replacement = CapsLockTrigger(
                keyboard: replacementKeyboard, keepAwake: keepAwake
            )
            var published: [CapsLockState] = []
            replacement.onStateChange = { published.append($0) }
            if retryWhileFailing {
                replacement.start()
                replacement.toggle()
                XCTAssertFalse(replacement.state.isRunning)
                XCTAssertFalse(replacement.state.isOn)
                XCTAssertNotNil(replacement.state.message)
                XCTAssertEqual(replacementKeyboard.starts, 0)
                XCTAssertFalse(replacementKeyboard.indicator)
                XCTAssertFalse(keepAwake.isAwake)
                XCTAssertFalse(published.contains { $0.isOn })
                XCTAssertTrue(sleep.isActive)
                XCTAssertGreaterThan(sleep.stops, 1)
                XCTAssertEqual(sleep.starts, 1)
            }

            sleep.stopError = nil
            replacement.start()
            XCTAssertEqual(replacement.state, CapsLockState(isRunning: true))
            XCTAssertFalse(sleep.isActive)
            XCTAssertFalse(keepAwake.isAwake)

            replacement.toggle()
            XCTAssertTrue(replacement.state.isOn)
            XCTAssertTrue(replacementKeyboard.indicator)
            XCTAssertTrue(keepAwake.isAwake)
            XCTAssertTrue(sleep.isActive)
            XCTAssertEqual(sleep.starts, 2)
            replacement.stop()
            XCTAssertFalse(keepAwake.isAwake)
            XCTAssertFalse(sleep.isActive)
        }
    }

    func testKeyboardFailuresDoNotReleaseAnotherRequest() throws {
        // Exercise startup, LED, and asynchronous keyboard failure paths through
        // the real trigger → request aggregation chain.
        for failure in ["startup", "indicator", "interruption"] {
            let keyboard = FakeKeyboard()
            let sleep = FakeSleep()
            let keepAwake = KeepAwakeController(sleep: sleep)
            let other = KeepAwakeController.RequestID()
            try keepAwake.acquire(other)
            let trigger = CapsLockTrigger(keyboard: keyboard, keepAwake: keepAwake)

            if failure == "startup" { keyboard.startError = TestError.failed }
            trigger.start()
            if failure == "indicator" { keyboard.indicatorError = TestError.failed }
            trigger.toggle()
            if failure == "interruption" { keyboard.onFailure?(TestError.failed) }
            keyboard.onCapsLockChange?(true)

            XCTAssertFalse(trigger.state.isRunning, failure)
            XCTAssertNotNil(trigger.state.message, failure)
            XCTAssertFalse(keyboard.indicator, failure)
            XCTAssertTrue(keepAwake.isAwake, failure)
            XCTAssertTrue(sleep.isActive, failure)
            try keepAwake.release(other)
            XCTAssertFalse(sleep.isActive, failure)
        }
    }

    private func makeController() -> (CapsLockTrigger, FakeKeyboard, FakeSleep) {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        return (CapsLockTrigger(keyboard: keyboard, keepAwake: keepAwake), keyboard, sleep)
    }
}

private enum TestError: Error { case failed }

private final class FakeKeyboard: KeyboardControl {
    var onCapsLockChange: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?
    var startError: Error?
    var indicatorError: Error?
    var stopError: Error?
    var indicator = false
    var starts = 0
    var stops = 0

    func start() throws {
        starts += 1
        if let startError { throw startError }
    }

    func setIndicator(isOn: Bool) throws {
        if let indicatorError { throw indicatorError }
        indicator = isOn
    }

    func stop() throws {
        stops += 1
        if let stopError { throw stopError }
        indicator = false
    }
}

private final class FakeSleep: SleepPrevention {
    var startError: Error?
    var stopError: Error?
    var starts = 0
    var stops = 0
    var isActive = false

    func start() throws {
        starts += 1
        if let startError { throw startError }
        isActive = true
    }

    func stop() throws {
        stops += 1
        if let stopError { throw stopError }
        isActive = false
    }
}
