import Foundation

enum AvatarAuthorityRefreshBudget {
    static let periodicTickNanoseconds: UInt64 = 3_000_000_000
    static let requestNanoseconds: UInt64 = 1_800_000_000
    static let totalNanoseconds: UInt64 = 5_000_000_000

    static func acceptsResponse(startedAt: UInt64, completedAt: UInt64) -> Bool {
        guard completedAt >= startedAt else { return false }
        return completedAt - startedAt <= requestNanoseconds
    }

    static var closesLostPushWithinDeadline: Bool {
        periodicTickNanoseconds <= totalNanoseconds - requestNanoseconds
    }
}

struct AvatarRealtimeProjectionValue: Equatable, Sendable {
    let tenantID: String
    let uid: String
    let url: String
    let cacheVersion: String
    let updatedAt: String
    let revision: Int64
    let generation: Int64
}

struct AvatarLocalCommitAuthorityFence: Equatable, Sendable {
    private(set) var tenantID = ""
    private(set) var uid = ""
    private(set) var resolvedURL = ""
    private(set) var cacheVersion = ""
    private(set) var updatedAt = ""
    private(set) var epoch: UInt64 = 0
    private(set) var minimumRemoteRevision: Int64 = 0
    private(set) var minimumRemoteGeneration: Int64 = 0

    var isActive: Bool {
        !tenantID.isEmpty && !uid.isEmpty && !resolvedURL.isEmpty
    }

    func protects(exactUID rawUID: String) -> Bool {
        isActive
            && uid == rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func bind(tenantID rawTenantID: String) {
        let normalized = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != tenantID else { return }
        purge()
        tenantID = normalized
    }

    mutating func record(
        tenantID rawTenantID: String,
        uid rawUID: String,
        resolvedURL rawResolvedURL: String,
        cacheVersion rawCacheVersion: String,
        updatedAt rawUpdatedAt: String,
        minimumRemoteRevision: Int64,
        minimumRemoteGeneration: Int64
    ) {
        let normalizedTenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUID = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = rawResolvedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTenantID.isEmpty,
              !normalizedUID.isEmpty,
              !normalizedURL.isEmpty else { return }
        bind(tenantID: normalizedTenantID)
        epoch &+= 1
        uid = normalizedUID
        resolvedURL = normalizedURL
        cacheVersion = rawCacheVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAt = rawUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minimumRemoteRevision = max(0, minimumRemoteRevision)
        self.minimumRemoteGeneration = max(0, minimumRemoteGeneration)
    }

    func allows(
        _ projection: AvatarRealtimeProjectionValue,
        resolvedProjectionURL: String
    ) -> Bool {
        guard isActive,
              projection.tenantID == tenantID,
              projection.uid == uid else { return true }
        let remoteURL = resolvedProjectionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteVersion = projection.cacheVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteUpdatedAt = projection.updatedAt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteURL == resolvedURL,
           (cacheVersion.isEmpty || remoteVersion == cacheVersion),
           (updatedAt.isEmpty || remoteUpdatedAt == updatedAt) {
            return true
        }
        return projection.generation > minimumRemoteGeneration
            || (projection.generation == minimumRemoteGeneration
                && projection.revision > minimumRemoteRevision)
    }

    @discardableResult
    mutating func consumeIfAuthoritative(
        _ projection: AvatarRealtimeProjectionValue,
        resolvedProjectionURL: String
    ) -> Bool {
        guard allows(projection, resolvedProjectionURL: resolvedProjectionURL) else {
            return false
        }
        if isActive, projection.tenantID == tenantID, projection.uid == uid {
            purge(keepingTenant: true)
        }
        return true
    }

    mutating func purge(keepingTenant: Bool = false) {
        let retainedTenantID = keepingTenant ? tenantID : ""
        tenantID = retainedTenantID
        uid = ""
        resolvedURL = ""
        cacheVersion = ""
        updatedAt = ""
        minimumRemoteRevision = 0
        minimumRemoteGeneration = 0
        if !keepingTenant {
            epoch = 0
        }
    }
}

enum AvatarRealtimeRefetchReason: Equatable, Sendable {
    case malformed
    case generationGap
    case revisionConflict
    case reconnect
    case authorityBehindFence
    case mixedAuthorityGeneration
}

enum AvatarRealtimeProjectionOutcome: Equatable, Sendable {
    case unrelated
    case ignoredForeignTenant
    case ignoredStale
    case idempotent
    case applied(AvatarRealtimeProjectionValue)
    case refetch(Set<String>, AvatarRealtimeRefetchReason)
}

struct AvatarRealtimeProjection: Sendable {
    private struct Fence: Equatable, Sendable {
        var value: AvatarRealtimeProjectionValue
    }

