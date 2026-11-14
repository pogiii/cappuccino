import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let screenDidLock = Notification.Name("com.apple.screenIsLocked")
    static let screenDidUnlock = Notification.Name("com.apple.screenIsUnlocked")

    private let capsLock: CapsLockTrigger
    private var statusBar: StatusBarController?
    private var reconnectTimer: Timer?
    private var sessionIsActive = true
    private var screenIsLocked = false
    private var macIsSleeping = false

    override convenience init() {
        let keepAwake = KeepAwakeController(sleep: MacSleepPrevention())
        let indicator = CapsLockLEDController(led: MacCapsLockLED())
        self.init(capsLock: CapsLockTrigger(
            keyboard: MacCapsLockKeyboard(), keepAwake: keepAwake, indicator: indicator
        ))
    }

    init(capsLock: CapsLockTrigger) {
        self.capsLock = capsLock
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

        // Screen lock need not deactivate the login session. Secure Input
        // detection in the keyboard adapter is an additional safety backstop.
        let screenCenter = DistributedNotificationCenter.default()
        screenCenter.addObserver(self, selector: #selector(pause),
                                 name: Self.screenDidLock, object: nil)
        screenCenter.addObserver(self, selector: #selector(resume),
                                 name: Self.screenDidUnlock, object: nil)

        // Secure Input may end after the unlock/activation notification. Retry
        // only when both the session and the keyboard preflight permit it.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reconnectKeyboard()
        }
        timer.tolerance = 0.1
        reconnectTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func pause(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.sessionDidResignActiveNotification:
            sessionIsActive = false
        case NSWorkspace.willSleepNotification:
            macIsSleeping = true
        case Self.screenDidLock:
            screenIsLocked = true
        default:
            return
        }
        capsLock.suspend(message: """
            Keyboard control is paused while locked, asleep, or inactive.
            Keep-awake mode is unchanged.
            """)
    }

    @objc func resume(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.sessionDidBecomeActiveNotification:
            sessionIsActive = true
        case NSWorkspace.didWakeNotification:
            macIsSleeping = false
        case Self.screenDidUnlock:
            screenIsLocked = false
        default:
            return
        }
        reconnectKeyboard()
    }

    func reconnectKeyboard() {
        guard sessionIsActive, !screenIsLocked, !macIsSleeping else { return }
        capsLock.reconnectIfAvailable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        capsLock.stop()
    }
}
