import IOKit.pwr_mgt
import XCTest
@testable import Cappuccino

final class MacSleepPreventionTests: XCTestCase {
    /// Exercises the real trigger → Keep Awake → macOS power adapter chain.
    func testRealAssertionsAreCreatedAndReleased() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        let keyboard = IntegrationKeyboard()
        let keepAwake = KeepAwakeController(sleep: power)
        let controller = CapsLockTrigger(
            keyboard: keyboard, keepAwake: keepAwake, indicator: keyboard.led.controller
        )
        controller.start()
        controller.toggle()

        XCTAssertNil(controller.state.message)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertEqual(try Set(ownAssertionTypes()), [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventUserIdleDisplaySleep
        ])

        controller.toggle()
        XCTAssertNil(controller.state.message)
        XCTAssertEqual(try ownAssertionTypes(), [])
        controller.stop()
    }

    func testRealAssertionsSurviveLockKeyboardInterruptionAndUnlock() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        let keyboard = IntegrationKeyboard()
        let controller = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: power),
            indicator: keyboard.led.controller
        )
        let app = AppDelegate(capsLock: controller)
        controller.start()
        controller.toggle()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        keyboard.onFailure?(NSError(domain: "Keyboard suspended", code: 1))

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertTrue(keyboard.led.output.isOn)
        keyboard.led.output.states = [.off]
        keyboard.led.scheduler.tick()
        XCTAssertTrue(keyboard.led.output.isOn)
        XCTAssertEqual(try Set(ownAssertionTypes()), [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventUserIdleDisplaySleep
        ])

        app.resume(Notification(name: AppDelegate.screenDidUnlock))
        XCTAssertTrue(controller.state.isRunning)
        XCTAssertTrue(controller.state.isOn)
        XCTAssertEqual(try ownAssertionTypes().count, 2)

        controller.stop()
        XCTAssertEqual(try ownAssertionTypes(), [])
        XCTAssertEqual(keyboard.led.output.writes.last, "Auto")
        XCTAssertEqual(keyboard.led.scheduler.activeCount, 0)
    }

    func testRealPowerAssertionsSurviveLEDOnlyFailure() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        let keyboard = IntegrationKeyboard()
        keyboard.led.output.onError = TestLEDError.failed
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: power),
            indicator: keyboard.led.controller
        )
        trigger.start()
        trigger.toggle()

        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(trigger.state.isOn)
        XCTAssertNotNil(trigger.state.indicatorMessage)
        XCTAssertEqual(try ownAssertionTypes().count, 2)
        trigger.stop()
        XCTAssertEqual(try ownAssertionTypes(), [])
    }

    func testRealAssertionsRemainUntilLastRequestEnds() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        let keepAwake = KeepAwakeController(sleep: power)
        let first = KeepAwakeController.RequestID()
        let second = KeepAwakeController.RequestID()
        try keepAwake.acquire(first)
        try keepAwake.acquire(second)
        XCTAssertEqual(try ownAssertionTypes().count, 2)

        try keepAwake.release(first)
        XCTAssertEqual(try ownAssertionTypes().count, 2)
        try keepAwake.release(second)
        XCTAssertEqual(try ownAssertionTypes(), [])
    }

    func testStartAndStopAreIdempotent() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        try power.start()
        try power.start()
        XCTAssertEqual(try ownAssertionTypes().count, 2)
        try power.stop()
        try power.stop()
        XCTAssertEqual(try ownAssertionTypes(), [])
    }

    private func ownAssertionTypes() throws -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        XCTAssertEqual(IOPMCopyAssertionsByProcess(&unmanaged), kIOReturnSuccess)
        let raw = try XCTUnwrap(unmanaged?.takeRetainedValue())
        let dictionary = raw as NSDictionary
        let entries = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)]
            as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard (entry[kIOPMAssertionNameKey] as? String)?
                .hasPrefix("Cappuccino:") == true else { return nil }
            return entry[kIOPMAssertionTypeKey] as? String
        }
    }
}

private final class IntegrationKeyboard: KeyboardControl {
    var onToggle: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    let led = LEDTestRig()
    var canConnect = true
    func start() throws {}
    func resetCapsLock() throws {}
    func stop() {}
}
