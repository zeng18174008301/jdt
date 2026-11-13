import Foundation
import Combine

public enum EmojiPickerMode: String, Codable, Sendable {
    case composer
    case reaction
}

public struct EmojiPickerSession: Equatable, Sendable {
    public init(catalogVersion: String, mode: EmojiPickerMode) {
        self.catalogVersion = catalogVersion; self.mode = mode
    }
    public let catalogVersion: String
    public var mode: EmojiPickerMode
    public var isOpen = false
    public var query = ""
    public var category = "recent"
    public var focusedItemID = ""
    public var scrollOffsets: [String: Double] = [:]

    private var viewKey: String {
        query.isEmpty ? "category:\(category)" : "search:\(query)"
    }

    public mutating func open(mode nextMode: EmojiPickerMode? = nil) {
        mode = nextMode ?? mode
        isOpen = true
    }

    public mutating func close() {
        isOpen = false
        focusedItemID = ""
    }

    public mutating func search(_ value: String) {
        query = value
        focusedItemID = ""
    }

    public mutating func selectCategory(_ value: String) {
        query = ""
        category = value.isEmpty ? "recent" : value
        focusedItemID = ""
    }

    public mutating func saveScroll(_ offset: Double) {
        scrollOffsets[viewKey] = max(0, offset)
    }

    public var restoredScroll: Double {
        max(0, scrollOffsets[viewKey] ?? 0)
    }

    public mutating func clearIdentity() {
        self = EmojiPickerSession(catalogVersion: catalogVersion, mode: mode)
    }
}

public struct EmojiInsertionResult: Equatable, Sendable {
    public let text: String
    public let selectionStart: Int
    public let selectionEnd: Int
}


public enum ChatEmojiInput {
    public static func insertEmojiAtSelection(
    text: String,
    selectionStart: Int,
    selectionEnd: Int,
    emoji: String
) -> EmojiInsertionResult {
    var boundaries = [0]
    var offset = 0
    for character in text {
        offset += String(character).utf16.count
        boundaries.append(offset)
    }
    let rawStart = max(0, min(selectionStart, text.utf16.count))
    let rawEnd = max(rawStart, min(selectionEnd, text.utf16.count))
    let start = boundaries.last(where: { $0 <= rawStart }) ?? 0
    let end = boundaries.first(where: { $0 >= rawEnd }) ?? text.utf16.count
    let startIndex = String.Index(utf16Offset: start, in: text)
    let endIndex = String.Index(utf16Offset: end, in: text)
    let next = String(text[..<startIndex]) + emoji + String(text[endIndex...])
    let caret = start + emoji.utf16.count
    return EmojiInsertionResult(text: next, selectionStart: caret, selectionEnd: caret)
}

}

@MainActor public final class EmojiPickerPresentationState: ObservableObject {
    @Published public var session: EmojiPickerSession
    public init(catalogVersion: String, mode: EmojiPickerMode) {
        session = EmojiPickerSession(catalogVersion: catalogVersion, mode: mode)
    }
    public var emptyStateTitle: String {
        if !session.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有找到相关 Emoji" }
        if session.category == "recent" { return "最近使用的 Emoji 会显示在这里" }
        if session.category == "frequent" { return "常用 Emoji 会随着使用自动更新" }
        return "此分类暂时没有可用 Emoji"
    }
}
