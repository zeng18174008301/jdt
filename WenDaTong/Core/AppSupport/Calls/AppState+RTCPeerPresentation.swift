import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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
    func refreshVoiceCallPeerIfBetter(_ peer: IMUser, matching callID: String?) {
        refreshIncomingVoiceCallCallerIfBetter(peer, matching: callID)
        refreshActiveVoiceCallPeerIfBetter(peer, matching: callID)
    }

    func refreshIncomingVoiceCallCallerIfBetter(_ caller: IMUser, matching callID: String?) {
        guard var call = incomingVoiceCall,
              voiceCallID(call.callID, matches: callID) else { return }
        let mergedCaller = voiceCallUser(merging: call.caller, with: caller)
        guard shouldReplaceVoiceCallUser(call.caller, with: mergedCaller, allowIdentityMismatch: true) else { return }
        call.caller = mergedCaller
        if (call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            call.callID = callID?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        incomingVoiceCall = call
    }

    private func refreshActiveVoiceCallPeerIfBetter(_ peer: IMUser, matching callID: String?) {
        guard var call = activeVoiceCall,
              voiceCallID(call.callID, matches: callID) else { return }
        let mergedPeer = voiceCallUser(merging: call.peer, with: peer)
        guard shouldReplaceVoiceCallUser(call.peer, with: mergedPeer, allowIdentityMismatch: true) else { return }
        call.peer = mergedPeer
        activeVoiceCall = call
    }

    private func voiceCallID(_ existing: String?, matches candidate: String?) -> Bool {
        let normalizedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedCandidate.isEmpty else { return true }
        return existing?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCandidate
    }

    private func shouldReplaceVoiceCallUser(_ existing: IMUser, with candidate: IMUser, allowIdentityMismatch: Bool = false) -> Bool {
        let sameIdentity = !Set(userIdentityCandidates(for: existing)).isDisjoint(with: Set(userIdentityCandidates(for: candidate)))
        guard sameIdentity || allowIdentityMismatch else { return false }
        if voiceCallUserLooksGeneric(existing), !voiceCallUserLooksGeneric(candidate) {
            return true
        }
        guard sameIdentity else { return false }
        if existing.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarURL != existing.avatarURL {
            return true
        }
        if existing.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarVersion != existing.avatarVersion {
            return true
        }
        if existing.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarUpdatedAt != existing.avatarUpdatedAt {
            return true
        }
        return false
    }

    private func voiceCallUserLooksGeneric(_ user: IMUser) -> Bool {
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "语音联系人" { return true }
        return userIdentityCandidates(for: user).contains(name)
    }

    func displayUserForVoiceCall(_ user: IMUser) -> IMUser {
        userIdentityCandidates(for: user).reduce(user) { best, identifier in
            let candidate = userForVoiceCall(uid: identifier)
            let merged = voiceCallUser(merging: best, with: candidate)
            return shouldReplaceVoiceCallUser(best, with: merged) ? merged : best
        }
    }

    func voiceCallChannelID(for user: IMUser, requestedChannelID: String?) -> String {
        let requested = requestedChannelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requested.isEmpty {
            return requested
        }
        if let conversation = directConversationForVoiceCall(uid: user.id, channelID: nil)
            ?? directConversationForVoiceCall(uid: user.userID, channelID: nil) {
            return remoteChannelID(for: conversation)
        }
        let currentID = (apiContext.imUID?.isEmpty == false ? apiContext.imUID : currentUser.id) ?? currentUser.id
        let peerID = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentID.isEmpty, !peerID.isEmpty, currentID != peerID else { return "" }
        return [currentID, canonicalDirectParticipantID(peerID)].filter { !$0.isEmpty }.sorted().joined(separator: ":")
    }

    func userForVoiceCall(uid: String, channelID: String? = nil) -> IMUser {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let user = contacts.first(where: { voiceCallUser($0, matches: trimmed) }) {
            return user
        }
        for conversation in conversationStore.conversationMessageSnapshots() {
            if let user = conversation.participants.first(where: { voiceCallUser($0, matches: trimmed) }) {
                return user
            }
        }
        if let conversation = directConversationForVoiceCall(uid: trimmed, channelID: channelID) {
            return voiceCallUser(from: conversation, fallbackUID: trimmed)
        }
        return IMUser(
            id: trimmed.isEmpty ? "unknown_voice_peer" : trimmed,
            userID: trimmed,
            name: trimmed.isEmpty ? "语音联系人" : trimmed,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(trimmed),
            badges: []
        )
    }

    func directConversationForVoiceCall(uid: String, channelID: String?) -> ConversationMessageSnapshot? {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentIDs = currentUserIdentitySet()
        let channelPeerIDs = Set(directChannelParts(trimmedChannelID).filter { !currentIDs.contains($0) })
        return conversationStore.conversationMessageSnapshots().first { conversation in
            guard conversation.kind == .direct else { return false }
            if !trimmedUID.isEmpty, directPeerID(for: conversation) == trimmedUID {
                return true
            }
            let conversationParts = Set((directChannelParts(conversation.id) + directChannelParts(remoteChannelID(for: conversation))).filter { !$0.isEmpty })
            if !trimmedUID.isEmpty, conversationParts.contains(trimmedUID) {
                return true
            }
            guard !channelPeerIDs.isEmpty else { return false }
            let conversationPeerIDs = conversationParts.filter { !currentIDs.contains($0) }
            return !conversationPeerIDs.isEmpty && !conversationPeerIDs.isDisjoint(with: channelPeerIDs)
        }
    }

    func voiceCallUser(from conversation: ConversationMessageSnapshot, fallbackUID: String) -> IMUser {
        let trimmedFallback = fallbackUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = currentUserIdentitySet()
        let peerID = directPeerID(for: conversation)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? directChannelParts(remoteChannelID(for: conversation)).first(where: { !currentIDs.contains($0) })
            ?? directChannelParts(conversation.id).first(where: { !currentIDs.contains($0) })
            ?? trimmedFallback
        if let user = contacts.first(where: { voiceCallUser($0, matches: peerID) }) {
            return user
        }
        if let user = conversation.participants.first(where: { voiceCallUser($0, matches: peerID) }) {
            return user
        }
        let resolvedID = peerID.isEmpty ? (trimmedFallback.isEmpty ? "unknown_voice_peer" : trimmedFallback) : peerID
        let displayName = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return IMUser(
            id: resolvedID,
            userID: resolvedID,
            name: displayName.isEmpty ? (resolvedID == "unknown_voice_peer" ? "语音联系人" : resolvedID) : displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(resolvedID),
            avatarURL: conversation.avatarURL,
            avatarVersion: conversation.avatarVersion,
            avatarUpdatedAt: conversation.avatarUpdatedAt,
            badges: []
        )
    }

    func voiceCallUser(_ user: IMUser, matches rawIdentifier: String) -> Bool {
        let normalized = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return userIdentityCandidates(for: user).contains(normalized)
    }

    enum VoiceCallPeerRole {
        case caller
        case callee
    }

    func voiceCallPeer(from call: RemoteRTCCall, identities: Set<String>) -> IMUser {
        let callerIsSelf = identities.contains(call.callerUID.trimmingCharacters(in: .whitespacesAndNewlines))
        let role: VoiceCallPeerRole = callerIsSelf ? .callee : .caller
        let peerUID = callerIsSelf ? call.calleeUID : call.callerUID
        let base = userForVoiceCall(uid: peerUID, channelID: call.channelID)
        let profile = role == .caller ? call.callerProfile : call.calleeProfile
        return voiceCallUser(
            merging: base,
            uid: profile?.uid ?? peerUID,
            userID: profile?.userID ?? "",
            displayName: role == .caller ? call.callerName : call.calleeName,
            avatarURL: role == .caller ? call.callerAvatarURL : call.calleeAvatarURL,
            avatarVersion: role == .caller ? call.callerAvatarVersion : call.calleeAvatarVersion,
            avatarUpdatedAt: role == .caller ? call.callerAvatarUpdatedAt : call.calleeAvatarUpdatedAt
        )
    }

    func voiceCallPeer(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        peerUID: String,
        peerRole: VoiceCallPeerRole,
        channelID: String
    ) -> IMUser {
        let profile = rtcProfile(from: payload, callPayload: callPayload, role: peerRole)
        let base = userForVoiceCall(uid: peerUID, channelID: channelID)
        return voiceCallUser(
            merging: base,
            uid: profile?.uid ?? peerUID,
            userID: profile?.userID ?? "",
            displayName: profile?.displayName ?? flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .name),
            avatarURL: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatar, fallback: profile?.avatar ?? ""),
            avatarVersion: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatarVersion, fallback: profile?.avatarVersion ?? ""),
            avatarUpdatedAt: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatarUpdatedAt, fallback: profile?.avatarUpdatedAt ?? "")
        )
    }

    private enum RTCProfileFlatField {
        case name
        case avatar
        case avatarVersion
        case avatarUpdatedAt
    }

    private func rtcProfile(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        role: VoiceCallPeerRole
    ) -> RemoteRTCParticipantProfile? {
        let nestedKeys: [String] = role == .caller
            ? ["caller_profile", "callerProfile", "caller", "from_profile"]
            : ["callee_profile", "calleeProfile", "callee", "target_profile"]
        for key in nestedKeys {
            if let object = payload[key]?.objectValue ?? callPayload[key]?.objectValue {
                let profile = RemoteRTCParticipantProfile(
                    uid: payloadString(object, ["uid", "im_uid", "imUID", "id"]),
                    userID: payloadString(object, ["user_id", "userID", "userId"]),
                    displayName: payloadString(object, ["display_name", "displayName", "nickname", "name", "username"]),
                    avatar: payloadString(object, ["avatar", "avatar_url", "avatarURL", "avatarUrl"]),
                    avatarVersion: payloadString(object, ["avatar_version", "avatarVersion", "version"]),
                    avatarUpdatedAt: payloadString(object, ["avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"])
                )
                if !profile.isEmpty {
                    return profile
                }
            }
        }
        return nil
    }

    private func flatRTCProfileString(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        role: VoiceCallPeerRole,
        field: RTCProfileFlatField,
        fallback: String = ""
    ) -> String {
        let keys: [String]
        switch (role, field) {
        case (.caller, .name):
            keys = ["caller_name", "callerName", "from_name", "fromName"]
        case (.callee, .name):
            keys = ["callee_name", "calleeName", "target_name", "targetName"]
        case (.caller, .avatar):
            keys = ["caller_avatar", "caller_avatar_url", "callerAvatar", "callerAvatarUrl", "from_avatar", "fromAvatar"]
        case (.callee, .avatar):
            keys = ["callee_avatar", "callee_avatar_url", "calleeAvatar", "calleeAvatarUrl", "target_avatar", "target_avatar_url", "targetAvatar", "targetAvatarUrl"]
        case (.caller, .avatarVersion):
            keys = ["caller_avatar_version", "callerAvatarVersion", "from_avatar_version", "fromAvatarVersion"]
        case (.callee, .avatarVersion):
            keys = ["callee_avatar_version", "calleeAvatarVersion", "target_avatar_version", "targetAvatarVersion"]
        case (.caller, .avatarUpdatedAt):
            keys = ["caller_avatar_updated_at", "callerAvatarUpdatedAt", "from_avatar_updated_at", "fromAvatarUpdatedAt"]
        case (.callee, .avatarUpdatedAt):
            keys = ["callee_avatar_updated_at", "calleeAvatarUpdatedAt", "target_avatar_updated_at", "targetAvatarUpdatedAt"]
        }
        let value = payloadString(payload, keys, fallback: payloadString(callPayload, keys))
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    func voiceCallUser(merging base: IMUser, with candidate: IMUser) -> IMUser {
        voiceCallUser(
            merging: base,
            uid: candidate.id,
            userID: candidate.userID,
            username: candidate.username,
            displayName: candidate.name,
            avatarURL: candidate.avatarURL,
            avatarVersion: candidate.avatarVersion,
            avatarUpdatedAt: candidate.avatarUpdatedAt
        )
    }

    func voiceCallUser(
        merging base: IMUser,
        uid: String,
        userID: String,
        username: String = "",
        displayName: String,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) -> IMUser {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseLooksGeneric = voiceCallUserLooksGeneric(base)
        let resolvedID = baseLooksGeneric && !normalizedUID.isEmpty ? normalizedUID : (base.id.isEmpty ? normalizedUID : base.id)
        let nextName: String
        if baseLooksGeneric,
           !normalizedName.isEmpty,
           !isIdentifierLikeDisplayName(normalizedName, matching: resolvedID) {
            nextName = normalizedName
        } else {
            nextName = base.name
        }

        let resolvedAvatar = resolvedVoiceCallAvatarURL(avatarURL)
        let baseAvatar = base.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAvatar = resolvedAvatar.isEmpty ? base.avatarURL : resolvedAvatar
        let incomingVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextVersion: String
        if resolvedAvatar.isEmpty {
            nextVersion = base.avatarVersion
        } else if !incomingVersion.isEmpty {
            nextVersion = incomingVersion
        } else {
            nextVersion = resolvedAvatar == baseAvatar ? base.avatarVersion : ""
        }
        let nextUpdatedAt: String
        if resolvedAvatar.isEmpty {
            nextUpdatedAt = base.avatarUpdatedAt
        } else if !incomingUpdatedAt.isEmpty {
            nextUpdatedAt = incomingUpdatedAt
        } else {
            nextUpdatedAt = resolvedAvatar == baseAvatar ? base.avatarUpdatedAt : ""
        }

        return IMUser(
            id: resolvedID.isEmpty ? base.id : resolvedID,
            userID: normalizedUserID.isEmpty ? base.userID : normalizedUserID,
            username: normalizedUsername.isEmpty ? base.username : normalizedUsername,
            name: nextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (resolvedID.isEmpty ? "语音联系人" : resolvedID) : nextName,
            title: base.title,
            department: base.department,
            departmentPathNames: base.departmentPathNames,
            phone: base.phone,
            phoneVerified: base.phoneVerified,
            realNameVerified: base.realNameVerified,
            realNameStatus: base.realNameStatus,
            email: base.email,
            status: base.status,
            enterprise: base.enterprise,
            avatarSeed: base.avatarSeed == 0 ? stableSeed(resolvedID) : base.avatarSeed,
            avatarURL: nextAvatar,
            avatarVersion: nextVersion,
            avatarUpdatedAt: nextUpdatedAt,
            badges: base.badges
        )
    }

    private func resolvedVoiceCallAvatarURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return resolveTenantAssetURL(trimmed)
    }

    func voiceCallAvatarSource(for peer: IMUser?) -> String {
        guard let peer else { return "" }
        let avatar = peer.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !avatar.isEmpty else { return "" }
        let identities = Set(userIdentityCandidates(for: peer))
        if contacts.contains(where: { contact in
            !Set(userIdentityCandidates(for: contact)).isDisjoint(with: identities)
                && contact.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar
        }) {
            return "contact"
        }
        if conversationStore.conversationMessageSnapshots().contains(where: { conversation in
            conversation.participants.contains { participant in
                !Set(userIdentityCandidates(for: participant)).isDisjoint(with: identities)
                    && participant.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar
            } || (conversation.kind == .direct
                && conversation.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar)
        }) {
            return "conversation"
        }
        return "rtc_payload"
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
