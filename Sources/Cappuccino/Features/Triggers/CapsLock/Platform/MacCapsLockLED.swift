import Darwin
import Foundation
import IOKit.hidsystem

/// Experimental macOS 26+ LED override, independent of the native modifier.
/// Discovery is lazy: constructing an unused/duplicate app makes no HID writes.
final class MacCapsLockLED: CapsLockLED {
    struct Service {
        let isBuiltIn: Bool
        let isKeyboard: Bool
        let read: () -> String?
        let write: (String) -> Bool
    }

    private let isSupported: Bool
    private let discover: () throws -> [Service]
    private var services: [Service] = []
    private var needsRestore = false

    init(
        isSupported: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
        discover: @escaping () throws -> [Service] = MacCapsLockLED.discoverServices
    ) {
        self.isSupported = isSupported
        self.discover = discover
    }

    func turnOn() throws {
        try loadServices()
        // Even a rejected write may leave another service overridden.
        needsRestore = true
        try write("On")
    }

    func reportedStates() throws -> [CapsLockLEDState] {
        try loadServices()
        return services.map {
            switch $0.read() {
            case "On": return .on
            case "Off": return .off
            default: return .unknown
            }
        }
    }

    func restore() throws {
        try loadServices()
        needsRestore = true
        try write("Auto")
        needsRestore = false
        // Re-discover next time rather than pin stale services across sessions.
        services = []
    }

    private func loadServices() throws {
        guard isSupported else {
            throw LEDError("Independent LED control requires macOS 26 or later.")
        }
        guard services.isEmpty else { return }
        services = try discover().filter { $0.isBuiltIn && $0.isKeyboard }
        guard !services.isEmpty else {
            throw LEDError("No built-in keyboard LED service is available.")
        }
    }

    private func write(_ value: String) throws {
        var rejected: [Int] = []
        for (index, service) in services.enumerated() {
            if !service.write(value) { rejected.append(index + 1) }
        }
        guard rejected.isEmpty else {
            throw LEDError("macOS rejected LED \(value) for keyboard service(s) \(rejected).")
        }
    }

    deinit {
        if needsRestore { try? restore() }
    }

    // The constructor and HIDCapsLockLED property are private, unsupported API.
    // Resolve the symbol instead of making an unavailable API a launch failure.
    private typealias CreateClient = @convention(c) (
        CFAllocator?, UInt32, CFDictionary?
    ) -> Unmanaged<IOHIDEventSystemClient>?

    static func discoverServices() throws -> [Service] {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw LEDError("Could not load IOKit for LED control.")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "IOHIDEventSystemClientCreateWithType") else {
            throw LEDError("The passive HID client API is unavailable.")
        }
        let create = unsafeBitCast(symbol, to: CreateClient.self)
        // Passive client type 2: no keyboard event subscriptions or seizure.
        guard let client = create(kCFAllocatorDefault, 2, nil)?.takeRetainedValue(),
              let rawServices = IOHIDEventSystemClientCopyServices(client) else {
            throw LEDError("Could not discover keyboard LED services.")
        }
        var result: [Service] = []
        for index in 0..<CFArrayGetCount(rawServices) {
            guard let pointer = CFArrayGetValueAtIndex(rawServices, index) else { continue }
            let service = unsafeBitCast(pointer, to: IOHIDServiceClient.self)
            let builtIn = IOHIDServiceClientCopyProperty(service, "Built-In" as CFString)
            result.append(Service(
                isBuiltIn: (builtIn as? NSNumber)?.boolValue == true,
                isKeyboard: IOHIDServiceClientConformsTo(service, 0x01, 0x06) != 0,
                read: {
                    withExtendedLifetime(client) {
                        IOHIDServiceClientCopyProperty(service, "HIDCapsLockLED" as CFString) as? String
                    }
                },
                write: { value in
                    withExtendedLifetime(client) {
                        IOHIDServiceClientSetProperty(service, "HIDCapsLockLED" as CFString, value as CFString)
                    }
                }
            ))
        }
        return result
    }
}

private struct LEDError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
