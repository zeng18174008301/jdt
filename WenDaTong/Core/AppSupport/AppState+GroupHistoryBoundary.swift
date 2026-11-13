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
    var groupHistoryLimitedMessage: String {
        groupHistoryLimitedMessageText
    }

    func historyLimitedReachedStartMessage(for conversation: ConversationMessageSnapshot) -> String {
        if conversation.kind == .group,
           let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive {
            return groupHistoryLimitedMessage
        }
        return conversation.messages.isEmpty ? "暂无历史消息" : "已同步到最早消息"
    }

    func historyBoundary(from result: RemoteMessageSyncResult, channelType: String) -> ConversationStore.HistoryVisibilityBoundary? {
        guard channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "group" else { return nil }
        return ConversationStore.HistoryVisibilityBoundary(
            fromSeq: result.historyVisibleFromSeq,
            limited: result.historyLimited,
            confirmed: true
        )
    }

    func historyBoundary(from remote: RemoteConversation, kind: ConversationKind) -> ConversationStore.HistoryVisibilityBoundary? {
        guard kind == .group else { return nil }
        return ConversationStore.HistoryVisibilityBoundary(
            fromSeq: remote.historyVisibleFromSeq,
            limited: remote.historyLimited,
            confirmed: true
        )
    }

    private func historyBoundaryForGroupChannelID(_ rawChannelID: String) -> ConversationStore.HistoryVisibilityBoundary? {
        let channelID = rawChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { return nil }
        if let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
            conversation.kind == .group && (conversation.id == channelID || remoteChannelID(for: conversation) == channelID)
        }) {
            return conversationStore.historyBoundary(for: conversation)
        }
        if let group = group(id: channelID),
           group.historyLimited || group.historyVisibleFromSeq > 1 {
            return ConversationStore.HistoryVisibilityBoundary(
                fromSeq: group.historyVisibleFromSeq,
                limited: group.historyLimited,
                confirmed: true
            )
        }
        return nil
    }

    func isRemoteMessageVisibleAfterHistoryBoundary(_ remote: RemoteMessage, boundary: ConversationStore.HistoryVisibilityBoundary?) -> Bool {
        guard let boundary, boundary.isRestrictive else { return true }
        return remote.channelSeq >= boundary.fromSeq
    }

    private func isFileItemVisibleAfterHistoryBoundary(_ file: FileItem) -> Bool {
        let channelType = file.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channelType == "group",
              let boundary = historyBoundaryForGroupChannelID(file.channelID),
              boundary.isRestrictive else { return true }
        return file.channelSeq >= boundary.fromSeq
    }

    func isFileItemVisibleInFileLists(_ file: FileItem) -> Bool {
        !file.isVoiceMessageAsset && isFileItemVisibleAfterHistoryBoundary(file)
    }

    func isFavoriteAssetVisibleAfterHistoryBoundary(_ item: FavoriteAssetItem) -> Bool {
        let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channelType == "group",
              let boundary = historyBoundaryForGroupChannelID(item.channelID),
              boundary.isRestrictive else { return true }
        return item.channelSeq >= boundary.fromSeq
    }

    @discardableResult
    func applyHistoryVisibilityBoundaryForGroup(
        channelID: String,
        boundary: ConversationStore.HistoryVisibilityBoundary,
        channelIDForConversation: ((ConversationMessageSnapshot) -> String)? = nil
    ) -> Bool {
        pruneDerivedCachesForHistoryBoundary(channelID: channelID, boundary: boundary)
        return conversationStore.applyHistoryVisibilityBoundary(
            channelID: channelID,
            boundary: boundary,
            channelIDForConversation: channelIDForConversation ?? { row in row.kind == .group ? self.remoteChannelID(for: row) : "" }
        )
    }

    func pruneDerivedCachesForHistoryBoundary(
        channelID: String,
        boundary: ConversationStore.HistoryVisibilityBoundary
    ) {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return }
        let previousBoundary = historyBoundaryForGroupChannelID(normalizedChannelID)
        let shouldClearForNewEpisode = previousBoundary.map { boundary.fromSeq < $0.fromSeq } ?? false
        guard shouldClearForNewEpisode || boundary.isRestrictive else { return }

        fileStore.purgeGroupHistoryFiles(
            groupID: normalizedChannelID,
            fromSeq: boundary.fromSeq,
            clearAll: shouldClearForNewEpisode
        )
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
        fileStore.favoriteAssetsSnapshot.items.removeAll { item in
            let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let itemChannelID = item.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelType == "group", itemChannelID == normalizedChannelID else { return false }
            if shouldClearForNewEpisode { return true }
            return item.channelSeq <= 0 || item.channelSeq < boundary.fromSeq
        }
        let scope = remoteDataScopeKey(for: apiContext)
        fileStore.favoriteAssetsCollection.remove(scope: scope) { item in
            let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let itemChannelID = item.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelType == "group", itemChannelID == normalizedChannelID else { return false }
            if shouldClearForNewEpisode { return true }
            return item.channelSeq <= 0 || item.channelSeq < boundary.fromSeq
        }
        fileStore.favoriteAssetsSnapshot.items = fileStore.favoriteAssetsCollection.activeItems
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END

        guard let conversationID = conversationStore.conversationMessageSnapshots().first(where: { conversation in
            conversation.kind == .group
                && (conversation.id == normalizedChannelID
                    || remoteChannelID(for: conversation) == normalizedChannelID)
        })?.id,
        let ticket = localMessageTicket,
        let context = mediaCacheScopeContext else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  context.sessionGeneration == self.localMessageSessionGeneration,
                  let candidates = try? await self.messagePersistence.removeMediaCacheReferences(
                    ticket: ticket,
                    conversationID: conversationID,
                    beforeChannelSequence: boundary.fromSeq,
                    clearAll: shouldClearForNewEpisode
                  ) else { return }
            for candidate in candidates {
                guard let url = self.mediaCacheURL(
                    relativePath: candidate.relativePath,
                    context: context
                ) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：历史边界媒体缓存清理放到后台，避免阻塞聊天页交互
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, conversation: ConversationMessageSnapshot) -> Bool {
        guard conversation.kind == .group,
              let boundary = conversationStore.historyBoundary(for: conversation),
              boundary.isRestrictive else { return false }
        let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        return code.contains("message_not_found")
            || code.contains("file_not_found")
            || code == "not_found"
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, conversationID: String) -> Bool {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        return shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, messageID: String) -> Bool {
        conversationStore.conversationMessageSnapshots().contains { conversation in
            conversation.messages.contains { $0.id == messageID }
                && shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
        }
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, file: FileItem) -> Bool {
        let channelID = file.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty,
              let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else { return false }
        return shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
    }

    @discardableResult
    func beginGroupHistoryBoundaryRequest(context: IMAPIContext, channelID: String, channelType: String) -> Int? {
        guard let key = groupHistoryBoundaryGenerationKey(context: context, channelID: channelID, channelType: channelType) else { return nil }
        return groupHistoryBoundaryGenerationTracker.begin(key: key)
    }

    func isCurrentGroupHistoryBoundaryResponse(context: IMAPIContext, channelID: String, channelType: String, generation: Int?) -> Bool {
        guard let generation,
              let key = groupHistoryBoundaryGenerationKey(context: context, channelID: channelID, channelType: channelType) else {
            return true
        }
        return groupHistoryBoundaryGenerationTracker.accepts(key: key, generation: generation)
    }

    private func groupHistoryBoundaryGenerationKey(context: IMAPIContext, channelID: String, channelType: String) -> String? {
        let normalizedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedChannelType == "group" else { return nil }
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, !imUID.isEmpty, !normalizedChannelID.isEmpty else { return nil }
        return [tenantID, imUID, normalizedChannelID].joined(separator: "|")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
