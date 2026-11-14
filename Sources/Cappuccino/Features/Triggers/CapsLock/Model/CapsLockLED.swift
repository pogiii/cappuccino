enum CapsLockLEDState: Equatable {
    case on, off, unknown
}

/// LED output only. Implementations must never enable native Caps Lock.
protocol CapsLockLED: AnyObject {
    /// May partially succeed; retain handles so restore() can clean up.
    func turnOn() throws
    func reportedStates() throws -> [CapsLockLEDState]

    /// Explicitly return ownership to macOS, even after a failed turnOn().
    /// Failed cleanup must remain retryable.
    func restore() throws
}
