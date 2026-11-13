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
    func scheduleDeliveryAcksForPersistedMessages() {
        // JHT_MOD_BEGIN DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改开始：批量 ack 扫描分片执行，保留原有调度与高水位判断
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        deliveryAckSweepGeneration &+= 1
        let generation = deliveryAckSweepGeneration
        deliveryAckSweepTask?.cancel()
        deliveryAckSweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let snapshot = self.conversationStore.conversationMessageSnapshots()
            var scannedCount = 0
            var scheduledCount = 0
            for conversation in snapshot where conversation.kind != .system {
                guard !Task.isCancelled,
                      self.deliveryAckSweepGeneration == generation,
                      self.isCurrentRemoteScope(scope) else {
                    return
                }
                scannedCount += 1
                if scannedCount > 1,
                   scannedCount % 8 == 1 {
                    guard await self.pauseDeliveryAckSweepSlice(generation: generation, scope: scope) else {
                        return
                    }
                }
                if let targetSeq = self.deliveryAckTargetSequence(for: conversation), targetSeq > 0 {
                    scheduledCount += 1
                    self.scheduleDeliveryAck(
                        conversation: conversation,
                        channelID: self.remoteChannelID(for: conversation),
                        channelSeq: targetSeq
                    )
                }
            }
            if self.deliveryAckSweepGeneration == generation {
                self.deliveryAckSweepTask = nil
            }
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMs >= 8 || scannedCount > 8 {
                print("[JHT Perf] delivery_ack_sweep_done scanned=\(scannedCount) scheduled=\(scheduledCount) elapsed_ms=\(elapsedMs)")
            }
            #endif
        }
        // JHT_MOD_END DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改开始：ack 目标 seq 单次循环计算，避免 filter/map/max 临时数组
    private func deliveryAckTargetSequence(for conversation: ConversationMessageSnapshot) -> Int64? {
        var latestIncomingSeq: Int64 = 0
        for message in conversation.messages {
            guard !message.isOutgoing,
                  message.kind != .system,
                  message.channelSeq > 0 else { continue }
            latestIncomingSeq = max(latestIncomingSeq, message.channelSeq)
        }
        guard latestIncomingSeq > 0 else { return nil }
        let coveredThrough = conversationStore.messageSequenceCoveredThrough(in: conversation)
        let targetSeq = min(latestIncomingSeq, coveredThrough)
        return targetSeq > 0 ? targetSeq : nil
    }

    private func pauseDeliveryAckSweepSlice(generation: UInt64, scope: String) async -> Bool {
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 4_000_000)
        } catch {
            return false
        }
        return !Task.isCancelled
            && deliveryAckSweepGeneration == generation
            && isCurrentRemoteScope(scope)
    }
    // JHT_MOD_END DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改结束

    func scheduleDeliveryAck(conversation: ConversationMessageSnapshot, channelID: String, channelSeq: Int64) {
        let context = apiContext
        guard context.hasIMSession, conversation.kind != .system, channelSeq > 0 else { return }
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        guard let ticket = localMessageTicket else { return }
        let key = "\(scope)|\(channelID)"
        guard channelSeq > (deliveryAckHighWaterByScope[key] ?? 0), deliveryAckTasksByScope[key] == nil else { return }
        deliveryAckTasksByScope[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let durableSeq = try? await self.messagePersistence.recordAckDesired(
                ticket: ticket,
                channelKey: channelID,
                type: "delivery",
                desiredSeq: channelSeq
            ), durableSeq > 0 else {
                self.deliveryAckTasksByScope[key] = nil
                return
            }
            var acknowledged = false
            for delayMS in [0, 500, 1_500] {
                if delayMS > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                }
                guard !Task.isCancelled,
                      self.remoteDataScopeKey(for: self.apiContext) == scope,
                      self.isCurrentRemoteScope(scope) else { break }
                do {
                    try await self.api.deliveryAck(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        channelSeq: durableSeq
                    )
                    try? await self.messagePersistence.confirmAck(
                        ticket: ticket,
                        channelKey: channelID,
                        type: "delivery",
                        confirmedSeq: durableSeq
                    )
                    self.deliveryAckHighWaterByScope[key] = max(self.deliveryAckHighWaterByScope[key] ?? 0, durableSeq)
                    acknowledged = true
                    break
                } catch {
                    // Delivery acknowledgement is best-effort and never blocks rendering.
                }
            }
            self.deliveryAckTasksByScope[key] = nil
            if acknowledged {
                self.scheduleDeliveryAcksForPersistedMessages()
            }
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
