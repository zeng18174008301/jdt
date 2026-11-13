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

// MARK: - Remote Message Payload Mapping

extension AppState {
    // MainActor partition: this file contains pure RemoteMessage / JSONValue
    // mapping bridges. They do not read AppState-owned UI state, so they are
    // nonisolated and can be reused from background mapping paths later.
    nonisolated func groupInviteApproval(from payload: [String: JSONValue], kind rawKind: String, fallbackTitle: String) -> GroupInviteApproval? {
        let approvalKinds: Set<String> = ["group_invite_approval", "group_join_approval", "group_member_invite_approval"]
        let receiptKinds: Set<String> = ["group_invite_receipt", "group_invite_waiting_approval", "group_invite_submitted", "group_invite_request"]
        let resultKinds: Set<String> = ["group_invite_result", "group_join_result", "group_member_invite_result"]
        let kindCandidates = [
            rawKind,
            payloadString(payload, ["kind", "type", "card_type", "notification_kind", "event_type", "event"])
        ]
        let kind = kindCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { approvalKinds.contains($0) || receiptKinds.contains($0) || resultKinds.contains($0) }
            ?? rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKind: String
        if approvalKinds.contains(kind) {
            normalizedKind = "group_invite_approval"
        } else if receiptKinds.contains(kind) {
            normalizedKind = "group_invite_receipt"
        } else if resultKinds.contains(kind) {
            normalizedKind = "group_invite_result"
        } else {
            return nil
        }
        let actions = payload["actions"]?.objectValue ?? [:]
        let requestID = payloadString(payload, ["request_id", "approval_id", "join_request_id", "id"])
        guard !requestID.isEmpty else { return nil }
        let requestType = payloadString(payload, ["request_type", "approval_type", "invite_type"])
        let status = payloadString(payload, ["status", "request_status", "approval_status", "action_status", "review_status"])
        let decision = payloadString(payload, ["decision", "approval_decision"])
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terminalStatuses: Set<String> = [
            "approved", "approve", "accepted", "pass", "passed",
            "rejected", "reject", "denied", "declined", "refused",
            "canceled", "cancelled", "cancel",
            "expired", "expire", "timed_out", "timeout"
        ]
        let processed = payloadBool(payload, ["processed", "is_processed", "handled", "is_handled", "action_processed"])
            ?? (normalizedKind == "group_invite_result"
                || terminalStatuses.contains(normalizedStatus)
                || !decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let resultText = payloadString(payload, ["result_text", "review_result", "result", "result_message", "message"])
        let approveEndpoint = payloadString(actions, ["approve_endpoint"])
        let rejectEndpoint = payloadString(actions, ["reject_endpoint"])
        let actionEndpoint = payloadString(payload, ["action_endpoint"])
        let canApprove = (payloadBool(payload, ["can_approve"])
            ?? payloadBool(actions, ["can_approve"])
            ?? payloadBool(actions, ["approve"])
            ?? (normalizedKind == "group_invite_approval" && !approveEndpoint.isEmpty)) && !processed
        let canReject = (payloadBool(payload, ["can_reject"])
            ?? payloadBool(actions, ["can_reject"])
            ?? payloadBool(actions, ["reject"])
            ?? (normalizedKind == "group_invite_approval" && !rejectEndpoint.isEmpty)) && !processed
        let isJoinRequestPayload = requestType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "join_request"
        let inviteeName: String
        let inviteeAccountID: String
        if isJoinRequestPayload {
            inviteeName = payloadString(payload, ["applicant_name", "target_name", "invitee_name"], fallback: "申请人")
            inviteeAccountID = payloadString(payload, ["applicant_account_id", "applicant_uid", "target_account_id", "target_uid", "invitee_account_id", "invitee_uid", "invitee_im_uid"])
        } else {
            inviteeName = payloadString(payload, ["invitee_name", "target_name", "applicant_name"], fallback: "被邀请人")
            inviteeAccountID = payloadString(payload, ["invitee_account_id", "invitee_uid", "invitee_im_uid", "target_account_id", "target_uid", "applicant_account_id", "applicant_uid"])
        }
        return GroupInviteApproval(
            requestID: requestID,
            requestType: requestType,
            groupID: payloadString(payload, ["group_id"]),
            groupName: payloadString(payload, ["group_name"], fallback: fallbackTitle),
            inviterName: payloadString(payload, ["inviter_name", "operator_name", "applicant_name"], fallback: isJoinRequestPayload ? "申请人" : "邀请人"),
            inviterAccountID: payloadString(payload, ["inviter_account_id", "inviter_uid", "inviter_im_uid", "operator_account_id", "operator_uid", "applicant_account_id", "applicant_uid"]),
            inviteeName: inviteeName,
            inviteeAccountID: inviteeAccountID,
            status: status.isEmpty ? (decision.isEmpty ? "pending" : decision) : status,
            resultText: resultText,
            processed: processed,
            approverName: payloadString(payload, ["approver_name", "decided_by_name", "reviewed_by_name", "reviewer_name", "processor_name", "handled_by_name", "handler_name"]),
            approverAccountID: payloadString(payload, ["approver_account_id", "approver_uid", "decided_by_account_id", "decided_by_uid", "reviewed_by", "reviewer_uid", "processor_uid", "handled_by_uid", "handler_uid"]),
            decidedAt: displayTime(payloadString(payload, ["decided_at", "reviewed_at", "processed_at", "handled_at"])),
            canApprove: canApprove,
            canReject: canReject,
            approveEndpoint: approveEndpoint,
            rejectEndpoint: rejectEndpoint,
            actionEndpoint: actionEndpoint,
            kind: normalizedKind
        )
    }

    // JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：AppState 保留 payload 读取入口，基础解析委托给 RemotePayloadReader
    nonisolated func payloadString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        RemotePayloadReader.string(payload, keys, fallback: fallback)
    }
    // JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

