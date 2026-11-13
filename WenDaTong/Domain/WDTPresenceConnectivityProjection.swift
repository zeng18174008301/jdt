import Foundation

struct PresenceConnectivityProjectionValue: Equatable, Sendable {
    let tenantID: String
    let uid: String
    let online: Bool?
    let presenceStatus: String
    let sessionEpoch: String
    let presenceRevision: Int64
    let realtimeGeneration: Int64
    let lastSeenAt: String
    let occurredAt: String
}

enum PresenceConnectivityRefetchReason: Equatable, Sendable {
    case malformed
    case connectivityConflict
}

enum PresenceConnectivityProjectionOutcome: Equatable, Sendable {
    case unrelated
    case ignoredForeignTenant
    case ignoredStale
    case idempotent
    case applied(PresenceConnectivityProjectionValue)
    case refetch(Set<String>, PresenceConnectivityRefetchReason)
}

struct PresenceConnectivityProjection: Sendable {
    private struct Fence: Equatable, Sendable {
        var value: PresenceConnectivityProjectionValue
    }

    private(set) var tenantID = ""
    private(set) var viewerID = ""
    private var fences: [String: Fence] = [:]

    var exactUIDs: Set<String> { Set(fences.keys) }
    var values: [PresenceConnectivityProjectionValue] {
        fences.values.map(\.value).sorted { $0.uid < $1.uid }
    }

    func value(forExactUID uid: String) -> PresenceConnectivityProjectionValue? {
        fences[uid]?.value
    }

    mutating func bind(tenantID rawTenantID: String, viewerID rawViewerID: String) {
        let nextTenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextViewerID = rawViewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tenantID != nextTenantID || viewerID != nextViewerID else { return }
        purge()
        tenantID = nextTenantID
        viewerID = nextViewerID
    }

    mutating func purge() {
        tenantID = ""
        viewerID = ""
        fences.removeAll(keepingCapacity: false)
    }

    mutating func consume(
        _ envelope: RealtimeEnvelope,
        activeTenantID: String,
        activeViewerID: String
    ) -> PresenceConnectivityProjectionOutcome {
        bind(tenantID: activeTenantID, viewerID: activeViewerID)
        guard !tenantID.isEmpty, !viewerID.isEmpty else { return .unrelated }
        switch PresenceConnectivityEvent.parse(envelope, activeTenantID: tenantID) {
        case .unrelated:
            return .unrelated
        case .foreignTenant:
            return .ignoredForeignTenant
        case .malformed(let possibleUID):
            return .refetch(possibleUID.map { Set([$0]) } ?? [], .malformed)
        case .valid(let event):
            return consume(event.value)
        }
    }

    private mutating func consume(_ incoming: PresenceConnectivityProjectionValue) -> PresenceConnectivityProjectionOutcome {
        guard let current = fences[incoming.uid]?.value else {
            fences[incoming.uid] = Fence(value: incoming)
            return .applied(incoming)
        }

        switch Self.compare(incoming, current) {
        case .orderedAscending:
            return .ignoredStale
        case .orderedSame:
            guard current.online == incoming.online,
                  current.presenceStatus == incoming.presenceStatus else {
                return .refetch([incoming.uid], .connectivityConflict)
            }
            return .idempotent
        case .orderedDescending:
            fences[incoming.uid] = Fence(value: incoming)
            return .applied(incoming)
        }
    }

