// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话/消息快照模型允许安全跨异步任务传递
public enum ConversationKind: String, Hashable, Sendable {
    case direct = "单聊"
    case group = "群聊"
    case system = "系统"
}

public enum MessageKind: String, Hashable, Sendable {
    case text
    case rtcCallRecord = "rtc_call_record"
    case image
    case file
    case system
    case location
    case voice
    case video
    case contactCard
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息投影状态允许安全跨异步任务传递
public enum MessageDelivery: String, Hashable, Sendable {
    case sending = "发送中"
    case sent = "已送达"
    case read = "已读"
    case failed = "未送达 · 点按重发"
    case recalled = "已撤回"
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息附属展示模型允许安全跨异步任务传递
public struct Reaction: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        emoji: String,
        count: Int,
        reactedByMe: Bool
    ) {
        self.id = id
        self.emoji = emoji
        self.count = count
        self.reactedByMe = reactedByMe
    }
    public let id: String
    public let emoji: String
    public var count: Int
    public var reactedByMe: Bool
}

public struct ReactionDetail: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        emoji: String,
        user: IMUser,
        time: String
    ) {
        self.id = id
        self.emoji = emoji
        self.user = user
        self.time = time
    }
    public let id: String
    public let emoji: String
    public let user: IMUser
    public let time: String
}

public struct ReadReceipt: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        user: IMUser,
        device: String,
        time: String
    ) {
        self.id = id
        self.user = user
        self.device = device
        self.time = time
    }
    public let id: String
    public let user: IMUser
    public let device: String
    public let time: String
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

public struct MentionIdentity: Identifiable, Hashable, Codable, Sendable {
    public let imUID: String
    public let userID: String
    public let username: String
    public let displayText: String

    public var id: String {
        if !imUID.isEmpty { return imUID }
        if !userID.isEmpty { return userID }
        return username
    }

    public var mentionToken: String {
        displayText.hasPrefix("@") ? displayText : "@\(displayText)"
    }

