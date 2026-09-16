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

// MARK: - Groups and Announcements

extension AppState {
    func loadGroupDetailForConversation(_ conversationID: String, force: Bool = true, includeSecondaryData: Bool = true) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .group else { return }
        loadGroupDetailIfNeeded(groupID: remoteChannelID(for: conversation), force: force, includeSecondaryData: includeSecondaryData)
    }

    func announcements(for groupID: String) -> [GroupAnnouncement] {
        groupAnnouncements[groupID] ?? []
    }

    func latestAnnouncement(for groupID: String) -> GroupAnnouncement? {
        groupAnnouncements[groupID]?.first
    }

    func currentUnreadAnnouncement(for groupID: String) -> GroupAnnouncement? {
        currentGroupAnnouncements[groupID]
    }

    func hasUnreadAnnouncement(for groupID: String) -> Bool {
        guard let announcement = currentUnreadAnnouncement(for: groupID),
              !announcement.id.isEmpty else {
            return false
        }
        let displayText = announcement.summary.isEmpty ? announcement.content : announcement.summary
        return announcement.unread && !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func markLatestAnnouncementRead(groupID: String, completion: ((Bool) -> Void)? = nil) {
        guard let announcement = currentUnreadAnnouncement(for: groupID) ?? latestAnnouncement(for: groupID),
              !announcement.id.isEmpty else {
            completion?(true)
            return
        }
        markGroupAnnouncementRead(groupID: groupID, announcementID: announcement.id, completion: completion)
    }

    func markGroupAnnouncementRead(groupID: String, announcementID: String, completion: ((Bool) -> Void)? = nil) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            completion?(false)
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        Task {
            do {
                let remote = try await api.markGroupAnnouncementRead(context: context, groupID: groupID, announcementID: announcementID)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                let item = groupAnnouncement(
                    from: remote,
                    fallbackGroupID: groupID,
                    requestPrivacyEpoch: announcementPrivacyEpoch
                )
                upsertGroupAnnouncement(item, markCurrentRead: true)
                await refreshGroupAnnouncements(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                completion?(true)
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                handleRemoteError(error, fallback: "公告已读同步失败")
                completion?(false)
            }
        }
    }

    func loadGroupAnnouncementDetail(groupID: String, announcementID: String, silent: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !announcementID.isEmpty else { return }
        let keyContext = contactStore.groupAnnouncementDetailLoadingKeyContext(
            groupID: groupID,
            announcementID: announcementID
        )
        let loadingKey = keyContext.loadingKey
        let context = apiContext
        guard context.hasIMSession else {
            if !silent {
                toast = "登录会话不可用，请重新登录"
            }
            completion?(false)
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        guard contactStore.beginGroupAnnouncementDetailLoading(loadingKey: loadingKey) else { return }
        Task {
            defer {
                contactStore.finishGroupAnnouncementDetailLoading(loadingKey: loadingKey)
            }
            do {
                let remote = try await api.groupAnnouncementDetail(context: context, groupID: groupID, announcementID: announcementID)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                upsertGroupAnnouncement(
                    groupAnnouncement(
                        from: remote,
                        fallbackGroupID: groupID,
                        requestPrivacyEpoch: announcementPrivacyEpoch
                    ),
                    markCurrentRead: false
                )
                completion?(true)
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                handleRemoteError(error, fallback: "群公告详情加载失败", silent: silent)
                completion?(false)
            }
        }
    }

}
