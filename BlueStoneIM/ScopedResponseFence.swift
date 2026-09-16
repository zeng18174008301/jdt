import Foundation

enum ScopedGenerationFamily: String, Codable, CaseIterable, Sendable {
    case tenantPolicy = "tenant_policy"
    case identity
    case certification
    case groupMembership = "group_membership"
    case groupSettings = "group_settings"
    case analytics
}

struct ScopedResponseScope: Equatable, Sendable {
    let tenantID: String
    let viewerID: String
    let appID: String
    let featureKey: String
    let subjectType: String
    let subjectID: String
    let sessionID: String
    let sessionGeneration: Int64
    let capabilityFingerprint: String

    init(
        tenantID: String,
        viewerID: String,
        appID: String,
        featureKey: String,
        subjectType: String,
        subjectID: String,
        sessionID: String,
        sessionGeneration: Int64,
        capabilityFingerprint: String
    ) {
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.viewerID = viewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.featureKey = featureKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectType = subjectType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectID = subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionGeneration = sessionGeneration
        self.capabilityFingerprint = capabilityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !tenantID.isEmpty
            && !viewerID.isEmpty
            && !appID.isEmpty
            && !featureKey.isEmpty
            && !subjectType.isEmpty
            && !subjectID.isEmpty
            && !sessionID.isEmpty
            && sessionGeneration >= 0
            && !capabilityFingerprint.isEmpty
    }
}

struct ScopedResponseVersion: Equatable, Sendable {
    static let currentContractVersion = 1

    let contractVersion: Int
    let revision: Int64
    let familyGenerations: [ScopedGenerationFamily: Int64]
    let requestSequence: Int64

    init(
        contractVersion: Int = ScopedResponseVersion.currentContractVersion,
        revision: Int64,
        familyGenerations: [ScopedGenerationFamily: Int64],
        requestSequence: Int64
    ) {
        self.contractVersion = contractVersion
        self.revision = revision
        self.familyGenerations = familyGenerations
        self.requestSequence = requestSequence
    }

    var isValid: Bool {
        contractVersion == Self.currentContractVersion
            && revision >= 0
            && requestSequence >= 0
            && familyGenerations.values.allSatisfy { $0 >= 0 }
    }
}

struct ScopedResponseCheckpoint: Equatable, Sendable {
    let scope: ScopedResponseScope
    let version: ScopedResponseVersion
}

enum ScopedResponseFenceOutcome: Equatable, Sendable {
    case apply(ScopedResponseCheckpoint)
    case ignoreIdempotent
    case ignoreStale
    case ignoreInactiveRequest
    case ignoreForeign
    case purge
    case purgeAndRefetch
}

enum ScopedResponseFence {
    static func evaluate(
        current: ScopedResponseCheckpoint?,
        activeScope: ScopedResponseScope?,
        activeRequestSequence: Int64,
        incoming: ScopedResponseCheckpoint
    ) -> ScopedResponseFenceOutcome {
        guard let activeScope else {
            return .purge
        }
        guard activeScope.isValid else {
            return .purgeAndRefetch
        }
        guard activeRequestSequence >= 0 else {
            return .purgeAndRefetch
        }
        if let current {
            guard current.scope == activeScope, current.version.isValid else {
                return .purgeAndRefetch
            }
        }
        guard incoming.scope == activeScope else {
            return .ignoreForeign
        }
        guard incoming.version.isValid else {
            return .purgeAndRefetch
        }
        guard incoming.version.requestSequence == activeRequestSequence else {
            return .ignoreInactiveRequest
        }
        guard let current else {
            return .apply(incoming)
        }
        if incoming.version.requestSequence < current.version.requestSequence {
            return .ignoreStale
        }
        if incoming.version.revision < current.version.revision {
            return .ignoreStale
        }

        var newerFamily = false
        for (family, incomingGeneration) in incoming.version.familyGenerations {
            guard let currentGeneration = current.version.familyGenerations[family] else {
                newerFamily = true
                continue
            }
            if incomingGeneration < currentGeneration {
                return .ignoreStale
            }
            if incomingGeneration > currentGeneration + 1 {
                return .purgeAndRefetch
            }
            if incomingGeneration > currentGeneration {
                newerFamily = true
            }
        }

        if incoming.version.revision > current.version.revision || newerFamily {
            var mergedGenerations = current.version.familyGenerations
            incoming.version.familyGenerations.forEach {
                mergedGenerations[$0.key] = $0.value
            }
            return .apply(
                ScopedResponseCheckpoint(
                    scope: incoming.scope,
                    version: ScopedResponseVersion(
                        contractVersion: incoming.version.contractVersion,
                        revision: incoming.version.revision,
                        familyGenerations: mergedGenerations,
                        requestSequence: incoming.version.requestSequence
                    )
                )
            )
        }
        return .ignoreIdempotent
    }

    static func reducing(
        current: ScopedResponseCheckpoint?,
        activeScope: ScopedResponseScope?,
        activeRequestSequence: Int64,
        incoming: ScopedResponseCheckpoint
    ) -> (ScopedResponseCheckpoint?, ScopedResponseFenceOutcome) {
        let outcome = evaluate(
            current: current,
            activeScope: activeScope,
            activeRequestSequence: activeRequestSequence,
            incoming: incoming
        )
        switch outcome {
        case .apply(let checkpoint):
            return (checkpoint, outcome)
        case .purge, .purgeAndRefetch:
            return (nil, outcome)
        case .ignoreIdempotent, .ignoreStale, .ignoreInactiveRequest, .ignoreForeign:
            return (current, outcome)
        }
    }
}