    public init(imUID: String, userID: String = "", username: String = "", displayText: String) {
        self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(user: IMUser) {
        self.init(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: user.name.isEmpty ? user.id : user.name
        )
    }

    public func matches(_ user: IMUser) -> Bool {
        let candidates = [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return [imUID, userID, username]
            .filter { !$0.isEmpty }
            .contains { key in candidates.contains(key) }
    }
}

public struct MessageReplyContext: Identifiable, Hashable, Codable, Sendable {
    public var messageID: String
    public var senderID: String
    public var senderName: String
    public var summary: String
    public var contentType: String
    public var channelSeq: Int64
    public var isUnavailable: Bool
    public var thumbnailURL: String = ""

    enum CodingKeys: String, CodingKey {
        case messageID
        case senderID
        case senderName
        case summary
        case contentType
        case channelSeq
        case isUnavailable
        case thumbnailURL
    }

    public var id: String {
        if !messageID.isEmpty { return messageID }
        if channelSeq > 0 { return "seq-\(channelSeq)" }
        return "\(senderID)|\(summary)"
    }

    public var quoteText: String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSummary = cleanSummary.isEmpty ? (isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : cleanSummary
        let cleanSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSender.isEmpty else { return fallbackSummary }
        return "\(cleanSender)：\(fallbackSummary)"
    }

    public init(
        messageID: String = "",
        senderID: String = "",
        senderName: String = "",
        summary: String,
        contentType: String = "",
        channelSeq: Int64 = 0,
        isUnavailable: Bool = false,
        thumbnailURL: String = ""
    ) {
        self.messageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senderID = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelSeq = channelSeq
        self.isUnavailable = isUnavailable
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messageID: try c.decodeIfPresent(String.self, forKey: .messageID) ?? "",
            senderID: try c.decodeIfPresent(String.self, forKey: .senderID) ?? "",
            senderName: try c.decodeIfPresent(String.self, forKey: .senderName) ?? "",
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            contentType: try c.decodeIfPresent(String.self, forKey: .contentType) ?? "",
            channelSeq: try c.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0,
            isUnavailable: try c.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false,
            thumbnailURL: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messageID, forKey: .messageID)
        try c.encode(senderID, forKey: .senderID)
        try c.encode(senderName, forKey: .senderName)
        try c.encode(summary, forKey: .summary)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(channelSeq, forKey: .channelSeq)
        try c.encode(isUnavailable, forKey: .isUnavailable)
        try c.encode(thumbnailURL, forKey: .thumbnailURL)
    }
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息模型允许安全跨后台投影任务传递
public struct ChatMessage: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        senderId: String,
        senderProvenance: BatchForwardSenderProvenance = .unknown,
        senderName: String,
        senderAvatarURL: String = "",
        senderAvatarVersion: String = "",
        senderAvatarUpdatedAt: String = "",
        senderAvatarSeed: UInt = 0,
        text: String,
        time: String,
        createdAt: Date? = nil,
        channelSeq: Int64 = 0,
        isOutgoing: Bool,
        status: MessageDelivery,
        kind: MessageKind,
        contentType: String = "",
        reactions: [Reaction],
        reactionDetails: [ReactionDetail] = [],
        readBy: [ReadReceipt],
        unreadBy: [ReadReceipt],
        readCount: Int? = nil,
        unreadCount: Int? = nil,
        readStateKnown: Bool = false,
        deliveryStateKnown: Bool = false,
        canViewReadDetails: Bool = true,
        quote: String? = nil,
        replyContext: MessageReplyContext? = nil,
        attachmentName: String? = nil,
        attachmentMeta: String? = nil,
        attachmentFileID: String? = nil,
        attachmentSizeBytes: Int64? = nil,
        attachmentPreviewURL: String = "",
        attachmentDownloadURL: String = "",
        attachmentPreviewAvailable: Bool = false,
        attachmentDownloadAvailable: Bool = false,
        attachmentTransferProgress: Double? = nil,
        attachmentMimeType: String = "",
        attachmentCacheKey: String = "",
        attachmentVersion: String = "",
        attachmentChecksum: String = "",
        attachmentMediaCategory: String = "",
        attachmentExtension: String = "",
        attachmentThumbnailURL: String = "",
        attachmentPosterURL: String = "",
        attachmentCoverURL: String = "",
        attachmentPreviewKind: String = "",
        attachmentContentDisposition: String = "",
        attachmentWidth: Int? = nil,
        attachmentHeight: Int? = nil,
        attachmentDurationSeconds: Double? = nil,
        attachmentUploadStatus: String = "",
        attachmentUploadFailure: AttachmentUploadFailure? = nil,
        isPinned: Bool = false,
        isPinnedContextOnly: Bool = false,
        isFavorited: Bool = false,
        isDeletedLocally: Bool = false,
        isEdited: Bool = false,
        auditTags: [String] = [],
        reportState: String? = nil,
        serverTrace: String? = nil,
        mentionExcluded: Bool = false,
        mentionAll: Bool = false,
        mentionedUsers: [MentionIdentity] = [],
        voiceWaveform: [Int] = [],
        stickerSnapshot: StickerMessageSnapshot? = nil,
        rtcCallRecord: RTCCallRecordPayload? = nil,
        systemEventType: String? = nil,
        systemDisplayStyle: String? = nil,
        systemColorToken: String? = nil,
        systemTextColorHex: String? = nil,
        systemBackgroundColorHex: String? = nil,
        systemAccentColorHex: String? = nil,
        groupInviteApproval: GroupInviteApproval? = nil
    ) {
        self.id = id
        self.senderId = senderId
        self.senderProvenance = senderProvenance
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.senderAvatarVersion = senderAvatarVersion
        self.senderAvatarUpdatedAt = senderAvatarUpdatedAt
        self.senderAvatarSeed = senderAvatarSeed
        self.text = text
        self.time = time
        self.createdAt = createdAt
        self.channelSeq = channelSeq
        self.isOutgoing = isOutgoing
        self.status = status
        self.kind = kind
        self.contentType = contentType
        self.reactions = reactions
        self.reactionDetails = reactionDetails
        self.readBy = readBy
        self.unreadBy = unreadBy
        self.readCount = readCount
        self.unreadCount = unreadCount
        self.readStateKnown = readStateKnown
        self.deliveryStateKnown = deliveryStateKnown
        self.canViewReadDetails = canViewReadDetails
        self.quote = quote
        self.replyContext = replyContext
        self.attachmentName = attachmentName
        self.attachmentMeta = attachmentMeta
        self.attachmentFileID = attachmentFileID
        self.attachmentSizeBytes = attachmentSizeBytes
        self.attachmentPreviewURL = attachmentPreviewURL
        self.attachmentDownloadURL = attachmentDownloadURL
        self.attachmentPreviewAvailable = attachmentPreviewAvailable
        self.attachmentDownloadAvailable = attachmentDownloadAvailable
        self.attachmentTransferProgress = attachmentTransferProgress
        self.attachmentMimeType = attachmentMimeType
        self.attachmentCacheKey = attachmentCacheKey
        self.attachmentVersion = attachmentVersion
        self.attachmentChecksum = attachmentChecksum
        self.attachmentMediaCategory = attachmentMediaCategory
        self.attachmentExtension = attachmentExtension
        self.attachmentThumbnailURL = attachmentThumbnailURL
        self.attachmentPosterURL = attachmentPosterURL
        self.attachmentCoverURL = attachmentCoverURL
        self.attachmentPreviewKind = attachmentPreviewKind
        self.attachmentContentDisposition = attachmentContentDisposition
        self.attachmentWidth = attachmentWidth
        self.attachmentHeight = attachmentHeight
        self.attachmentDurationSeconds = attachmentDurationSeconds
        self.attachmentUploadStatus = attachmentUploadStatus
        self.attachmentUploadFailure = attachmentUploadFailure
        self.isPinned = isPinned
        self.isPinnedContextOnly = isPinnedContextOnly
        self.isFavorited = isFavorited
        self.isDeletedLocally = isDeletedLocally
        self.isEdited = isEdited
        self.auditTags = auditTags
        self.reportState = reportState
        self.serverTrace = serverTrace
        self.mentionExcluded = mentionExcluded
        self.mentionAll = mentionAll
        self.mentionedUsers = mentionedUsers
        self.voiceWaveform = voiceWaveform
        self.stickerSnapshot = stickerSnapshot
        self.rtcCallRecord = rtcCallRecord
        self.systemEventType = systemEventType
        self.systemDisplayStyle = systemDisplayStyle
        self.systemColorToken = systemColorToken
        self.systemTextColorHex = systemTextColorHex
        self.systemBackgroundColorHex = systemBackgroundColorHex
        self.systemAccentColorHex = systemAccentColorHex
        self.groupInviteApproval = groupInviteApproval
    }
    public let id: String
    public let senderId: String
    public var senderProvenance: BatchForwardSenderProvenance = .unknown
    public var senderName: String
    public var senderAvatarURL: String = ""
    public var senderAvatarVersion: String = ""
    public var senderAvatarUpdatedAt: String = ""
    public var senderAvatarSeed: UInt = 0
    public var text: String
    public let time: String
    public var createdAt: Date? = nil
    public var channelSeq: Int64 = 0
    public let isOutgoing: Bool
    public var status: MessageDelivery
    public let kind: MessageKind
    public var contentType: String = ""
    public var reactions: [Reaction]
    public var reactionDetails: [ReactionDetail] = []
    public var readBy: [ReadReceipt]
    public var unreadBy: [ReadReceipt]
    public var readCount: Int? = nil
    public var unreadCount: Int? = nil
    public var readStateKnown: Bool = false
    public var deliveryStateKnown: Bool = false
    public var canViewReadDetails: Bool = true
    public var quote: String?
    public var replyContext: MessageReplyContext? = nil
    public var attachmentName: String?
    public var attachmentMeta: String?
    public var attachmentFileID: String? = nil
    public var attachmentSizeBytes: Int64? = nil
    public var attachmentPreviewURL: String = ""
    public var attachmentDownloadURL: String = ""
    public var attachmentPreviewAvailable: Bool = false
    public var attachmentDownloadAvailable: Bool = false
    public var attachmentTransferProgress: Double? = nil
    public var attachmentMimeType: String = ""
    public var attachmentCacheKey: String = ""
    public var attachmentVersion: String = ""
    public var attachmentChecksum: String = ""
    public var attachmentMediaCategory: String = ""
    public var attachmentExtension: String = ""
    public var attachmentThumbnailURL: String = ""
    public var attachmentPosterURL: String = ""
    public var attachmentCoverURL: String = ""
    public var attachmentPreviewKind: String = ""
    public var attachmentContentDisposition: String = ""
    public var attachmentWidth: Int? = nil
    public var attachmentHeight: Int? = nil
    public var attachmentDurationSeconds: Double? = nil
    public var attachmentUploadStatus: String = ""
    public var attachmentUploadFailure: AttachmentUploadFailure? = nil
    public var isPinned: Bool = false
    public var isPinnedContextOnly: Bool = false
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    public var isHistorySearchDateContent: Bool {
        createdAt != nil && channelSeq > 0 && !isPinnedContextOnly && !isDeletedLocally && kind != .system
            && (status == .sent || status == .read)
    }
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    public var isFavorited: Bool = false
    public var isDeletedLocally: Bool = false
    public var isEdited: Bool = false
	public var editRevision: Int64 = 0
    public var auditTags: [String] = []
    public var reportState: String? = nil
    public var serverTrace: String? = nil
    public var mentionExcluded: Bool = false
    public var mentionAll: Bool = false
    public var mentionedUsers: [MentionIdentity] = []
    public var voiceWaveform: [Int] = []
    public var stickerSnapshot: StickerMessageSnapshot? = nil
    public var rtcCallRecord: RTCCallRecordPayload? = nil

