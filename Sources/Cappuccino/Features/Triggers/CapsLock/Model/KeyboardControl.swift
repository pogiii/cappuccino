/// Implementations deliver callbacks on the same thread as the trigger.
protocol KeyboardControl: AnyObject {
    /// One deduplicated physical action, not an assignment from native Caps Lock.
    var onToggle: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    /// Cheap preflight for automatic retries; start() still checks and can fail.
    var canConnect: Bool { get }

    func start() throws
    func resetCapsLock() throws
    func stop() throws
}
