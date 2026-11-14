import XCTest
@testable import Cappuccino

final class StatusBarControllerTests: XCTestCase {
    func testHealthyOnAndOffPresentPowerState() {
        let on = StatusBarPresentation(state: CapsLockState(isRunning: true, isOn: true))
        XCTAssertEqual(on.symbol, "cup.and.saucer.fill")
        XCTAssertTrue(on.title.contains("Keeping Mac Awake"))
        XCTAssertFalse(on.retryVisible)
        XCTAssertTrue(on.toggleEnabled)

        let off = StatusBarPresentation(state: CapsLockState(isRunning: true))
        XCTAssertEqual(off.symbol, "cup.and.saucer")
        XCTAssertTrue(off.title.contains("Normal Sleep"))
        XCTAssertFalse(off.retryVisible)
    }

    func testLEDOnlyFailureShowsRetryWithoutClaimingKeyboardDisconnection() {
        let view = StatusBarPresentation(state: CapsLockState(
            isRunning: true, isOn: true, indicatorMessage: "Unsupported LED"
        ))
        XCTAssertEqual(view.symbol, "cup.and.saucer.fill")
        XCTAssertTrue(view.retryVisible)
        XCTAssertTrue(view.toggleEnabled)
        XCTAssertTrue(view.detail.contains("LED"))
        XCTAssertFalse(view.detail.contains("Keyboard paused"))
        XCTAssertTrue(view.tooltip.contains("LED: Unsupported LED"))
    }

    func testKeyboardPauseDoesNotHideAwakeStateOrDisableSwitchingOff() {
        let view = StatusBarPresentation(state: CapsLockState(
            isOn: true, message: "Secure Input"
        ))
        XCTAssertEqual(view.symbol, "cup.and.saucer.fill")
        XCTAssertTrue(view.title.contains("Keeping Mac Awake"))
        XCTAssertTrue(view.detail.contains("Keyboard paused"))
        XCTAssertTrue(view.retryVisible)
        XCTAssertTrue(view.toggleEnabled)
    }

    func testCombinedFailuresAreBothVisibleAndOffDisconnectedCannotSwitchOn() {
        let view = StatusBarPresentation(state: CapsLockState(
            message: "Keyboard unavailable", indicatorMessage: "LED unavailable"
        ))
        XCTAssertEqual(view.symbol, "exclamationmark.circle")
        XCTAssertTrue(view.detail.contains("Keyboard and LED"))
        XCTAssertTrue(view.tooltip.contains("Keyboard unavailable"))
        XCTAssertTrue(view.tooltip.contains("LED unavailable"))
        XCTAssertFalse(view.toggleEnabled)
        XCTAssertTrue(view.retryVisible)
    }
}
