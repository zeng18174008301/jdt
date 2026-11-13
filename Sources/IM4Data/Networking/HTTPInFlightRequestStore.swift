// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
import Foundation

// WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_BEGIN
public struct HTTPInFlightTaskClaim<Value: Sendable>: Sendable {
    public let task: Task<Value, Error>
    fileprivate let registration: Registration?

    fileprivate final class Registration: Sendable {
        let key: String
        let task: Task<Value, Error>

        init(key: String, task: Task<Value, Error>) {
            self.key = key
            self.task = task
        }
    }
}

@MainActor
public final class HTTPInFlightRequestStore<Value: Sendable> {
    public init() {}

    private var registrationsByKey: [String: HTTPInFlightTaskClaim<Value>.Registration] = [:]

    var registeredTaskCount: Int {
        registrationsByKey.count
    }

    public func task(for key: String?, create: () -> Task<Value, Error>) -> HTTPInFlightTaskClaim<Value> {
        guard let key, !key.isEmpty else {
            return HTTPInFlightTaskClaim(task: create(), registration: nil)
        }
        if let existing = registrationsByKey[key] {
            return HTTPInFlightTaskClaim(task: existing.task, registration: nil)
        }
        let registration = HTTPInFlightTaskClaim<Value>.Registration(key: key, task: create())
        registrationsByKey[key] = registration
        return HTTPInFlightTaskClaim(task: registration.task, registration: registration)
    }

    public func finish(_ claim: HTTPInFlightTaskClaim<Value>) {
        guard let registration = claim.registration,
              registrationsByKey[registration.key] === registration else { return }
        registrationsByKey[registration.key] = nil
    }

    public func reset() {
        registrationsByKey.removeAll()
    }
}
// WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_END
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END
