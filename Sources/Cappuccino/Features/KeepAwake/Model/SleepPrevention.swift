protocol SleepPrevention: AnyObject {
    /// Acquire both idle-system and idle-display prevention on success.
    /// If acquisition/rollback fails, retain handles so stop() can retry cleanup.
    func start() throws

    /// Idempotent; retain failed-to-release handles for a later retry.
    func stop() throws
}
