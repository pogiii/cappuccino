/// Implementations deliver callbacks on the same thread as the controller.
protocol KeyboardControl: AnyObject {
    var onCapsLockChange: ((Bool) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func start() throws
    func setIndicator(isOn: Bool) throws
    func stop() throws
}
