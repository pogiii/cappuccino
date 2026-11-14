import Foundation

/// Owns LED output, not power or keyboard input. All work uses the main run loop.
final class CapsLockLEDController {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    private let led: CapsLockLED
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private var cancelCheck: (() -> Void)?
    private var generation = 0
    private var activated = false
    private var needsCleanup = false
    private var recoveryWrites: [TimeInterval] = []
    private var isOn = false

    private(set) var message: String? {
        didSet {
            if message != oldValue { onIssueChange?(message) }
        }
    }
    var onIssueChange: ((String?) -> Void)?

    init(
        led: CapsLockLED,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = CapsLockLEDController.scheduleTimer
    ) {
        self.led = led
        self.now = now
        self.schedule = schedule
    }

    /// Explicit startup repair, only after the app's single-instance guard.
    func activate() {
        guard !activated else { return }
        activated = true
        restore()
    }

    func setOn(_ isOn: Bool) {
        guard self.isOn != isOn else { return }
        self.isOn = isOn
        activated = true
        if isOn {
            start()
        } else {
            stop()
        }
    }

    func retry() {
        guard activated else { activate(); return }
        guard message != nil else { return }
        if isOn { start() } else { restore() }
    }

    func stop() {
        isOn = false
        stopMonitoring()
        if activated && (needsCleanup || message != nil) { restore() }
    }

    private func start() {
        stopMonitoring()
        recoveryWrites = []
        // Do not accept another override until failed cleanup has succeeded.
        if needsCleanup {
            restore()
            guard !needsCleanup else { return }
        }
        needsCleanup = true
        do {
            try led.turnOn()
            message = nil
            let expectedGeneration = generation
            cancelCheck = schedule(0.25) { [weak self] in
                guard let self, self.isOn, self.generation == expectedGeneration else { return }
                self.check()
            }
        } catch {
            fail(error)
        }
    }

    private func check() {
        do {
            let states = try led.reportedStates()
            guard !states.isEmpty, !states.contains(.unknown) else {
                throw IndicatorError("Could not read a known LED state.")
            }
            guard states.contains(.off) else { return }
            let time = now()
            recoveryWrites.removeAll { time - $0 >= 10 }
            guard recoveryWrites.count < 8 else {
                throw IndicatorError("LED recovery paused after eight updates in ten seconds. Another utility or macOS may be resetting it.")
            }
            recoveryWrites.append(time)
            try led.turnOn()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        stopMonitoring()
        var detail = error.localizedDescription
        do {
            try led.restore()
            needsCleanup = false
        } catch {
            needsCleanup = true
            detail += "\nNormal LED restoration also failed: \(error.localizedDescription)"
        }
        message = detail
    }

    private func restore() {
        needsCleanup = true
        do {
            try led.restore()
            needsCleanup = false
            message = nil
        } catch {
            message = "Could not restore normal LED control: \(error.localizedDescription)"
        }
    }

    private func stopMonitoring() {
        generation += 1
        cancelCheck?()
        cancelCheck = nil
    }

    private static func scheduleTimer(_ interval: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    deinit {
        cancelCheck?()
        if activated && needsCleanup { try? led.restore() }
    }
}

private struct IndicatorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