    public var isRTCCallRecordMessage: Bool {
        contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
    }

    public var isStickerMessage: Bool {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedContentType == "sticker" || stickerSnapshot != nil
    }

    public var isForwardSupported: Bool {
        guard !isDeletedLocally,
              status != .sending,
              status != .failed,
              status != .recalled,
              !isRTCCallRecordMessage else { return false }
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isStickerMessage {
            return normalizedContentType.isEmpty || normalizedContentType == "sticker"
        }
        switch kind {
        case .text:
            return normalizedContentType.isEmpty || normalizedContentType == "text"
        case .file:
            guard normalizedContentType.isEmpty || normalizedContentType == "file" || normalizedContentType == "attachment" else {
                return false
            }
            let mediaCategory = attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let previewKind = attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unsupportedMedia = ["image", "video", "audio", "voice"]
            return !unsupportedMedia.contains(mediaCategory) && !unsupportedMedia.contains(previewKind)
        default:
            return false
        }
    }
    public var systemEventType: String? = nil
    public var systemDisplayStyle: String? = nil
    public var systemColorToken: String? = nil
    public var systemTextColorHex: String? = nil
    public var systemBackgroundColorHex: String? = nil
    public var systemAccentColorHex: String? = nil
    public var groupInviteApproval: GroupInviteApproval? = nil
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

public func inferredAttachmentMediaCategory(kind: MessageKind, name: String, mimeType: String) -> String {
    let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let ext = (name as NSString).pathExtension.lowercased()
    if kind == .voice {
        return "voice"
    }
    if kind == .image || normalizedMime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext) {
        return "image"
    }
    if normalizedMime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(ext) {
        return "video"
    }
    if normalizedMime.contains("pdf") || ext == "pdf" {
        return "pdf"
    }
    if normalizedMime.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) {
        return "audio"
    }
    if ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
        return "archive"
    }
    return "file"
}

