import XCTest
@testable import Cappuccino

final class AwakeControllerTests: XCTestCase {
    func testStartupIsOffAndDoesNotPreventSleep() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()

        XCTAssertEqual(controller.state, AwakeState(isRunning: true))
        XCTAssertEqual(keyboard.indicator, false)
        XCTAssertEqual(sleep.starts, 0)
    }

    func testKeyboardAndMenuUseTheSameTransitions() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        keyboard.onCapsLockChange?(true)

        XCTAssertTrue(controller.state.isAwake)
        XCTAssertTrue(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, true)

        controller.toggle()
        XCTAssertFalse(controller.state.isAwake)
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
        var published: [AwakeState] = []
        controller.onStateChange = { published.append($0) }
        controller.toggle()

        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
        XCTAssertNotNil(controller.state.message)
        XCTAssertFalse(published.contains { $0.isAwake })
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
        XCTAssertFalse(controller.state.isAwake)
        XCTAssertFalse(sleep.isActive)
        XCTAssertEqual(keyboard.indicator, false)
    }

    func testStopCleansUpAndIgnoresLateKeyboardEvents() {
        let (controller, keyboard, sleep) = makeController()
        controller.start()
        controller.toggle()
        controller.stop()
        keyboard.onCapsLockChange?(true)

        XCTAssertEqual(controller.state, AwakeState())
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

    private func makeController() -> (AwakeController, FakeKeyboard, FakeSleep) {
        let keyboard = FakeKeyboard()
        let sleep = FakeSleep()
        return (AwakeController(keyboard: keyboard, sleep: sleep), keyboard, sleep)
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
    var isActive = false

    func start() throws {
        starts += 1
        if let startError { throw startError }
        isActive = true
    }

    func stop() throws {
        if let stopError { throw stopError }
        isActive = false
    }
}
