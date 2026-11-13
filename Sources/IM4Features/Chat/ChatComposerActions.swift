import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_COMPOSER_DRAFT_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatComposerDraft {
    public var input = ""
    public var selection = NSRange(location: 0, length: 0)
    public var replyQuote: String?
    public var replyContext: MessageReplyContext?
    public var mentionAll = false
    public var mentions: [MentionIdentity] = []
    public var externalMentions: [MentionIdentity] = []
    public var showTools = false
    public var showEmoji = false

    public init(input: String = "", selection: NSRange = NSRange(location: 0, length: 0),
        replyQuote: String? = nil, replyContext: MessageReplyContext? = nil, mentionAll: Bool = false,
        mentions: [MentionIdentity] = [], externalMentions: [MentionIdentity] = [], showTools: Bool = false, showEmoji: Bool = false) {
        self.input = input; self.selection = selection; self.replyQuote = replyQuote; self.replyContext = replyContext
        self.mentionAll = mentionAll; self.mentions = mentions; self.externalMentions = externalMentions
        self.showTools = showTools; self.showEmoji = showEmoji
    }

    // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_BEGIN
    mutating public func replaceInputMovingCaretToEnd(_ value: String) {
        input = value
        selection = NSRange(location: value.utf16.count, length: 0)
    }

    mutating func prependInputPreservingSelection(_ prefix: String) {
        guard !prefix.isEmpty else { return }
        let previous = Self.boundedSelection(selection, in: input)
        input = prefix + input
        selection = NSRange(location: prefix.utf16.count + previous.location, length: previous.length)
    }

    private static func boundedSelection(_ range: NSRange, in text: String) -> NSRange {
        let count = text.utf16.count
        let location = min(max(0, range.location), count)
        let bounded = NSRange(location: location, length: min(max(0, range.length), count - location))
        let value = text as NSString
        func splitsSurrogate(at offset: Int) -> Bool {
            guard offset < count else { return false }
            return (0xDC00...0xDFFF).contains(value.character(at: offset))
        }
        guard splitsSurrogate(at: location) || splitsSurrogate(at: location + bounded.length) else { return bounded }
        // Only repair invalid UTF-16 boundaries; valid selections retain their exact length.
        if bounded.length == 0 {
            return NSRange(location: value.rangeOfComposedCharacterSequence(at: location).location, length: 0)
        }
        return value.rangeOfComposedCharacterSequences(for: bounded)
    }
    // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_END
}

public struct ChatComposerToken: Equatable {
    public let scope: [String?]
    public let conversationID: String
    public let epoch: UInt64
}
// WDT_IOS1_COMPOSER_DRAFT_VALUE_BOUNDARY_20261111_END
