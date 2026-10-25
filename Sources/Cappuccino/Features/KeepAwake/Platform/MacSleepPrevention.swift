import Foundation
import IOKit.pwr_mgt

final class MacSleepPrevention: SleepPrevention {
    private var assertions: [IOPMAssertionID] = []

    func start() throws {
        guard assertions.isEmpty else { return }
        do {
            for type in [kIOPMAssertionTypePreventUserIdleSystemSleep,
                         kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    type as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Cappuccino: Keep Awake" as CFString,
                    &id
                )
                guard result == kIOReturnSuccess else {
                    throw PowerError(operation: "create sleep assertion", code: result)
                }
                assertions.append(id)
            }
        } catch {
            // Keep any failed-to-release IDs so stop() can retry them.
            try stop()
            throw error
        }
    }

    func stop() throws {
        var remaining: [IOPMAssertionID] = []
        var failure: PowerError?
        for id in assertions {
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess {
                remaining.append(id)
                failure = PowerError(operation: "release sleep assertion", code: result)
            }
        }
        assertions = remaining
        if let failure { throw failure }
    }

    deinit {
        try? stop()
    }
}

private struct PowerError: LocalizedError {
    let operation: String
    let code: IOReturn

    var errorDescription: String? {
        "Could not \(operation) (IOKit \(code)). Quit Cappuccino to release its power assertions."
    }
}
