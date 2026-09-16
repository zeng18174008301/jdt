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

// MARK: - Group System Message Presentation

extension AppState {
    // MainActor partition: group system preview reads AppState-owned presentation
    // state such as groups, contacts, and member-count policy. Keep this actor
    // isolated; only the payload reader delegate below is pure support code.
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

    private func groupMembershipServerText(_ payload: [String: JSONValue]) -> String? {
        let text = payloadString(payload, ["text", "summary", "content", "body", "display_text"])
        return text.isEmpty ? nil : text
    }

    private func groupSystemGroupName(_ message: RemoteMessage) -> String {
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

    private func groupSystemUserDisplayName(
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

    private func groupSystemTargetDisplayText(
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

    private func groupSystemTargetNames(payload: [String: JSONValue], participants: [IMUser]) -> [String] {
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

    private func formattedGroupSystemTargetNames(_ names: [String], totalCount: Int, maxVisible: Int = 2) -> String {
        let visibleNames = Array(names.prefix(max(1, maxVisible)))
        let joined = visibleNames.joined(separator: "、")
        guard totalCount > visibleNames.count else { return joined }
        return "\(joined)等\(totalCount)人"
    }

    private func payloadStringArray(_ payload: [String: JSONValue], _ keys: [String]) -> [String] {
        // JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：群系统消息字符串数组读取委托给 RemotePayloadReader
        RemotePayloadReader.stringArray(payload, keys)
        // JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束
    }

    private func groupSystemUser(_ user: IMUser, matches id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty && $0.caseInsensitiveCompare(normalizedID) == .orderedSame }
    }

    private func safeGroupSystemUserName(_ user: IMUser, matching id: String) -> String? {
        for candidate in [user.name, user.username] {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableGroupSystemDisplayName(name, matching: [id]) {
                return name
            }
        }
        return nil
    }

    private func isUsableGroupSystemDisplayName(_ name: String, matching ids: [String]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSyntheticGroupSystemDisplayName(trimmed) else { return false }
        if isIdentifierLikeDisplayName(trimmed, matching: "") { return false }
        return !ids.contains { id in
            let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalizedID.isEmpty && isIdentifierLikeDisplayName(trimmed, matching: normalizedID)
        }
    }

    private func isSyntheticGroupSystemDisplayName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return true }
        if normalized.hasPrefix("NO_SUCH") { return true }
        return ["UNKNOWN", "NULL", "NIL", "NONE"].contains(normalized)
    }
}
