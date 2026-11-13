import IM4Domain
import IM4DesignSystem
import SwiftUI

// WDT_IOS1_CHAT_ROW_FACTORY_20261110_BEGIN
// Feature-owned values and named actions; no Store, AppState or general context.
public struct ChatTimelineRowInput {
    public let row: MessageRowModel
    public let conversationID: String
    public let isGroupConversation: Bool
    public let isBatchSelected: Bool
}

public struct ChatTimelineRowActions {
    public let onSelectionTap: (() -> Void)?
    public let onLongPress: () -> Void
    public let onReadTap: () -> Void
    public let onSenderTap: (IMUser) -> Void
    public let onContactCardTap: (IMUser) -> Void
    public let onMentionTap: (IMUser) -> Void
    public let onAttachmentTap: (ChatMessage) -> Void
}

@MainActor
public struct ChatTimelineRowFactory {
    let makeRow: @MainActor (ChatTimelineRowInput, ChatTimelineRowActions) -> AnyView

    public init(makeRow: @escaping @MainActor (ChatTimelineRowInput, ChatTimelineRowActions) -> AnyView) {
        self.makeRow = makeRow
    }
}

private struct ChatTimelineRowFactoryKey: EnvironmentKey {
    static let defaultValue: ChatTimelineRowFactory? = nil
}

extension EnvironmentValues {
    public var chatTimelineRowFactory: ChatTimelineRowFactory? {
        get { self[ChatTimelineRowFactoryKey.self] }
        set { self[ChatTimelineRowFactoryKey.self] = newValue }
    }
}

@MainActor
public struct ChatTimelineRow: View {
    let input: ChatTimelineRowInput
    let actions: ChatTimelineRowActions
    @Environment(\.chatTimelineRowFactory) private var factory

    public init(row: MessageRowModel, conversationID: String, isGroupConversation: Bool,
         isBatchSelected: Bool = false, onSelectionTap: (() -> Void)? = nil,
         onLongPress: @escaping () -> Void, onReadTap: @escaping () -> Void,
         onSenderTap: @escaping (IMUser) -> Void = { _ in },
         onContactCardTap: @escaping (IMUser) -> Void = { _ in },
         onMentionTap: @escaping (IMUser) -> Void = { _ in },
         onAttachmentTap: @escaping (ChatMessage) -> Void = { _ in }) {
        input = ChatTimelineRowInput(row: row, conversationID: conversationID,
            isGroupConversation: isGroupConversation, isBatchSelected: isBatchSelected)
        actions = ChatTimelineRowActions(onSelectionTap: onSelectionTap, onLongPress: onLongPress,
            onReadTap: onReadTap, onSenderTap: onSenderTap, onContactCardTap: onContactCardTap,
            onMentionTap: onMentionTap, onAttachmentTap: onAttachmentTap)
    }

    public var body: some View {
        guard let factory else { preconditionFailure("App must inject ChatTimelineRowFactory") }
        // App observation/presentation equality stays inside the rendered row.
        // Never equate/cache this action-bearing wrapper or assign a new identity.
        return factory.makeRow(input, actions)
    }
}
// WDT_IOS1_CHAT_ROW_FACTORY_20261110_END
