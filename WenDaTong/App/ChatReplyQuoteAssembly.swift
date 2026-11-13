import IM4Features
// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
import SwiftUI
import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110
import UIKit

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
@MainActor
func resolvedVisibleReplyPresentation(
    for message: ChatMessage,
    conversation: @autoclosure () -> ConversationMessageSnapshot,
    state: AppState,
    indexedSources: ChatReplySourceSnapshot? = nil, // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110
    showsProcessingNotices: Bool? = nil // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
) -> (quote: String, context: MessageReplyContext?)? {
    guard let fallbackQuote = visibleReplyQuote(for: message) else { return nil }
    guard var context = message.replyContext else {
        return (fallbackQuote, nil)
    }
    let showsNotices = showsProcessingNotices ?? state.shouldShowMessageProcessingNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    if !showsNotices && context.isUnavailable { return nil }
    let sourceMessageID = context.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
    let source: ChatMessage?
    if let indexedSources {
        source = indexedSources.lookup.message(in: indexedSources.messages, id: sourceMessageID, sequence: context.channelSeq)
    } else {
        source = conversation().messages.first { candidate in
            if !sourceMessageID.isEmpty, candidate.id == sourceMessageID {
                return true
            }
            return context.channelSeq > 0 && candidate.channelSeq == context.channelSeq
        }
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END
    guard let source else {
        return (fallbackQuote, context)
    }
    let sourceUnavailable = source.status == .recalled || source.isDeletedLocally
    if !showsNotices && sourceUnavailable { return nil }
    context.isUnavailable = sourceUnavailable
    context.summary = sourceUnavailable
        ? "原消息不可见/已删除"
        : resolvedReplySummary(for: source, state: state)
    context.contentType = source.contentType.isEmpty ? source.kind.rawValue : source.contentType
    if context.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        context.senderName = source.senderName
    }
    if source.isStickerMessage {
        context.thumbnailURL = source.stickerSnapshot?.thumbnailURL ?? context.thumbnailURL
    }
    return (context.quoteText, context)
}

@MainActor
private func resolvedReplySummary(for message: ChatMessage, state: AppState) -> String {
    switch message.kind {
    case .rtcCallRecord:
        return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
            ?? "[通话记录]"
    case .image:
        return "[图片]"
    case .file:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        switch state.attachmentMediaCategory(for: message) {
        case "video":
            return "[视频]"
        case "audio":
            return name.isEmpty ? "[音频]" : "[音频] \(name)"
        default:
            return name.isEmpty ? "[文件]" : "[文件] \(name)"
        }
    case .voice:
        return "[语音]"
    case .video:
        return "[视频]"
    case .location:
        return "[位置]"
    case .contactCard:
        let name = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[名片]" : "[名片] \(name)"
    case .system:
        return "回复了一条消息"
    case .text:
        if message.isStickerMessage {
            return message.stickerSnapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText
        }
        let text = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "回复了一条消息" : text
    }
}

// WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
struct TranscriptReplyQuote: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.chatReplySource) private var sources
    @Environment(\.chatShowsMessageProcessingNotices) private var showsNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    let message: ChatMessage
    let conversationID: String
    let outgoing: Bool

    var body: some View {
        let resolved = resolvedVisibleReplyPresentation(
            for: message,
            conversation: state.conversation(id: conversationID),
            state: state,
            indexedSources: sources,
            showsProcessingNotices: showsNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        )
#if DEBUG
        let _ = ChatReplyAssemblyDiagnostics.resolution?(message.id, resolved != nil)
#endif
        if let reply = resolved {
            ReplyQuoteBlock(
                quote: reply.quote, context: reply.context, outgoing: outgoing,
                hasTransparentBackground: !message.isStickerMessage && AttachmentGIFPresentation.usesBorderlessContainer(message)
            )
        }
    }
}
// WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END

struct ReplyQuoteBlock: View {
    let quote: String
    var context: MessageReplyContext? = nil
    let outgoing: Bool
    var compact = false
    var hasTransparentBackground = false

    private var usesOutgoingFill: Bool { outgoing && !hasTransparentBackground }
    @EnvironmentObject private var state: AppState
    @Environment(\.contactDirectoryPresentation) private var directory // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110

    private var parsedQuote: (sender: String, summary: String) {
        if let context {
            let sender = replyContextDisplaySenderName(context)
            let summary = context.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                sender.isEmpty ? "原消息" : sender,
                summary.isEmpty ? (context.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary
            )
        }
        let normalized = quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["：", ":"] {
            if let range = normalized.range(of: separator) {
                let sender = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sender.isEmpty, !summary.isEmpty {
                    return (sender, summary)
                }
            }
        }
        return ("回复消息", normalized.isEmpty ? "回复了一条消息" : normalized)
    }

    private func replyContextDisplaySenderName(_ context: MessageReplyContext) -> String {
        let senderID = context.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderName = context.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [senderID],
            candidates: [senderName],
            fallback: senderName.isEmpty ? "原消息" : senderName,
            directory: directory // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110
        )
    }

    private var isStickerQuote: Bool {
        context?.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sticker"
    }

    private var resolvedThumbnailURL: String {
        state.resolvedStickerAssetURLString(context?.thumbnailURL ?? "")
    }

    var body: some View {
        let parsed = parsedQuote
        let presentation = ReplyQuotePresentation(
            sender: parsed.sender, summary: parsed.summary, senderID: context?.senderID ?? "",
            sourceMessageID: context?.messageID ?? "", isSticker: isStickerQuote,
            thumbnailURL: resolvedThumbnailURL, originalThumbnailURL: context?.thumbnailURL ?? ""
        )
#if DEBUG
        ChatReplyAssemblyDiagnostics.capture?(presentation)
#endif
        return ReplyQuoteContent(presentation: presentation, outgoing: outgoing, compact: compact,
                                hasTransparentBackground: hasTransparentBackground).equatable()
    }
}

#if DEBUG
@MainActor enum ChatReplyAssemblyDiagnostics {
    static var capture: ((ReplyQuotePresentation) -> Void)?
    static var resolution: ((String, Bool) -> Void)?
}
#endif
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END

// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END
