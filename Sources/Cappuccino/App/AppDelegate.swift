import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AwakeController(
        keyboard: MacCapsLockKeyboard(), sleep: MacSleepPrevention()
    )
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid multiple instances fighting over the LED and power assertions.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusBar = StatusBarController(controller: controller)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(pause),
                           name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(pause),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(resume),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume),
                           name: NSWorkspace.didWakeNotification, object: nil)
        controller.start()
    }

    @objc private func pause(_ notification: Notification) {
        controller.stop(message: "Paused while the Mac sleeps or your session is inactive.")
    }

    @objc private func resume(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        controller.stop()
    }
}