    private struct Watermark: Equatable, Sendable {
        var revision: Int64
        var generation: Int64

        mutating func merge(revision: Int64, generation: Int64) {
            self.revision = max(self.revision, revision)
            self.generation = max(self.generation, generation)
        }
    }

    private(set) var tenantID = ""
    private(set) var familyGeneration: Int64 = 0
    private var familyGenerationEstablished = false
    private var familyEventID = ""
    private var fences: [String: Fence] = [:]
    private var pendingAuthority: [String: Watermark] = [:]

    var exactUIDs: Set<String> { Set(fences.keys).union(pendingAuthority.keys) }
    var pendingAuthorityUIDs: Set<String> { Set(pendingAuthority.keys) }
    var values: [AvatarRealtimeProjectionValue] {
        fences.values.map(\.value).sorted { $0.uid < $1.uid }
    }

    func value(forExactUID uid: String) -> AvatarRealtimeProjectionValue? {
        fences[uid]?.value
    }

    mutating func bind(tenantID rawTenantID: String) {
        let nextTenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tenantID != nextTenantID else { return }
        purge()
        tenantID = nextTenantID
    }

    mutating func purge() {
        tenantID = ""
        familyGeneration = 0
        familyGenerationEstablished = false
        familyEventID = ""
        fences.removeAll(keepingCapacity: false)
        pendingAuthority.removeAll(keepingCapacity: false)
    }

    @discardableResult
    mutating func retireExactUIDAfterLocalCommit(
        _ rawUID: String
    ) -> AvatarRealtimeProjectionValue? {
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return nil }
        let retired = fences.removeValue(forKey: uid)?.value
        markAuthority(
            uid: uid,
            revision: (retired?.revision ?? 0) &+ (retired == nil ? 0 : 1),
            generation: retired?.generation ?? familyGeneration
        )
        return retired
    }

    mutating func consume(_ envelope: RealtimeEnvelope, activeTenantID: String) -> AvatarRealtimeProjectionOutcome {
        bind(tenantID: activeTenantID)
        guard !tenantID.isEmpty else { return .unrelated }
        switch AvatarRealtimeEvent.parse(envelope, activeTenantID: tenantID) {
        case .unrelated:
            return .unrelated
        case .foreignTenant:
            return .ignoredForeignTenant
        case .malformed(let possibleUID):
            let affected = possibleUID.map { Set([$0]) } ?? exactUIDs
            guard !affected.isEmpty else { return .refetch([], .malformed) }
            for uid in affected {
                markAuthority(uid: uid, revision: 0, generation: 0)
            }
            return .refetch(affected, .malformed)
        case .valid(let event):
            return consume(event)
        }
    }

    mutating func requireAuthorityAfterReconnect() -> AvatarRealtimeProjectionOutcome {
        let affected = exactUIDs
        for uid in affected {
            let fence = fences[uid]?.value
            markAuthority(
                uid: uid,
                revision: fence?.revision ?? 0,
                generation: fence?.generation ?? 0
            )
        }
        return .refetch(affected, .reconnect)
    }

