#!/usr/bin/env swift
// Experimental macOS 26+ built-in keyboard LED probe. Not linked into Cappuccino.
import CoreGraphics
import Darwin
import Foundation
import IOKit.hidsystem

private enum LEDMode: String {
    case on = "On"
    case auto = "Auto"
}

private struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func report(_ message: String) {
    print(message)
    fflush(stdout)
}

private struct Options {
    enum Command {
        case inspect, test(Int), restore, help
    }

    let command: Command
    let dryRun: Bool
    let recover: Bool
    let simulatedResets: Int

    static let usage = """
        Usage: swift Scripts/led-probe.swift [inspect | test [seconds] | restore] [--recover] [--dry-run]

        inspect    Read-only discovery (the default); never writes the LED.
        test       Request LED On once, then restore Auto after 60 seconds by default.
                   Duration must be an integer from 1 through 300 seconds.
        restore    Restore system-managed Auto mode after an interrupted/crashed probe.
        --recover  Test only: check every 250 ms; reapply On when reported Off.
                   Stop after 8 recovery attempts, or on unreadable state/write failure.
        --dry-run  Simulate LED operations without opening a HID client.
        --simulate-resets N  Dry-run tests only: simulate 1...20 competing system resets.

        Experimental private API; macOS 26+ and built-in keyboards only.
        Quit Cappuccino and other LED tools first. Turn actual Caps Lock off.
        This never changes logical Caps Lock, reads keystrokes, or prevents sleep.
        SIGINT/SIGTERM/SIGHUP restore Auto; SIGKILL/crashes cannot guarantee cleanup.
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var dryRun = false
        var recover = false
        var simulatedResets = 0
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                guard !dryRun else { throw ProbeError(message: "Duplicate --dry-run.\n\(usage)") }
                dryRun = true
            case "--recover":
                guard !recover else { throw ProbeError(message: "Duplicate --recover.\n\(usage)") }
                recover = true
            case "--simulate-resets":
                guard simulatedResets == 0, index + 1 < arguments.count,
                      let count = Int(arguments[index + 1]), (1...20).contains(count) else {
                    throw ProbeError(message: "--simulate-resets requires 1...20.\n\(usage)")
                }
                simulatedResets = count
                index += 1
            default:
                words.append(arguments[index])
            }
            index += 1
        }
        let command: Command
        switch words.first ?? "inspect" {
        case "help", "--help", "-h":
            guard words.count == 1 else { throw ProbeError(message: usage) }
            command = .help
        case "inspect":
            guard words.count <= 1 else { throw ProbeError(message: usage) }
            command = .inspect
        case "restore":
            guard words.count == 1 else { throw ProbeError(message: usage) }
            command = .restore
        case "test":
            guard words.count <= 2,
                  let seconds = Int(words.count == 2 ? words[1] : "60"),
                  (1...300).contains(seconds) else {
                throw ProbeError(message: "Test duration must be 1...300 whole seconds.\n\(usage)")
            }
            command = .test(seconds)
        default:
            throw ProbeError(message: usage)
        }
        if recover || simulatedResets > 0 {
            guard case .test = command else {
                throw ProbeError(message: "--recover and --simulate-resets require test.\n\(usage)")
            }
        }
        guard simulatedResets == 0 || dryRun else {
            throw ProbeError(message: "--simulate-resets requires --dry-run.\n\(usage)")
        }
        return Options(
            command: command, dryRun: dryRun, recover: recover, simulatedResets: simulatedResets
        )
    }
}

private protocol LEDOutput {
    var reportedStates: [String] { get }
    func inspect()
    func apply(_ mode: LEDMode) throws
}

private struct LEDRecovery {
    static let interval: TimeInterval = 0.25
    static let maximumAttempts = 8
    private(set) var attempts = 0

    mutating func check(_ led: LEDOutput) throws {
        let states = led.reportedStates
        guard !states.isEmpty, states.allSatisfy({ $0 == "On" || $0 == "Off" }) else {
            throw ProbeError(message: "Recovery stopped: cannot read a known LED state: \(states).")
        }
        guard states.contains("Off") else { return }
        guard attempts < Self.maximumAttempts else {
            throw ProbeError(message: "Recovery limit of \(Self.maximumAttempts) attempts reached; the LED is still reported Off.")
        }
        attempts += 1
        report("LED recovery attempt \(attempts)/\(Self.maximumAttempts): reported Off; reapplying On.")
        try led.apply(.on)
    }
}

private final class BuiltInLED: LEDOutput {
    // Both the passive constructor and HIDCapsLockLED are unsupported API.
    // Resolve the constructor dynamically so a missing symbol fails cleanly.
    private typealias CreateClient = @convention(c) (
        CFAllocator?, UInt32, CFDictionary?
    ) -> Unmanaged<IOHIDEventSystemClient>?

    private let client: IOHIDEventSystemClient
    private let keyboards: [IOHIDServiceClient]
    private let ledKey = "HIDCapsLockLED" as CFString

    init() throws {
        guard #available(macOS 26, *) else {
            throw ProbeError(message: "This probe only tests the macOS 26+ built-in keyboard override.")
        }
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw ProbeError(message: "Could not load IOKit.")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "IOHIDEventSystemClientCreateWithType") else {
            throw ProbeError(message: "The passive HID client constructor is unavailable.")
        }
        let create = unsafeBitCast(symbol, to: CreateClient.self)
        // Client type 2 is passive: no keyboard event subscriptions or device seizure.
        guard let client = create(kCFAllocatorDefault, 2, nil)?.takeRetainedValue(),
              let services = IOHIDEventSystemClientCopyServices(client) else {
            throw ProbeError(message: "Could not enumerate HID services through a passive client.")
        }
        self.client = client
        var keyboards: [IOHIDServiceClient] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let pointer = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = unsafeBitCast(pointer, to: IOHIDServiceClient.self)
            // Generic Desktop / Keyboard, and positively identified as built-in.
            guard IOHIDServiceClientConformsTo(service, 0x01, 0x06) != 0,
                  let builtIn = IOHIDServiceClientCopyProperty(service, "Built-In" as CFString),
                  (builtIn as? NSNumber)?.boolValue == true else { continue }
            keyboards.append(service)
        }
        guard !keyboards.isEmpty else {
            throw ProbeError(message: "No built-in keyboard HID service is visible. No LED writes were made.")
        }
        self.keyboards = keyboards
    }

    private func reportedState(of keyboard: IOHIDServiceClient) -> String {
        guard let value = IOHIDServiceClientCopyProperty(keyboard, ledKey) else {
            return "<not exposed>"
        }
        return String(describing: value)
    }

    var reportedStates: [String] {
        keyboards.map { reportedState(of: $0) }
    }

    func inspect() {
        for (index, state) in reportedStates.enumerated() {
            // Apple's getter returns the reported LED state, not the override
            // mode: On/Off alone cannot reveal whether another tool owns it.
            report("Built-in keyboard \(index + 1): HIDCapsLockLED=\(state) (reported state)")
        }
    }

    func apply(_ mode: LEDMode) throws {
        var rejected: [Int] = []
        // Try every selected service even if one fails, especially during cleanup.
        for (index, keyboard) in keyboards.enumerated() {
            let accepted = IOHIDServiceClientSetProperty(keyboard, ledKey, mode.rawValue as CFString)
            report("Built-in keyboard \(index + 1): requested LED \(mode.rawValue); accepted=\(accepted)")
            if !accepted { rejected.append(index + 1) }
        }
        guard rejected.isEmpty else {
            throw ProbeError(message: "LED \(mode.rawValue) was rejected for service(s) \(rejected).")
        }
    }
}

private final class SimulatedLED: LEDOutput {
    private var mode = LEDMode.auto
    private var remainingResets: Int
    private var resetTimer: Timer?

    init(resets: Int) {
        remainingResets = resets
        guard resets > 0 else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.mode == .on else { return }
            self.mode = .auto
            self.remainingResets -= 1
            report("[dry run] Simulated system reset: LED Off")
            if self.remainingResets == 0 { timer.invalidate() }
        }
        resetTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    var reportedStates: [String] { [mode == .on ? "On" : "Off"] }

    func inspect() {
        report("[dry run] Simulated keyboard: HIDCapsLockLED=\(reportedStates[0]) (reported state)")
    }
    func apply(_ mode: LEDMode) {
        if mode == .auto {
            resetTimer?.invalidate()
            resetTimer = nil
        }
        self.mode = mode
        report("[dry run] requested LED \(mode.rawValue)")
    }

    deinit {
        resetTimer?.invalidate()
    }
}

private func nativeCapsLockIsOn() -> Bool {
    CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
}

private func reportNativeCapsLock() {
    report("Logical Caps Lock: \(nativeCapsLockIsOn() ? "ON" : "off") (read-only snapshot)")
}

private func runTest(seconds: Int, led: LEDOutput, dryRun: Bool, recover: Bool) throws -> Int32 {
    guard dryRun || !nativeCapsLockIsOn() else {
        throw ProbeError(message: "Actual Caps Lock is on. Turn it off before testing; no LED writes were made.")
    }

    var finished = false
    var caughtSignal: Int32?
    let previousInterrupt = signal(SIGINT, SIG_IGN)
    let previousTerminate = signal(SIGTERM, SIG_IGN)
    let previousHangup = signal(SIGHUP, SIG_IGN)
    let signalSources = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            caughtSignal = number
            finished = true
        }
        source.activate()
        return source
    }
    let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { _ in finished = true }
    RunLoop.main.add(timer, forMode: .default)

    let center = DistributedNotificationCenter.default()
    let observers = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map { name in
        center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
            report("Observed \(name). Snapshot only; no LED write from this handler.")
            led.inspect()
            if !dryRun { reportNativeCapsLock() }
        }
    }
    defer {
        timer.invalidate()
        observers.forEach { center.removeObserver($0) }
        signalSources.forEach { $0.cancel() }
        signal(SIGINT, previousInterrupt)
        signal(SIGTERM, previousTerminate)
        signal(SIGHUP, previousHangup)
    }

    var testFailure: Error?
    var recovery = LEDRecovery()
    do {
        try led.apply(.on)
        if recover {
            report("LED test started: \(seconds) seconds. Recovery checks every 250 ms; limit \(LEDRecovery.maximumAttempts) attempts.")
        } else {
            report("LED test started: \(seconds) seconds. One On request, no periodic reassertion.")
        }
        report("Lock/unlock manually. A successful API call is NOT proof the physical light changed.")
        if !dryRun { reportNativeCapsLock() }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var nextCheck = Date().addingTimeInterval(LEDRecovery.interval)
        while !finished, Date() < deadline {
            let wake = recover ? min(deadline, nextCheck) : deadline
            _ = RunLoop.main.run(mode: .default, before: wake)
            // No asynchronous recovery callback can run after we leave this loop.
            if recover, !finished, Date() < deadline, Date() >= nextCheck {
                try recovery.check(led)
                nextCheck = Date().addingTimeInterval(LEDRecovery.interval)
            }
        }
    } catch {
        testFailure = error
    }

    if recover { report("LED recovery stopped after \(recovery.attempts) attempt(s); restoring Auto.") }
    // Always attempt Auto, including after a partially accepted On request.
    do {
        try led.apply(.auto)
    } catch {
        let original = testFailure.map { " Initial error: \($0.localizedDescription)" } ?? ""
        throw ProbeError(message: """
            Could not fully restore Auto: \(error.localizedDescription).\(original)
            Run: swift Scripts/led-probe.swift restore
            """)
    }
    report("System-managed Auto requested. Confirm the physical LED returned to normal.")
    if !dryRun { reportNativeCapsLock() }
    if let testFailure { throw testFailure }
    return caughtSignal.map { 128 + $0 } ?? 0
}

private func main() throws -> Int32 {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    if case .help = options.command {
        report(Options.usage)
        return 0
    }
    report("Cappuccino LED-only probe — \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let led: LEDOutput = try options.dryRun
        ? SimulatedLED(resets: options.simulatedResets) : BuiltInLED()
    led.inspect()
    if !options.dryRun { reportNativeCapsLock() }
    switch options.command {
    case .inspect:
        report("Read-only inspection complete. Property presence/readback does not prove physical LED control.")
        return 0
    case .test(let seconds):
        return try runTest(seconds: seconds, led: led, dryRun: options.dryRun, recover: options.recover)
    case .restore:
        try led.apply(.auto)
        report("System-managed Auto requested. Confirm the physical LED returned to normal.")
        return 0
    case .help:
        return 0
    }
}

do {
    exit(try main())
} catch {
    FileHandle.standardError.write(Data("LED probe: \(error.localizedDescription)\n".utf8))
    exit(1)
}
