// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public func highlightedMentionText(_ text: String, target: String, baseColor: Color) -> Text {
    if text.localizedCaseInsensitiveContains("@所有人") {
        return highlightedMentionText(text, targets: ["@所有人", target].filter { !$0.isEmpty }, baseColor: baseColor)
    }
    guard !target.isEmpty else {
        return Text(text).foregroundColor(baseColor)
    }

    var result = Text("")
    var cursor = text.startIndex
    var found = false

    while let range = text.range(of: target, options: .caseInsensitive, range: cursor..<text.endIndex) {
        found = true
        if cursor < range.lowerBound {
            result = result + Text(String(text[cursor..<range.lowerBound])).foregroundColor(baseColor)
        }
        result = result + Text(String(text[range])).foregroundColor(IMColor.danger)
        cursor = range.upperBound
    }

    if cursor < text.endIndex {
        result = result + Text(String(text[cursor..<text.endIndex])).foregroundColor(baseColor)
    }

    return found ? result : Text(text).foregroundColor(baseColor)
}

private func highlightedMentionText(_ text: String, targets: [String], baseColor: Color) -> Text {
    var result = Text("")
    var cursor = text.startIndex
    var found = false
    while cursor < text.endIndex {
        let matches = targets.compactMap { target -> (Range<String.Index>, String)? in
            guard let range = text.range(of: target, options: .caseInsensitive, range: cursor..<text.endIndex) else { return nil }
            return (range, target)
        }
        guard let match = matches.sorted(by: { lhs, rhs in
            if lhs.0.lowerBound == rhs.0.lowerBound { return lhs.0.upperBound > rhs.0.upperBound }
            return lhs.0.lowerBound < rhs.0.lowerBound
        }).first else {
            result = result + Text(String(text[cursor..<text.endIndex])).foregroundColor(baseColor)
            break
        }
        found = true
        if cursor < match.0.lowerBound {
            result = result + Text(String(text[cursor..<match.0.lowerBound])).foregroundColor(baseColor)
        }
        result = result + Text(String(text[match.0])).foregroundColor(match.1 == "@所有人" ? IMColor.warning : IMColor.danger)
        cursor = match.0.upperBound
    }
    return found ? result : Text(text).foregroundColor(baseColor)
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
