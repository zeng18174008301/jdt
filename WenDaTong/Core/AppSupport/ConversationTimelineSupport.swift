import IM4Domain
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

// JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改开始：远端会话时间/排序纯计算从 AppState 拆出
enum RemoteConversationTimelineMapper {
    static func activityDate(remote: RemoteConversation, previous: ConversationMessageSnapshot?) -> Date? {
        let hasMessageTime = !(remote.lastMessageAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let previous, previous.sortTimestamp > 0,
           latestSeq(remote: remote) <= previous.lastMsgSeq,
           previous.lastMsgSeq > 0 || (remote.lastMessage == nil && !hasMessageTime) {
            // Metadata refreshes can advance last_activity_at/updated_at
            // without adding a message. Keep the existing message order.
            return Date(timeIntervalSince1970: previous.sortTimestamp)
        }
        let remoteCandidates = sortTimeCandidates(remote)
        for candidate in remoteCandidates where !AppStateTimeFormatter.isTimeOnlyRemoteValue(candidate) {
            if let date = AppStateTimeFormatter.parseRemoteDate(candidate) {
                return date
            }
        }
        let displayFallbackCandidates = remoteCandidates + [previous?.time]
        for candidate in displayFallbackCandidates {
            if let date = AppStateTimeFormatter.parseRemoteAbsoluteDate(candidate) {
                return date
            }
        }
        if let previous, previous.sortTimestamp > 0 {
            return Date(timeIntervalSince1970: previous.sortTimestamp)
        }
        return nil
    }

    static func displayTime(
        remote: RemoteConversation,
        previous: ConversationMessageSnapshot?,
        activityDate: Date?
    ) -> String {
        if let last = remote.lastMessage,
           last.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
            return rtcMessageDisplayTime(last)
        }
        if let activityDate {
            return AppStateTimeFormatter.displayTime(activityDate)
        }
        let lastMessageAt = remote.lastMessageAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastMessageAt.isEmpty {
            return AppStateTimeFormatter.displayTime(lastMessageAt)
        }
        let messageCreatedAt = remote.lastMessage?.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !messageCreatedAt.isEmpty {
            return AppStateTimeFormatter.displayTime(messageCreatedAt)
        }
        let lastActivityAt = remote.lastActivityAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastActivityAt.isEmpty {
            return AppStateTimeFormatter.displayTime(lastActivityAt)
        }
        let updatedAt = remote.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !updatedAt.isEmpty {
            return AppStateTimeFormatter.displayTime(updatedAt)
        }
        return previous?.time ?? ""
    }

    static func sortTimestamp(remote: RemoteConversation, previous: ConversationMessageSnapshot? = nil) -> TimeInterval {
        activityDate(remote: remote, previous: previous)?.timeIntervalSince1970 ?? 0
    }

    static func latestSeq(remote: RemoteConversation) -> Int64 {
        max(remote.lastMsgSeq, remote.lastMessage?.channelSeq ?? 0)
    }

    static func freshnessPrecedes(_ lhs: RemoteConversation, _ rhs: RemoteConversation) -> Bool {
        let lhsSeq = latestSeq(remote: lhs)
        let rhsSeq = latestSeq(remote: rhs)
        if lhsSeq != rhsSeq { return lhsSeq > rhsSeq }
        let lhsTimestamp = sortTimestamp(remote: lhs)
        let rhsTimestamp = sortTimestamp(remote: rhs)
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp }
        if lhs.version != rhs.version { return lhs.version > rhs.version }
        return lhs.channelID < rhs.channelID
    }

    private static func sortTimeCandidates(_ remote: RemoteConversation) -> [String?] {
        [
            remote.lastMessageAt,
            remote.lastMessage?.createdAt,
            remote.lastActivityAt,
            remote.updatedAt
        ]
    }

    private static func rtcMessageDisplayTime(_ remote: RemoteMessage) -> String {
        let record = remote.channelSeq > 0 && !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RTCCallRecordPayload.parse(
                contentType: remote.contentType,
                channelType: remote.channelType,
                fromUID: remote.fromUID,
                payload: remote.payload
            )
            : nil
        let date = RTCCallRecordTimeProjection.messageDate(
            outerDate: AppStateTimeFormatter.parseRemoteDate(remote.createdAt),
            record: record,
            contentType: remote.contentType,
            channelType: remote.channelType,
            fromUID: remote.fromUID
        )
        return date.map { AppStateTimeFormatter.displayTime($0) } ?? "时间未知"
    }
}
// JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改开始：远端会话去重选择拆到纯 helper，减少 AppState 内重复状态扫描
enum RemoteConversationCanonicalizer {
    static func canonical(
        _ remoteConversations: [RemoteConversation],
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup?
    ) -> [RemoteConversation] {
        var byChannelID: [String: RemoteConversation] = [:]
        byChannelID.reserveCapacity(remoteConversations.count)
        for remote in remoteConversations {
            let channelID = ConversationChannelIdentityMapper.normalizedRemoteChannelID(
                remote.channelID,
                channelType: remote.channelType,
                currentID: currentID,
                currentIDs: currentIDs,
                lookup: lookup
            )
            guard !channelID.isEmpty else { continue }
            if let current = byChannelID[channelID] {
                if RemoteConversationTimelineMapper.freshnessPrecedes(remote, current) {
                    byChannelID[channelID] = remote
                }
            } else {
                byChannelID[channelID] = remote
            }
        }
        return Array(byChannelID.values)
    }
}
// JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改开始：频道/会话 ID 纯映射从 AppState 拆出，保留原有规则
typealias ConversationChannelIdentityMapper = IM4Domain.ConversationChannelIdentityMapper
// JHT_MOD_END APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改结束 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
