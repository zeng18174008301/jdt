import Foundation
import IM4Domain
import IM4Features


typealias EmojiCatalogIndex = IM4Domain.EmojiCatalogIndex
typealias EmojiPickerCoreError = IM4Domain.EmojiPickerCoreError
typealias EmojiPickerMode = IM4Features.EmojiPickerMode
typealias EmojiPickerSession = IM4Features.EmojiPickerSession
typealias EmojiInsertionResult = IM4Features.EmojiInsertionResult

func insertEmojiAtSelection(text: String, selectionStart: Int, selectionEnd: Int, emoji: String) -> EmojiInsertionResult {
    ChatEmojiInput.insertEmojiAtSelection(text: text, selectionStart: selectionStart, selectionEnd: selectionEnd, emoji: emoji)
}
