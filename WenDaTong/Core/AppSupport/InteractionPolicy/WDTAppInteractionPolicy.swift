import Combine // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import SwiftUI // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
import UniformTypeIdentifiers

// WDT_APP_CONTRACT_20261021_01_08: strict, optional values distinguish missing backend projections.
struct TenantInteractionPolicy: Decodable, Equatable, Sendable {
    var allowMemberGroupLeave: Bool?
    var allowMemberFriendDelete: Bool?
    var allowMemberBlacklist: Bool?
    var processingNoticeEnabled: Bool?

    init() {}

    private enum Keys: String, CodingKey {
        case group, relationship, message
        case leave = "allow_member_group_leave"
        case delete = "allow_member_friend_delete"
        case blacklist = "allow_member_blacklist"
        case notice = "processing_notice_enabled"
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let group = try? root.nestedContainer(keyedBy: Keys.self, forKey: .group)
        let relationship = try? root.nestedContainer(keyedBy: Keys.self, forKey: .relationship)
        let message = try? root.nestedContainer(keyedBy: Keys.self, forKey: .message)
        allowMemberGroupLeave = try? group?.decode(Bool.self, forKey: .leave)
        allowMemberFriendDelete = try? relationship?.decode(Bool.self, forKey: .delete)
        allowMemberBlacklist = try? relationship?.decode(Bool.self, forKey: .blacklist)
        processingNoticeEnabled = try? message?.decode(Bool.self, forKey: .notice)
    }

    static func permitsOrdinaryAction(role: String, enabled: Bool?) -> Bool {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "internal": return true
        case "member": return enabled == true
        default: return false
        }
    }
}

enum TenantMessageAction: String, Sendable {
    case recall, edit, forward

    var title: String {
        switch self {
        case .recall: return "撤回"
        case .edit: return "编辑"
        case .forward: return "转发"
        }
    }
}

struct MessageActionsPolicy: Decodable, Equatable, Sendable {
    var recallEnabled: Bool?
    var editEnabled: Bool?
    var forwardEnabled: Bool?

    init() {}

    private enum Keys: String, CodingKey {
        case actions = "message_actions"
        case effective
        case recall = "recall_enabled"
        case edit = "edit_enabled"
        case forward = "forward_enabled"
        case legacyRecall = "message_recall_enabled"
        case legacyEdit = "message_edit_enabled"
        case legacyForward = "message_forward_enabled"
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let actions = try? root.nestedContainer(keyedBy: Keys.self, forKey: .actions)
        let effective = try? actions?.nestedContainer(keyedBy: Keys.self, forKey: .effective)
        func flag(_ key: Keys, legacy: Keys) -> Bool? {
            if root.contains(.actions) && actions == nil { return nil }
            if actions?.contains(.effective) == true && effective == nil { return nil }
            if effective?.contains(key) == true {
                return try? effective?.decode(Bool.self, forKey: key)
            }
            return try? root.decode(Bool.self, forKey: legacy)
        }
        recallEnabled = flag(.recall, legacy: .legacyRecall)
        editEnabled = flag(.edit, legacy: .legacyEdit)
        forwardEnabled = flag(.forward, legacy: .legacyForward)
    }

    func value(for action: TenantMessageAction) -> Bool? {
        switch action {
        case .recall: return recallEnabled
        case .edit: return editEnabled
        case .forward: return forwardEnabled
        }
    }
}

struct AppInteractionPolicyResponse: Decodable {
    let policy: RemoteTenantClientPolicy
    let interactions: TenantInteractionPolicy

    private enum Keys: String, CodingKey { case policy = "tenant_policy" }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        policy = try root.decode(RemoteTenantClientPolicy.self, forKey: .policy)
        interactions = try root.decode(TenantInteractionPolicy.self, forKey: .policy)
    }
}

@MainActor
extension IMAPIClient {
    func appInteractionPolicy(context: IMAPIContext) async throws -> AppInteractionPolicyResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/policy", bearer: context.imToken, requestAuthority: requestAuthority)
    }
}

// WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
@MainActor
final class TenantInteractionPresentationStore {
    struct ChatPolicy: Equatable {
        let actions: MessageActionsPolicy
        let showsProcessingNotices: Bool
    }

    struct Snapshot: Equatable {
        var activeScope: String?
        var policyScope = ""
        var rules = TenantInteractionPolicy()
        var actions = MessageActionsPolicy()

        var isCurrent: Bool { activeScope == policyScope }

        var currentRules: TenantInteractionPolicy {
            isCurrent ? rules : TenantInteractionPolicy()
        }

        var currentActions: MessageActionsPolicy {
            isCurrent ? actions : MessageActionsPolicy()
        }

        var showsProcessingNotices: Bool { currentRules.processingNoticeEnabled != false }
        var canForward: Bool { currentActions.forwardEnabled == true }
        var chat: ChatPolicy { ChatPolicy(actions: currentActions, showsProcessingNotices: showsProcessingNotices) }
    }

    @Published var snapshot = Snapshot()

    func setActiveScope(_ scope: String?) {
        if snapshot.activeScope != scope { snapshot.activeScope = scope }
    }

    func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}
// WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
    func updateTenantInteractionPresentationScope() {
        tenantInteractionStore.setActiveScope(apiContext.hasIMSession ? remoteDataScopeKey(for: apiContext) : nil)
    }

    var hasCurrentInteractionPolicyScope: Bool {
        apiContext.hasIMSession && tenantInteractionStore.snapshot.policyScope == remoteDataScopeKey(for: apiContext)
    }

    var shouldShowMessageProcessingNotices: Bool {
        !hasCurrentInteractionPolicyScope || tenantInteractionStore.snapshot.rules.processingNoticeEnabled != false
    }

    var canLeaveGroupByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? tenantInteractionStore.snapshot.rules.allowMemberGroupLeave : nil)
    }

    var canDeleteFriendByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? tenantInteractionStore.snapshot.rules.allowMemberFriendDelete : nil)
    }

    var canBlacklistByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? tenantInteractionStore.snapshot.rules.allowMemberBlacklist : nil)
    }

    func messageActionPolicyUnavailableReason(_ action: TenantMessageAction, policy: MessageActionsPolicy? = nil) -> String? {
        let effective = policy ?? (hasCurrentInteractionPolicyScope ? tenantInteractionStore.snapshot.actions : MessageActionsPolicy())
        switch effective.value(for: action) {
        case true: return nil
        case false: return "当前企业已关闭消息\(action.title)"
        case nil: return "消息\(action.title)策略暂未就绪，请稍后重试"
        }
    }
    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END

    // WDT_APP_CONTRACT_20261021_08: processing notices are hidden only in the display projection.
    func visibleConversationLastMessage(_ conversation: ConversationMessageSnapshot, showsProcessingNotices: Bool? = nil) -> String { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let summary = conversation.lastMessage
        let latest = conversation.messages.last(where: { !$0.isPinnedContextOnly })
        if let latest, latest.channelSeq >= conversation.lastMsgSeq,
           !(showsProcessingNotices ?? shouldShowMessageProcessingNotices), latest.isDeletedLocally || latest.status == .recalled {
            return ""
        }
        if let latest, latest.channelSeq >= conversation.lastMsgSeq || (latest.channelSeq == 0 && latest.isOutgoing) {
            guard let label = latest.conversationAttachmentPreview else { return summary }
            // Older caches could store either the name or a bracketed type followed by the name.
            let legacyPrefix = ["[图片] ", "[视频] ", "[语音] ", "[音频] ", "[文件] ", "[PDF] "]
                .first(where: { summary.hasPrefix($0) })
            let value = legacyPrefix.map { String(summary.dropFirst($0.count)) } ?? summary
            if value == latest.attachmentName || value == latest.text {
                return label
            }
        } else {
            // Without the latest message, only recognize legacy app-generated media names.
            let pathExtension = (summary as NSString).pathExtension
            guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else { return summary }
            let stem = mediaAttachmentDisplayName(summary)
            if type.conforms(to: .image), ["图片消息", "[图片] 图片消息"].contains(stem) {
                return "图片"
            }
            if type.conforms(to: .movie), ["视频消息", "[视频] 视频消息"].contains(stem) {
                return "视频"
            }
        }
        return summary
    }

    func shouldDisplaySearchResult(_ item: RemoteTenantSearchResult, showsProcessingNotices: Bool? = nil) -> Bool { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        guard !(showsProcessingNotices ?? shouldShowMessageProcessingNotices),
              let target = item.jumpTarget,
              let channelID = target.channelID,
              let conversation = conversationStore.conversationMessageSnapshots().first(where: {
                  $0.id == channelID || remoteChannelID(for: $0) == channelID
              }),
              let message = conversation.messages.first(where: {
                  $0.id == target.messageID || (target.channelSeq ?? 0) > 0 && $0.channelSeq == target.channelSeq
              }) else { return true }
        return !message.isDeletedLocally && message.status != .recalled
    }

    func resetAppInteractionPolicy() {
        interactionPolicyGeneration = UUID()
        interactionPolicyRefreshTask?.cancel()
        interactionPolicyRefreshTask = nil
        interactionPolicyRefreshedAt = nil
        tenantInteractionStore.snapshot = .init(activeScope: tenantInteractionStore.snapshot.activeScope) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    }

    func refreshAppInteractionPolicy(force: Bool = false) {
        let context = apiContext
        guard context.hasIMSession, let client = api as? IMAPIClient else { return }
        let scope = remoteDataScopeKey(for: context)
        if tenantInteractionStore.snapshot.policyScope != scope { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
            resetAppInteractionPolicy()
            tenantInteractionStore.snapshot.policyScope = scope // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        }
        guard interactionPolicyRefreshTask == nil else { return }
        if !force, let refreshedAt = interactionPolicyRefreshedAt,
           Date().timeIntervalSince(refreshedAt) < 30 { return }
        let generation = interactionPolicyGeneration
        interactionPolicyRefreshTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.interactionPolicyGeneration == generation
                    && self.isCurrentRemoteScope(scope)
            }
            defer {
                if self.interactionPolicyGeneration == generation {
                    self.interactionPolicyRefreshTask = nil
                }
            }
            do {
                let response = try await client.appInteractionPolicy(context: context)
                guard isCurrent() else { return }
                var controls = response.interactions
                // A missing projection or a transient failure must not undo a known false.
                if controls.processingNoticeEnabled == nil {
                    controls.processingNoticeEnabled = self.tenantInteractionStore.snapshot.rules.processingNoticeEnabled // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                }
                self.tenantInteractionStore.snapshot.rules = controls // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                self.applyTenantClientPolicy(response.policy, context: context)
                self.interactionPolicyRefreshedAt = Date()
            } catch {
                guard isCurrent() else { return }
                var unavailable = TenantInteractionPolicy()
                unavailable.processingNoticeEnabled = self.tenantInteractionStore.snapshot.rules.processingNoticeEnabled // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                self.tenantInteractionStore.snapshot.rules = unavailable // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                self.interactionPolicyRefreshedAt = nil
                self.markGroupMemberCountPolicyUnresolved(scope: scope)
            }
            do {
                // Read only the action projection; this refresh does not mutate RTC/file capabilities.
                let config = try await self.api.fileUploadConfig(context: context)
                guard isCurrent() else { return }
                self.tenantInteractionStore.snapshot.actions = config.messageActionsPolicy // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
            } catch {
                guard isCurrent() else { return }
                self.tenantInteractionStore.snapshot.actions = MessageActionsPolicy() // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                self.interactionPolicyRefreshedAt = nil
            }
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
