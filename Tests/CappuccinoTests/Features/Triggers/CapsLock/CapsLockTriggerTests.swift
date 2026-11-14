import XCTest
@testable import Cappuccino

final class CapsLockTriggerTests: XCTestCase {
    func testIndependentLEDFailureDoesNotRollBackPowerOrDisconnectKeyboard() {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let rig = LEDTestRig()
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: sleep),
            indicator: rig.controller
        )
        trigger.start()
        rig.output.onError = TestLEDError.failed
        trigger.toggle()

        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(sleep.isActive)
        XCTAssertNotNil(trigger.state.indicatorMessage)
        XCTAssertNil(trigger.state.message)

        rig.output.onError = nil
        trigger.retry()
        XCTAssertTrue(rig.output.isOn)
        XCTAssertNil(trigger.state.indicatorMessage)
        XCTAssertEqual(sleep.starts, 1)
        XCTAssertEqual(keyboard.starts, 1, "LED-only retry must not restart a healthy keyboard")
    }

    func testUnsupportedLEDStillAllowsPowerWithoutNativeLEDControl() {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let indicator = CapsLockLEDController(led: MacCapsLockLED(
            isSupported: false, discover: {
                XCTFail("Unavailable capability must not access HID services")
                return []
            }
        ))
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: sleep), indicator: indicator
        )
        trigger.start()
        trigger.toggle()

        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertNotNil(trigger.state.indicatorMessage)
        XCTAssertEqual(keyboard.nativeResets, 1, "LED-on must not write the native modifier")
    }

    func testUnusedTriggerDestructionDoesNotResetAnotherInstancesLED() {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        var trigger: CapsLockTrigger? = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: sleep),
            indicator: keyboard.led.controller
        )
        XCTAssertNotNil(trigger)
        trigger = nil
        XCTAssertTrue(keyboard.led.output.writes.isEmpty)
        XCTAssertEqual(sleep.starts, 0)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testEveryCleanupIsAttemptedAndRetryDoesNotRestoreAwakeIntent() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        sleep.stopError = TestError.failed
        keyboard.stopError = TestError.failed
        keyboard.led.output.restoreError = TestLEDError.failed
        controller.stop()

        XCTAssertFalse(controller.state.isOn)
        XCTAssertNotNil(controller.state.message)
        XCTAssertNotNil(controller.state.indicatorMessage)
        XCTAssertEqual(keyboard.led.output.writes.last, "Auto")
        XCTAssertEqual(keyboard.led.scheduler.activeCount, 0)

        sleep.stopError = nil
        keyboard.stopError = nil
        keyboard.led.output.restoreError = nil
        controller.retry()
        XCTAssertEqual(controller.state, CapsLockState(isRunning: true))
        XCTAssertFalse(sleep.isActive)
        XCTAssertFalse(keyboard.indicator)
    }

    func testKeyboardSuspensionLeavesIndependentLEDAndPowerActive() {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let rig = LEDTestRig()
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: sleep),
            indicator: rig.controller
        )
        trigger.start()
        trigger.toggle()
        trigger.suspend(message: "Locked")
        rig.output.states = [.off]
        rig.scheduler.tick()

        XCTAssertTrue(trigger.state.isOn)
        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertTrue(rig.output.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(sleep.stops, 0)
        trigger.stop()
        XCTAssertFalse(rig.output.isOn)
        XCTAssertEqual(rig.scheduler.activeCount, 0)
    }

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
        keyboard.onToggle?()

        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, true)

        controller.toggle()
        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)

        controller.toggle()
        keyboard.onToggle?()
        XCTAssertFalse(controller.state.isOn, "The first key action after menu-on must switch off")
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.nativeResets, 3)
    }

    func testRepeatedIntentAndStartAreIdempotent() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.start()
        controller.setOn(true)
        controller.setOn(true)

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

    func testNativeResetFailureStillSwitchesOffPowerAndLED() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        keyboard.resetError = TestError.failed
        controller.toggle()

        XCTAssertEqual(sleep.starts, 1)
        XCTAssertFalse(sleep.isActive)
        XCTAssertFalse(controller.state.isRunning)
        XCTAssertNotNil(controller.state.message)
        XCTAssertFalse(keyboard.indicator)
        XCTAssertNil(controller.state.indicatorMessage)
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

    func testKeyboardInterruptionAndReconnectPreservePowerAndIndicator() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        keyboard.onFailure?(TestError.failed)

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertNotNil(controller.state.message)
        XCTAssertEqual(sleep.stops, 0)

        controller.start()

        XCTAssertTrue(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertNil(controller.state.message)
        XCTAssertEqual(sleep.starts, 1)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testSuspensionIsIdempotentAndIgnoresLateKeyboardEvents() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.suspend(message: "Screen locked")
        controller.suspend(message: "Screen locked")
        keyboard.onToggle?()
        keyboard.onToggle?()

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testMenuCanSwitchOffWhileKeyboardIsSuspended() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.suspend(message: "Secure Input")
        keyboard.resetError = TestError.failed
        controller.toggle()

        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(controller.state.message, "Secure Input")
        XCTAssertEqual(sleep.stops, 1)

        keyboard.resetError = nil
        controller.reconnectIfAvailable()
        XCTAssertEqual(controller.state, CapsLockState(isRunning: true))
        XCTAssertFalse(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 1)
    }

    func testSuspensionWhileOffDoesNotAcquireRequestOnReconnect() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.suspend(message: "Screen locked")
        controller.toggle()

        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(sleep.isActive)

        controller.reconnectIfAvailable()
        XCTAssertEqual(controller.state, CapsLockState(isRunning: true))
        XCTAssertFalse(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 0)
    }

    func testAutomaticReconnectWaitsForKeyboardAvailability() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.suspend(message: "Secure Input")
        keyboard.canConnect = false
        controller.reconnectIfAvailable()

        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertFalse(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)

        keyboard.canConnect = true
        controller.reconnectIfAvailable()
        controller.reconnectIfAvailable()
        XCTAssertEqual(keyboard.starts, 2)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testFailedReconnectPreservesEstablishedRequest() {
        for failure in ["startup", "reset"] {
            let (controller, keyboard, sleep) = makeController()
            controller.start()
            controller.toggle()
            controller.suspend(message: "Screen locked")
            if failure == "startup" { keyboard.startError = TestError.failed }
            if failure == "reset" { keyboard.resetError = TestError.failed }
            controller.reconnectIfAvailable()

            XCTAssertFalse(controller.state.isRunning, failure)
            XCTAssertTrue(controller.state.isOn, failure)
            XCTAssertTrue(sleep.isActive, failure)
            XCTAssertTrue(keyboard.indicator, failure)
            XCTAssertNotNil(controller.state.message, failure)
            XCTAssertEqual(sleep.stops, 0, failure)

            keyboard.startError = nil
            keyboard.resetError = nil
            controller.reconnectIfAvailable()
            XCTAssertTrue(controller.state.isRunning, failure)
            XCTAssertTrue(keyboard.indicator, failure)
            XCTAssertEqual(sleep.starts, 1, failure)
        }
    }

    func testSuspensionCleanupFailureIsVisibleWithoutReleasingPower() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        keyboard.stopError = TestError.failed
        controller.suspend(message: "Screen locked")

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(sleep.isActive)
        XCTAssertTrue(controller.state.message?.contains("Screen locked") == true)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testStopWhileSuspendedReleasesRequestAndDoesNotRestoreIt() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.suspend(message: "Screen locked")
        controller.stop()

        XCTAssertEqual(controller.state, CapsLockState())
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(sleep.stops, 1)

        controller.reconnectIfAvailable()
        XCTAssertFalse(controller.state.isOn)
        XCTAssertFalse(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 1)
    }

    func testStopCleansUpAndIgnoresLateKeyboardEvents() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.stop()
        keyboard.onToggle?()

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
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
        )
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
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
        )
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
                keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
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
                keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
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
                keyboard: replacementKeyboard, keepAwake: keepAwake,
                indicator: replacementKeyboard.led.controller
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
        // Exercise startup, native reset, and asynchronous failure paths through
        // the real trigger → request aggregation chain.
        for failure in ["startup", "reset", "interruption"] {
            let keyboard = FakeKeyboard()
            let sleep = FakeSleep()
            let keepAwake = KeepAwakeController(sleep: sleep)
            let other = KeepAwakeController.RequestID()
            try keepAwake.acquire(other)
            let trigger = CapsLockTrigger(
                keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
            )

            if failure == "startup" { keyboard.startError = TestError.failed }
            if failure == "reset" { keyboard.resetError = TestError.failed }
            trigger.start()
            trigger.toggle()
            if failure == "interruption" { keyboard.onFailure?(TestError.failed) }
            keyboard.onToggle?()

            XCTAssertFalse(trigger.state.isRunning, failure)
            XCTAssertNotNil(trigger.state.message, failure)
            XCTAssertEqual(keyboard.indicator, failure == "interruption", failure)
            XCTAssertTrue(keepAwake.isAwake, failure)
            XCTAssertTrue(sleep.isActive, failure)
            try keepAwake.release(other)
            XCTAssertEqual(trigger.state.isOn, failure == "interruption", failure)
            XCTAssertEqual(sleep.isActive, failure == "interruption", failure)
            trigger.stop()
            XCTAssertFalse(sleep.isActive, failure)
        }
    }

    private func makeController() -> (CapsLockTrigger, FakeKeyboard, FakeSleep) {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        let keepAwake = KeepAwakeController(sleep: sleep)
        return (
            CapsLockTrigger(keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller),
            keyboard, sleep
        )
    }
}

private enum TestError: Error { case failed }

private final class FakeKeyboard: KeyboardControl {
    var onToggle: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    // Test fixture convenience; keyboard methods never control this output.
    let led = LEDTestRig()
    var canConnect = true
    var startError: Error?
    var resetError: Error?
    var stopError: Error?
    var indicator: Bool { led.output.isOn }
    var nativeResets = 0
    var starts = 0
    var stops = 0

    func start() throws {
        starts += 1
        if let startError { throw startError }
    }

    func resetCapsLock() throws {
        nativeResets += 1
        if let resetError { throw resetError }
    }

    func stop() throws {
        stops += 1
        if let stopError { throw stopError }
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
