import SwiftUI

public enum ChatTranscriptKeyboardDismissalTrigger: CaseIterable {
    case tap
    case verticalScroll
    case longPress
}

public struct ChatTranscriptKeyboardDismissalPlan: Equatable {
    public let dismissesKeyboard: Bool
    let preservesDraft: Bool
    let sendsMessage: Bool
    let acknowledgesRead: Bool
    let loadsHistoryPage: Bool
    let rebuildsTimeline: Bool
    let requestsScrollTarget: Bool
}

// WDT_CHAT_KEYBOARD_INSET_20261021_BEGIN: release stale keyboard insets only when neither chat editor is active.
func chatIgnoredKeyboardEdges(composerIsEditing: Bool, searchIsFocused: Bool) -> Edge.Set {
    composerIsEditing || searchIsFocused ? [] : .bottom
}
// WDT_CHAT_KEYBOARD_INSET_20261021_END

public func chatTranscriptKeyboardDismissalPlan(
    trigger: ChatTranscriptKeyboardDismissalTrigger
) -> ChatTranscriptKeyboardDismissalPlan {
    ChatTranscriptKeyboardDismissalPlan(
        dismissesKeyboard: true,
        preservesDraft: true,
        sendsMessage: false,
        acknowledgesRead: false,
        loadsHistoryPage: false,
        rebuildsTimeline: false,
        requestsScrollTarget: false
    )
}
