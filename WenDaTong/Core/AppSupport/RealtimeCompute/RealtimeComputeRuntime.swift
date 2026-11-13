// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
@MainActor
final class RealtimeComputeRuntime {
    // MainActor admission queue only. Computation receives immutable values on its own actor.
    // Continuations resume the original caller task, retaining its cancellation/fence context.
    private var derivationOwner: UUID?
    private var derivationWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []
    func enterDerivation() async -> UUID {
        let id = UUID()
        if derivationOwner == nil { derivationOwner = id; return id }
        await withCheckedContinuation { derivationWaiters.append((id, $0)) }
        return id
    }
    func leaveDerivation(_ id: UUID) {
        precondition(derivationOwner == id)
        guard !derivationWaiters.isEmpty else { derivationOwner = nil; return }
        let next = derivationWaiters.removeFirst()
        derivationOwner = next.0; next.1.resume()
    }
#if DEBUG
    // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_BEGIN
    var queuedDerivationCount: Int { derivationWaiters.count }
    // WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_END
    // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
    var onSequenceRecoveryTask: ((ConversationStore.HistorySyncClaim, Task<Void, Never>) -> Void)?
    // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
    var onDerivation: (([MessageDerivationSample]) -> Void)?
    var beforeRecoveryProjection: (@MainActor (String, Int64) async -> Void)? // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111
#endif
    var owner: UUID?
    var backgroundRequested = false
#if DEBUG
    struct Observation {
        let attempts: Int
        let stalePlans: Int
        let fallback: Bool
        let fallbackReasons: [String]
        let mappedOnMainThread: Bool
        let mergedOnMainThread: Bool
    }
    var probe: (@Sendable (RealtimeComputeWorker.Phase) -> Void)?
    var onComputed: ((Observation) -> Void)?
    var fallbackDuringApply = false
    var fallbackReasons: [String] = []
#endif
}

struct RealtimeMappingReferences: Sendable {
    var identities: Set<String> = []
    var groups: Set<String> = []
    var avatars: Set<String> = []
    var requiresContactNameLookup = false
}

extension RealtimeComputeWorker {
    func references(_ groups: [RealtimeRawMessageGroup]) -> RealtimeMappingReferences {
        var result = RealtimeMappingReferences()
        func read(_ value: JSONValue, key: String?) {
            switch value {
            case .object(let values): for (k, v) in values { read(v, key: k) }
            case .array(let values): for value in values { read(value, key: key) }
            default:
                guard let key, let raw = value.stringValue else { return }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.contains("contact_card") || text.hasPrefix("个人名片：") || text.hasPrefix("推荐名片：") { result.requiresContactNameLookup = true }
                guard !text.isEmpty else { return }
                // Retain every scalar lookup candidate, including unrecognised future UID aliases and absent contacts.
                result.identities.insert(text)
                if ["group_id", "channel_id"].contains(key) { result.groups.insert(text) }
            }
        }
        for group in groups {
            result.groups.insert(group.channelID)
            for message in group.messages {
                if message.contentType.lowercased().contains("contact") { result.requiresContactNameLookup = true }
                result.identities.insert(message.fromUID.trimmingCharacters(in: .whitespacesAndNewlines))
                let avatar = message.senderAvatar.trimmingCharacters(in: .whitespacesAndNewlines)
                if !avatar.isEmpty { result.avatars.insert(avatar) }
                read(.object(message.payload), key: nil)
            }
        }
        return result
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
