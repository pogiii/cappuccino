import AppKit
import ApplicationServices

/// Keeps power truth separate from keyboard/indicator warnings.
struct StatusBarPresentation {
    let symbol: String
    let title: String
    let detail: String
    let tooltip: String
    let toggleEnabled: Bool
    let retryVisible: Bool

    init(state: CapsLockState) {
        symbol = state.isOn ? "cup.and.saucer.fill" :
            (state.isRunning ? "cup.and.saucer" : "exclamationmark.circle")
        title = state.isOn ? "Cappuccino — Keeping Mac Awake" :
            (state.isRunning ? "Cappuccino — Normal Sleep" : "Cappuccino — Not Connected")
        if state.indicatorMessage != nil {
            detail = state.message != nil
                ? "Keyboard and LED need attention — click Retry"
                : "LED needs attention — click Retry"
        } else if state.message != nil {
            detail = state.isOn ? "Keyboard paused — still keeping Mac awake" :
                "Keyboard disconnected — click Retry"
        } else {
            detail = "Caps Lock LED = stay-awake mode"
        }
        tooltip = ([title] + state.issues).joined(separator: "\n")
        toggleEnabled = state.isRunning || state.isOn
        retryVisible = !state.isRunning || state.indicatorMessage != nil
    }
}

final class StatusBarController: NSObject {
    private let capsLock: CapsLockTrigger
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let summary = NSMenuItem()
    private let detail = NSMenuItem()
    private let toggleItem = NSMenuItem(
        title: "Keep Mac Awake", action: #selector(toggle), keyEquivalent: ""
    )
    private let retryItem = NSMenuItem(
        title: "Retry Connections", action: #selector(retry), keyEquivalent: ""
    )

    init(capsLock: CapsLockTrigger) {
        self.capsLock = capsLock
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        summary.isEnabled = false
        detail.isEnabled = false
        menu.addItem(summary)
        menu.addItem(detail)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        retryItem.target = self
        menu.addItem(retryItem)
        let permission = NSMenuItem(
            title: "Allow Accessibility…", action: #selector(requestPermission), keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Cappuccino", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        capsLock.onStateChange = { [weak self] state in self?.render(state) }
        render(capsLock.state)
    }

    private func render(_ state: CapsLockState) {
        let view = StatusBarPresentation(state: state)
        item.button?.image = NSImage(systemSymbolName: view.symbol, accessibilityDescription: "Cappuccino")
        item.button?.image?.isTemplate = true
        summary.title = view.title
        detail.title = view.detail
        item.button?.toolTip = view.tooltip
        toggleItem.isEnabled = view.toggleEnabled
        toggleItem.state = state.isOn ? .on : .off
        retryItem.isHidden = !view.retryVisible
    }

    @objc private func toggle() {
        capsLock.toggle()
    }

    @objc private func retry() {
        capsLock.retry()
        let issues = capsLock.state.issues
        if !issues.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cappuccino connections need attention"
            alert.informativeText = issues.joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