    private static func compare(
        _ lhs: PresenceConnectivityProjectionValue,
        _ rhs: PresenceConnectivityProjectionValue
    ) -> ComparisonResult {
        if lhs.sessionEpoch != rhs.sessionEpoch {
            return lhs.sessionEpoch < rhs.sessionEpoch ? .orderedAscending : .orderedDescending
        }
        if lhs.presenceRevision != rhs.presenceRevision {
            return lhs.presenceRevision < rhs.presenceRevision ? .orderedAscending : .orderedDescending
        }
        if lhs.realtimeGeneration != rhs.realtimeGeneration {
            return lhs.realtimeGeneration < rhs.realtimeGeneration ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

private struct PresenceConnectivityEvent: Equatable, Sendable {
    enum ParseResult: Equatable, Sendable {
        case unrelated
        case foreignTenant
        case malformed(possibleUID: String?)
        case valid(PresenceConnectivityEvent)
    }

    let value: PresenceConnectivityProjectionValue

    static func parse(_ envelope: RealtimeEnvelope, activeTenantID: String) -> ParseResult {
        let outerType = exactString(envelope.type) ?? ""
        let eventType = exactString(envelope.payload["event_type"]?.stringValue) ?? ""
        let eventName = exactString(envelope.payload["event"]?.stringValue) ?? ""
        let expectedEvent = "presence.connectivity.updated"
        guard outerType == expectedEvent || eventType == expectedEvent || eventName == expectedEvent else {
            return .unrelated
        }

        let aliasKeys = ["subject_id", "subject_im_uid", "im_uid", "uid"]
        let aliases = aliasKeys.compactMap { exactString(envelope.payload[$0]?.stringValue) }
        let possibleUID = aliases.first
        let payloadTenantID = exactString(envelope.payload["tenant_id"]?.stringValue)
        if let payloadTenantID, payloadTenantID != activeTenantID {
            return .foreignTenant
        }

        guard payloadTenantID == activeTenantID,
              exactString(envelope.payload["subject_type"]?.stringValue) == "user",
              let uid = canonicalUID(aliases),
              let presenceStatus = normalizedPresenceStatus(
                envelope.payload["presence_status"]?.stringValue
              ),
              let sessionEpoch = exactString(envelope.payload["session_epoch"]?.stringValue),
              let presenceRevision = nonnegativeInt64(
                envelope.payload["presence_revision"] ?? envelope.payload["revision"]
              ),
              let realtimeGeneration = nonnegativeInt64(
                envelope.payload["realtime_generation"] ?? envelope.payload["generation"]
              ) else {
            return .malformed(possibleUID: possibleUID)
        }

        let online = canonicalOnline(presenceStatus: presenceStatus)

        return .valid(PresenceConnectivityEvent(value: PresenceConnectivityProjectionValue(
            tenantID: activeTenantID,
            uid: uid,
            online: online,
            presenceStatus: presenceStatus,
            sessionEpoch: sessionEpoch,
            presenceRevision: presenceRevision,
            realtimeGeneration: realtimeGeneration,
            lastSeenAt: exactString(envelope.payload["last_seen_at"]?.stringValue) ?? "",
            occurredAt: exactString(envelope.payload["occurred_at"]?.stringValue) ?? ""
        )))
    }

    private static func canonicalUID(_ aliases: [String]) -> String? {
        guard !aliases.isEmpty else { return nil }
        let unique = Set(aliases)
        return unique.count == 1 ? aliases[0] : nil
    }

    private static func normalizedPresenceStatus(_ value: String?) -> String? {
        guard let exact = exactString(value)?.lowercased() else { return nil }
        switch exact {
        case "online", "offline", "hidden", "unknown":
            return exact
        default:
            return nil
        }
    }

    private static func canonicalOnline(presenceStatus: String) -> Bool? {
        switch presenceStatus {
        case "online":
            return true
        case "offline":
            return false
        case "hidden", "unknown":
            return nil
        default:
            return nil
        }
    }

    private static func exactString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value == trimmed ? value : nil
    }

    private static func nonnegativeInt64(_ value: JSONValue?) -> Int64? {
        let decoded: Int64?
        switch value {
        case .int(let number):
            decoded = Int64(number)
        case .double(let number) where number.isFinite && number.rounded() == number:
            decoded = Int64(exactly: number)
        case .string(let value):
            decoded = exactString(value).flatMap(Int64.init)
        default:
            decoded = nil
        }
        guard let decoded, decoded >= 0 else { return nil }
        return decoded
    }
}
