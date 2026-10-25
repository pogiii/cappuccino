import CoreGraphics
import XCTest
@testable import Cappuccino

final class MacKeyboardEventTests: XCTestCase {
    func testFilterRemovesOnlyCapsLock() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let otherFlags: CGEventFlags = [
            .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn
        ]
        event.flags = otherFlags.union(.maskAlphaShift)

        MacCapsLockKeyboard.removeCapsLock(from: event)

        XCTAssertEqual(event.flags, otherFlags)
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
        XCTAssertEqual(event.type, .keyDown)
    }

    func testUnmodifiedEventsStayUnmodified() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false))
        event.flags = []
        MacCapsLockKeyboard.removeCapsLock(from: event)
        XCTAssertEqual(event.flags, [])
        XCTAssertEqual(event.type, .keyUp)
    }

    func testFilterDoesNotLowercaseExplicitUnicodeText() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let text = Array("ÄBC".utf16)
        event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        event.flags = [.maskAlphaShift, .maskShift]

        MacCapsLockKeyboard.removeCapsLock(from: event)

        var result = [UniChar](repeating: 0, count: 8)
        var count = 0
        event.keyboardGetUnicodeString(
            maxStringLength: result.count, actualStringLength: &count, unicodeString: &result
        )
        XCTAssertEqual(String(utf16CodeUnits: result, count: count), "ÄBC")
        XCTAssertEqual(event.flags, [.maskShift])
    }
}