    mutating func applyAuthorityBatch(
        summaries: [UserSummaryV2],
        subjectTenantID: String
    ) -> [AvatarRealtimeProjectionOutcome] {
        let responseTenantID = subjectTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, responseTenantID == tenantID else {
            return [.ignoredForeignTenant]
        }
        guard !summaries.isEmpty else { return [] }
        let affectedUIDs = Set(summaries.map(\.imUID).filter { !$0.isEmpty })
        let generations = Set(summaries.map { $0.generations.identity })
        guard generations.count == 1, let batchGeneration = generations.first else {
            for uid in affectedUIDs {
                markAuthority(uid: uid, revision: 0, generation: 0)
            }
            return [.refetch(affectedUIDs, .mixedAuthorityGeneration)]
        }
        guard batchGeneration >= 0 else {
            return [.refetch(affectedUIDs, .malformed)]
        }
        if batchGeneration < familyGeneration {
            let blocked = affectedUIDs.filter { pendingAuthority[$0] != nil }
            return blocked.isEmpty
                ? [.ignoredStale]
                : [.refetch(Set(blocked), .authorityBehindFence)]
        }

        var stagedFences = fences
        var outcomes: [AvatarRealtimeProjectionOutcome] = []
        for summary in summaries {
            let uid = summary.imUID
            guard uid == summary.userID,
                  uid == uid.trimmingCharacters(in: .whitespacesAndNewlines),
                  !uid.isEmpty,
                  summary.userRevision >= 0,
                  AvatarRealtimeEvent.isStableAuthorityAvatarURL(summary.avatar.url) else {
                if !uid.isEmpty {
                    markAuthority(uid: uid, revision: 0, generation: batchGeneration)
                }
                return [.refetch(uid.isEmpty ? affectedUIDs : [uid], .malformed)]
            }
            if let minimum = pendingAuthority[uid],
               summary.userRevision < minimum.revision || batchGeneration < minimum.generation {
                return [.refetch([uid], .authorityBehindFence)]
            }
            if let current = stagedFences[uid]?.value {
                if summary.userRevision < current.revision {
                    return [.refetch([uid], .authorityBehindFence)]
                }
                if summary.userRevision == current.revision {
                    guard summary.avatar.url == current.url else {
                        markAuthority(
                            uid: uid,
                            revision: current.revision,
                            generation: batchGeneration
                        )
                        return [.refetch([uid], .revisionConflict)]
                    }
                    let advanced = AvatarRealtimeProjectionValue(
                        tenantID: current.tenantID,
                        uid: current.uid,
                        url: current.url,
                        cacheVersion: current.cacheVersion,
                        updatedAt: current.updatedAt,
                        revision: current.revision,
                        generation: batchGeneration
                    )
                    stagedFences[uid] = Fence(value: advanced)
                    outcomes.append(.idempotent)
                    continue
                }
            }

            let value = AvatarRealtimeProjectionValue(
                tenantID: tenantID,
                uid: uid,
                url: summary.avatar.url,
                cacheVersion: summary.avatar.version,
                updatedAt: "",
                revision: summary.userRevision,
                generation: batchGeneration
            )
            stagedFences[uid] = Fence(value: value)
            outcomes.append(.applied(value))
        }
        fences = stagedFences
        familyGeneration = max(familyGeneration, batchGeneration)
        familyGenerationEstablished = true
        familyEventID = ""
        for uid in affectedUIDs {
            pendingAuthority.removeValue(forKey: uid)
        }
        return outcomes
    }

    mutating func applyAuthority(
        summary: UserSummaryV2,
        subjectTenantID: String
    ) -> AvatarRealtimeProjectionOutcome {
        applyAuthorityBatch(summaries: [summary], subjectTenantID: subjectTenantID).first ?? .unrelated
    }

    private mutating func consume(_ event: AvatarRealtimeEvent) -> AvatarRealtimeProjectionOutcome {
        let pendingMinimum = pendingAuthority[event.uid]
        if let pendingMinimum,
           event.revision < pendingMinimum.revision
            || event.generation < pendingMinimum.generation {
            return .refetch([event.uid], .authorityBehindFence)
        }
        let resolvesRecordedGap = pendingMinimum.map {
            $0.generation > familyGeneration + 1
                && event.generation >= $0.generation
                && event.revision >= $0.revision
        } ?? false
        if familyGenerationEstablished {
            if event.generation < familyGeneration {
                return .ignoredStale
            }
            if event.generation == familyGeneration {
                if familyEventID == event.eventID,
                   let current = fences[event.uid]?.value,
                   current.revision == event.revision,
                   current.url == event.url {
                    return .idempotent
                }
                markAuthority(uid: event.uid, revision: event.revision, generation: event.generation)
                return .refetch([event.uid], .revisionConflict)
            }
            if event.generation > familyGeneration + 1, !resolvesRecordedGap {
                markAuthority(uid: event.uid, revision: event.revision, generation: event.generation)
                return .refetch([], .generationGap)
            }
        }
        if let current = fences[event.uid]?.value {
            if event.revision < current.revision || event.generation < current.generation {
                if event.generation > current.generation {
                    markAuthority(uid: event.uid, revision: event.revision, generation: event.generation)
                    return .refetch([event.uid], .authorityBehindFence)
                }
                return .ignoredStale
            }
            if event.revision == current.revision {
                guard event.url == current.url,
                      event.generation == current.generation else {
                    markAuthority(uid: event.uid, revision: event.revision, generation: event.generation)
                    return .refetch([event.uid], .revisionConflict)
                }
                return .idempotent
            }
            guard event.generation > current.generation else {
                return .ignoredStale
            }
        }

        let value = AvatarRealtimeProjectionValue(
            tenantID: event.tenantID,
            uid: event.uid,
            url: event.url,
            cacheVersion: String(event.revision),
            updatedAt: event.updatedAt,
            revision: event.revision,
            generation: event.generation
        )
        fences[event.uid] = Fence(value: value)
        familyGeneration = event.generation
        familyGenerationEstablished = true
        familyEventID = event.eventID
        pendingAuthority.removeValue(forKey: event.uid)
        return .applied(value)
    }

