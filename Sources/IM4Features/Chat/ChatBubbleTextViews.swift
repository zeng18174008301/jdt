import IM4Domain
import IM4DesignSystem
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

// WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
private struct ChatShowsMessageProcessingNoticesKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    public var chatShowsMessageProcessingNotices: Bool? {
        get { self[ChatShowsMessageProcessingNoticesKey.self] }
        set { self[ChatShowsMessageProcessingNoticesKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END

public func visibleReplyQuote(for message: ChatMessage) -> String? {
    let rawQuote = message.quote ?? message.replyContext?.quoteText
    let quote = rawQuote?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return quote?.isEmpty == false ? quote : nil
}

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
public struct ReplyQuotePresentation: Equatable {
    public let sender: String
    public let summary: String
    public let senderID: String
    public let sourceMessageID: String
    public let isSticker: Bool
    public let thumbnailURL: String
    public let originalThumbnailURL: String

    public init(sender: String,
        summary: String,
        senderID: String,
        sourceMessageID: String,
        isSticker: Bool,
        thumbnailURL: String,
        originalThumbnailURL: String) {
        self.sender = sender
        self.summary = summary
        self.senderID = senderID
        self.sourceMessageID = sourceMessageID
        self.isSticker = isSticker
        self.thumbnailURL = thumbnailURL
        self.originalThumbnailURL = originalThumbnailURL
    }
}

public struct ReplyQuoteContent: View, Equatable {
    let presentation: ReplyQuotePresentation
    let outgoing: Bool
    let compact: Bool
    let hasTransparentBackground: Bool
    @Environment(\.chatCertificationRendering) private var certificationSource
    private var usesOutgoingFill: Bool { outgoing && !hasTransparentBackground }
    private var isStickerQuote: Bool { presentation.isSticker }
    private var resolvedThumbnailURL: String { presentation.thumbnailURL }

    nonisolated static public func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation && lhs.outgoing == rhs.outgoing
            && lhs.compact == rhs.compact && lhs.hasTransparentBackground == rhs.hasTransparentBackground
    }

    public var body: some View {
        let parsed = presentation
        HStack(alignment: .top, spacing: 8) {
            Capsule(style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.46) : IMColor.brand.opacity(0.64))
                .frame(width: 3, height: compact ? 34 : 42)
            if isStickerQuote {
                stickerQuoteThumbnail
            }
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: compact ? 8 : 9, weight: .black))
                    Text(parsed.sender)
                        .lineLimit(1)
                    ChatCertificationPillView(
                        exactUID: presentation.senderID,
                        compact: true
                    )
                }
                .font(.system(size: compact ? 11 : 12, weight: .black))
                .foregroundStyle(usesOutgoingFill ? .white.opacity(0.86) : IMColor.brand)
                Text(parsed.summary)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 8 : 9)
        .padding(.vertical, compact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.14) : IMColor.brand.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .stroke(usesOutgoingFill ? .white.opacity(0.16) : IMColor.brand.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .certificationAccessibilityLabel(
            "回复 \(parsed.sender)",
            reference: certificationSource?.reference(forExactUID: presentation.senderID),
            trailing: parsed.summary
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    }

    private var stickerQuoteThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.16) : IMColor.brand.opacity(0.10))
            if resolvedThumbnailURL.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
            } else {
                ChatRemoteImageView(
                    urlString: resolvedThumbnailURL,
                    cacheKey: "reply-sticker|\(presentation.sourceMessageID)|\(presentation.originalThumbnailURL)",
                    contentMode: .fit,
                    // WDT_CHAT_RESOURCE_PERF_20261023: bound the quote preview, not the original asset.
                    maxPixelSize: Int((compact ? 30 : 34) * UIScreen.main.scale)
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
                }
                .padding(3)
            }
        }
        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    public init(presentation: ReplyQuotePresentation,
        outgoing: Bool,
        compact: Bool,
        hasTransparentBackground: Bool) {
        self.presentation = presentation
        self.outgoing = outgoing
        self.compact = compact
        self.hasTransparentBackground = hasTransparentBackground
    }
}

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END

public struct MentionTextTarget: Hashable {
    public let name: String
    public let user: IMUser?
    public var isAll = false

    public var token: String { "@\(name)" }

    public init(name: String,
        user: IMUser? = nil,
        isAll: Bool = false) {
        self.name = name
        self.user = user
        self.isAll = isAll
    }
}

private struct MentionTextSegment: Identifiable {
    let id = UUID()
    let text: String
    let user: IMUser?
    let isMention: Bool
    let isAll: Bool
}

struct MentionStyledMessageText: View {
    let text: String
    let targets: [MentionTextTarget]
    let outgoing: Bool
    let onMentionTap: (IMUser) -> Void

    private var segments: [MentionTextSegment] {
        mentionTextSegments(in: text, targets: targets)
    }

