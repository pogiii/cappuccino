import AppKit
import ApplicationServices

final class StatusBarController: NSObject {
    private let controller: AwakeController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let summary = NSMenuItem()
    private let detail = NSMenuItem()
    private let toggleItem = NSMenuItem(
        title: "Keep Mac Awake", action: #selector(toggle), keyEquivalent: ""
    )
    private let retryItem = NSMenuItem(
        title: "Retry Keyboard Connection", action: #selector(retry), keyEquivalent: ""
    )

    init(controller: AwakeController) {
        self.controller = controller
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

        controller.onStateChange = { [weak self] state in self?.render(state) }
        render(controller.state)
    }

    private func render(_ state: AwakeState) {
        let symbol = !state.isRunning ? "exclamationmark.circle" :
            (state.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cappuccino")
        item.button?.image?.isTemplate = true
        let title = !state.isRunning ? "Cappuccino — Not Connected" :
            (state.isAwake ? "Cappuccino — Keeping Mac Awake" : "Cappuccino — Normal Sleep")
        summary.title = title
        detail.title = state.message == nil
            ? "Caps Lock LED = stay-awake mode"
            : "Connection issue — click Retry for details"
        item.button?.toolTip = state.message.map { "\(title)\n\($0)" } ?? title
        toggleItem.isEnabled = state.isRunning
        toggleItem.state = state.isAwake ? .on : .off
        retryItem.isHidden = state.isRunning
    }

    @objc private func toggle() {
        controller.toggle()
    }

    @objc private func retry() {
        controller.start()
        if let message = controller.state.message {
            let alert = NSAlert()
            alert.messageText = "Cappuccino could not connect"
            alert.informativeText = message
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
