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
    #if DEBUG
    func debugConfigureRegistrationResolutionScreenshotScenarioForTesting(_ rawValue: String) -> Bool {
        configureRegistrationResolutionScreenshotScenarioIfRequested([
            "--registration-resolution-screenshot=\(rawValue)"
        ])
    }

    func debugConfigureLicenseQuotaScreenshotScenarioForTesting(_ rawValue: String) -> Bool {
        configureLicenseQuotaScreenshotScenarioIfRequested([
            "--license-quota-screenshot=\(rawValue)"
        ])
    }

    func debugMessagePreviewForTesting(_ message: RemoteMessage, participants: [IMUser] = []) -> String {
        messagePreview(message, participants: participants)
    }

    func debugChatMessageForTesting(_ message: RemoteMessage, participants: [IMUser] = []) -> ChatMessage {
        chatMessage(from: message, participants: participants)
    }

    func debugHandleRealtimeEnvelopeForTesting(_ envelope: RealtimeEnvelope) {
        handleRealtimeEnvelope(envelope)
    }

    func debugApplyRemoteGroupsForTesting(_ remoteGroups: [RemoteUserGroup]) {
        applyRemoteGroups(remoteGroups)
    }

    func debugApplyRemoteConversationsForTesting(
        _ remoteConversations: [RemoteConversation],
        replacing: Bool = true
    ) {
        applyRemoteConversations(remoteConversations, replacing: replacing)
    }

    func debugResetAvatarRealtimeAssetResolutionCountForTesting() {
        avatarRealtimeAssetResolutionCountForTesting = 0
    }

    func debugAvatarRealtimeAssetResolutionCountForTesting() -> Int {
        avatarRealtimeAssetResolutionCountForTesting
    }

    func debugReapplyAllAvatarRealtimeProjectionsForTesting() {
        reapplyAllAvatarRealtimeProjections()
    }

    func debugApplyAvatarRealtimeProjectionsForTesting(_ projections: [AvatarRealtimeProjectionValue]) {
        applyAvatarRealtimeProjections(projections)
    }

    func debugHandleRemoteErrorForTesting(_ error: Error, fallback: String = "操作失败") {
        handleRemoteError(error, fallback: fallback)
    }

    func debugHasIMSessionForTesting() -> Bool {
        apiContext.hasIMSession
    }

    func debugMinimumGroupMemberProfileGenerationForTesting(groupID: String) -> Int64 {
        minimumGroupMemberProfileGenerationByScopedGroupKey[
            groupMemberProfileCacheKey(groupID: groupID)
        ] ?? 0
    }

    func debugApplyGroupMembersResultForTesting(
        _ result: RemoteGroupMembersResult,
        groupID: String,
        profileGenerationAtRequestStart: Int64? = nil
    ) {
        applyGroupMembers(
            result.items,
            selfMember: result.selfMember,
            total: result.total,
            groupID: groupID,
            partial: result.hasMore == true,
            nextOffset: result.nextOffset,
            nextCursor: result.nextCursor,
            profileGenerationAtRequestStart: profileGenerationAtRequestStart
        )
    }

    func debugApplyMyGroupMemberProfileForTesting(
        _ profile: RemoteGroupMemberProfile,
        fallbackGroupID: String
    ) {
        applyMyGroupMemberProfile(profile, fallbackGroupID: fallbackGroupID)
    }
    #endif

    // Group membership system preview helpers are split to Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift.

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

    // Identity, conversation title, and pure formatting bridges are split to Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift.
}
