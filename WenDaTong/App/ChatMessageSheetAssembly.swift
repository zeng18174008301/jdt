import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI

struct MessageEditAuthoritativeSuccess: Equatable {
    let scope: String
    let conversationID: String
    let messageID: String
    let submittedText: String
    let expectedRevision: Int64
    let authoritativeRevision: Int64
}

func messageEditAuthoritativeSuccess(
    saved: Bool,
    scope: String,
    currentScope: String,
    conversationID: String,
    currentConversationID: String,
    messageID: String,
    submittedText: String,
    expectedRevision: Int64,
    currentMessage: ChatMessage?
) -> MessageEditAuthoritativeSuccess? {
    let normalizedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard saved,
          !scope.isEmpty,
          scope == currentScope,
          conversationID == currentConversationID,
          let currentMessage,
          currentMessage.id == messageID,
          currentMessage.editRevision > expectedRevision,
          currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText else { return nil }
    return MessageEditAuthoritativeSuccess(
        scope: scope,
        conversationID: conversationID,
        messageID: messageID,
        submittedText: normalizedText,
        expectedRevision: expectedRevision,
        authoritativeRevision: currentMessage.editRevision
    )
}

func messageEditAuthoritativeSuccessIsCurrent(
    _ success: MessageEditAuthoritativeSuccess,
    currentScope: String,
    currentConversationID: String,
    currentMessage: ChatMessage?
) -> Bool {
    guard success.scope == currentScope,
          success.conversationID == currentConversationID,
          let currentMessage,
          currentMessage.id == success.messageID,
          currentMessage.editRevision >= success.authoritativeRevision,
          currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == success.submittedText else { return false }
    return true
}


struct MessageEditSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    let onAuthoritativeSuccess: (MessageEditAuthoritativeSuccess) -> Bool
    var body: some View {
        state.observeChatSecondaryEntry { entry in
            MessageEditContent(message: message, conversationID: conversationID, save: { text in
                guard entry.isCurrent(state) else { return false }
                let submissionScope = state.activeConversationHistoryScope
                let expectedRevision = state.conversationStore.conversationMessageSnapshots()
                    .first(where: { $0.id == conversationID })?.messages.first(where: { $0.id == message.id })?.editRevision ?? message.editRevision
                let saved = await state.editMessage(messageID: message.id, in: conversationID, newText: text)
                let currentMessage = state.conversationStore.conversationMessageSnapshots()
                    .first(where: { $0.id == conversationID })?.messages.first(where: { $0.id == message.id })
                guard let success = messageEditAuthoritativeSuccess(saved: saved, scope: submissionScope,
                    currentScope: state.activeConversationHistoryScope, conversationID: conversationID,
                    currentConversationID: state.messageEditCurrentConversationID ?? "", messageID: message.id,
                    submittedText: text, expectedRevision: expectedRevision, currentMessage: currentMessage),
                    onAuthoritativeSuccess(success) else { return false }
                return true
            })
        }
    }
}

struct MessageReportSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    var body: some View {
        state.observeChatSecondaryEntry { entry in
            ContactDirectoryPresentationView(store: state.contactStore) {
                assembledContent(entry: entry)
            }
        }
    }
    private func assembledContent(entry: ChatSecondaryEntry) -> some View {
        let name: String
        if isCancelledUserAvatarURL(message.senderAvatarURL) { name = cancelledUserDisplayName }
        else {
            let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
            name = state.remarkPreferredDisplayName(identifiers: [message.senderId], candidates: [storedName],
                fallback: storedName.isEmpty ? "未知用户" : storedName)
        }
        let actions = ChatReportActions(submit: { reason, description in
            guard entry.isCurrent(state) else { return .rejected }
            let result = await state.submitMessageReportDetailed(messageID: message.id, in: conversationID,
                reason: reason, description: description)
            switch result {
            case .submitted: return .submitted
            case .alreadyReported(let report): return .alreadyReported(ChatReportDisplay(reason: report.reason, description: report.description))
            case .failed: return .failed
            }
        }, lookup: {
            guard entry.isCurrent(state) else { return nil }
            guard let report = await state.lookupMessageReport(messageID: message.id, in: conversationID) else { return nil }
            return ChatReportDisplay(reason: report.reason, description: report.description)
        })
        return MessageReportContent(senderName: name,
            certification: state.certificationPillSource.reference(forExactUID: message.senderId)?.chatFeatureReference, actions: actions,
            message: message, conversationID: conversationID)
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
