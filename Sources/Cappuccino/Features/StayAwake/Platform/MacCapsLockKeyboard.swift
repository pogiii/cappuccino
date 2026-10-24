import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hidsystem

/// Prototype strategy: leave the native Caps Lock state/LED coupled, but remove
/// its modifier from events before applications receive them. No key remapping,
/// Unicode rewriting, private LED API, or persistent system settings.
///
/// This does NOT change the global modifier state queried directly by other
/// software. Secure Input bypasses event taps, so monitoring is stopped there.
final class MacCapsLockKeyboard: KeyboardControl {
    var onCapsLockChange: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    private var connection: io_connect_t = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var safetyTimer: Timer?
    private var lastCapsLockState = false
    private var generation = 0

    func start() throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { throw KeyboardError.accessibility }
        guard !IsSecureEventInputEnabled() else { throw KeyboardError.secureInput }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != 0 else { throw KeyboardError.systemUnavailable }
        let result = IOServiceOpen(
            service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection
        )
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else {
            connection = 0
            throw KeyboardError.ioKit(result)
        }

        do {
            let mask = Self.eventTypes.reduce(CGEventMask(0)) {
                $0 | (CGEventMask(1) << $1.rawValue)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let keyboard = Unmanaged<MacCapsLockKeyboard>
                        .fromOpaque(context).takeUnretainedValue()
                    return keyboard.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                throw KeyboardError.eventTap
            }
            self.tap = tap
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                throw KeyboardError.eventTap
            }
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            // Fail closed rather than leave an illuminated Caps Lock key while
            // the input filter is unavailable. Also catches permission revocation.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.checkAvailability()
            }
            safetyTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            try? stop()
            throw error
        }
    }

    func setIndicator(isOn: Bool) throws {
        guard connection != 0 else { throw KeyboardError.systemUnavailable }
        if isOn && IsSecureEventInputEnabled() { throw KeyboardError.secureInput }
        let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), isOn)
        guard result == kIOReturnSuccess else { throw KeyboardError.ioKit(result) }
        lastCapsLockState = isOn
    }

    func stop() throws {
        generation += 1
        safetyTimer?.invalidate()
        safetyTimer = nil
        var resetResult = kIOReturnSuccess
        // Turn Caps Lock off before removing the filter. The regular key
        // behavior returns once the event tap is invalidated.
        if connection != 0 {
            resetResult = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
            IOServiceClose(connection)
            connection = 0
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        lastCapsLockState = false
        if resetResult != kIOReturnSuccess { throw KeyboardError.resetFailed(resetResult) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let eventGeneration = generation
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never invalidate the tap from inside its callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tap != nil, self.generation == eventGeneration else { return }
                self.onFailure?(KeyboardError.interrupted)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let isOn = event.flags.contains(.maskAlphaShift)
            if isOn != lastCapsLockState {
                lastCapsLockState = isOn
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.tap != nil, self.generation == eventGeneration else { return }
                    self.onCapsLockChange?(isOn)
                }
            }
        }

        Self.removeCapsLock(from: event)
        return Unmanaged.passUnretained(event)
    }

    /// Preserve Shift, Option, shortcuts, layouts, and text; never lowercase
    /// Unicode strings, which would break intentional uppercase and input methods.
    static func removeCapsLock(from event: CGEvent) {
        event.flags.remove(.maskAlphaShift)
    }

    private func checkAvailability() {
        if IsSecureEventInputEnabled() {
            onFailure?(KeyboardError.secureInput)
        } else if !AXIsProcessTrusted() {
            onFailure?(KeyboardError.accessibility)
        } else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            onFailure?(KeyboardError.interrupted)
        }
    }

    // Strip the modifier from pointer events too: apps may read it on clicks.
    private static let eventTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged,
        .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged
    ]

    deinit {
        try? stop()
    }
}

private enum KeyboardError: LocalizedError {
    case accessibility, secureInput, systemUnavailable, eventTap, interrupted
    case ioKit(IOReturn), resetFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .accessibility:
            return "Allow Cappuccino in System Settings → Privacy & Security → Accessibility, then retry."
        case .secureInput:
            return "Paused for Secure Input (for example, a password field). Leave that field, then retry."
        case .systemUnavailable:
            return "The macOS keyboard service is unavailable."
        case .eventTap:
            return "Could not filter keyboard events. Check Accessibility permission, then quit and reopen Cappuccino."
        case .interrupted:
            return "macOS interrupted the keyboard filter. Stay-awake mode has stopped. Retry to reconnect."
        case .ioKit(let code):
            return "Could not set Caps Lock and its LED (IOKit \(code))."
        case .resetFailed(let code):
            return "Could not turn Caps Lock off (IOKit \(code)). Quit Cappuccino and check Caps Lock before typing."
        }
    }
}