    private mutating func markAuthority(uid: String, revision: Int64, generation: Int64) {
        if var current = pendingAuthority[uid] {
            current.merge(revision: revision, generation: generation)
            pendingAuthority[uid] = current
        } else {
            pendingAuthority[uid] = Watermark(revision: revision, generation: generation)
        }
    }
}

enum AvatarRealtimeSurfaceProjector {
    static func hasExactAuthorityCoverage(
        requestedUIDs: Set<String>,
        itemUIDs: [String],
        missingUIDs: [String]
    ) -> Bool {
        let itemSet = Set(itemUIDs)
        let missingSet = Set(missingUIDs)
        return itemUIDs.count == itemSet.count
            && missingUIDs.count == missingSet.count
            && itemSet.union(missingSet) == requestedUIDs
            && itemSet.isDisjoint(with: missingSet)
    }

    static func isCompleteAvatarAuthorityBatch(
        requestedUIDs: Set<String>,
        itemUIDs: [String],
        missingUIDs: [String],
        allItemsAuthoritative: Bool
    ) -> Bool {
        missingUIDs.isEmpty
            && allItemsAuthoritative
            && itemUIDs.count == requestedUIDs.count
            && Set(itemUIDs) == requestedUIDs
    }

    static func shouldMaintainAuthorityLoop(
        certificationUIDs: Set<String>,
        certificationScopeMatches: Bool,
        avatarUIDs: Set<String>
    ) -> Bool {
        (!certificationUIDs.isEmpty && certificationScopeMatches) || !avatarUIDs.isEmpty
    }

    static func user(
        _ user: IMUser,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> IMUser {
        guard user.id == projection.uid else { return user }
        return IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            lastLoginAt: user.lastLoginAt,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: resolvedURL,
            avatarVersion: projection.cacheVersion,
            avatarUpdatedAt: projection.updatedAt.isEmpty
                ? user.avatarUpdatedAt
                : projection.updatedAt,
            badges: user.badges
        )
    }

