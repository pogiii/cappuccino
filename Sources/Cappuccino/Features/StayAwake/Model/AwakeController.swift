struct AwakeState: Equatable {
    var isRunning = false
    var isAwake = false
    var message: String?
}

/// Owns the behavior, not the menu or the macOS APIs. All calls are serialized
/// by the app's main run loop; tests can exercise it synchronously.
final class AwakeController {
    private let keyboard: KeyboardControl
    private let sleep: SleepPrevention

    private(set) var state = AwakeState() {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    var onStateChange: ((AwakeState) -> Void)?

    init(keyboard: KeyboardControl, sleep: SleepPrevention) {
        self.keyboard = keyboard
        self.sleep = sleep
        keyboard.onCapsLockChange = { [weak self] isOn in
            self?.setAwake(isOn)
        }
        keyboard.onFailure = { [weak self] error in
            self?.stop(message: error.localizedDescription)
        }
    }

    func start() {
        guard !state.isRunning else { return }
        do {
            // Retry cleanup before acquiring anything new after a failure.
            try sleep.stop()
            try keyboard.start()
            try keyboard.setIndicator(isOn: false)
            state = AwakeState(isRunning: true)
        } catch {
            stop(message: error.localizedDescription)
        }
    }

    func toggle() {
        setAwake(!state.isAwake)
    }

    func setAwake(_ isOn: Bool) {
        guard state.isRunning, state.isAwake != isOn else { return }
        do {
            if isOn {
                try sleep.start()
            } else {
                try sleep.stop()
            }
            // Publish success only after both the power and keyboard operations
            // succeed. Indicator failure rolls power prevention back.
            try keyboard.setIndicator(isOn: isOn)
            state = AwakeState(isRunning: true, isAwake: isOn)
        } catch {
            stop(message: error.localizedDescription)
        }
    }

    func stop(message: String? = nil) {
        var messages = [message].compactMap { $0 }
        do {
            try sleep.stop()
        } catch {
            messages.append(error.localizedDescription)
        }
        do {
            try keyboard.stop()
        } catch {
            messages.append(error.localizedDescription)
        }
        state = AwakeState(message: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }
}
