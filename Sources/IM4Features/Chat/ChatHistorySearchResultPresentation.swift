import SwiftUI
import IM4DesignSystem // WDT_IOS1_CHAT_SEARCH_PAGE_20261113

public struct ChatSearchHighlightPresentation: Equatable, Sendable {
    public let field: String
    public let start: Int
    public let length: Int
    public init(field: String, start: Int, length: Int) {
        self.field = field; self.start = start; self.length = length
    }
}
@MainActor public struct ChatHistorySearchResultPresentation {
    public let resultID: String
    public let type: String
    public let displayKind: String? // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
    public let title: String
    public let subtitle: String?
    public let snippet: String?
    public let highlightRanges: [ChatSearchHighlightPresentation]
    let highlightedPreview: Text // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
    var id: String { "\(type):\(resultID)" }
    private let selection: () -> Void
    public init(resultID: String, type: String, title: String, subtitle: String?, snippet: String?,
        highlightRanges: [ChatSearchHighlightPresentation], previewField: String? = nil,
        displayKind: String? = nil, select: @escaping () -> Void) {
        self.resultID = resultID; self.type = type; self.title = title
        self.subtitle = subtitle; self.snippet = snippet; self.highlightRanges = highlightRanges
        self.selection = select
        self.displayKind = displayKind // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        let hasSnippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let field = previewField ?? (hasSnippet ? "snippet" : "title")
        let text = field == "snippet" ? (snippet ?? title) : title
        self.highlightedPreview = Self.highlightedText(text, field: field, ranges: highlightRanges)
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    }
    public func select() { selection() }

    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    private static func highlightedText(_ value: String, field: String, ranges: [ChatSearchHighlightPresentation]) -> Text {
        let scalars = Array(value.unicodeScalars)
        let matching = ranges.filter {
            $0.field == field && $0.start >= 0 && $0.start < scalars.count
                && $0.length > 0 && $0.length <= scalars.count - $0.start
        }.sorted { $0.start < $1.start }
        guard !matching.isEmpty else { return Text(value) }
        var spans: [Range<Int>] = []
        for range in matching {
            let next = range.start..<(range.start + range.length)
            if let last = spans.last, last.upperBound >= next.lowerBound {
                spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
            } else {
                spans.append(next)
            }
        }
        func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(scalars[range])) }
        var output = AttributedString()
        var cursor = 0
        for span in spans {
            output += AttributedString(text(cursor..<span.lowerBound))
            var match = AttributedString(text(span))
            match.foregroundColor = IMColor.brand
            output += match
            cursor = span.upperBound
        }
        output += AttributedString(text(cursor..<scalars.count))
        return Text(output)
    }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
}