    nonisolated func isStickerPayload(_ payload: [String: JSONValue], contentType: String = "") -> Bool {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedContentType == "sticker" { return true }
        let payloadType = payloadString(payload, ["type", "content_type", "kind"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if payloadType == "sticker" { return true }
        return !attachmentPayloadString(payload, ["sticker_id"]).isEmpty
    }

    nonisolated func stickerFallbackText(from payload: [String: JSONValue]) -> String {
        let fallback = payloadString(payload, ["fallback_text", "fallback", "text", "summary", "preview"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? StickerMessageSnapshot.fallbackText : fallback
    }

    nonisolated func stickerSnapshot(from message: RemoteMessage) -> StickerMessageSnapshot? {
        guard isStickerPayload(message.payload, contentType: message.contentType) else { return nil }
        var variants = stickerVariantSnapshots(from: message.payload)
        let thumbnailFileID = attachmentPayloadString(message.payload, ["thumbnail_file_id", "thumb_file_id", "preview_file_id"])
        let fileID = attachmentPayloadString(
            message.payload,
            ["file_id", "original_file_id", "source_file_id", "animation_file_id", "asset_file_id"],
            fallback: variants.first(where: { !$0.fileID.isEmpty })?.fileID ?? thumbnailFileID
        )
        let stickerID = attachmentPayloadString(message.payload, ["sticker_id", "id"])
        guard !stickerID.isEmpty || !fileID.isEmpty else { return nil }
        let mimeType = attachmentPayloadString(message.payload, ["mime_type"], fallback: "image/gif")
        let thumbnailURL = attachmentPayloadString(message.payload, ["thumbnail_url", "thumb_url", "thumbnail_endpoint", "preview_thumbnail_url", "thumbnail_preview_url", "preview_url"])
        if variants.isEmpty, !fileID.isEmpty {
            variants = [
                StickerMessageVariantSnapshot(
                    kind: "original",
                    fileID: fileID,
                    mimeType: mimeType,
                    thumbnailURL: thumbnailURL,
                    cacheKey: attachmentPayloadString(message.payload, ["cache_key", "cacheKey", "version"])
                )
            ]
        }
        return StickerMessageSnapshot(
            stickerID: stickerID,
            packID: attachmentPayloadString(message.payload, ["pack_id"]),
            fileID: fileID,
            mimeType: mimeType,
            width: attachmentPayloadInt64(message.payload, ["width"]).map(Int.init),
            height: attachmentPayloadInt64(message.payload, ["height"]).map(Int.init),
            durationMS: attachmentPayloadInt64(message.payload, ["duration_ms"]).map(Int.init),
            frameCount: attachmentPayloadInt64(message.payload, ["frame_count"]).map(Int.init),
            thumbnailURL: thumbnailURL,
            variants: variants,
            fallbackText: stickerFallbackText(from: message.payload)
        )
    }

    private nonisolated func stickerVariantSnapshots(from payload: [String: JSONValue]) -> [StickerMessageVariantSnapshot] {
        guard case .array(let values)? = payload["variants"] else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value else { return nil }
            let fileID = payloadString(object, ["file_id", "original_file_id", "source_file_id", "animation_file_id", "asset_file_id"])
            let kind = payloadString(object, ["kind", "variant"])
            let mimeType = payloadString(object, ["mime_type"])
            guard !fileID.isEmpty || !kind.isEmpty || !mimeType.isEmpty else { return nil }
            return StickerMessageVariantSnapshot(
                kind: kind,
                fileID: fileID,
                mimeType: mimeType,
                assetURL: payloadString(object, ["url", "asset_url", "file_url", "animation_url", "source_url", "original_url", "download_url", "download_public"]),
                sizeBytes: payloadInt64(object, ["size_bytes", "size"]),
                width: payloadInt64(object, ["width"]).map(Int.init),
                height: payloadInt64(object, ["height"]).map(Int.init),
                durationMS: payloadInt64(object, ["duration_ms"]).map(Int.init),
                frameCount: payloadInt64(object, ["frame_count"]).map(Int.init),
                thumbnailURL: payloadString(object, ["thumbnail_url", "thumb_url", "thumbnail_endpoint", "preview_thumbnail_url", "thumbnail_preview_url", "preview_url"]),
                cacheKey: payloadString(object, ["cache_key", "cacheKey", "version"])
            )
        }
    }

    // JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：附件 payload 基础读取委托给 RemotePayloadReader
    nonisolated func attachmentPayloadObjects(_ payload: [String: JSONValue]) -> [[String: JSONValue]] {
        RemotePayloadReader.attachmentObjects(payload)
    }

    // JHT_MOD_BEGIN APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改开始：媒体缓存扩展复用原有附件 payload 解析入口保持同模块可见
    nonisolated func attachmentPayloadString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        RemotePayloadReader.attachmentString(payload, keys, fallback: fallback)
    }
    // JHT_MOD_END APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改结束

    nonisolated func encodedAttachmentResourceID(from payload: [String: JSONValue]) -> String? {
        RemotePayloadReader.encodedAttachmentResourceID(from: payload)
    }
    // JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

    // JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：payload 类型转换委托给 RemotePayloadReader
    nonisolated func attachmentPayloadBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        RemotePayloadReader.attachmentBool(payload, keys)
    }

    nonisolated func attachmentPayloadInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        RemotePayloadReader.attachmentInt64(payload, keys)
    }