extension ChatMessage {
    public var resolvedAttachmentMimeType: String {
        let explicit = attachmentMimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !explicit.isEmpty {
            return explicit
        }
        if let value = attachmentMeta?
            .components(separatedBy: " · ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           value.contains("/") {
            return value.lowercased()
        }
        if kind == .image { return "image/jpeg" }
        if kind == .voice { return "audio/mp4" }
        return "application/octet-stream"
    }

    public var conversationAttachmentPreview: String? {
        guard !isDeletedLocally, status != .recalled else { return nil }
        switch kind {
        case .image: return "图片"
        case .video: return "视频"
        case .voice: return "音频"
        case .file:
            let explicit = attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let preview = attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = attachmentName.flatMap { $0.isEmpty ? nil : $0 } ?? text
            let category = [explicit, preview].first { ["image", "video", "audio", "voice"].contains($0) }
                ?? inferredAttachmentMediaCategory(
                    kind: kind,
                    name: name,
                    mimeType: resolvedAttachmentMimeType
                )
            switch category {
            case "image": return "图片"
            case "video": return "视频"
            case "audio", "voice": return "音频"
            default: return "文件"
            }
        default: return nil
        }
    }

}

public enum MessageMentionProjection {
    public static func includes(_ message: ChatMessage, currentActor: IMUser) -> Bool {
        guard !message.isOutgoing,
              message.status != .recalled,
              !message.isDeletedLocally,
              message.kind != .system,
              !message.mentionExcluded else {
            return false
        }
        if message.mentionAll {
            return true
        }
        return message.mentionedUsers.contains { $0.matches(currentActor) }
    }
}

public struct MessageSearchHit: Identifiable, Hashable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        messageID: String,
        conversationID: String,
        senderName: String,
        snippet: String,
        time: String
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.senderName = senderName
        self.snippet = snippet
        self.time = time
    }
    public let id: String
    public let messageID: String
    public let conversationID: String
    public let senderName: String
    public let snippet: String
    public let time: String
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
