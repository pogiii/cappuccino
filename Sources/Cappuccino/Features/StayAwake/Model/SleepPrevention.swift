protocol SleepPrevention: AnyObject {
    /// Acquire both idle-system and idle-display sleep prevention, or neither.
    func start() throws
    func stop() throws
}
