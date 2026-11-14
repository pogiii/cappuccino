import AppKit
import XCTest
@testable import Cappuccino

final class AppDelegateTests: XCTestCase {
    func testLockAndUnlockPreserveRequestAndIndependentIndicator() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        app.reconnectKeyboard()

        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertEqual(sleep.stops, 0)

        app.resume(Notification(name: AppDelegate.screenDidUnlock))

        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 1)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testLockAndUnlockWhileOffDoNotEnableAwakeMode() {
        let (app, trigger, keyboard, sleep) = makeApp(isOn: false)
        app.pause(Notification(name: AppDelegate.screenDidLock))
        app.resume(Notification(name: AppDelegate.screenDidUnlock))

        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertFalse(trigger.state.isOn)
        XCTAssertFalse(keyboard.indicator)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(sleep.starts, 0)
    }

    func testUnlockWaitsForSecureInputToEndBeforeReconnecting() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        keyboard.canConnect = false
        app.resume(Notification(name: AppDelegate.screenDidUnlock))
        app.reconnectKeyboard()

        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertTrue(trigger.state.isOn)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertTrue(sleep.isActive)

        keyboard.canConnect = true
        app.reconnectKeyboard()

        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testWakeDoesNotReconnectLockedOrInactiveSession() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: NSWorkspace.sessionDidResignActiveNotification))
        app.pause(Notification(name: AppDelegate.screenDidLock))
        app.pause(Notification(name: NSWorkspace.willSleepNotification))

        app.resume(Notification(name: NSWorkspace.didWakeNotification))
        app.reconnectKeyboard()
        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertEqual(keyboard.starts, 1)

        app.resume(Notification(name: AppDelegate.screenDidUnlock))
        app.reconnectKeyboard()
        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertEqual(keyboard.starts, 1)

        app.resume(Notification(name: NSWorkspace.sessionDidBecomeActiveNotification))
        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(sleep.starts, 1)
        XCTAssertEqual(sleep.stops, 0)
    }

    func testUnlockDoesNotReconnectWhileMacIsSleeping() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        app.pause(Notification(name: NSWorkspace.willSleepNotification))
        app.resume(Notification(name: AppDelegate.screenDidUnlock))
        app.reconnectKeyboard()

        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertTrue(sleep.isActive)

        app.resume(Notification(name: NSWorkspace.didWakeNotification))
        XCTAssertTrue(trigger.state.isRunning)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertEqual(sleep.starts, 1)
    }

    func testQuitWhileLockedReleasesPower() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(trigger.state, CapsLockState())
        XCTAssertFalse(keyboard.indicator)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(sleep.stops, 1)
    }

    func testLEDRecoversWhileKeyboardRemainsLocked() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        keyboard.led.output.states = [.off]
        keyboard.led.scheduler.tick()

        XCTAssertFalse(trigger.state.isRunning)
        XCTAssertTrue(keyboard.indicator)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(keyboard.starts, 1)
        XCTAssertNil(trigger.state.indicatorMessage)
    }

    func testSwitchingOffWhileLockedDoesNotChangeIntentionalNativeCapsLock() {
        let (app, trigger, keyboard, sleep) = makeApp()
        app.pause(Notification(name: AppDelegate.screenDidLock))
        keyboard.nativeCapsLock = true
        trigger.toggle()

        XCTAssertFalse(sleep.isActive)
        XCTAssertFalse(trigger.state.isOn)
        XCTAssertTrue(keyboard.nativeCapsLock)
        XCTAssertEqual(keyboard.led.output.writes.last, "Auto")
        XCTAssertEqual(keyboard.led.scheduler.activeCount, 0)
    }

    private func makeApp(isOn: Bool = true) -> (AppDelegate, CapsLockTrigger, SessionKeyboard, SessionSleep) {
        let keyboard = SessionKeyboard()
        let sleep = SessionSleep()
        let trigger = CapsLockTrigger(
            keyboard: keyboard, keepAwake: KeepAwakeController(sleep: sleep),
            indicator: keyboard.led.controller
        )
        trigger.start()
        if isOn { trigger.toggle() }
        return (AppDelegate(capsLock: trigger), trigger, keyboard, sleep)
    }
}

private final class SessionKeyboard: KeyboardControl {
    var onToggle: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    let led = LEDTestRig()
    var canConnect = true
    var indicator: Bool { led.output.isOn }
    var nativeCapsLock = false
    var starts = 0

    func start() { starts += 1 }
    func resetCapsLock() { nativeCapsLock = false }
    func stop() { nativeCapsLock = false }
}

private final class SessionSleep: SleepPrevention {
    var isActive = false
    var starts = 0
    var stops = 0

    func start() {
        starts += 1
        isActive = true
    }

    func stop() {
        stops += 1
        isActive = false
    }
}
