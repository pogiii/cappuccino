struct CapsLockState: Equatable {
    var isRunning = false
    /// The manual request, not keyboard availability or aggregate Keep Awake state.
    var isOn = false
    var message: String?
    var indicatorMessage: String?

    var issues: [String] {
        [message, indicatorMessage.map { "LED: \($0)" }].compactMap { $0 }
    }
}

/// Owns the manual Caps Lock/menu request and keyboard safety, not global power
/// state. Stopping this trigger never releases another trigger's request.
final class CapsLockTrigger {
    private let keyboard: KeyboardControl
    private let keepAwake: KeepAwakeController
    private let indicator: CapsLockLEDController
    private let request = KeepAwakeController.RequestID()

    private(set) var state = CapsLockState() {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    var onStateChange: ((CapsLockState) -> Void)?

    init(keyboard: KeyboardControl, keepAwake: KeepAwakeController, indicator: CapsLockLEDController) {
        self.keyboard = keyboard
        self.keepAwake = keepAwake
        self.indicator = indicator
        keyboard.onToggle = { [weak self] in
            guard let self, self.state.isRunning else { return }
            self.toggle()
        }
        keyboard.onFailure = { [weak self] error in
            self?.suspend(message: error.localizedDescription)
        }
        indicator.onIssueChange = { [weak self] message in
            self?.state.indicatorMessage = message
        }
    }

    func start() {
        indicator.activate()
        guard !state.isRunning else { return }
        do {
            // Retry failed power cleanup, but never release an active request
            // just because its keyboard connection is being restored.
            if !state.isOn { try keepAwake.release(request) }
            try keyboard.start()
            try keyboard.resetCapsLock()
            state = CapsLockState(
                isRunning: true, isOn: state.isOn, indicatorMessage: indicator.message
            )
        } catch {
            suspend(message: error.localizedDescription)
        }
    }

    func retry() {
        start()
        indicator.retry()
    }

    func reconnectIfAvailable() {
        guard !state.isRunning, keyboard.canConnect else { return }
        start()
    }

    func toggle() {
        setOn(!state.isOn)
    }

    func setOn(_ isOn: Bool) {
        // A disconnected keyboard must not prevent the menu from switching off.
        guard state.isOn != isOn, state.isRunning || !isOn else { return }
        do {
            if isOn {
                try keepAwake.acquire(request)
            } else {
                try keepAwake.release(request)
            }
        } catch {
            stop(message: error.localizedDescription)
            return
        }
        // Power success is independent of keyboard cleanup and LED availability.
        state.isOn = isOn
        if !isOn, state.isRunning {
            do {
                try keyboard.resetCapsLock()
            } catch {
                suspend(message: error.localizedDescription)
            }
        }
        indicator.setOn(isOn)
    }

    /// Disconnect/reset native Caps Lock for safe typing without cancelling the
    /// user's keep-awake request or its independently maintained indicator.
    func suspend(message: String) {
        var messages = [message]
        do {
            try keyboard.stop()
        } catch {
            messages.append(error.localizedDescription)
        }
        state = CapsLockState(
            isOn: state.isOn, message: messages.joined(separator: "\n"),
            indicatorMessage: indicator.message
        )
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
        indicator.stop()
        state = CapsLockState(
            message: messages.isEmpty ? nil : messages.joined(separator: "\n"),
            indicatorMessage: indicator.message
        )
    }

    deinit {
        // Explicit stop retains retry ownership. At destruction, the shared
        // controller must own any remaining power cleanup instead of a dead ID.
        keepAwake.abandon(request)
        try? keyboard.stop()
        indicator.stop()
    }
}
