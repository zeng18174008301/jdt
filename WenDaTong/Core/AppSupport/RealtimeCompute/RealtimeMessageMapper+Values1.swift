import IM4Features
import IM4Domain
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeMessageMapper {
    // Source Core/AppSupport/AppState+GroupHistoryBoundary.swift:66; pure value snapshot counterpart.
    func isRemoteMessageVisibleAfterHistoryBoundary(_ remote: RemoteMessage, boundary: ConversationStore.HistoryVisibilityBoundary?) -> Bool {
        guard let boundary, boundary.isRestrictive else { return true }
        return remote.channelSeq >= boundary.fromSeq
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:468; pure value snapshot counterpart.
    func isAnnouncementSystemMessage(_ remote: RemoteMessage) -> Bool {
        guard remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" else {
            return false
        }
        let event = (remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue ?? "").lowercased()
        let kind = (remote.payload["kind"]?.stringValue ?? remote.payload["category"]?.stringValue ?? "").lowercased()
        if event.contains("announcement") || kind == "announcement" || kind == "notice" {
            return true
        }
        // 群成员事件(入群/邀请/移出/退群)绝不能按公告过滤。之前用
        // messagePreview 文本包含“公告”做兜底,导致群名带“公告”的群
        // (如「全员公告群」)所有入群系统消息在 applyRemoteMessages 里
        // 被整批丢弃,历史消息永远补不齐。
        if isGroupMembershipSystemEvent(event) {
            return false
        }
        let displayStyle = (remote.payload["display_style"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if displayStyle == "group_event_notice" {
            return false
        }
        // 其余未带明确事件类型的旧格式系统消息才允许文本兜底判断。
        guard event.isEmpty else { return false }
        let text = messagePreview(remote)
        return text.contains("公告")
    }

    // Source Core/AppSupport/MessageMapping/AppState+MessageAndReplyProjection.swift:384; pure value snapshot counterpart.
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
                return VoiceMessagePayload.durationLabel(durationMS: VoiceMessagePayload.decodedDurationMS(durationSeconds) ?? 0)
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

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:122; pure value snapshot counterpart.
    func stickerFallbackText(from payload: [String: JSONValue]) -> String {
        let fallback = payloadString(payload, ["fallback_text", "fallback", "text", "summary", "preview"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? StickerMessageSnapshot.fallbackText : fallback
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:107; pure value snapshot counterpart.
    func payloadString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        RemotePayloadReader.string(payload, keys, fallback: fallback)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:112; pure value snapshot counterpart.
    func isStickerPayload(_ payload: [String: JSONValue], contentType: String = "") -> Bool {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedContentType == "sticker" { return true }
        let payloadType = payloadString(payload, ["type", "content_type", "kind"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if payloadType == "sticker" { return true }
        return !attachmentPayloadString(payload, ["sticker_id"]).isEmpty
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:197; pure value snapshot counterpart.
    func attachmentPayloadString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        RemotePayloadReader.attachmentString(payload, keys, fallback: fallback)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:282; pure value snapshot counterpart.
    func attachmentDuration(from payload: [String: JSONValue]) -> Double? {
        RemotePayloadReader.attachmentDuration(from: payload)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:329; pure value snapshot counterpart.
    func remoteMessageKind(from message: RemoteMessage) -> MessageKind {
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

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:388; pure value snapshot counterpart.
    func messageKind(from contentType: String) -> MessageKind {
        AppStatePresentationHelper.messageKind(from: contentType)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:315; pure value snapshot counterpart.
    func isContactCardRemoteMessage(_ message: RemoteMessage) -> Bool {
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

    // Source Core/AppSupport/AppState+ContactCardMessagePresentation.swift:62; pure value snapshot counterpart.
    func contactCardUID(for user: IMUser) -> String? {
        let displayName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [user.id, user.userID]
            .compactMap { normalizedContactCardUID($0, rejecting: displayName) }
            .first
    }

    // Source Core/AppSupport/AppState+ContactCardMessagePresentation.swift:69; pure value snapshot counterpart.
    func contactCardUID(for message: ChatMessage) -> String? {
        let displayName = contactCardDisplayName(from: message)
        if let directID = normalizedContactCardUID(message.attachmentMeta, rejecting: displayName) {
            return directID
        }
        let normalizedMeta = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = (contacts + input.directoryUsers).filter { user in
            user.name == displayName
                || (!normalizedMeta.isEmpty && (user.id == normalizedMeta || user.userID == normalizedMeta))
        }
        let uniqueIDs = Set(candidates.compactMap { contactCardUID(for: $0) })
        return uniqueIDs.count == 1 ? uniqueIDs.first : nil
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:128; pure value snapshot counterpart.
    func contactCardUID(from message: RemoteMessage) -> String? {
        [
            message.payload["contact_uid"]?.stringValue,
            message.payload["contact_user_id"]?.stringValue,
            message.payload["user_id"]?.stringValue,
            message.payload["im_uid"]?.stringValue,
            message.payload["target_uid"]?.stringValue,
            message.payload["contact_id"]?.stringValue
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    // Source Core/AppSupport/AppState+ContactCardMessagePresentation.swift:16; pure value snapshot counterpart.
    func normalizedContactCardUID(_ value: String?, rejecting displayName: String = "") -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty || normalized != normalizedName else { return nil }
        return normalized
    }

    // Source Core/AppSupport/AppState+ContactCardMessagePresentation.swift:45; pure value snapshot counterpart.
    func contactCardDisplayName(from message: ChatMessage) -> String {
        let name = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未知用户" : name
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:353; pure value snapshot counterpart.
    func isSystemRemoteMessage(_ message: RemoteMessage) -> Bool {
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

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:117; pure value snapshot counterpart.
    func contactCardPreviewDisplayName(from message: RemoteMessage) -> String? {
        let fallbackName = contactCardName(from: message)
        guard let contactID = contactCardUID(from: message) else { return fallbackName }
        let displayName = remarkPreferredDisplayName(
            identifiers: [contactID],
            candidates: [fallbackName],
            fallback: fallbackName ?? contactID
        )
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : displayName
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift:40; pure value snapshot counterpart.
    func remarkPreferredDisplayName(
        for user: IMUser,
        fallback: String? = nil,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
        directory: ContactStore.DirectoryPresentationSnapshot? = nil
    ) -> String {
        remarkPreferredDisplayName(
            identifiers: [user.id, user.userID, user.username],
            candidates: [user.name, user.username, user.userID],
            fallback: fallback ?? (user.id.isEmpty ? "未知用户" : user.id),
            contactLookup: contactLookup,
            directory: directory
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift:102; pure value snapshot counterpart.
    func remarkPreferredDisplayName(
        identifiers: [String],
        candidates: [String?],
        fallback: String,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
        directory: ContactStore.DirectoryPresentationSnapshot? = nil
    ) -> String {
        let normalizedIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let remark = contactRemarkValue(matching: normalizedIdentifiers, contactLookup: contactLookup, directory: directory) {
            return remark
        }
        return preferredDisplayName(candidates: candidates, identifiers: normalizedIdentifiers, fallback: fallback)
    }

    // Source Core/AppSupport/GroupFileMapping/AppState+RemoteConversationProjection.swift:100; pure value snapshot counterpart.
    func preferredDisplayName(candidates: [String?], identifiers: [String?] = [], fallback: String) -> String {
        let normalizedIdentifiers = identifiers
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedCandidates = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let usable = normalizedCandidates.first(where: { candidate in
            guard !isIdentifierLikeDisplayName(candidate, matching: "") else { return false }
            return !normalizedIdentifiers.contains { id in
                isIdentifierLikeDisplayName(candidate, matching: id)
            }
        }) {
            return usable
        }
        return normalizedCandidates.first ?? fallback
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:29; pure value snapshot counterpart.
    func isIdentifierLikeDisplayName(_ name: String, matching id: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty { return true }
        if normalizedName.caseInsensitiveCompare(normalizedID) == .orderedSame { return true }
        return false
    }

    // Source Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift:102; pure value snapshot counterpart.
    func contactCardName(from message: RemoteMessage) -> String? {
        if let name = message.payload["contact_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let text = message.payload["text"]?.stringValue
            ?? message.payload["content"]?.stringValue
            ?? message.payload["body"]?.stringValue
        else { return nil }
        let stripped = text
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:21; pure value snapshot counterpart.
    func groupMembershipSystemPreview(_ message: RemoteMessage, participants: [IMUser]) -> String? {
        let event = payloadString(message.payload, ["event_type", "event"])
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isGroupMembershipSystemEvent(normalizedEvent) else { return nil }

        if let serverText = groupMembershipServerText(message.payload) {
            return serverText
        }

        let groupName = groupSystemGroupName(message)
        let actorName = groupSystemUserDisplayName(
            payload: message.payload,
            nameKeys: ["actor_name", "operator_name", "inviter_name", "sender_display_name", "sender_name", "from_name"],
            idKeys: ["actor_uid", "operator_uid", "inviter_uid", "sender_uid", "from_uid"],
            participants: participants,
            fallback: "管理员"
        )
        let targetName = groupSystemTargetDisplayText(
            payload: message.payload,
            nameKeys: ["target_name", "target_nickname", "invitee_name", "applicant_name", "member_name", "nickname", "display_name", "user_name", "name"],
            idKeys: ["target_uid", "target_user_id", "invitee_uid", "applicant_uid", "member_uid", "im_uid", "user_id"],
            participants: participants,
            fallback: "成员"
        )

        switch normalizedEvent {
        case "group_member_invited", "group_member_invite", "group_member_added":
            return "\(actorName)邀请\(targetName)加入群「\(groupName)」"
        case "group_member_joined", "group_joined":
            return "\(targetName)加入群「\(groupName)」"
        case "group_member_removed", "group_member_deleted", "group_member_kicked":
            return "\(actorName)将\(targetName)移出群「\(groupName)」"
        case "group_member_left", "group_member_quit", "group_member_exited", "group_left":
            return "\(targetName)退出群「\(groupName)」"
        default:
            return "\(actorName)更新了群「\(groupName)」成员：\(targetName)"
        }
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:102; pure value snapshot counterpart.
    func groupSystemTargetDisplayText(
        payload: [String: JSONValue],
        nameKeys: [String],
        idKeys: [String],
        participants: [IMUser],
        fallback: String
    ) -> String {
        let names = groupSystemTargetNames(payload: payload, participants: participants)
        if !names.isEmpty {
            if !shouldShowGroupMemberCount {
                return names.prefix(2).joined(separator: "、")
            }
            let count = max(Int(payloadInt64(payload, ["target_count", "member_count", "count"]) ?? Int64(names.count)), names.count)
            return formattedGroupSystemTargetNames(names, totalCount: count)
        }
        let uids = payloadStringArray(payload, ["target_uids", "target_user_ids", "invitee_uids", "member_uids", "im_uids"])
        if !uids.isEmpty {
            let displayNames = uids.map { id in
                if let user = user(for: id) ?? participants.first(where: { groupSystemUser($0, matches: id) }),
                   let name = safeGroupSystemUserName(user, matching: id) {
                    return name
                }
                return id
            }
            if !shouldShowGroupMemberCount {
                return displayNames.prefix(2).joined(separator: "、")
            }
            let count = max(Int(payloadInt64(payload, ["target_count", "member_count", "count"]) ?? Int64(displayNames.count)), displayNames.count)
            return formattedGroupSystemTargetNames(displayNames, totalCount: count)
        }
        return groupSystemUserDisplayName(
            payload: payload,
            nameKeys: nameKeys,
            idKeys: idKeys,
            participants: participants,
            fallback: fallback
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:78; pure value snapshot counterpart.
    func groupSystemUserDisplayName(
        payload: [String: JSONValue],
        nameKeys: [String],
        idKeys: [String],
        participants: [IMUser],
        fallback: String
    ) -> String {
        let ids = idKeys
            .map { payloadString(payload, [$0]) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for id in ids {
            if let user = user(for: id) ?? participants.first(where: { groupSystemUser($0, matches: id) }),
               let name = safeGroupSystemUserName(user, matching: id) {
                return name
            }
        }
        let payloadName = payloadString(payload, nameKeys)
        if isUsableGroupSystemDisplayName(payloadName, matching: ids) {
            return payloadName
        }
        return fallback
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:197; pure value snapshot counterpart.
    func isUsableGroupSystemDisplayName(_ name: String, matching ids: [String]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSyntheticGroupSystemDisplayName(trimmed) else { return false }
        if isIdentifierLikeDisplayName(trimmed, matching: "") { return false }
        return !ids.contains { id in
            let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalizedID.isEmpty && isIdentifierLikeDisplayName(trimmed, matching: normalizedID)
        }
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:207; pure value snapshot counterpart.
    func isSyntheticGroupSystemDisplayName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return true }
        if normalized.hasPrefix("NO_SUCH") { return true }
        return ["UNKNOWN", "NULL", "NIL", "NONE"].contains(normalized)
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:187; pure value snapshot counterpart.
    func safeGroupSystemUserName(_ user: IMUser, matching id: String) -> String? {
        for candidate in [user.name, user.username] {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableGroupSystemDisplayName(name, matching: [id]) {
                return name
            }
        }
        return nil
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:179; pure value snapshot counterpart.
    func groupSystemUser(_ user: IMUser, matches id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty && $0.caseInsensitiveCompare(normalizedID) == .orderedSame }
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:166; pure value snapshot counterpart.
    func formattedGroupSystemTargetNames(_ names: [String], totalCount: Int, maxVisible: Int = 2) -> String {
        let visibleNames = Array(names.prefix(max(1, maxVisible)))
        let joined = visibleNames.joined(separator: "、")
        guard totalCount > visibleNames.count else { return joined }
        return "\(joined)等\(totalCount)人"
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:270; pure value snapshot counterpart.
    func payloadInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        RemotePayloadReader.int64(payload, keys)
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:173; pure value snapshot counterpart.
    func payloadStringArray(_ payload: [String: JSONValue], _ keys: [String]) -> [String] {
        RemotePayloadReader.stringArray(payload, keys)
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:141; pure value snapshot counterpart.
    func groupSystemTargetNames(payload: [String: JSONValue], participants: [IMUser]) -> [String] {
        let rawNames = payloadStringArray(payload, ["target_names", "target_nicknames", "invitee_names", "member_names"])
        let rawIDs = payloadStringArray(payload, ["target_uids", "target_user_ids", "invitee_uids", "member_uids", "im_uids"])
        var result: [String] = []
        var seen = Set<String>()
        for index in 0..<max(rawNames.count, rawIDs.count) {
            let id = index < rawIDs.count ? rawIDs[index] : ""
            let name = index < rawNames.count ? rawNames[index] : ""
            let displayName: String
            if isUsableGroupSystemDisplayName(name, matching: id.isEmpty ? [] : [id]) {
                displayName = name
            } else if !id.isEmpty,
                      let user = user(for: id) ?? participants.first(where: { groupSystemUser($0, matches: id) }),
                      let knownName = safeGroupSystemUserName(user, matching: id) {
                displayName = knownName
            } else {
                displayName = id
            }
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:65; pure value snapshot counterpart.
    func groupSystemGroupName(_ message: RemoteMessage) -> String {
        let payloadName = payloadString(message.payload, ["group_name", "channel_name", "conversation_name"])
        if !payloadName.isEmpty, !isSyntheticGroupSystemDisplayName(payloadName) {
            return payloadName
        }
        let groupID = payloadString(message.payload, ["group_id", "channel_id"], fallback: message.channelID)
        if let group = groups.first(where: { $0.id == groupID }) {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return "当前群"
    }

    // Source Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift:60; pure value snapshot counterpart.
    func groupMembershipServerText(_ payload: [String: JSONValue]) -> String? {
        let text = payloadString(payload, ["text", "summary", "content", "body", "display_text"])
        return text.isEmpty ? nil : text
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift:194; pure value snapshot counterpart.
    func isRemoteMessageFromCurrentUser(_ message: RemoteMessage) -> Bool {
        currentMessageSenderIdentitySet().contains(message.fromUID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:302; pure value snapshot counterpart.
    func isAdminDeletedRemoteMessage(_ message: RemoteMessage) -> Bool {
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

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:224; pure value snapshot counterpart.
    func payloadBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        RemotePayloadReader.bool(payload, keys)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:305; pure value snapshot counterpart.
    func matchedPendingLocalMessageID(for remote: RemoteMessage, pendingLocals: [ChatMessage], usedLocalIDs: Set<String>) -> String? {
        let remoteClientIDs = remoteClientMessageIdentifiers(remote)
        for clientID in remoteClientIDs
            where pendingLocals.contains(where: { $0.id == clientID }) && !usedLocalIDs.contains(clientID) {
            return clientID
        }
        guard remoteClientIDs.isEmpty else { return nil }

        let remoteSender = remote.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSenderIsCurrentUser = isRemoteMessageFromCurrentUser(remote)
        guard remoteSenderIsCurrentUser || remoteSender.isEmpty else { return nil }

        let maxTimeDrift: TimeInterval = remoteSenderIsCurrentUser ? 10 * 60 : 2 * 60
        if isAttachmentMessageKind(remoteMessageKind(from: remote)) {
            let candidates = pendingLocals.compactMap { local -> String? in
                guard !usedLocalIDs.contains(local.id),
                      pendingLocalMessage(local, matches: remote, maxTimeDrift: maxTimeDrift) else { return nil }
                return local.id
            }
            return candidates.count == 1 ? candidates[0] : nil
        }
        return pendingLocals.first { local in
            !usedLocalIDs.contains(local.id) && pendingLocalMessage(local, matches: remote, maxTimeDrift: maxTimeDrift)
        }?.id
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:335; pure value snapshot counterpart.
    func pendingLocalMessage(_ local: ChatMessage, matches remote: RemoteMessage, maxTimeDrift: TimeInterval = 10 * 60) -> Bool {
        guard local.isOutgoing else { return false }
        let remoteKind = remoteMessageKind(from: remote)
        if isAttachmentMessageKind(local.kind) || isAttachmentMessageKind(remoteKind) {
            guard attachmentKindsCompatible(local: local, remoteKind: remoteKind, remote: remote) else { return false }
            return pendingLocalAttachment(local, matches: remote, maxTimeDrift: maxTimeDrift)
        } else {
            guard local.kind == remoteKind else { return false }
        }
        let localText = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteText = messagePreview(remote).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localText.isEmpty, localText == remoteText else { return false }
        if let localDate = local.createdAt,
           let remoteDate = parseRemoteDate(remote.createdAt),
           abs(localDate.timeIntervalSince(remoteDate)) > maxTimeDrift {
            return false
        }
        return true
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:413; pure value snapshot counterpart.
    func pendingLocalAttachment(_ local: ChatMessage, matches remote: RemoteMessage, maxTimeDrift: TimeInterval) -> Bool {
        guard attachmentTimeMatches(local, remote: remote, maxTimeDrift: maxTimeDrift) else { return false }
        let localSize = local.attachmentSizeBytes ?? 0
        let remoteSize = attachmentPayloadInt64(remote.payload, ["size_bytes", "size"]) ?? 0
        if localSize > 0, remoteSize > 0, localSize != remoteSize {
            return false
        }

        let localFileID = (local.attachmentFileID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFileIDs = remoteAttachmentIdentifiers(remote)
        if !localFileID.isEmpty, !remoteFileIDs.isEmpty {
            return remoteFileIDs.contains(localFileID)
        }

        let localCacheKey = local.attachmentCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteCacheKey = attachmentPayloadString(remote.payload, ["cache_key", "cacheKey", "thumb_object_key", "thumbnail_object_key", "object_key"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !localCacheKey.isEmpty, localCacheKey == remoteCacheKey {
            let localVersion = local.attachmentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteVersion = attachmentPayloadString(remote.payload, ["version", "file_version", "cache_version"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let localChecksum = local.attachmentChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteChecksum = attachmentPayloadString(remote.payload, ["checksum"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localVersion.isEmpty, !remoteVersion.isEmpty, localVersion != remoteVersion {
                return !localChecksum.isEmpty && localChecksum == remoteChecksum
            }
            if !localChecksum.isEmpty, !remoteChecksum.isEmpty, localChecksum != remoteChecksum {
                return false
            }
            return true
        } else if !localCacheKey.isEmpty || !remoteCacheKey.isEmpty {
            return false
        }

        return false
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:454; pure value snapshot counterpart.
    func remoteAttachmentIdentifiers(_ remote: RemoteMessage) -> Set<String> {
        Set(["file_id", "attachment_id", "media_id", "id"]
            .map { attachmentPayloadString(remote.payload, [$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:212; pure value snapshot counterpart.
    func attachmentPayloadInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        RemotePayloadReader.attachmentInt64(payload, keys)
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:460; pure value snapshot counterpart.
    func attachmentTimeMatches(_ local: ChatMessage, remote: RemoteMessage, maxTimeDrift: TimeInterval) -> Bool {
        guard let localDate = local.createdAt,
              let remoteDate = parseRemoteDate(remote.createdAt) else {
            return true
        }
        return abs(localDate.timeIntervalSince(remoteDate)) <= maxTimeDrift
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:376; pure value snapshot counterpart.
    func attachmentKindsCompatible(local: ChatMessage, remoteKind: MessageKind, remote: RemoteMessage) -> Bool {
        if local.kind == remoteKind { return true }
        let localCategory = attachmentMediaCategory(for: local)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let remoteCategory = remoteAttachmentMediaCategory(remote, remoteKind: remoteKind)
        if !localCategory.isEmpty, !remoteCategory.isEmpty, localCategory == remoteCategory {
            return true
        }
        if local.kind == .voice, ["voice", "audio"].contains(remoteCategory) {
            return true
        }
        if remoteKind == .voice, ["voice", "audio"].contains(localCategory) {
            return true
        }
        return local.kind == .file && remoteKind == .video && localCategory == "video"
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
