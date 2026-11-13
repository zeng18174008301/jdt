import Foundation

struct CertificationPresentationScope: Equatable, Sendable {
    let tenantID: String
    let viewerID: String
    let appID: String
    let subjectUID: String
    let sessionID: String
    let sessionGeneration: Int64
    let realtimeGeneration: Int64

    init(
        tenantID: String,
        viewerID: String,
        appID: String,
        subjectUID: String,
        sessionID: String,
        sessionGeneration: Int64,
        realtimeGeneration: Int64 = 0
    ) {
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.viewerID = viewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectUID = subjectUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionGeneration = sessionGeneration
        self.realtimeGeneration = realtimeGeneration
    }

    var isValid: Bool {
        !tenantID.isEmpty
            && !viewerID.isEmpty
            && !appID.isEmpty
            && !subjectUID.isEmpty
            && !sessionID.isEmpty
            && sessionGeneration >= 0
            && realtimeGeneration >= 0
    }
}

struct CertificationPresentationRootScope: Equatable, Hashable, Sendable {
    let tenantID: String
    let viewerID: String
    let appID: String
    let sessionID: String
    let sessionGeneration: Int64
    let realtimeGeneration: Int64

    init(
        tenantID: String,
        viewerID: String,
        appID: String,
        sessionID: String,
        sessionGeneration: Int64,
        realtimeGeneration: Int64
    ) {
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.viewerID = viewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionGeneration = sessionGeneration
        self.realtimeGeneration = realtimeGeneration
    }

    var isValid: Bool {
        !tenantID.isEmpty
            && !viewerID.isEmpty
            && !appID.isEmpty
            && !sessionID.isEmpty
            && sessionGeneration >= 0
            && realtimeGeneration >= 0
    }

    func subjectScope(exactUID: String) -> CertificationPresentationScope? {
        let uid = exactUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid, !uid.isEmpty else { return nil }
        return CertificationPresentationScope(
            tenantID: tenantID,
            viewerID: viewerID,
            appID: appID,
            subjectUID: uid,
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            realtimeGeneration: realtimeGeneration
        )
    }
}

enum CertificationProfileUIDBatch {
    static let maximumCount = 100

    static func normalizedAll(
        _ rawUIDs: some Sequence<String>
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawUID in rawUIDs {
            let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            result.append(uid)
        }
        return result
    }

    static func normalized(_ rawUIDs: some Sequence<String>) -> [String] {
        Array(normalizedAll(rawUIDs).prefix(maximumCount))
    }
}

enum CertificationProfileFetchFailureKind: Equatable, Sendable {
    case transient
    case terminal
}

struct CertificationProfileRequestFence: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading(wave: Int64, priorAttempts: Int)
        case resolved
        case negative
        case failed(attempt: Int, nextRetryAt: Date)
    }

    static let maximumAttemptsPerWave = 5
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]

    private(set) var scope: CertificationPresentationRootScope?
    private(set) var phases: [String: Phase] = [:]
    private(set) var wave: Int64 = 0

    mutating func bind(_ nextScope: CertificationPresentationRootScope?) {
        let normalized = nextScope?.isValid == true ? nextScope : nil
        guard normalized != scope else { return }
        scope = normalized
        phases.removeAll(keepingCapacity: false)
        wave &+= 1
    }

    mutating func invalidate(_ rawUIDs: some Sequence<String>) {
        for uid in CertificationProfileUIDBatch.normalizedAll(rawUIDs) {
            phases.removeValue(forKey: uid)
        }
    }

    func eligibleUIDs(
        from rawUIDs: some Sequence<String>,
        now: Date
    ) -> [String] {
        CertificationProfileUIDBatch.normalizedAll(rawUIDs).filter { uid in
            switch phases[uid] {
            case nil:
                return true
            case .failed(let attempt, let nextRetryAt):
                return attempt < Self.maximumAttemptsPerWave && now >= nextRetryAt
            case .loading, .resolved, .negative:
                return false
            }
        }
    }

    func queueableUIDs(
        from rawUIDs: some Sequence<String>
    ) -> [String] {
        CertificationProfileUIDBatch.normalizedAll(rawUIDs).filter { uid in
            switch phases[uid] {
            case nil:
                return true
            case .failed(let attempt, _):
                return attempt < Self.maximumAttemptsPerWave
            case .loading, .resolved, .negative:
                return false
            }
        }
    }

    func nextRetryDate(
        for rawUIDs: some Sequence<String>,
        now: Date
    ) -> Date? {
        var next: Date?
        for uid in CertificationProfileUIDBatch.normalizedAll(rawUIDs) {
            switch phases[uid] {
            case nil:
                return now
            case .failed(let attempt, let nextRetryAt)
                where attempt < Self.maximumAttemptsPerWave:
                next = min(next ?? nextRetryAt, nextRetryAt)
            case .loading, .resolved, .negative, .failed:
                continue
            }
        }
        return next
    }

    mutating func begin(
        exactUIDs rawUIDs: some Sequence<String>,
        now: Date
    ) -> (wave: Int64, exactUIDs: [String])? {
        let batch = CertificationProfileUIDBatch.normalized(
            eligibleUIDs(from: rawUIDs, now: now)
        )
        guard !batch.isEmpty else { return nil }
        wave &+= 1
        let requestWave = wave
        for uid in batch {
            let priorAttempts: Int
            if case .failed(let attempt, _) = phases[uid] {
                priorAttempts = attempt
            } else {
                priorAttempts = 0
            }
            phases[uid] = .loading(
                wave: requestWave,
                priorAttempts: priorAttempts
            )
        }
        return (requestWave, batch)
    }

    mutating func markResolved(
        exactUIDs rawUIDs: some Sequence<String>,
        wave requestWave: Int64
    ) {
        updateLoading(rawUIDs, wave: requestWave) { _, _ in .resolved }
    }

    mutating func markNegative(
        exactUIDs rawUIDs: some Sequence<String>,
        wave requestWave: Int64
    ) {
        updateLoading(rawUIDs, wave: requestWave) { _, _ in .negative }
    }

    @discardableResult
    mutating func markFailed(
        exactUIDs rawUIDs: some Sequence<String>,
        wave requestWave: Int64,
        kind: CertificationProfileFetchFailureKind,
        now: Date
    ) -> Set<String> {
        var retryable: Set<String> = []
        updateLoading(rawUIDs, wave: requestWave) { priorAttempts, uid in
            let attempt = kind == .terminal
                ? Self.maximumAttemptsPerWave
                : min(Self.maximumAttemptsPerWave, priorAttempts + 1)
            let nextRetryAt: Date
            if kind == .terminal || attempt >= Self.maximumAttemptsPerWave {
                nextRetryAt = .distantFuture
            } else {
                let delay = Self.retryDelays[min(
                    max(0, attempt - 1),
                    Self.retryDelays.count - 1
                )]
                nextRetryAt = now.addingTimeInterval(delay)
                retryable.insert(uid)
            }
            return .failed(attempt: attempt, nextRetryAt: nextRetryAt)
        }
        return retryable
    }

    private mutating func updateLoading(
        _ rawUIDs: some Sequence<String>,
        wave requestWave: Int64,
        transform: (_ priorAttempts: Int, _ uid: String) -> Phase
    ) {
        for uid in CertificationProfileUIDBatch.normalizedAll(rawUIDs) {
            guard case .loading(let wave, let priorAttempts) = phases[uid],
                  wave == requestWave else { continue }
            phases[uid] = transform(priorAttempts, uid)
        }
    }
}

// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
private struct CertificationProfileRequestBrokerKey: Hashable, Sendable {
    let scope: CertificationPresentationRootScope
    let exactUID: String
    let requestAuthority: IMAuthSessionFence?
}
// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

struct CertificationProfileBrokerResponse: Sendable {
    let items: [RemoteUserProfileSummary]
    let missingUIDs: [String]
    let hasMalformedCoverage: Bool
}

@MainActor
final class CertificationProfileRequestBroker {
    static let shared = CertificationProfileRequestBroker()

    private struct Entry {
        let token: UUID
        let exactUIDs: Set<String>
        let task: Task<RemoteUserProfilesResponse, Error>
    }

    private var entries: [CertificationProfileRequestBrokerKey: Entry] = [:]

    func response(
        scope: CertificationPresentationRootScope,
        exactUIDs rawUIDs: some Sequence<String>,
        requestAuthority: IMAuthSessionFence? = nil, // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
        operation: @escaping @MainActor ([String]) async throws -> RemoteUserProfilesResponse
    ) async throws -> CertificationProfileBrokerResponse {
        let exactUIDs = CertificationProfileUIDBatch.normalized(rawUIDs).sorted()
        let uncoveredUIDs = exactUIDs.filter { uid in
            entries[
                CertificationProfileRequestBrokerKey(
                    scope: scope,
                    exactUID: uid,
                    requestAuthority: requestAuthority // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
                )
            ] == nil
        }
        if !uncoveredUIDs.isEmpty {
            let token = UUID()
            let task = Task { @MainActor in
                try await operation(uncoveredUIDs)
            }
            let entry = Entry(
                token: token,
                exactUIDs: Set(uncoveredUIDs),
                task: task
            )
            for uid in uncoveredUIDs {
                entries[CertificationProfileRequestBrokerKey(
                    scope: scope,
                    exactUID: uid,
                    requestAuthority: requestAuthority // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
                )] = entry
            }
        }

        var selectedEntries: [UUID: Entry] = [:]
        for uid in exactUIDs {
            let key = CertificationProfileRequestBrokerKey(
                scope: scope,
                exactUID: uid,
                requestAuthority: requestAuthority // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
            )
            if let entry = entries[key] {
                selectedEntries[entry.token] = entry
            }
        }
        defer {
            for uid in exactUIDs {
                let key = CertificationProfileRequestBrokerKey(
                    scope: scope,
                    exactUID: uid,
                    requestAuthority: requestAuthority // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
                )
                if let entry = entries[key],
                   selectedEntries[entry.token] != nil {
                    entries.removeValue(forKey: key)
                }
            }
        }

        var items: [RemoteUserProfileSummary] = []
        var missingUIDs: [String] = []
        var hasMalformedCoverage = false
        let requestedUIDSet = Set(exactUIDs)
        for token in selectedEntries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = selectedEntries[token] else { continue }
            let response = try await entry.task.value
            let responseUIDs = Set(
                response.items.map(\.imUID) + response.missingUIDs
            )
            if responseUIDs != entry.exactUIDs {
                hasMalformedCoverage = true
            }
            items.append(contentsOf: response.items.filter {
                requestedUIDSet.contains($0.imUID)
            })
            missingUIDs.append(contentsOf: response.missingUIDs.filter {
                requestedUIDSet.contains($0)
            })
        }
        return CertificationProfileBrokerResponse(
            items: items,
            missingUIDs: missingUIDs,
            hasMalformedCoverage: hasMalformedCoverage
        )
    }
}
