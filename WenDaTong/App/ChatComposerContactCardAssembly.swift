// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
import IM4Domain
import IM4Features
import IM4Stores
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
struct ContactCardPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactsStore: ContactStore
    let remarkPreferredDisplayName: (IMUser) -> String
    let candidate: (IMUser) -> ChatContactCardCandidate
    let canSend: () -> Bool
    let share: (IMUser, String?) -> Void
    @Binding var replyQuote: String?
    @Binding var replyContext: MessageReplyContext?
    @Binding var showTools: Bool
    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SHEET_PARAM - 修改开始：名片发送前回到底部回调
    var onSendStarted: () -> Void = {}
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SHEET_PARAM - 修改结束：名片发送前回到底部回调
    @StateObject private var presentation = ChatContactPickerPresentationState()
    private var query: String { presentation.query }

    private var contacts: [IMUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contactsStore.contacts }
        return contactsStore.contacts.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(remarkPreferredDisplayName(user)),
                query: trimmed
            )
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
    var body: some View {
        ContactDirectoryPresentationView(store: contactsStore) { directoryContent }
    }
    // WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

    private var directoryContent: some View {
        ChatContactCardPickerContent(query: $presentation.query, contacts: contacts.map(candidate)) { user in
                                    guard canSend() else { return }
                                    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SEND - 修改开始：发送名片时回到最新消息
                                    onSendStarted()
                                    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SEND - 修改结束：发送名片时回到最新消息
                                    share(user, replyQuote)
                                    replyQuote = nil
                                    replyContext = nil
                                    showTools = false
                                    dismiss()
        }
    }
}
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END
