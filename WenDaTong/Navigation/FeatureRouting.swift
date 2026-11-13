import SwiftUI

// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
// SwiftUI-layer contracts carry only Domain values/IDs and existing callbacks.
// They own no navigation state and never construct a Feature implementation.
@MainActor
struct ChatFeatureRouting {
    private let chat: @MainActor (String, RemoteTenantSearchJumpTarget?) -> AnyView

    init(makeChat: @escaping @MainActor (String, RemoteTenantSearchJumpTarget?) -> AnyView) {
        chat = makeChat
    }

    func makeChat(_ conversationID: String, initialSearchJumpTarget: RemoteTenantSearchJumpTarget? = nil) -> AnyView {
        chat(conversationID, initialSearchJumpTarget)
    }
}

@MainActor
struct ContactsFeatureRouting {
    let userProfile: @MainActor (IMUser, ((String) -> Void)?, String?) -> AnyView
    func makeUserProfile(user: IMUser, onOpenConversation: ((String) -> Void)? = nil, sourceGroupID: String? = nil) -> AnyView {
        userProfile(user, onOpenConversation, sourceGroupID)
    }
    let groupDetail: @MainActor (GroupInfo, (() -> Void)?, (() -> Void)?) -> AnyView
    func makeGroupDetail(group: GroupInfo, onSearchHistory: (() -> Void)? = nil, onPinnedMessages: (() -> Void)? = nil) -> AnyView {
        groupDetail(group, onSearchHistory, onPinnedMessages)
    }
}

private struct ChatFeatureRoutingKey: EnvironmentKey {
    static let defaultValue: ChatFeatureRouting? = nil
}

private struct ContactsFeatureRoutingKey: EnvironmentKey {
    static let defaultValue: ContactsFeatureRouting? = nil
}

extension EnvironmentValues {
    var chatFeatureRouting: ChatFeatureRouting? {
        get { self[ChatFeatureRoutingKey.self] }
        set { self[ChatFeatureRoutingKey.self] = newValue }
    }
    var contactsFeatureRouting: ContactsFeatureRouting? {
        get { self[ContactsFeatureRoutingKey.self] }
        set { self[ContactsFeatureRoutingKey.self] = newValue }
    }
}

@MainActor
func requiredChatRouting(_ routing: ChatFeatureRouting?) -> ChatFeatureRouting {
    guard let routing else { preconditionFailure("App must inject ChatFeatureRouting") }
    return routing
}

@MainActor
func requiredContactsRouting(_ routing: ContactsFeatureRouting?) -> ContactsFeatureRouting {
    guard let routing else { preconditionFailure("App must inject ContactsFeatureRouting") }
    return routing
}
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END
