import Foundation

/// Aggregates independent requests without knowing which triggers create them.
/// All calls are serialized by the app's main run loop.
final class KeepAwakeController {
    struct RequestID: Hashable {
        private let value = UUID()
    }

    private let sleep: SleepPrevention
    private var requests: Set<RequestID> = []
    private var failure: Error?

    /// A failed power transition is not reported as successful sleep prevention.
    var isAwake: Bool { !requests.isEmpty && failure == nil }

    init(sleep: SleepPrevention) {
        self.sleep = sleep
    }

    func acquire(_ request: RequestID) throws {
        // Retry cleanup through release before accepting more work. The adapter
        // may have only partially acquired or released its power assertions.
        if let failure { throw failure }
        guard !requests.contains(request) else { return }
        if requests.isEmpty {
            do {
                try sleep.start()
            } catch {
                failure = error
                throw error
            }
        }
        requests.insert(request)
    }

    func release(_ request: RequestID) throws {
        // After a failed first acquisition or owner abandonment there may be no
        // committed request, but the adapter may still need cleanup.
        guard requests.contains(request) || (requests.isEmpty && failure != nil) else { return }
        if requests.count <= 1 {
            do {
                try sleep.stop()
            } catch {
                failure = error
                throw error
            }
            failure = nil
        }
        requests.remove(request)
    }

    /// Only for owner destruction: transfer any failed cleanup to this controller.
    /// With no requests left, release can retry it without the abandoned ID.
    func abandon(_ request: RequestID) {
        try? release(request)
        requests.remove(request)
    }
}
