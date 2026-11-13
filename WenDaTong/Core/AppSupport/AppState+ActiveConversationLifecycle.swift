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
    func subscribeRealtimeConversation(_ conversationID: String) {
        // WDT_RECEIPT_DETAIL_SCOPE_20261023: switching pages clears only the previous personnel details.
        if let previousID = activeRealtimeConversationID, previousID != conversationID {
            clearReadReceiptDetailAuthority(conversationID: previousID)
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "switch_conversation")
        _ = conversationSelectionEpochFence.select(
            scope: remoteDataScopeKey(for: apiContext),
            conversationID: conversationID
        )
        activeRealtimeConversationID = conversationID
        conversationStore.prepareActiveRealtimeConversationAutoRead(conversationID: conversationID)
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        startRealtimeConnection(context: apiContext)
        sendRealtimeSubscribe(for: conversation)
    }

    func updateRealtimeConversationAutoRead(_ conversationID: String, canAutoRead: Bool) {
        conversationStore.updateActiveRealtimeConversationAutoRead(
            conversationID: conversationID,
            activeConversationID: activeRealtimeConversationID,
            canAutoRead: canAutoRead
        )
    }

    func leaveRealtimeConversation(_ conversationID: String) {
        clearReadReceiptDetailAuthority(conversationID: conversationID) // WDT_RECEIPT_DETAIL_SCOPE_20261023
        conversationSelectionEpochFence.leave(
            scope: remoteDataScopeKey(for: apiContext),
            conversationID: conversationID
        )
        if activeRealtimeConversationID == conversationID {
            activeRealtimeConversationID = nil
        }
        conversationStore.clearActiveRealtimeConversationAutoRead(conversationID: conversationID)
        cancelWarmConversationRefresh(conversationID)
    }

    func scheduleWarmConversationRefreshAfterInitialRender(_ conversationID: String) {
        guard apiContext.hasIMSession,
              conversationStore.conversationMessageSnapshots().contains(where: { $0.id == conversationID }) else { return }
        let refreshKey = warmConversationRefreshKey(conversationID)
        let expectedScope = activeConversationHistoryScope
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.conversationStore.finishWarmRefreshTask(refreshKey: refreshKey)
                guard self.activeConversationHistoryScope == expectedScope,
                      self.activeRealtimeConversationID == conversationID,
                      self.conversationStore.conversationMessageSnapshots().contains(where: { $0.id == conversationID }) else { return }
                self.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: false,
                    trimToLatestWindow: true
                )
            }
        }
        conversationStore.replaceWarmRefreshTask(refreshKey: refreshKey, task: task)
    }

    private func cancelWarmConversationRefresh(_ conversationID: String) {
        conversationStore.cancelWarmRefreshTasks(conversationID: conversationID)
    }

    private func warmConversationRefreshKey(_ conversationID: String) -> String {
        activeConversationScopedStateKeyContext(for: conversationID).stateKey
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
