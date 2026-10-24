import IOKit.pwr_mgt
import XCTest
@testable import Cappuccino

final class MacSleepPreventionTests: XCTestCase {
    /// Exercises the real model → macOS power adapter → IOKit chain.
    func testRealAssertionsAreCreatedAndReleased() throws {
        let power = MacSleepPrevention()
        defer { try? power.stop() }
        let keyboard = IntegrationKeyboard()
        let controller = AwakeController(keyboard: keyboard, sleep: power)
        controller.start()
        controller.toggle()

        XCTAssertNil(controller.state.message)
        XCTAssertTrue(controller.state.isAwake)
        XCTAssertEqual(try Set(ownAssertionTypes()), [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventUserIdleDisplaySleep
        ])

        controller.toggle()
        XCTAssertNil(controller.state.message)
        XCTAssertEqual(try ownAssertionTypes(), [])
        controller.stop()
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
    var onCapsLockChange: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?
    func start() throws {}
    func setIndicator(isOn: Bool) throws {}
    func stop() {}
}
