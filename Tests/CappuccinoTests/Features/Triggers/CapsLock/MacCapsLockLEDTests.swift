import XCTest
@testable import Cappuccino

final class MacCapsLockLEDTests: XCTestCase {
    func testConstructionAndUnusedDestructionDoNotDiscoverOrWrite() {
        var discoveries = 0
        var led: MacCapsLockLED? = MacCapsLockLED(isSupported: true, discover: {
            discoveries += 1
            return []
        })
        XCTAssertNotNil(led)
        led = nil
        XCTAssertEqual(discoveries, 0)
    }

    func testOnlyBuiltInKeyboardsReceiveWritesAndReads() throws {
        let builtIn = LEDServiceFixture()
        let external = LEDServiceFixture()
        let pointer = LEDServiceFixture()
        let led = MacCapsLockLED(isSupported: true, discover: {
            [builtIn.service(), external.service(isBuiltIn: false), pointer.service(isKeyboard: false)]
        })

        try led.turnOn()
        XCTAssertEqual(try led.reportedStates(), [.on])
        try led.restore()

        XCTAssertEqual(builtIn.writes, ["On", "Auto"])
        XCTAssertTrue(external.writes.isEmpty)
        XCTAssertTrue(pointer.writes.isEmpty)
    }

    func testUnsupportedAndMissingKeyboardsFailWithoutWrites() {
        let external = LEDServiceFixture()
        let unsupported = MacCapsLockLED(isSupported: false, discover: {
            XCTFail("Unsupported OS must not discover services")
            return []
        })
        XCTAssertThrowsError(try unsupported.turnOn())
        let missing = MacCapsLockLED(isSupported: true, discover: { [external.service(isBuiltIn: false)] })
        XCTAssertThrowsError(try missing.turnOn())
        XCTAssertTrue(external.writes.isEmpty)
    }

    func testUnavailablePrivateAPIIsAnExplicitFailure() {
        let led = MacCapsLockLED(isSupported: true, discover: { throw LEDFixtureError.failed })
        XCTAssertThrowsError(try led.turnOn())
    }

    func testAbsentOrUnexpectedStateIsUnknownNotOff() throws {
        let keyboard = LEDServiceFixture()
        let led = MacCapsLockLED(isSupported: true, discover: { [keyboard.service()] })
        keyboard.state = nil
        XCTAssertEqual(try led.reportedStates(), [.unknown])
        keyboard.state = "Auto"
        XCTAssertEqual(try led.reportedStates(), [.unknown])
        keyboard.state = "Off"
        XCTAssertEqual(try led.reportedStates(), [.off])
    }

    func testPartialWriteAndFailedCleanupRetainEveryServiceForRetry() throws {
        let first = LEDServiceFixture()
        let second = LEDServiceFixture()
        second.rejected = ["On", "Auto"]
        var discoveries = 0
        let led = MacCapsLockLED(isSupported: true, discover: {
            discoveries += 1
            return [first.service(), second.service()]
        })

        XCTAssertThrowsError(try led.turnOn())
        XCTAssertThrowsError(try led.restore())
        XCTAssertEqual(first.writes, ["On", "Auto"])
        XCTAssertEqual(second.writes, ["On", "Auto"])

        second.rejected = []
        try led.restore()
        XCTAssertEqual(first.writes, ["On", "Auto", "Auto"])
        XCTAssertEqual(second.writes, ["On", "Auto", "Auto"])
        XCTAssertEqual(discoveries, 1)
    }

    func testExplicitStartupRestoreAndActiveDestructionRestoreAuto() throws {
        let keyboard = LEDServiceFixture()
        var led: MacCapsLockLED? = MacCapsLockLED(isSupported: true, discover: { [keyboard.service()] })
        try led?.restore()
        XCTAssertEqual(keyboard.writes, ["Auto"])
        try led?.turnOn()
        led = nil
        XCTAssertEqual(keyboard.writes, ["Auto", "On", "Auto"])
    }

    func testRejectedStartupRestorationRemainsOwnedForDestructionRetry() {
        let keyboard = LEDServiceFixture()
        keyboard.rejected = ["Auto"]
        var led: MacCapsLockLED? = MacCapsLockLED(isSupported: true, discover: { [keyboard.service()] })
        XCTAssertThrowsError(try led?.restore())
        keyboard.rejected = []
        led = nil
        XCTAssertEqual(keyboard.writes, ["Auto", "Auto"])
    }

    func testRealControllerCleansPartialAdapterWritesWithoutStartingMonitor() {
        let first = LEDServiceFixture()
        let second = LEDServiceFixture()
        second.rejected = ["On"]
        let adapter = MacCapsLockLED(isSupported: true, discover: { [first.service(), second.service()] })
        let scheduler = LEDTestScheduler()
        let controller = CapsLockLEDController(led: adapter, schedule: scheduler.schedule)
        controller.setOn(true)

        XCTAssertEqual(first.writes, ["On", "Auto"])
        XCTAssertEqual(second.writes, ["On", "Auto"])
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertNotNil(controller.message)
    }
}

private enum LEDFixtureError: Error { case failed }

private final class LEDServiceFixture {
    var state: String? = "Off"
    var rejected: Set<String> = []
    var writes: [String] = []

    func service(isBuiltIn: Bool = true, isKeyboard: Bool = true) -> MacCapsLockLED.Service {
        MacCapsLockLED.Service(
            isBuiltIn: isBuiltIn,
            isKeyboard: isKeyboard,
            read: { self.state },
            write: { value in
                self.writes.append(value)
                guard !self.rejected.contains(value) else { return false }
                self.state = value == "Auto" ? "Off" : value
                return true
            }
        )
    }
}
