import IM4Domain
import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

extension AppState {
    private func remoteReplyQuote(from message: RemoteMessage, participants: [IMUser]) -> String? {
        if let context = remoteReplyContext(from: message, participants: participants) {
            return context.quoteText
        }
        if let topLevelQuote = sanitizedReplyComponent(message.quote) {
            return topLevelQuote
        }
        if let payloadQuote = sanitizedReplyComponent(payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"])) {
            return payloadQuote
        }

        for key in ["reply_message", "replyMessage", "quoted_message", "quoted", "reply"] {
            guard let value = message.payload[key] else { continue }
            if let quote = remoteReplyQuote(from: value, participants: participants) {
                return quote
            }
        }
        for key in ["reply_to", "replyTo"] {
            guard let replyTo = message.payload[key] else { continue }
            if case .object = replyTo, let quote = remoteReplyQuote(from: replyTo, participants: participants) {
                return quote
            }
            if let messageID = sanitizedReplyComponent(replyTo.stringValue) {
                return unavailableReplyContext(messageID: messageID).quoteText
            }
        }

        if let extra = message.payload["message_extra"]?.objectValue,
           let reply = extra["reply"],
           let quote = remoteReplyQuote(from: reply, participants: participants) {
            return quote
        }

        return nil
    }

    private func remoteReplyContext(from message: RemoteMessage, participants: [IMUser]) -> MessageReplyContext? {
        for key in ["reply_to", "replyTo"] {
            guard let replyTo = message.payload[key] else { continue }
            if replyTo.objectValue != nil,
               let context = remoteReplyContext(from: replyTo, participants: participants) {
                return context
            }
            if let messageID = sanitizedReplyComponent(replyTo.stringValue) {
                return replyContextFromQuote(message.quote ?? payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"]), messageID: messageID)
                    ?? unavailableReplyContext(messageID: messageID)
            }
        }
        for key in ["reply_message", "replyMessage", "reply", "quoted_message", "quoted"] {
            guard let value = message.payload[key],
                  let context = remoteReplyContext(from: value, participants: participants) else { continue }
            return context
        }
        if let replyID = sanitizedReplyComponent(payloadString(message.payload, ["reply_to_message_id", "reply_message_id", "quoted_message_id"])) {
            return replyContextFromQuote(message.quote ?? payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"]), messageID: replyID)
                ?? unavailableReplyContext(messageID: replyID)
        }
        if let extra = message.payload["message_extra"]?.objectValue,
           let reply = extra["reply"],
           let context = remoteReplyContext(from: reply, participants: participants) {
            return context
        }
        return nil
    }

    private func remoteReplyQuote(from value: JSONValue, participants: [IMUser]) -> String? {
        if let context = remoteReplyContext(from: value, participants: participants) {
            return context.quoteText
        }
        if let stringValue = value.stringValue {
            return sanitizedReplyComponent(stringValue)
        }
        guard let object = value.objectValue else { return nil }
        if let directQuote = sanitizedReplyComponent(payloadString(object, ["quote", "quote_text", "quoted_text"])) {
            return directQuote
        }
        if let nested = object["message"], let quote = remoteReplyQuote(from: nested, participants: participants) {
            return quote
        }

        let senderName = replySenderDisplayName(from: object, participants: participants)
        let summary = remoteReplySummary(from: object) ?? "回复了一条消息"
        guard let cleanSummary = sanitizedReplyComponent(summary) else { return nil }
        guard let cleanSender = sanitizedReplyComponent(senderName), !cleanSender.isEmpty else {
            return cleanSummary
        }
        if cleanSummary.hasPrefix("\(cleanSender)：") || cleanSummary.hasPrefix("\(cleanSender):") {
            return cleanSummary
        }
        return "\(cleanSender)：\(cleanSummary)"
    }

    private func remoteReplyContext(from value: JSONValue, participants: [IMUser]) -> MessageReplyContext? {
        if let stringValue = value.stringValue {
            return replyContextFromQuote(stringValue)
        }
        guard let object = value.objectValue else { return nil }
        if let nested = object["message"],
           let context = remoteReplyContext(from: nested, participants: participants) {
            return context
        }
        let messageID = payloadString(object, ["message_id", "id", "msg_id", "reply_to_message_id", "reply_message_id", "quoted_message_id"])
        let senderID = payloadString(object, ["from_uid", "sender_uid", "sender_user_id", "from_user_id", "im_uid", "user_id"])
        let senderName = replySenderDisplayName(from: object, participants: participants)
        let status = payloadString(object, ["status", "message_status"]).lowercased()
        let isUnavailable = ["deleted", "recalled", "removed", "invisible"].contains(status)
        let summary = remoteReplySummary(from: object)
            ?? sanitizedReplyComponent(payloadString(object, ["quote", "quote_text", "quoted_text", "reply_quote"]))
            ?? (isUnavailable ? "原消息不可查看/已撤回" : "回复了一条消息")
        let contentType = payloadString(object, ["content_type", "type", "kind", "media_category", "category", "preview_kind"])
        let channelSeq = payloadInt64(object, ["channel_seq", "seq"]) ?? 0
        return MessageReplyContext(
            messageID: messageID,
            senderID: senderID,
            senderName: senderName,
            summary: summary,
            contentType: contentType,
            channelSeq: channelSeq,
            isUnavailable: isUnavailable,
            thumbnailURL: payloadString(object, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"])
        )
    }

    private func replyContextFromQuote(_ quote: String?, messageID: String = "") -> MessageReplyContext? {
        guard let cleanQuote = sanitizedReplyComponent(quote) else { return nil }
        for separator in ["：", ":"] {
            if let range = cleanQuote.range(of: separator) {
                let sender = String(cleanQuote[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = String(cleanQuote[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    return MessageReplyContext(messageID: messageID, senderName: sender, summary: summary)
                }
            }
        }
        return MessageReplyContext(messageID: messageID, summary: cleanQuote)
    }

    private func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

    private func remoteReplySummary(from object: [String: JSONValue]) -> String? {
        if isStickerPayload(object, contentType: payloadString(object, ["content_type", "type"])) {
            return stickerFallbackText(from: object)
        }
        if let text = sanitizedReplyComponent(payloadString(object, ["text", "content", "body", "message_text", "original_text", "display_text", "summary", "preview", "quote", "quote_text", "quoted_text", "reply_quote"])) {
            return text
        }

        let contentType = payloadString(object, ["content_type", "type", "mime_type"])
        let kind = payloadString(object, ["kind", "media_category", "category", "preview_kind"])
        let normalizedType = "\(contentType) \(kind)".lowercased()
        let fileName = sanitizedReplyComponent(payloadString(object, ["file_name", "name", "filename", "attachment_name"]))
        if normalizedType.contains("image") || normalizedType.contains("photo") {
            return "[图片]"
        }
        if normalizedType.contains("video") || normalizedType.contains("movie") {
            return "[视频]"
        }
        if normalizedType.contains("voice") || normalizedType.contains("audio") {
            return "[语音]"
        }
        if normalizedType.contains("contact") || normalizedType.contains("card") {
            return "[名片] \(fileName ?? "联系人")"
        }
        if normalizedType.contains("file") || normalizedType.contains("pdf") || normalizedType.contains("download") || fileName != nil {
            if let fileName {
                return "[文件] \(fileName)"
            }
            return "[文件]"
        }
        return nil
    }

    private func replySenderDisplayName(from object: [String: JSONValue], participants: [IMUser]) -> String {
        let payloadName = payloadString(
            object,
            ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "display_name", "nickname", "user_name"]
        )
        if !payloadName.isEmpty {
            return payloadName
        }
        let senderID = payloadString(object, ["from_uid", "sender_uid", "sender_user_id", "from_user_id", "im_uid", "user_id"])
        guard !senderID.isEmpty else { return "" }
        let knownUser = user(for: senderID) ?? participants.first { user in
            user.id == senderID || user.userID == senderID || user.username == senderID
        }
        if let knownUser {
            let name = knownUser.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !isIdentifierLikeDisplayName(name, matching: senderID) {
                return name
            }
        }
        return senderID
    }

    private func sanitizedReplyComponent(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 180 {
            return collapsed
        }
        let index = collapsed.index(collapsed.startIndex, offsetBy: 180)
        return "\(collapsed[..<index])…"
    }

    private func rtcMessageDisplayTime(_ remote: RemoteMessage) -> String {
        let record = remote.channelSeq > 0 && !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RTCCallRecordPayload.parse(contentType: remote.contentType, channelType: remote.channelType, fromUID: remote.fromUID, payload: remote.payload)
            : nil
        let date = RTCCallRecordTimeProjection.messageDate(
            outerDate: parseRemoteDate(remote.createdAt),
            record: record,
            contentType: remote.contentType,
            channelType: remote.channelType,
            fromUID: remote.fromUID
        )
        return date.map { displayTime($0) } ?? "时间未知"
    }

    func chatMessage(from remote: RemoteMessage, participants: [IMUser] = [], forceOutgoing: Bool = false) -> ChatMessage {
        let isOutgoing = forceOutgoing || isRemoteMessageFromCurrentUser(remote)
        let kind = remoteMessageKind(from: remote)
        let rtcCallRecord: RTCCallRecordPayload? = {
            guard remote.channelSeq > 0,
                  !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return RTCCallRecordPayload.parse(
                contentType: remote.contentType,
                channelType: remote.channelType,
                fromUID: remote.fromUID,
                payload: remote.payload
            )
        }()
        let isAdminDeleted = isAdminDeletedRemoteMessage(remote)
        let isContactCard = kind == .contactCard
        let isAttachment = kind == .image || kind == .video || kind == .file || kind == .voice
        let stickerSnapshot = stickerSnapshot(from: remote)
        let attachmentFileName = attachmentPayloadString(remote.payload, ["file_name", "name", "filename"])
        let attachmentMimeType = attachmentPayloadString(remote.payload, ["mime_type", "content_type"])
        let attachmentSizeBytes = attachmentPayloadInt64(remote.payload, ["size_bytes", "size"])
        let attachmentObjectKey = attachmentPayloadString(remote.payload, ["thumb_object_key", "thumbnail_object_key", "object_key"])
        let attachmentCacheKey = attachmentPayloadString(remote.payload, ["cache_key", "cacheKey"], fallback: attachmentObjectKey)
        let attachmentVersion = attachmentPayloadString(remote.payload, ["version", "file_version", "cache_version"])
        let attachmentChecksum = attachmentPayloadString(remote.payload, ["checksum"])
        let attachmentMediaCategory = attachmentPayloadString(remote.payload, ["media_category", "category", "kind"])
        let attachmentExtension = attachmentPayloadString(remote.payload, ["extension", "ext", "file_extension"])
        let attachmentThumbnailURL = attachmentPayloadString(remote.payload, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"])
        let attachmentPosterURL = attachmentPayloadString(remote.payload, ["poster_url", "video_poster_url"])
        let attachmentCoverURL = attachmentPayloadString(remote.payload, ["cover_url", "video_cover_url"])
        let attachmentPreviewKind = attachmentPayloadString(remote.payload, ["preview_kind"])
        let attachmentContentDisposition = attachmentPayloadString(remote.payload, ["content_disposition", "disposition"])
        let attachmentWidth = attachmentPayloadInt64(remote.payload, ["width"]).map(Int.init)
        let attachmentHeight = attachmentPayloadInt64(remote.payload, ["height"]).map(Int.init)
        let attachmentDurationSeconds = attachmentDuration(from: remote.payload)
        let attachmentWaveform = kind == .voice ? attachmentWaveform(from: remote.payload) : []
        let attachmentUploadStatus = attachmentPayloadString(remote.payload, ["attachment_status", "upload_status", "status"])
        let attachmentPreviewURL = attachmentPayloadString(remote.payload, ["preview_url", "preview_public"])
        let attachmentDownloadURL = attachmentPayloadString(remote.payload, ["download_url", "download_public"])
        let replyContext = remoteReplyContext(from: remote, participants: participants)
        let replyQuote = replyContext?.quoteText ?? remoteReplyQuote(from: remote, participants: participants)
        let attachmentPreviewAvailable = attachmentPreviewAllowed(
            previewURL: attachmentPreviewURL,
            previewKind: attachmentPreviewKind,
            contentDisposition: attachmentContentDisposition,
            backendAvailable: attachmentPayloadBool(remote.payload, ["preview_available"])
        )
        let attachmentMeta = isContactCard
            ? contactCardUID(from: remote)
            : (isAttachment ? attachmentMeta(kind: kind, mimeType: attachmentMimeType, sizeBytes: attachmentSizeBytes) : nil)
        let senderID = forceOutgoing && remote.fromUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localOutgoingMessageSenderID()
            : remote.fromUID
        let senderName = senderDisplayName(for: remote, isOutgoing: isOutgoing, kind: kind, participants: participants)
        let senderAvatarSnapshot = senderAvatarSnapshot(
            for: remote,
            senderID: senderID,
            isOutgoing: isOutgoing,
            participants: participants
        )
        var message = ChatMessage(
            id: remote.messageID,
            senderId: senderID,
            senderProvenance: remote.senderProvenance,
            senderName: senderName,
            senderAvatarURL: senderAvatarSnapshot.avatarURL,
            senderAvatarVersion: senderAvatarSnapshot.avatarVersion,
            senderAvatarUpdatedAt: senderAvatarSnapshot.avatarUpdatedAt,
            senderAvatarSeed: senderAvatarSnapshot.avatarSeed,
            text: messagePreview(remote, participants: participants),
            time: kind == .rtcCallRecord ? rtcMessageDisplayTime(remote) : displayTime(remote.createdAt),
            createdAt: parseRemoteDate(remote.createdAt),
            channelSeq: remote.channelSeq,
            isOutgoing: isOutgoing,
            status: isOutgoing ? .sent : .read,
            kind: kind,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: replyQuote,
            attachmentName: isContactCard ? contactCardName(from: remote) : (isAttachment ? attachmentFileName : nil),
            attachmentMeta: attachmentMeta,
            attachmentFileID: isAttachment ? encodedAttachmentResourceID(from: remote.payload) : nil,
            attachmentSizeBytes: isAttachment ? attachmentSizeBytes : nil,
            attachmentPreviewURL: isAttachment ? attachmentPreviewURL : "",
            attachmentDownloadURL: isAttachment ? attachmentDownloadURL : "",
            attachmentPreviewAvailable: isAttachment && attachmentPreviewAvailable,
            attachmentDownloadAvailable: isAttachment && (attachmentPayloadBool(remote.payload, ["download_available"]) ?? (!attachmentDownloadURL.isEmpty || !(attachmentPayloadString(remote.payload, ["file_id", "attachment_id", "media_id", "id"]).isEmpty))),
            mentionExcluded: kind == .system || remote.payload["mention_excluded"]?.boolValue == true,
            mentionAll: remoteMessageMentionsAll(remote),
            systemEventType: remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue,
            systemDisplayStyle: remote.payload["display_style"]?.stringValue,
            systemColorToken: remote.payload["color_token"]?.stringValue,
            systemTextColorHex: remote.payload["text_color"]?.stringValue,
            systemBackgroundColorHex: remote.payload["background_color"]?.stringValue,
            systemAccentColorHex: remote.payload["accent_color"]?.stringValue,
            groupInviteApproval: groupInviteApproval(from: remote.payload, kind: remote.payload["kind"]?.stringValue ?? remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue ?? "", fallbackTitle: messagePreview(remote, participants: participants))
        )
        message.replyContext = replyContext ?? replyContextFromQuote(replyQuote)
        message.contentType = remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.contentType.isEmpty, stickerSnapshot != nil {
            message.contentType = "sticker"
        }
        message.stickerSnapshot = stickerSnapshot
        message.rtcCallRecord = rtcCallRecord
        message.isEdited = remote.isEdited
		message.editRevision = remote.editRevision
        if isAttachment && !isAdminDeleted {
            message.attachmentMimeType = attachmentMimeType
            message.attachmentCacheKey = attachmentCacheKey
            message.attachmentVersion = attachmentVersion
            message.attachmentChecksum = attachmentChecksum
            message.attachmentMediaCategory = attachmentMediaCategory
            message.attachmentExtension = attachmentExtension
            message.attachmentThumbnailURL = attachmentThumbnailURL
            message.attachmentPosterURL = attachmentPosterURL
            message.attachmentCoverURL = attachmentCoverURL
            message.attachmentPreviewKind = attachmentPreviewKind
            message.attachmentContentDisposition = attachmentContentDisposition
            message.attachmentWidth = attachmentWidth
            message.attachmentHeight = attachmentHeight
            message.attachmentDurationSeconds = attachmentDurationSeconds
            message.voiceWaveform = attachmentWaveform
            message.attachmentUploadStatus = attachmentUploadStatus
        }
        message.mentionedUsers = remoteMentionIdentities(from: remote)
        // History may retain the original payload and a read summary after a
        // recall. Sanitize after mapping so neither can reappear in the row.
        if isAdminDeleted {
            conversationStore.markMessageAsAdminDeleted(&message)
        } else if ["recalled", "revoked"].contains(remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            conversationStore.markMessageAsRecalledFromRemoteStatus(&message)
        } else {
            applyRemoteReadSummary(from: remote, to: &message)
        }
        return message
    }

    func messagePreview(_ message: RemoteMessage, participants: [IMUser] = []) -> String {
        if isAdminDeletedRemoteMessage(message) {
            return "原消息已删除"
        }
        if message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
            if let record = RTCCallRecordPayload.parse(
                contentType: message.contentType,
                channelType: message.channelType,
                fromUID: message.fromUID,
                payload: message.payload
            ) {
                return record.presentation(
                    viewerIsCaller: isRemoteMessageFromCurrentUser(message)
                ).conversationPreview
            }
            return RTCCallRecordPayload.safeFallbackText(payload: message.payload)
        }
        if isSystemRemoteMessage(message) {
            if let groupEventText = groupMembershipSystemPreview(message, participants: participants) {
                return groupEventText
            }
            let text = payloadString(message.payload, ["text", "content", "body"])
            if !text.isEmpty { return text }
            let event = payloadString(message.payload, ["event_type", "event"])
            return event.isEmpty ? "群成员变更" : "群成员变更：\(event)"
        }
        if isContactCardRemoteMessage(message) {
            return contactCardPreviewDisplayName(from: message).map { "个人名片：\($0)" }
                ?? message.payload["text"]?.stringValue
                ?? message.payload["content"]?.stringValue
                ?? "个人名片"
        }
        if message.contentType == "contact_card" {
            return contactCardPreviewDisplayName(from: message).map { "个人名片：\($0)" }
                ?? message.payload["text"]?.stringValue
                ?? "个人名片"
        }
        if remoteMessageKind(from: message) == .voice {
            if let durationSeconds = attachmentDuration(from: message.payload), durationSeconds > 0 {
                return VoiceMessagePayload.durationLabel(durationMS: VoiceMessagePayload.decodedDurationMS(durationSeconds) ?? 0) // WDT_IOS1_SAFE_NUMERIC_20261023
            }
            return ""
        }
        if isStickerPayload(message.payload, contentType: message.contentType) {
            return stickerFallbackText(from: message.payload)
        }
        return message.payload["text"]?.stringValue
        ?? message.payload["content"]?.stringValue
        ?? message.payload["body"]?.stringValue
        ?? message.payload["file_name"]?.stringValue
        ?? "[\(message.contentType)]"
    }

}