struct CurrentProfileAuthorityScope: Codable, Equatable, Sendable {
    let tenantID: String
    let actorIMUID: String
    let appID: String

    init?(tenantID: String, actorIMUID: String, appID: String) {
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActorIMUID = actorIMUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTenantID.isEmpty,
              !normalizedActorIMUID.isEmpty,
              !normalizedAppID.isEmpty else {
            return nil
        }
        self.tenantID = normalizedTenantID
        self.actorIMUID = normalizedActorIMUID
        self.appID = normalizedAppID
    }
}

struct CurrentProfileAuthorityRequest: Equatable, Sendable {
    let scope: CurrentProfileAuthorityScope
    let mutationEpoch: Int64
    let allowsLegacyAcknowledgement: Bool
}

struct CurrentProfileAuthoritySnapshot: Equatable, Sendable {
    let tenantID: String
    let imUID: String
    let appID: String
    let userRevision: Int64?
    let identityGeneration: Int64?
    let nickname: String
    let avatar: String

    init(
        tenantID: String,
        imUID: String,
        appID: String,
        userRevision: Int64?,
        identityGeneration: Int64?,
        nickname: String,
        avatar: String
    ) {
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userRevision = userRevision
        self.identityGeneration = identityGeneration
        self.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isVersioned: Bool {
        userRevision != nil || identityGeneration != nil
    }
}

struct CurrentProfileAuthorityCheckpoint: Codable, Equatable, Sendable {
    let scope: CurrentProfileAuthorityScope
    let userRevision: Int64
    let identityGeneration: Int64
    let nickname: String
    let avatar: String

    init(
        scope: CurrentProfileAuthorityScope,
        userRevision: Int64,
        identityGeneration: Int64,
        nickname: String,
        avatar: String
    ) {
        self.scope = scope
        self.userRevision = userRevision
        self.identityGeneration = identityGeneration
        self.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CurrentProfileAuthorityDecision: Equatable, Sendable {
    case acceptVersioned(CurrentProfileAuthorityCheckpoint)
    case acceptLegacy
    case rejectPreMutationResponse
    case rejectScopeMismatch
    case rejectMalformed
    case rejectDowngrade
    case rejectRevisionConflict
    case rejectLegacyAfterMutation
}

struct CurrentProfileAuthorityFence: Equatable, Sendable {
    private(set) var mutationEpoch: Int64 = 0
    private(set) var checkpoint: CurrentProfileAuthorityCheckpoint?

    mutating func reconcileScope(_ scope: CurrentProfileAuthorityScope?) {
        guard checkpoint?.scope != scope else { return }
        mutationEpoch = 0
        checkpoint = nil
    }

    mutating func hydrate(_ restored: CurrentProfileAuthorityCheckpoint?, for scope: CurrentProfileAuthorityScope?) {
        mutationEpoch = 0
        guard let restored, restored.scope == scope else {
            checkpoint = nil
            return
        }
        checkpoint = restored
    }

    mutating func beginRead(scope: CurrentProfileAuthorityScope) -> CurrentProfileAuthorityRequest {
        CurrentProfileAuthorityRequest(
            scope: scope,
            mutationEpoch: mutationEpoch,
            allowsLegacyAcknowledgement: false
        )
    }

    mutating func beginMutation(scope: CurrentProfileAuthorityScope) -> CurrentProfileAuthorityRequest {
        mutationEpoch &+= 1
        return CurrentProfileAuthorityRequest(
            scope: scope,
            mutationEpoch: mutationEpoch,
            allowsLegacyAcknowledgement: true
        )
    }

    mutating func consume(
        _ snapshot: CurrentProfileAuthoritySnapshot,
        request: CurrentProfileAuthorityRequest
    ) -> CurrentProfileAuthorityDecision {
        guard request.mutationEpoch == mutationEpoch else {
            return .rejectPreMutationResponse
        }
        let normalizedAppID = snapshot.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (snapshot.tenantID.isEmpty || snapshot.tenantID == request.scope.tenantID),
              snapshot.imUID == request.scope.actorIMUID,
              (normalizedAppID.isEmpty || normalizedAppID == request.scope.appID) else {
            return .rejectScopeMismatch
        }
        let hasRevision = snapshot.userRevision != nil
        let hasGeneration = snapshot.identityGeneration != nil
        guard hasRevision == hasGeneration else {
            return .rejectMalformed
        }
        guard let userRevision = snapshot.userRevision,
              let identityGeneration = snapshot.identityGeneration else {
            guard checkpoint == nil else {
                return .rejectLegacyAfterMutation
            }
            guard mutationEpoch == 0 || request.allowsLegacyAcknowledgement else {
                return .rejectLegacyAfterMutation
            }
            return .acceptLegacy
        }
        guard !snapshot.tenantID.isEmpty,
              userRevision >= 0,
              identityGeneration >= 0 else {
            return .rejectMalformed
        }
        if let checkpoint {
            guard checkpoint.scope == request.scope else {
                self.checkpoint = nil
                return .rejectScopeMismatch
            }
            guard userRevision >= checkpoint.userRevision,
                  identityGeneration >= checkpoint.identityGeneration else {
                return .rejectDowngrade
            }
            if userRevision == checkpoint.userRevision,
               (snapshot.nickname != checkpoint.nickname || snapshot.avatar != checkpoint.avatar) {
                return .rejectRevisionConflict
            }
        }
        let next = CurrentProfileAuthorityCheckpoint(
            scope: request.scope,
            userRevision: userRevision,
            identityGeneration: identityGeneration,
            nickname: snapshot.nickname,
            avatar: snapshot.avatar
        )
        checkpoint = next
        return .acceptVersioned(next)
    }
}