    nonisolated func attachmentPayloadDouble(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        RemotePayloadReader.attachmentDouble(payload, keys)
    }

    nonisolated func attachmentPayloadIntArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        RemotePayloadReader.attachmentIntArray(payload, keys)
    }

    nonisolated func payloadBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        RemotePayloadReader.bool(payload, keys)
    }
    // JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

    nonisolated func remoteMessageMentionsAll(_ message: RemoteMessage) -> Bool {
        if payloadBool(message.payload, ["mention_all"]) == true {
            return true
        }
        if payloadString(message.payload, ["mention_scope"]).lowercased() == "all" {
            return true
        }
        guard case .array(let mentions)? = message.payload["mentions"] else { return false }
        return mentions.contains { item in
            guard case .object(let object) = item else { return false }
            let type = payloadString(object, ["type"]).lowercased()
            let target = payloadString(object, ["target"]).lowercased()
            return type == "all" || target == "all"
        }
    }

    nonisolated func remoteMentionIdentities(from message: RemoteMessage) -> [MentionIdentity] {
        guard case .array(let mentions)? = message.payload["mentions"] else { return [] }
        var seen = Set<String>()
        return mentions.compactMap { item in
            guard case .object(let object) = item else { return nil }
            let type = payloadString(object, ["type"]).lowercased()
            guard type.isEmpty || type == "user" || type == "member" else { return nil }
            let imUID = payloadString(object, ["im_uid", "uid", "target_uid", "user_uid", "id"])
            let userID = payloadString(object, ["user_id"])
            let username = payloadString(object, ["username", "account", "account_id"])
            let rawDisplay = payloadString(object, ["display_text", "label", "name", "nickname", "display_name"])
            let displayText = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^@", with: "", options: .regularExpression)
            let identity = MentionIdentity(
                imUID: imUID,
                userID: userID,
                username: username,
                displayText: displayText.isEmpty ? (imUID.isEmpty ? userID : imUID) : displayText
            )
            guard !identity.id.isEmpty, seen.insert(identity.id).inserted else { return nil }
            return identity
        }
    }

    // JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：payload 数值/数组转换委托给 RemotePayloadReader
    nonisolated func payloadInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        RemotePayloadReader.int64(payload, keys)
    }

    nonisolated func payloadDouble(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        RemotePayloadReader.double(payload, keys)
    }

    nonisolated func payloadIntArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        RemotePayloadReader.intArray(payload, keys)
    }

    nonisolated func attachmentDuration(from payload: [String: JSONValue]) -> Double? {
        RemotePayloadReader.attachmentDuration(from: payload)
    }

    nonisolated func attachmentWaveform(from payload: [String: JSONValue]) -> [Int] {
        RemotePayloadReader.attachmentWaveform(from: payload)
    }
    // JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

    nonisolated func attachmentPreviewAllowed(previewURL: String, previewKind: String, contentDisposition: String, backendAvailable: Bool?) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：预览可用性纯判断委托给非 MainActor helper
        FileItemProjectionHelper.attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            backendAvailable: backendAvailable
        )
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    nonisolated func isAdminDeletedRemoteMessage(_ message: RemoteMessage) -> Bool {
        let normalizedStatus = message.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedContentType = message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let event = payloadString(message.payload, ["event_type", "event", "type"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let deletedByAdmin = payloadBool(message.payload, ["admin_deleted", "deleted_by_admin", "is_tombstone"]) == true
        return ["deleted", "tombstone", "admin_deleted", "removed", "invisible"].contains(normalizedStatus)
            || ["tombstone", "deleted", "message_deleted"].contains(normalizedContentType)
            || ["admin_delete", "admin_delete_message", "message_admin_delete", "group_admin_delete_message", "message_deleted"].contains(event)
            || deletedByAdmin
    }

    nonisolated func isContactCardRemoteMessage(_ message: RemoteMessage) -> Bool {
        guard !isSystemRemoteMessage(message) else { return false }
        let contentType = message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if contentType == "contact_card" { return true }
        if contactCardUID(from: message) != nil || message.payload["contact_name"]?.stringValue != nil {
            return true
        }
        guard let text = message.payload["text"]?.stringValue
            ?? message.payload["content"]?.stringValue
            ?? message.payload["body"]?.stringValue
        else { return false }
        return text.hasPrefix("个人名片：") || text.hasPrefix("推荐名片：")
    }

    nonisolated func remoteMessageKind(from message: RemoteMessage) -> MessageKind {
        if isSystemRemoteMessage(message) { return .system }
        if isContactCardRemoteMessage(message) { return .contactCard }
        if isStickerPayload(message.payload, contentType: message.contentType) { return .text }
        let contentType = message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if contentType == "voice" || contentType == "audio" {
            return .voice
        }
        if contentType == "file" || contentType == "attachment" {
            let mediaCategory = attachmentPayloadString(message.payload, ["media_category", "category", "kind"]).lowercased()
            let previewKind = attachmentPayloadString(message.payload, ["preview_kind"]).lowercased()
            if mediaCategory == "image" || previewKind == "image" {
                return .image
            }
            if mediaCategory == "video" || previewKind == "video" {
                return .video
            }
            if mediaCategory == "voice" || mediaCategory == "audio" || previewKind == "voice" || previewKind == "audio" {
                return .voice
            }
        }
        return messageKind(from: message.contentType)
    }

    nonisolated func isSystemRemoteMessage(_ message: RemoteMessage) -> Bool {
        let contentType = message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["system", "system_message", "system_notification"].contains(contentType) {
            return true
        }
        if message.payload["system_event"]?.boolValue == true {
            return true
        }
        let event = payloadString(message.payload, ["event_type", "event", "kind"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if isGroupMembershipSystemEvent(event) {
            return true
        }
        let displayStyle = payloadString(message.payload, ["display_style"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if displayStyle == "group_event_notice" {
            return true
        }
        let colorToken = payloadString(message.payload, ["color_token"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return colorToken == "im.system.group_event"
    }
}
