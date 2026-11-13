import SwiftUI
import IM4Features
import IM4Stores

// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
// App is the only layer naming both Features. These factories are stateless
// values; state/Store ownership stays in the original environment and pages.
@MainActor
enum AppFeatureComposition {
    static func chatRouting() -> ChatFeatureRouting {
        ChatFeatureRouting(makeChat: { conversationID, initialSearchJumpTarget in
            AnyView(ChatView(conversationID: conversationID, initialSearchJumpTarget: initialSearchJumpTarget))
        })
    }

    static func contactsRouting() -> ContactsFeatureRouting {
        ContactsFeatureRouting(
            userProfile: { user, onOpenConversation, sourceGroupID in
                AnyView(UserProfileView(user: user, onOpenConversation: onOpenConversation, sourceGroupID: sourceGroupID))
            },
            groupDetail: { group, onSearchHistory, onPinnedMessages in
                AnyView(GroupDetailView(group: group, onSearchHistory: onSearchHistory, onPinnedMessages: onPinnedMessages))
            }
        )
    }
}

// WDT_IOS1_CHAT_SCREEN_SCOPED_STORES_20261111_BEGIN
struct ChatScreenStores {
    let currentUser: CurrentUserPresentationStore
    let enterpriseMembership: EnterpriseMembershipPresentationStore
    let batchForward: BatchForwardPresentationStore
    let conversations: ConversationStore
    let contacts: ContactStore
    let files: FileStore
    let tenantClientPolicy: TenantClientPolicyPresentationStore
    let tenantInteraction: TenantInteractionPresentationStore
    let sessionIdentity: ChatBubbleSessionIdentitySource
    let searchInvalidation: SearchInvalidationStore
}

private struct ChatScreenStoresKey: EnvironmentKey {
    static let defaultValue: ChatScreenStores? = nil
}

private struct ChatScreenActionsKey: EnvironmentKey {
    static let defaultValue: ChatScreenActionsSource? = nil
}

extension EnvironmentValues {
    var chatScreenActions: ChatScreenActionsSource? {
        get { self[ChatScreenActionsKey.self] }
        set { self[ChatScreenActionsKey.self] = newValue }
    }

    var chatScreenStores: ChatScreenStores? {
        get { self[ChatScreenStoresKey.self] }
        set { self[ChatScreenStoresKey.self] = newValue }
    }
}
// WDT_IOS1_CHAT_SCREEN_SCOPED_STORES_20261111_END

// WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_BEGIN
extension View {
    @MainActor
    func appStateEnvironment(_ state: AppState) -> some View {
        environmentObject(state)
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
            .environmentObject(state.callStore)
            .environment(\.certificationPillSource, state.certificationPillSource)
            .environment(\.chatFeatureRouting, AppFeatureComposition.chatRouting())
            .environment(\.chatScreenStores, ChatScreenStores(
                currentUser: state.currentUserPresentationStore,
                enterpriseMembership: state.enterpriseMembershipStore,
                batchForward: state.batchForwardStore,
                conversations: state.conversationStore,
                contacts: state.contactStore,
                files: state.fileStore,
                tenantClientPolicy: state.tenantClientPolicyStore,
                tenantInteraction: state.tenantInteractionStore,
                sessionIdentity: state.chatBubbleSessionIdentitySource,
                searchInvalidation: state.searchInvalidationStore
            ))
            .environment(\.chatScreenActions, ChatScreenActionsSource { ChatScreenActions.bind(state) })
            .environment(\.contactsFeatureRouting, AppFeatureComposition.contactsRouting())
            // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
            .environment(\.chatTimelineRowFactory, AppFeatureComposition.timelineRowFactory(state: state))
            // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
            .environment(\.chatVisualRendering, AppFeatureComposition.chatVisualRendering())
            .environment(\.chatCertificationRendering, AppFeatureComposition.chatCertificationRendering(state.certificationPillSource))
            // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
            .environment(\.chatComposerServices, ChatComposerServices.bind(state))
            // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END
            // WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN
            .environment(\.attachmentDetailSource, { message, conversationID in
                AttachmentDetailSource.bind(state, message: message, conversationID: conversationID)
            })
            // WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END
    }
}
// WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END
