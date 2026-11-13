import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeMessageMapper {
    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:394; pure value snapshot counterpart.
    func remoteAttachmentMediaCategory(_ remote: RemoteMessage, remoteKind: MessageKind) -> String {
        let explicit = attachmentPayloadString(remote.payload, ["media_category", "category", "kind", "preview_kind"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !explicit.isEmpty { return explicit }
        switch remoteKind {
        case .image:
            return "image"
        case .video:
            return "video"
        case .voice:
            return "voice"
        case .file:
            return "file"
        default:
            return ""
        }
    }

    // Source Core/AppSupport/AppState+AttachmentURLsAndProgress.swift:358; pure value snapshot counterpart.
    func attachmentMediaCategory(for message: ChatMessage) -> String {
        if message.kind == .voice {
            return "voice"
        }
        let explicit = message.attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !explicit.isEmpty { return explicit }
        let previewKind = message.attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["image", "video", "pdf", "audio", "voice", "download"].contains(previewKind), previewKind != "download" {
            return previewKind
        }
        return inferredAttachmentMediaCategory(kind: message.kind, name: message.attachmentName ?? message.text, mimeType: attachmentMimeType(from: message))
    }

    // Source Core/AppSupport/AppState+AttachmentCacheResources.swift:22; pure value snapshot counterpart.
    func attachmentMimeType(from message: ChatMessage) -> String {
        message.resolvedAttachmentMimeType
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:372; pure value snapshot counterpart.
    func isAttachmentMessageKind(_ kind: MessageKind) -> Bool {
        kind == .image || kind == .file || kind == .video || kind == .voice
    }

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:245; pure value snapshot counterpart.
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
            reducer.markMessageAsAdminDeleted(&message)
        } else if ["recalled", "revoked"].contains(remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            reducer.markMessageAsRecalledFromRemoteStatus(&message)
        } else {
            applyRemoteReadSummary(from: remote, to: &message)
        }
        return message
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:245; pure value snapshot counterpart.
    func remoteMentionIdentities(from message: RemoteMessage) -> [MentionIdentity] {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:139; pure value snapshot counterpart.
    func replyContextFromQuote(_ quote: String?, messageID: String = "") -> MessageReplyContext? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:216; pure value snapshot counterpart.
    func sanitizedReplyComponent(_ rawValue: String?) -> String? {
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

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:21; pure value snapshot counterpart.
    func groupInviteApproval(from payload: [String: JSONValue], kind rawKind: String, fallbackTitle: String) -> GroupInviteApproval? {
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

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:229; pure value snapshot counterpart.
    func remoteMessageMentionsAll(_ message: RemoteMessage) -> Bool {
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

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:208; pure value snapshot counterpart.
    func attachmentPayloadBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        RemotePayloadReader.attachmentBool(payload, keys)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:202; pure value snapshot counterpart.
    func encodedAttachmentResourceID(from payload: [String: JSONValue]) -> String? {
        RemotePayloadReader.encodedAttachmentResourceID(from: payload)
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:233; pure value snapshot counterpart.
    func senderAvatarSnapshot(
        for message: RemoteMessage,
        senderID: String,
        isOutgoing: Bool,
        participants: [IMUser]
    ) -> (avatarURL: String, avatarVersion: String, avatarUpdatedAt: String, avatarSeed: UInt) {
        if isOutgoing {
            return (
                currentUser.avatarURL,
                currentUser.avatarVersion,
                currentUser.avatarUpdatedAt,
                currentUser.avatarSeed
            )
        }

        let knownUsers = knownSenderUsers(for: senderID, participants: participants)
        let avatarUser = knownUsers.first {
            !$0.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rawRemoteAvatar = message.senderAvatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAvatarURL = rawRemoteAvatar.isEmpty ? "" : resolveTenantAssetURL(rawRemoteAvatar)
        let remoteAvatarVersion = message.senderAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAvatarUpdatedAt = message.senderAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSeed = avatarUser?.avatarSeed ?? knownUsers.first?.avatarSeed ?? stableSeed(senderID)
        guard remoteAvatarURL.isEmpty else {
            let matchesKnownAvatar = avatarUser?.avatarURL == remoteAvatarURL
            return (
                remoteAvatarURL,
                remoteAvatarVersion.isEmpty ? (matchesKnownAvatar ? avatarUser?.avatarVersion ?? "" : "") : remoteAvatarVersion,
                remoteAvatarUpdatedAt.isEmpty ? (matchesKnownAvatar ? avatarUser?.avatarUpdatedAt ?? "" : "") : remoteAvatarUpdatedAt,
                fallbackSeed
            )
        }
        return (
            avatarUser?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            remoteAvatarVersion.isEmpty ? avatarUser?.avatarVersion ?? "" : remoteAvatarVersion,
            remoteAvatarUpdatedAt.isEmpty ? avatarUser?.avatarUpdatedAt ?? "" : remoteAvatarUpdatedAt,
            fallbackSeed
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:392; pure value snapshot counterpart.
    func stableSeed(_ value: String) -> UInt {
        AppStatePresentationHelper.stableSeed(value)
    }

    // Source Core/AppSupport/MessageMapping/AppState+MessageMappingSupport.swift:109; pure value snapshot counterpart.
    func senderDisplayName(for message: RemoteMessage, isOutgoing: Bool, kind: MessageKind, participants: [IMUser]) -> String {
        if kind == .system { return "系统" }

        let senderID = message.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotName = payloadString(message.payload, ["sender_snapshot_name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !snapshotName.isEmpty, !isIdentifierLikeDisplayName(snapshotName, matching: senderID) {
            return snapshotName
        }
        if isOutgoing { return currentUser.name }
        let payloadName = payloadString(
            message.payload,
            ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "nickname", "display_name", "user_name"]
        )
        let topLevelName = message.senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteName = !topLevelName.isEmpty ? topLevelName : payloadName
        if !remoteName.isEmpty, !isIdentifierLikeDisplayName(remoteName, matching: senderID) {
            return remoteName
        }
        let knownUser = knownSenderUser(for: senderID, participants: participants)
        if let knownUser {
            let knownName = knownUser.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifiers = [senderID, knownUser.id, knownUser.userID, knownUser.username]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if contactRemarkValue(matching: identifiers) == nil, !knownName.isEmpty {
                return knownName
            }
        }
        return senderID.isEmpty ? "未知用户" : senderID
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:274; pure value snapshot counterpart.
    func knownSenderUser(for senderID: String, participants: [IMUser]) -> IMUser? {
        let candidates = knownSenderUsers(for: senderID, participants: participants)
        return candidates.first {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && !isIdentifierLikeDisplayName(name, matching: senderID)
        } ?? candidates.first
    }

    // Source Core/AppSupport/AppState+MediaSending.swift:326; pure value snapshot counterpart.
    func attachmentMeta(kind: MessageKind, mimeType: String, sizeBytes: Int64?) -> String {
        var parts: [String] = []
        if kind == .image {
            parts.append(mimeType.isEmpty ? "图片" : mimeType.uppercased())
        } else if kind == .voice {
            parts.append("语音")
        } else {
            parts.append(mimeType.isEmpty ? "文件" : mimeType)
        }
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:291; pure value snapshot counterpart.
    func attachmentPreviewAllowed(previewURL: String, previewKind: String, contentDisposition: String, backendAvailable: Bool?) -> Bool {
        FileItemProjectionHelper.attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            backendAvailable: backendAvailable
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:16; pure value snapshot counterpart.
    func remoteReplyQuote(from message: RemoteMessage, participants: [IMUser]) -> String? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:81; pure value snapshot counterpart.
    func remoteReplyQuote(from value: JSONValue, participants: [IMUser]) -> String? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:161; pure value snapshot counterpart.
    func remoteReplySummary(from object: [String: JSONValue]) -> String? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:194; pure value snapshot counterpart.
    func replySenderDisplayName(from object: [String: JSONValue], participants: [IMUser]) -> String {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:52; pure value snapshot counterpart.
    func remoteReplyContext(from message: RemoteMessage, participants: [IMUser]) -> MessageReplyContext? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:108; pure value snapshot counterpart.
    func remoteReplyContext(from value: JSONValue, participants: [IMUser]) -> MessageReplyContext? {
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

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:153; pure value snapshot counterpart.
    func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:286; pure value snapshot counterpart.
    func attachmentWaveform(from payload: [String: JSONValue]) -> [Int] {
        RemotePayloadReader.attachmentWaveform(from: payload)
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
