import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capsLock: CapsLockTrigger
    private var statusBar: StatusBarController?

    override init() {
        let keepAwake = KeepAwakeController(sleep: MacSleepPrevention())
        capsLock = CapsLockTrigger(keyboard: MacCapsLockKeyboard(), keepAwake: keepAwake)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid multiple instances fighting over the LED and power assertions.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusBar = StatusBarController(capsLock: capsLock)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(pause),
                           name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(pause),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(resume),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume),
                           name: NSWorkspace.didWakeNotification, object: nil)
        capsLock.start()
    }

    @objc private func pause(_ notification: Notification) {
        capsLock.stop(message: "Paused while the Mac sleeps or your session is inactive.")
    }

    @objc private func resume(_ notification: Notification) {
        capsLock.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        capsLock.stop()
    }
}
