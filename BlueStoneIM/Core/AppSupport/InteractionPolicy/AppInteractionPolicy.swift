import Foundation

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
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/policy", bearer: context.imToken)
    }
}

extension AppState {
    var hasCurrentInteractionPolicyScope: Bool {
        apiContext.hasIMSession && interactionPolicyScope == remoteDataScopeKey(for: apiContext)
    }

    var shouldShowMessageProcessingNotices: Bool {
        !hasCurrentInteractionPolicyScope || interactionPolicy.processingNoticeEnabled != false
    }

    var canLeaveGroupByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? interactionPolicy.allowMemberGroupLeave : nil)
    }

    var canDeleteFriendByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? interactionPolicy.allowMemberFriendDelete : nil)
    }

    var canBlacklistByTenantPolicy: Bool {
        TenantInteractionPolicy.permitsOrdinaryAction(role: currentEnterprise.role,
            enabled: hasCurrentInteractionPolicyScope ? interactionPolicy.allowMemberBlacklist : nil)
    }

    func messageActionPolicyUnavailableReason(_ action: TenantMessageAction) -> String? {
        let value = hasCurrentInteractionPolicyScope ? messageActionsPolicy.value(for: action) : nil
        switch value {
        case true: return nil
        case false: return "当前企业已关闭消息\(action.title)"
        case nil: return "消息\(action.title)策略暂未就绪，请稍后重试"
        }
    }

    // WDT_APP_CONTRACT_20261021_08: do not rewrite stored summaries or match user text.
    func visibleConversationLastMessage(_ conversation: Conversation) -> String {
        guard !shouldShowMessageProcessingNotices,
              let latest = conversation.messages.last(where: { !$0.isPinnedContextOnly }),
              latest.channelSeq >= conversation.lastMsgSeq,
              latest.isDeletedLocally || latest.status == .recalled else {
            return conversation.lastMessage
        }
        return ""
    }

    func shouldDisplaySearchResult(_ item: RemoteTenantSearchResult) -> Bool {
        guard !shouldShowMessageProcessingNotices,
              let target = item.jumpTarget,
              let channelID = target.channelID,
              let conversation = conversations.first(where: {
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
        interactionPolicyScope = ""
        interactionPolicyRefreshedAt = nil
        interactionPolicy = TenantInteractionPolicy()
        messageActionsPolicy = MessageActionsPolicy()
    }

    func refreshAppInteractionPolicy(force: Bool = false) {
        let context = apiContext
        guard context.hasIMSession, let client = api as? IMAPIClient else { return }
        let scope = remoteDataScopeKey(for: context)
        if interactionPolicyScope != scope {
            resetAppInteractionPolicy()
            interactionPolicyScope = scope
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
                    controls.processingNoticeEnabled = self.interactionPolicy.processingNoticeEnabled
                }
                self.interactionPolicy = controls
                self.applyTenantClientPolicy(response.policy, context: context)
                self.interactionPolicyRefreshedAt = Date()
            } catch {
                guard isCurrent() else { return }
                var unavailable = TenantInteractionPolicy()
                unavailable.processingNoticeEnabled = self.interactionPolicy.processingNoticeEnabled
                self.interactionPolicy = unavailable
                self.interactionPolicyRefreshedAt = nil
                self.markGroupMemberCountPolicyUnresolved(scope: scope)
            }
            do {
                // Read only the action projection; this refresh does not mutate RTC/file capabilities.
                let config = try await self.api.fileUploadConfig(context: context)
                guard isCurrent() else { return }
                self.messageActionsPolicy = config.messageActionsPolicy
            } catch {
                guard isCurrent() else { return }
                self.messageActionsPolicy = MessageActionsPolicy()
                self.interactionPolicyRefreshedAt = nil
            }
        }
    }
}