    static func authorityUID(for record: CallRecord) -> String? {
        let peerID = record.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !peerID.isEmpty { return peerID }
        let fallback = record.peerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    static func isDirectPeerEvent(
        conversationID: String,
        remoteChannelID: String,
        participantUIDs: [String],
        currentUID: String,
        eventUID: String
    ) -> Bool {
        directPeerUID(
            conversationID: conversationID,
            remoteChannelID: remoteChannelID,
            participantUIDs: participantUIDs,
            currentUID: currentUID
        ) == eventUID && eventUID != currentUID
    }

    static func directPeerUID(
        conversationID: String,
        remoteChannelID: String,
        participantUIDs: [String],
        currentUID: String
    ) -> String? {
        guard !currentUID.isEmpty else { return nil }
        func parts(_ value: String) -> [String] {
            let rawParts = value
                .split { $0 == ":" || $0 == "|" || $0 == "," }
                .map(String.init)
                .filter { !$0.isEmpty }
            if rawParts.count == 3,
               let prefix = rawParts.first?.lowercased(),
               ["direct", "dm", "single"].contains(prefix) {
                return Array(rawParts.dropFirst())
            }
            return rawParts
        }
        for channelID in [remoteChannelID, conversationID] {
            let channelParts = parts(channelID)
            guard channelParts.contains(currentUID) else { continue }
            let peers = Set(channelParts.filter { $0 != currentUID })
            if peers.count == 1 {
                return peers.first
            }
        }
        let participantPeers = Set(participantUIDs.filter {
            !$0.isEmpty && $0 != currentUID
        })
        if participantPeers.count == 1 {
            return participantPeers.first
        }
        let weakChannelPeers = Set(
            [remoteChannelID, conversationID]
                .flatMap(parts)
                .filter { !$0.isEmpty && $0 != currentUID }
        )
        return weakChannelPeers.count == 1 ? weakChannelPeers.first : nil
    }

    static func friendRequest(
        _ request: FriendRequest,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> FriendRequest {
        guard request.userID == projection.uid else { return request }
        return FriendRequest(
            id: request.id,
            name: request.name,
            userID: request.userID,
            avatarURL: resolvedURL,
            source: request.source,
            message: request.message,
            status: request.status,
            direction: request.direction,
            tenantReviewStatus: request.tenantReviewStatus,
            peerReviewStatus: request.peerReviewStatus,
            canRespond: request.canRespond,
            outcome: request.outcome,
            relationStatus: request.relationStatus,
            friendAction: request.friendAction,
            friendFlow: request.friendFlow,
            directlyEstablished: request.directlyEstablished,
            requiresTenantReview: request.requiresTenantReview,
            requiresTargetApproval: request.requiresTargetApproval,
            resolutionMode: request.resolutionMode,
            accepted: request.accepted
        )
    }

    static func groupJoinRequest(
        _ request: GroupJoinRequest,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> GroupJoinRequest {
        guard request.applicantUID == projection.uid else { return request }
        return GroupJoinRequest(
            id: request.id,
            groupID: request.groupID,
            applicantUID: request.applicantUID,
            applicantName: request.applicantName,
            applicantAvatarURL: resolvedURL,
            inviterAvatarURL: request.inviterAvatarURL,
            inviterName: request.inviterName,
            status: request.status,
            message: request.message,
            createdAt: request.createdAt
        )
    }

    static func callRecord(
        _ record: CallRecord,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> CallRecord {
        guard record.peerID == projection.uid || record.peerUserID == projection.uid else {
            return record
        }
        return CallRecord(
            id: record.id,
            callID: record.callID,
            peerID: record.peerID,
            peerUserID: record.peerUserID,
            peerAvatarURL: resolvedURL,
            peerAvatarVersion: projection.cacheVersion,
            peerAvatarUpdatedAt: projection.updatedAt.isEmpty
                ? record.peerAvatarUpdatedAt
                : projection.updatedAt,
            peerAvatarSource: record.peerAvatarSource,
            title: record.title,
            subtitle: record.subtitle,
            time: record.time,
            status: record.status,
            direction: record.direction,
            callType: record.callType,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            endReason: record.endReason,
            stateVersion: record.stateVersion
        )
    }

    static func userSearchResult(
        _ result: UserSearchResult,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> UserSearchResult {
        guard result.imUID == projection.uid || result.userID == projection.uid else {
            return result
        }
        return UserSearchResult(
            imUID: result.imUID,
            userID: result.userID,
            nickname: result.nickname,
            phone: result.phone,
            avatarURL: resolvedURL,
            status: result.status,
            presenceStatus: result.presenceStatus,
            relationStatus: result.relationStatus,
            canApplyFriend: result.canApplyFriend,
            reason: result.reason,
            friendAction: result.friendAction,
            friendFlow: result.friendFlow,
            requiresTenantReview: result.requiresTenantReview,
            requiresTargetApproval: result.requiresTargetApproval
        )
    }

    static func groupMuteListItem(
        _ item: GroupMuteListItem,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> GroupMuteListItem {
        guard item.targetUID == projection.uid else { return item }
        return GroupMuteListItem(
            groupID: item.groupID,
            targetUID: item.targetUID,
            targetUserID: item.targetUserID,
            targetUsername: item.targetUsername,
            targetNickname: item.targetNickname,
            targetAvatarURL: resolvedURL,
            targetRole: item.targetRole,
            operatorUID: item.operatorUID,
            operatorName: item.operatorName,
            reason: item.reason,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            createdAtText: item.createdAtText,
            updatedAtText: item.updatedAtText
        )
    }
}

private struct AvatarRealtimeEvent: Equatable, Sendable {
    enum ParseResult: Equatable, Sendable {
        case unrelated
        case foreignTenant
        case malformed(possibleUID: String?)
        case valid(AvatarRealtimeEvent)
    }

    let tenantID: String
    let uid: String
    let url: String
    let updatedAt: String
    let revision: Int64
    let generation: Int64
    let eventID: String

    static func parse(_ envelope: RealtimeEnvelope, activeTenantID: String) -> ParseResult {
        let outerType = exactString(envelope.type) ?? ""
        let eventType = exactString(envelope.payload["event_type"]?.stringValue) ?? ""
        let eventName = exactString(envelope.payload["event"]?.stringValue) ?? ""
        let isCandidate = eventType == "identity.summary.updated" || eventName == "avatar_updated"
        guard isCandidate else { return .unrelated }

        let allowedKeys: Set<String> = [
            "event", "event_id", "event_type", "tenant_id", "subject_type",
            "subject_id", "revision", "generation_family", "generation",
            "changed", "occurred_at", "uid", "url", "version", "updated_at"
        ]

        let possibleUID = exactString(
            envelope.payload["subject_id"]?.stringValue
                ?? envelope.payload["uid"]?.stringValue
        )
        let payloadTenantID = exactString(envelope.payload["tenant_id"]?.stringValue)
        if let payloadTenantID, payloadTenantID != activeTenantID {
            return .foreignTenant
        }

        let subjectID = exactString(envelope.payload["subject_id"]?.stringValue)
        let uid = exactString(envelope.payload["uid"]?.stringValue)
        let subjectType = exactString(envelope.payload["subject_type"]?.stringValue)
        let family = exactString(envelope.payload["generation_family"]?.stringValue)
        let url = exactString(envelope.payload["url"]?.stringValue)
        let occurredAt = exactString(envelope.payload["occurred_at"]?.stringValue)
        let updatedAt = exactString(envelope.payload["updated_at"]?.stringValue)
        let eventID = exactString(envelope.payload["event_id"]?.stringValue)
        let revision = positiveInt64(envelope.payload["revision"])
        let version = positiveInt64(envelope.payload["version"])
        let generation = positiveInt64(envelope.payload["generation"])
        let changedIsExactAvatar: Bool
        if case .array(let values)? = envelope.payload["changed"] {
            changedIsExactAvatar = values == [.string("avatar")]
        } else {
            changedIsExactAvatar = false
        }

        guard outerType == "notification",
              Set(envelope.payload.keys) == allowedKeys,
              eventType == "identity.summary.updated",
              eventName == "avatar_updated",
              payloadTenantID == activeTenantID,
              subjectType == "user",
              let subjectID, let uid, uid == subjectID,
              family == "identity",
              let revision, let version, version == revision,
              let generation,
              let url, isStableTenantAvatarURL(url),
              let occurredAt, let updatedAt, updatedAt == occurredAt,
              let eventID,
              changedIsExactAvatar else {
            return .malformed(possibleUID: possibleUID)
        }
        return .valid(AvatarRealtimeEvent(
            tenantID: activeTenantID,
            uid: uid,
            url: url,
            updatedAt: updatedAt,
            revision: revision,
            generation: generation,
            eventID: eventID
        ))
    }

    static func isStableTenantAvatarURL(_ value: String) -> Bool {
        let prefix = "/api/tenant/avatar/"
        guard value.hasPrefix(prefix),
              !value.contains("?"),
              !value.contains("#") else { return false }
        let opaque = value.dropFirst(prefix.count)
        guard (1...180).contains(opaque.utf8.count), opaque != ".", opaque != ".." else {
            return false
        }
        return opaque.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 95, 126, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }

    static func isStableAuthorityAvatarURL(_ value: String) -> Bool {
        if isStableTenantAvatarURL(value) { return true }
        let prefix = "/api/tenant/static/avatars/"
        guard value.hasPrefix(prefix),
              !value.contains("?"),
              !value.contains("#") else { return false }
        let remainder = value.dropFirst(prefix.count)
        guard (1...512).contains(remainder.utf8.count) else { return false }
        let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            guard (1...180).contains(segment.utf8.count), segment != ".", segment != ".." else {
                return false
            }
            return segment.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 46, 95, 126, 48...57, 65...90, 97...122:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private static func exactString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value == trimmed ? value : nil
    }

    private static func positiveInt64(_ value: JSONValue?) -> Int64? {
        let decoded: Int64?
        switch value {
        case .int(let number):
            decoded = Int64(number)
        case .double(let number) where number.isFinite && number.rounded() == number:
            decoded = Int64(exactly: number)
        default:
            decoded = nil
        }
        guard let decoded, decoded > 0 else { return nil }
        return decoded
    }
}
