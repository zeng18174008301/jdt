import Combine
import Foundation

// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
// Derived UI input only: these are the existing dispatch guard's identity values.
// This source owns no authorization, generation, credentials, network or persistence state.
struct ChatBubbleSessionIdentity: Equatable {
    let scope: [String?]
    let sessionGeneration: UInt64
    let sessionEpoch: String
    let authoritySessionID: String
}

@MainActor
final class ChatBubbleSessionIdentitySource {
    private let subject = CurrentValueSubject<ChatBubbleSessionIdentity?, Never>(nil)

    var updates: AnyPublisher<ChatBubbleSessionIdentity, Never> {
        subject.compactMap { $0 }.eraseToAnyPublisher()
    }

    func replace(_ identity: ChatBubbleSessionIdentity) {
        guard subject.value != identity else { return }
        subject.send(identity)
    }
}

extension AppState {
    var chatBubbleSessionIdentity: ChatBubbleSessionIdentity {
        chatBubbleSessionIdentity(context: apiContext)
    }

    func chatBubbleSessionIdentity(context: IMAPIContext) -> ChatBubbleSessionIdentity {
        ChatBubbleSessionIdentity(
            scope: [context.accountID, context.tenantID, context.appID, context.imUID, context.deviceID],
            sessionGeneration: localMessageSessionGeneration,
            sessionEpoch: context.sessionEpoch,
            authoritySessionID: context.authSessionFence.authoritySessionID
        )
    }

    func publishChatBubbleSessionIdentity(ifDifferentFrom previous: ChatBubbleSessionIdentity) {
        let current = chatBubbleSessionIdentity
        if current != previous { chatBubbleSessionIdentitySource.replace(current) }
    }
}
// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
