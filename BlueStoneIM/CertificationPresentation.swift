import Foundation

let certificationPresentationStyleToken = "tenant_certified_v1"
let certificationPresentationAccessiblePrefix = "由本企业认证"

enum CertificationPillPlacement: String, Equatable, Sendable {
    case afterName = "after_name"
    case belowName = "below_name"
}

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

private struct CertificationProfileRequestBrokerKey: Hashable, Sendable {
    let scope: CertificationPresentationRootScope
    let exactUID: String
}

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
        operation: @escaping @MainActor ([String]) async throws -> RemoteUserProfilesResponse
    ) async throws -> CertificationProfileBrokerResponse {
        let exactUIDs = CertificationProfileUIDBatch.normalized(rawUIDs).sorted()
        let uncoveredUIDs = exactUIDs.filter { uid in
            entries[
                CertificationProfileRequestBrokerKey(
                    scope: scope,
                    exactUID: uid
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
                    exactUID: uid
                )] = entry
            }
        }

        var selectedEntries: [UUID: Entry] = [:]
        for uid in exactUIDs {
            let key = CertificationProfileRequestBrokerKey(
                scope: scope,
                exactUID: uid
            )
            if let entry = entries[key] {
                selectedEntries[entry.token] = entry
            }
        }
        defer {
            for uid in exactUIDs {
                let key = CertificationProfileRequestBrokerKey(
                    scope: scope,
                    exactUID: uid
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

struct CertificationPresentation: Equatable, Sendable {
    let visibleLabel: String
    let accessibilityLabel: String
    let styleToken: String
    let revision: Int64
    let generation: Int64

    init?(
        certification: UserSummaryV2.Certification,
        generation: Int64
    ) {
        let normalizedLabel = certification.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard certification.verified,
              certification.style == certificationPresentationStyleToken,
              certification.revision > 0,
              generation > 0,
              certificationPresentationLabelIsSafe(normalizedLabel) else {
            return nil
        }
        visibleLabel = normalizedLabel
        accessibilityLabel = "\(certificationPresentationAccessiblePrefix)：\(normalizedLabel)"
        styleToken = certificationPresentationStyleToken
        revision = certification.revision
        self.generation = generation
    }

    var avatarDecoration: IdentityPresentationDecoration {
        IdentityPresentationDecoration(
            slot: .avatarLowerRight,
            value: "shield-check:\(styleToken)",
            accessibilityLabel: accessibilityLabel
        )
    }

    func pillDecoration(
        compact: Bool
    ) -> (decoration: IdentityPresentationDecoration, placement: CertificationPillPlacement) {
        (
            IdentityPresentationDecoration(
                slot: .afterNameCertificationPill,
                value: visibleLabel,
                accessibilityLabel: accessibilityLabel
            ),
            compact ? .belowName : .afterName
        )
    }

    var identityDecorations: [IdentityPresentationDecoration] {
        [
            avatarDecoration,
            pillDecoration(compact: false).decoration
        ]
    }
}

enum CertificationPresentationFenceOutcome: String, Equatable, Sendable {
    case applied
    case cleared
    case idempotent
    case ignoredStale = "ignored_stale"
    case ignoredForeign = "ignored_foreign"
    case invalidated
    case purged
    case purgedForRefetch = "purged_for_refetch"
}

struct CertificationPresentationState: Equatable, Sendable {
    private(set) var scope: CertificationPresentationScope?
    private(set) var generation: Int64
    private(set) var revision: Int64
    private(set) var presentation: CertificationPresentation?
    private(set) var authoritativeClear: Bool
    private(set) var needsRefetch: Bool

    init(scope: CertificationPresentationScope?) {
        self.scope = scope?.isValid == true ? scope : nil
        generation = 0
        revision = 0
        presentation = nil
        authoritativeClear = false
        needsRefetch = false
    }

    mutating func setScope(
        _ nextScope: CertificationPresentationScope?
    ) -> CertificationPresentationFenceOutcome {
        let normalized = nextScope?.isValid == true ? nextScope : nil
        guard normalized != scope else {
            return .idempotent
        }
        scope = normalized
        generation = 0
        revision = 0
        presentation = nil
        authoritativeClear = false
        needsRefetch = false
        return normalized == nil ? .purged : .cleared
    }

    mutating func apply(
        summary: UserSummaryV2,
        responseScope: CertificationPresentationScope,
        subjectTenantID: String,
        fresh: Bool
    ) -> CertificationPresentationFenceOutcome {
        guard let scope, scope == responseScope else {
            return .ignoredForeign
        }
        guard scope.isValid,
              fresh,
              subjectTenantID.trimmingCharacters(in: .whitespacesAndNewlines) == scope.tenantID,
              summary.imUID == scope.subjectUID,
              let incomingGeneration = summary.generations.certification,
              incomingGeneration >= 0 else {
            return purgeForRefetch(
                generation: summary.generations.certification ?? generation,
                revision: revision
            )
        }
        let incomingPresentation: CertificationPresentation?
        if let certification = summary.certification {
            guard let value = CertificationPresentation(
                certification: certification,
                generation: incomingGeneration
            ) else {
                return purgeForRefetch(
                    generation: incomingGeneration,
                    revision: max(revision, certification.revision)
                )
            }
            incomingPresentation = value
        } else {
            incomingPresentation = nil
        }
        let incomingRevision = incomingPresentation?.revision ?? revision
        if generation > 0 && incomingGeneration < generation {
            return .ignoredStale
        }
        if generation > 0 && incomingGeneration > generation + 1 {
            return purgeForRefetch(
                generation: incomingGeneration,
                revision: max(revision, incomingRevision)
            )
        }
        if incomingGeneration == generation {
            if presentation == nil && authoritativeClear &&
                incomingPresentation != nil {
                return .ignoredStale
            }
            if incomingRevision < revision {
                return .ignoredStale
            }
            if incomingPresentation == nil {
                presentation = nil
                authoritativeClear = true
                needsRefetch = false
                return .cleared
            }
            if needsRefetch && !authoritativeClear {
                presentation = incomingPresentation
                revision = max(revision, incomingRevision)
                authoritativeClear = false
                needsRefetch = false
                return .applied
            }
            if incomingRevision == revision && presentation != nil {
                return .idempotent
            }
            if incomingRevision == revision {
                return .ignoredStale
            }
            return purgeForRefetch(
                generation: incomingGeneration,
                revision: incomingRevision
            )
        }
        if incomingPresentation != nil, generation > 0, incomingRevision <= revision {
            return purgeForRefetch(
                generation: incomingGeneration,
                revision: revision
            )
        }
        generation = incomingGeneration
        revision = max(revision, incomingRevision)
        presentation = incomingPresentation
        authoritativeClear = incomingPresentation == nil
        needsRefetch = false
        return incomingPresentation == nil ? .cleared : .applied
    }

    mutating func invalidate(
        generation incomingGeneration: Int64,
        revision incomingRevision: Int64? = nil
    ) -> CertificationPresentationFenceOutcome {
        guard incomingGeneration > 0,
              incomingRevision.map({ $0 > 0 }) ?? true else {
            return purgeForRefetch(generation: generation, revision: revision)
        }
        if incomingGeneration < generation {
            return .ignoredStale
        }
        if incomingGeneration == generation {
            guard let incomingRevision else {
                return .idempotent
            }
            if incomingRevision < revision {
                return .ignoredStale
            }
            if incomingRevision == revision {
                return .idempotent
            }
        }
        generation = incomingGeneration
        revision = max(revision, incomingRevision ?? revision)
        authoritativeClear = false
        needsRefetch = true
        return .invalidated
    }

    mutating func applyAuthoritativeMissing(
        responseScope: CertificationPresentationScope,
        fresh: Bool
    ) -> CertificationPresentationFenceOutcome {
        guard let scope, scope == responseScope else {
            return .ignoredForeign
        }
        guard scope.isValid, fresh else {
            return purgeForRefetch(generation: generation, revision: revision)
        }
        if presentation == nil, authoritativeClear, !needsRefetch {
            return .idempotent
        }
        presentation = nil
        authoritativeClear = true
        needsRefetch = false
        return .cleared
    }

    mutating func markMalformedForRefetch() -> CertificationPresentationFenceOutcome {
        purgeForRefetch(generation: generation, revision: revision)
    }

    mutating func clear(
        dropScope: Bool = false,
        resetFence: Bool = false
    ) -> CertificationPresentationFenceOutcome {
        if dropScope {
            scope = nil
        }
        if resetFence {
            generation = 0
            revision = 0
        }
        presentation = nil
        authoritativeClear = false
        needsRefetch = false
        return .purged
    }

    private mutating func purgeForRefetch(
        generation incomingGeneration: Int64,
        revision incomingRevision: Int64
    ) -> CertificationPresentationFenceOutcome {
        let nextGeneration = max(generation, max(0, incomingGeneration))
        let nextRevision = max(revision, max(0, incomingRevision))
        if generation == nextGeneration,
           revision == nextRevision,
           needsRefetch {
            return .idempotent
        }
        generation = nextGeneration
        revision = nextRevision
        needsRefetch = true
        return .purgedForRefetch
    }
}

struct CertificationIdentityRoot: Equatable, Sendable {
    private(set) var scope: CertificationPresentationRootScope?
    private(set) var subjectStates: [String: CertificationPresentationState]

    init(scope: CertificationPresentationRootScope? = nil) {
        self.scope = scope?.isValid == true ? scope : nil
        subjectStates = [:]
    }

    var exactUIDs: [String] {
        subjectStates.keys.sorted()
    }

    mutating func bind(
        _ nextScope: CertificationPresentationRootScope?
    ) -> CertificationPresentationFenceOutcome {
        let normalized = nextScope?.isValid == true ? nextScope : nil
        guard normalized != scope else { return .idempotent }
        scope = normalized
        subjectStates.removeAll(keepingCapacity: false)
        return normalized == nil ? .purged : .cleared
    }

    func presentation(forExactUID rawUID: String) -> CertificationPresentation? {
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty,
              let expectedScope = scope?.subjectScope(exactUID: uid),
              let state = subjectStates[uid],
              state.scope == expectedScope else {
            return nil
        }
        return state.presentation
    }

    func state(forExactUID rawUID: String) -> CertificationPresentationState? {
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return nil }
        return subjectStates[uid]
    }

    mutating func apply(
        summary: UserSummaryV2,
        subjectTenantID: String,
        responseScope: CertificationPresentationRootScope,
        fresh: Bool
    ) -> CertificationPresentationFenceOutcome {
        guard scope == responseScope,
              let subjectScope = responseScope.subjectScope(exactUID: summary.imUID) else {
            return .ignoredForeign
        }
        var state = subjectStates[summary.imUID]
            ?? CertificationPresentationState(scope: subjectScope)
        _ = state.setScope(subjectScope)
        let outcome = state.apply(
            summary: summary,
            responseScope: subjectScope,
            subjectTenantID: subjectTenantID,
            fresh: fresh
        )
        if subjectStates[summary.imUID] != state {
            subjectStates[summary.imUID] = state
        }
        return outcome
    }

    mutating func applyAuthoritativeMissing(
        exactUID rawUID: String,
        responseScope: CertificationPresentationRootScope,
        fresh: Bool
    ) -> CertificationPresentationFenceOutcome {
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope == responseScope,
              let subjectScope = responseScope.subjectScope(exactUID: uid) else {
            return .ignoredForeign
        }
        var state = subjectStates[uid]
            ?? CertificationPresentationState(scope: subjectScope)
        _ = state.setScope(subjectScope)
        let outcome = state.applyAuthoritativeMissing(
            responseScope: subjectScope,
            fresh: fresh
        )
        if subjectStates[uid] != state {
            subjectStates[uid] = state
        }
        return outcome
    }

    mutating func invalidate(
        exactUID rawUID: String,
        tenantID rawTenantID: String,
        generation: Int64,
        revision: Int64
    ) -> CertificationPresentationFenceOutcome {
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope,
              tenantID == scope.tenantID,
              let subjectScope = scope.subjectScope(exactUID: uid) else {
            return .ignoredForeign
        }
        var state = subjectStates[uid]
            ?? CertificationPresentationState(scope: subjectScope)
        _ = state.setScope(subjectScope)
        let outcome = state.invalidate(
            generation: generation,
            revision: revision
        )
        if subjectStates[uid] != state {
            subjectStates[uid] = state
        }
        return outcome
    }

    mutating func markMalformedForRefetch(
        exactUIDs rawUIDs: some Sequence<String>
    ) -> Bool {
        guard let scope else { return false }
        var changed = false
        for uid in CertificationProfileUIDBatch.normalizedAll(rawUIDs) {
            guard let subjectScope = scope.subjectScope(exactUID: uid) else { continue }
            var state = subjectStates[uid]
                ?? CertificationPresentationState(scope: subjectScope)
            _ = state.setScope(subjectScope)
            _ = state.markMalformedForRefetch()
            if subjectStates[uid] != state {
                subjectStates[uid] = state
                changed = true
            }
        }
        return changed
    }

    mutating func purge() {
        scope = nil
        subjectStates.removeAll(keepingCapacity: false)
    }
}

private func certificationPresentationLabelIsSafe(_ value: String) -> Bool {
    guard !value.isEmpty, value.unicodeScalars.count <= 16 else {
        return false
    }
    let forbiddenScalars: Set<UInt32> = [
        0x061c, 0x200e, 0x200f, 0x2028, 0x2029,
        0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
        0x2066, 0x2067, 0x2068, 0x2069
    ]
    return value.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0)
            && !forbiddenScalars.contains($0.value)
    }
}
