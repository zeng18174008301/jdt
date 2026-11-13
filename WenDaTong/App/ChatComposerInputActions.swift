import IM4Features
import SwiftUI
import UIKit

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
extension ChatComposer {
    func inputActionIsCurrent(_ origin: ChatBubbleSessionIdentity) -> Bool {
        guard origin == services.currentIdentity() else { return false }
        guard sharedComposerState != nil else { return true }
        return composerState.token?.scope == sharedComposerScope && composerState.token?.conversationID == conversationID
    }

    func performInputAction(origin: ChatBubbleSessionIdentity, _ action: () -> Void) {
        guard inputActionIsCurrent(origin) else { return }
        action()
    }

    func textEntryActions(origin: ChatBubbleSessionIdentity, renderInput: ChatComposerTextEntryInput, mentionQuery: String?) -> ChatComposerTextEntryActions {
        let actions = ChatComposerTextEntryActions(
            toggleEmoji: { performInputAction(origin: origin) {
                guard !isDisabled else { services.toast(disabledReason); return }
                dismissActiveChatKeyboard()
                withoutComposerLayoutAnimation { showEmoji.toggle(); showTools = false }
            } },
            toggleTools: { performInputAction(origin: origin) {
                guard !isDisabled else { services.toast(disabledReason); return }
                requestLatestScrollForComposerAction()
                dismissActiveChatKeyboard()
                withoutComposerLayoutAnimation { showTools.toggle(); showEmoji = false }
            } },
            send: { performInputAction(origin: origin, sendCurrentInput) },
            onBeginEditing: onBeginEditing, onEditingChanged: onEditingChanged
        )
#if DEBUG
        ChatComposerInputDiagnostics.capture?(ChatComposerInputProbe(
            conversationID: conversationID, owner: composerState, composer: self, input: renderInput,
            origin: origin, disabledReason: disabledReason, activeMentionQuery: mentionQuery, actions: actions,
            selectMention: { user in performInputAction(origin: origin) { insertMention(user) } },
            insertEmoji: { emoji in performInputAction(origin: origin) { insertEmojiAtCurrentSelection(emoji) } }
        ))
#endif
        return actions
    }
}
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

#if DEBUG
struct ChatComposerInputProbe {
    let conversationID: String
    let owner: ComposerState
    let composer: ChatComposer
    let input: ChatComposerTextEntryInput
    let origin: ChatBubbleSessionIdentity
    let disabledReason: String
    let activeMentionQuery: String?
    let actions: ChatComposerTextEntryActions
    let selectMention: (IMUser) -> Void
    let insertEmoji: (String) -> Void
}
@MainActor enum ChatComposerInputDiagnostics {
    static var capture: ((ChatComposerInputProbe) -> Void)?
    static var mentionActions: ((String, @escaping (IMUser) -> Void, @escaping () -> Void) -> Void)?
}
#endif
// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END
