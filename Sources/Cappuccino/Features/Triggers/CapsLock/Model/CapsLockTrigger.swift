struct CapsLockState: Equatable {
    var isRunning = false
    /// The manual request/LED state, not the aggregate Keep Awake state.
    var isOn = false
    var message: String?
}

/// Owns the manual Caps Lock/menu request and keyboard safety, not global power
/// state. Stopping this trigger never releases another trigger's request.
final class CapsLockTrigger {
    private let keyboard: KeyboardControl
    private let keepAwake: KeepAwakeController
    private let request = KeepAwakeController.RequestID()

    private(set) var state = CapsLockState() {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    var onStateChange: ((CapsLockState) -> Void)?

    init(keyboard: KeyboardControl, keepAwake: KeepAwakeController) {
        self.keyboard = keyboard
        self.keepAwake = keepAwake
        keyboard.onCapsLockChange = { [weak self] isOn in
            self?.setOn(isOn)
        }
        keyboard.onFailure = { [weak self] error in
            self?.stop(message: error.localizedDescription)
        }
    }

    func start() {
        guard !state.isRunning else { return }
        do {
            // Retry cleanup before acquiring anything new after a failure.
            try keepAwake.release(request)
            try keyboard.start()
            try keyboard.setIndicator(isOn: false)
            state = CapsLockState(isRunning: true)
        } catch {
            stop(message: error.localizedDescription)
        }
    }

    func toggle() {
        setOn(!state.isOn)
    }

    func setOn(_ isOn: Bool) {
        guard state.isRunning, state.isOn != isOn else { return }
        do {
            if isOn {
                try keepAwake.acquire(request)
            } else {
                try keepAwake.release(request)
            }
            // Publish success only after both the power and keyboard operations
            // succeed. Indicator failure rolls back only this trigger's request.
            try keyboard.setIndicator(isOn: isOn)
            state = CapsLockState(isRunning: true, isOn: isOn)
        } catch {
            stop(message: error.localizedDescription)
        }
    }

    func stop(message: String? = nil) {
        var messages = [message].compactMap { $0 }
        do {
            try keepAwake.release(request)
        } catch {
            messages.append(error.localizedDescription)
        }
        do {
            try keyboard.stop()
        } catch {
            messages.append(error.localizedDescription)
        }
        state = CapsLockState(message: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }

    deinit {
        // Explicit stop retains retry ownership. At destruction, the shared
        // controller must own any remaining power cleanup instead of a dead ID.
        keepAwake.abandon(request)
        try? keyboard.stop()
    }
}