    private var mentionUsersByURL: [String: IMUser] {
        segments.reduce(into: [:]) { result, segment in
            guard let user = segment.user, let url = mentionURL(for: user) else { return }
            result[url.absoluteString] = user
        }
    }

    private var attributedText: AttributedString {
        var output = AttributedString()
        let baseColor = outgoing ? Color.white : IMColor.ink
        let mentionColor = outgoing ? Color(im4Hex: 0xEAF2FF) : Color(im4Hex: 0x2563EB)
        let mentionAllColor = outgoing ? Color(im4Hex: 0xFFE8A3) : Color(im4Hex: 0xB45309)

        for segment in segments {
            var part = AttributedString(segment.text)
            part.font = segment.isMention ? .system(size: 15, weight: .heavy) : .system(size: 15, weight: .semibold)
            part.foregroundColor = segment.isAll ? mentionAllColor : (segment.isMention ? mentionColor : baseColor)
            if segment.isMention, let user = segment.user, let url = mentionURL(for: user) {
                part.link = url
            }
            output += part
        }
        return output
    }

    var body: some View {
        Text(attributedText)
            .environment(\.openURL, OpenURLAction { url in
                guard let user = mentionUsersByURL[url.absoluteString] else {
                    return .discarded
                }
                onMentionTap(user)
                return .handled
            })
    }
}

private func mentionTextSegments(in text: String, targets: [MentionTextTarget]) -> [MentionTextSegment] {
    guard !text.isEmpty, !targets.isEmpty else {
        return [MentionTextSegment(text: text, user: nil, isMention: false, isAll: false)]
    }

    var segments: [MentionTextSegment] = []
    var cursor = text.startIndex

    while cursor < text.endIndex {
        guard let match = nextMentionMatch(in: text, from: cursor, targets: targets) else {
            segments.append(MentionTextSegment(text: String(text[cursor..<text.endIndex]), user: nil, isMention: false, isAll: false))
            break
        }

        if cursor < match.range.lowerBound {
            segments.append(MentionTextSegment(text: String(text[cursor..<match.range.lowerBound]), user: nil, isMention: false, isAll: false))
        }
        segments.append(MentionTextSegment(text: String(text[match.range]), user: match.target.user, isMention: true, isAll: match.target.isAll))
        cursor = match.range.upperBound
    }

    return segments
}

private func nextMentionMatch(in text: String, from cursor: String.Index, targets: [MentionTextTarget]) -> (range: Range<String.Index>, target: MentionTextTarget)? {
    var best: (range: Range<String.Index>, target: MentionTextTarget)?
    for target in targets {
        var searchStart = cursor
        while searchStart < text.endIndex,
              let range = text.range(of: target.token, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            if isSafeMentionBoundary(in: text, range: range) {
                if best == nil
                    || range.lowerBound < best!.range.lowerBound
                    || (range.lowerBound == best!.range.lowerBound && range.upperBound > best!.range.upperBound) {
                    best = (range, target)
                }
                break
            }
            searchStart = range.upperBound
        }
    }
    return best
}

private func isSafeMentionBoundary(in text: String, range: Range<String.Index>) -> Bool {
    if range.lowerBound > text.startIndex {
        let before = text[text.index(before: range.lowerBound)]
        if isEmailOrIdentifierContinuation(before) {
            return false
        }
    }
    if range.upperBound < text.endIndex {
        let after = text[range.upperBound]
        if isEmailOrIdentifierContinuation(after) {
            return false
        }
    }
    return true
}

private func isEmailOrIdentifierContinuation(_ character: Character) -> Bool {
    if character.isLetter || character.isNumber { return true }
    return [".", "_", "-", "@"].contains(String(character))
}

public func mentionUserKey(for user: IMUser) -> String {
    let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if !id.isEmpty { return id }
    let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !userID.isEmpty { return userID }
    return user.username.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func mentionUserStableKeys(for user: IMUser) -> [String] {
    var seen = Set<String>()
    return [user.id, user.userID, user.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

public func mentionTargetName(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix("@") {
        text.removeFirst()
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func mentionVisibleDisplayName(for user: IMUser) -> String {
    if user.isCancelledUser {
        return cancelledUserDisplayName
    }
    let trimmedName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let stableKeys = Set(mentionUserStableKeys(for: user))
    if !trimmedName.isEmpty, !stableKeys.contains(trimmedName) {
        return trimmedName
    }
    return "未命名成员"
}

private func mentionURL(for user: IMUser) -> URL? {
    let key = mentionUserKey(for: user)
    guard !key.isEmpty else { return nil }
    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
    return URL(string: "im2-mention://user/\(encodedKey)")
}

private extension Array where Element == IMUser {
    func deduplicatedByMentionIdentity() -> [IMUser] {
        var seen = Set<String>()
        return filter { user in
            let key = mentionUserKey(for: user)
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
