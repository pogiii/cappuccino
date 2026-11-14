import Foundation
@testable import Cappuccino

enum TestLEDError: LocalizedError {
    case failed
    var errorDescription: String? { "Test LED failure" }
}

final class TestCapsLockLED: CapsLockLED {
    var states: [CapsLockLEDState] = [.off]
    var writes: [String] = []
    var reads = 0
    var onError: Error?
    var readError: Error?
    var restoreError: Error?
    var isOn: Bool { states == [.on] }

    func turnOn() throws {
        writes.append("On")
        if let onError { throw onError }
        states = [.on]
    }

    func reportedStates() throws -> [CapsLockLEDState] {
        reads += 1
        if let readError { throw readError }
        return states
    }

    func restore() throws {
        writes.append("Auto")
        if let restoreError { throw restoreError }
        states = [.off]
    }
}

final class LEDTestClock {
    var now: TimeInterval = 0
}

final class LEDTestScheduler {
    final class Task {
        let action: () -> Void
        var cancelled = false
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    var tasks: [Task] = []
    var intervals: [TimeInterval] = []
    var activeCount: Int { tasks.filter { !$0.cancelled }.count }

    func schedule(_ interval: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let task = Task(action)
        tasks.append(task)
        intervals.append(interval)
        return { task.cancelled = true }
    }

    func tick() {
        tasks.filter { !$0.cancelled }.forEach { $0.action() }
    }
}

struct LEDTestRig {
    let output = TestCapsLockLED()
    let clock = LEDTestClock()
    let scheduler = LEDTestScheduler()
    let controller: CapsLockLEDController

    init() {
        controller = CapsLockLEDController(
            led: output, now: { [clock] in clock.now }, schedule: scheduler.schedule
        )
    }
}
