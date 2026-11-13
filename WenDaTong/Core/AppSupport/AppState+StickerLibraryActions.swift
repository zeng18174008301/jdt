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
import IM4Stores // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112

extension AppState {
    private func stickerMessageSnapshot(for item: StickerLibraryItem) -> StickerMessageSnapshot {
        let variants = item.variants.map { variant in
            StickerMessageVariantSnapshot(
                kind: variant.kind,
                fileID: variant.fileID,
                mimeType: variant.mimeType,
                assetURL: variant.assetURL,
                sizeBytes: variant.sizeBytes,
                width: variant.width,
                height: variant.height,
                durationMS: variant.durationMS,
                frameCount: variant.frameCount,
                thumbnailURL: variant.thumbnailURL,
                cacheKey: variant.cacheKey
            )
        }
        let fileID = item.fileID.isEmpty
            ? variants.first(where: { !$0.fileID.isEmpty })?.fileID ?? ""
            : item.fileID
        let stickerID = item.stickerID.isEmpty ? item.id : item.stickerID
        return StickerMessageSnapshot(
            stickerID: stickerID,
            packID: item.packID,
            fileID: fileID,
            mimeType: item.mimeType.isEmpty ? "image/gif" : item.mimeType,
            width: item.width,
            height: item.height,
            durationMS: item.durationMS,
            frameCount: item.frameCount,
            thumbnailURL: item.thumbnailURL,
            variants: variants
        )
    }

    func loadOfficialStickerPack(_ packID: String) async {
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !stickerStore.officialStickers(packID: packID).isEmpty { return }
        await refreshOfficialStickerPack(packID)
    }

    func uploadStickerGIF(data: Data, name: String, conversationID: String) {
        uploadStickerImage(data: data, name: name, conversationID: conversationID)
    }

    func uploadStickerImage(data: Data, name: String, conversationID: String) {
        guard !data.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("表情数据读取失败，请重新选择")
            return
        }
        guard let uploadFile = stickerUploadFileDescriptor(data: data, name: name) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅支持上传 GIF/JPG/PNG 表情")
            return
        }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversation.kind != .system else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前会话不支持添加表情")
            return
        }
        let context = apiContext
        guard let binding = activateStickerLibrary() else { // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        stickerStore.beginLocalUpload(
            id: uploadID,
            name: uploadFile.fileName,
            mimeType: uploadFile.mimeType,
            sizeBytes: data.count,
            data: data,
            conversationID: conversationID,
            binding: binding
        )
        Task {
            await performStickerImageUpload(
                uploadID: uploadID,
                data: data,
                fileName: uploadFile.fileName,
                mimeType: uploadFile.mimeType,
                fileExtension: uploadFile.fileExtension,
                conversation: conversation,
                context: context,
                binding: binding
            )
        }
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    func deleteSticker(_ item: StickerLibraryItem) {
        guard let binding = stickerStore.activeBinding else { return }
        Task {
            await deleteUserSticker(item, binding: binding)
        }
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    func retryStickerUpload(_ item: StickerLibraryItem) {
        guard item.isLocalUploadPlaceholder else { return }
        let context = apiContext
        guard let binding = stickerStore.activeBinding, isCurrentStickerLibrary(binding) else { // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        guard let draft = stickerStore.localUploadDraft(id: item.id) else {
            stickerStore.failLocalUpload(id: item.id, binding: binding)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请重新选择文件上传")
            return
        }
        guard let uploadFile = stickerUploadFileDescriptor(data: draft.data, name: draft.name) else {
            stickerStore.failLocalUpload(id: item.id, binding: binding)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅支持上传 GIF/JPG/PNG 表情")
            return
        }
        guard let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == draft.conversationID }),
              conversation.kind != .system else {
            stickerStore.failLocalUpload(id: item.id, binding: binding)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前会话不支持添加表情")
            return
        }
        stickerStore.updateLocalUpload(id: item.id, phase: .uploading, progress: 0.02, binding: binding)
        Task {
            await performStickerImageUpload(
                uploadID: item.id,
                data: draft.data,
                fileName: uploadFile.fileName,
                mimeType: uploadFile.mimeType,
                fileExtension: uploadFile.fileExtension,
                conversation: conversation,
                context: context,
                binding: binding
            )
        }
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    func moveSticker(_ item: StickerLibraryItem, direction: Int) {
        guard let binding = stickerStore.activeBinding else { return }
        Task {
            await moveUserSticker(item, direction: direction, binding: binding)
        }
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    @discardableResult
    func sendSticker(
        _ item: StickerLibraryItem,
        conversationID: String,
        quote: String? = nil,
        replyContext: MessageReplyContext? = nil,
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard item.isActive else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(item.isFailed ? "表情处理失败，暂不能发送" : "表情处理中，完成后才能发送")
            return false
        }
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
        if isSystemReadOnlyConversation(conversation) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return false
        }
        if let message = directSendBlockedMessage(for: conversation) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversation) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let snapshot = stickerMessageSnapshot(for: item)
        guard !snapshot.stickerID.isEmpty, !snapshot.fileID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("表情资源缺少文件信息，暂不能发送")
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_sticker")
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: snapshot.fallbackText,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .text,
            contentType: "sticker",
            reactions: [],
            readBy: [],
            unreadBy: conversationStore.conversationMessageSnapshot(at: cIndex).participants.prefix(3).map { ReadReceipt(id: "pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: nil,
            attachmentMeta: nil
        )
        message.createdAt = Date()
        message.replyContext = replyContext
        message.stickerSnapshot = snapshot
        guard let appendedConversation = conversationStore.appendLocalOutgoingMessage(
            message,
            to: conversationID,
            preview: snapshot.fallbackText
        ) else { return false }
        let channelID = remoteChannelID(for: appendedConversation)
        Task {
            var durableTicket: LocalMessageSessionTicket?
            do {
                durableTicket = try await enqueueDurableOutgoing(
                    messageID: message.id,
                    conversationID: conversationID,
                    operationKind: "send_sticker",
                    context: context,
                    scope: scope
                )
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                let remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                    try await api.sendSticker(
                        context: context,
                        conversation: appendedConversation,
                        channelID: channelID,
                        sticker: snapshot,
                        quote: quote,
                        replyContext: replyContext,
                        clientMessageID: message.id
                    )
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                guard isCurrentRemoteScope(scope) else { return }
                removeMessage(messageID: message.id, in: conversationID)
                applyRemoteMessages(
                    [remote],
                    channelID: remote.channelID.isEmpty ? channelID : remote.channelID,
                    channelType: remote.channelType.isEmpty ? apiChannelType(for: appendedConversation.kind) : remote.channelType
                )
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if await retainUnconfirmedOutgoing(error, ticket: durableTicket, messageID: message.id,
                                                   conversationID: conversationID, scope: scope) { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                if isNotFriendsError(error) {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .failedPermanent)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleNotFriends(for: appendedConversation, context: directFriendRequestContext(from: error, fallback: appendedConversation))
                } else if isSendPolicyForbidden(error) {
                    let groupAllMuted = isGroupAllMutedError(error)
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(appendedConversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(appendedConversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .cancelled)
                    handleRemoteError(error, fallback: "表情发送失败")
                    removeMessage(messageID: message.id, in: conversationID)
                    if groupAllMuted {
                        onPolicyRejected?()
                    }
                } else {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleRemoteError(error, fallback: "表情发送失败")
                }
            }
        }
        return true
    }

    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    struct StickerManifestBinding {
        let runtime: StickerStore.Binding
        let generation: UUID
        let authority: IMAuthSessionFence
    }

    func stickerManifestBinding(context: IMAPIContext, runtime: StickerStore.Binding) -> StickerManifestBinding {
        StickerManifestBinding(runtime: runtime, generation: stickerManifestBindingGeneration, authority: context.authSessionFence)
    }

    func isCurrentStickerManifestBinding(_ binding: StickerManifestBinding) -> Bool {
        binding.generation == stickerManifestBindingGeneration
            && isCurrentStickerLibrary(binding.runtime)
            && (apiContext.isSameAuthAuthority(as: binding.authority)
                || apiContext.credentialsAdvanced(since: binding.authority))
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    final class StickerManifestOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var retired = false

        nonisolated var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !retired
        }

        nonisolated func retire() {
            lock.lock()
            retired = true
            lock.unlock()
        }
    }

    struct StickerManifestHydration {
        let operation: StickerManifestOperation? // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112: non-manifest hydration uses its captured library binding.
        let isCurrent: @MainActor () -> Bool
    }

    func beginStickerManifestOperation() -> StickerManifestOperation {
        stickerManifestOperation?.retire()
        let operation = StickerManifestOperation()
        stickerManifestOperation = operation
        return operation
    }

    func ownsStickerManifest(_ operation: StickerManifestOperation, binding: StickerManifestBinding) -> Bool {
        operation === stickerManifestOperation && isCurrentStickerManifestBinding(binding)
    }
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END

    func retireStickerManifestRequests() {
        stickerManifestBindingGeneration = UUID()
        stickerManifestOperation?.retire() // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        stickerManifestOperation = nil
        stickerManifestPollTask?.cancel()
        stickerManifestPollTask = nil
    }

    func reconcileStickerManifestAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        let scope = stickerRuntimeScope(for: newContext)
        let sameScope = scope != nil && stickerRuntimeScope(for: oldContext) == scope
        if sameScope && newContext.credentialsAdvanced(since: oldContext.authSessionFence) { return }
        let resumePoll = sameScope && stickerManifestPollTask != nil
        retireStickerManifestRequests()
        if sameScope {
            if stickerStore.isManifestRefreshing { stickerStore.setManifestRefreshing(false) }
            if resumePoll, let runtime = stickerStore.activeBinding { scheduleStickerManifestPollIfNeeded(runtime: runtime) } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        } else if stickerStore.activeBinding != nil {
            stickerStore.resetRuntime()
        }
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
    }

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    func refreshUserStickerManifest(
        force: Bool = false, silent: Bool = false, schedulePoll: Bool = true,
        continuing preparation: StickerManifestOperation? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let context = apiContext
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        if let preparation {
            guard let runtime = stickerStore.activeBinding,
                  ownsStickerManifest(preparation, binding: stickerManifestBinding(context: context, runtime: runtime)) else { return }
        }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        guard let runtime = activateStickerLibrary() else {
            if !silent {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            return
        }
        let binding = stickerManifestBinding(context: context, runtime: runtime)
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
        if stickerStore.isManifestRefreshing && !force { return }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        let operation = preparation ?? beginStickerManifestOperation()
        stickerStore.setManifestRefreshing(true)
        @MainActor func ownsRefresh() -> Bool {
            ownsStickerManifest(operation, binding: binding)
        }
        let hydration = StickerManifestHydration(operation: operation, isCurrent: { ownsRefresh() && !Task.isCancelled })
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        defer {
            if ownsRefresh(), stickerStore.isManifestRefreshing {
                stickerStore.setManifestRefreshing(false)
            }
        }
        do {
            let remoteItems = try await api.listUserStickers(context: context, limit: 200)
            guard ownsRefresh(), !Task.isCancelled else { return }
            let items = await hydrateStickerLibraryItems(remoteItems.map(StickerLibraryItem.init(remote:)),
                context: context, manifest: hydration) // WDT_IOS1_STICKER_MANIFEST_R2_20261111
            guard ownsRefresh(), !Task.isCancelled else { return }
            stickerStore.replaceMyStickers(items, binding: runtime) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
            if schedulePoll {
                scheduleStickerManifestPollIfNeeded(runtime: runtime)
            }
        } catch {
            guard ownsRefresh(), !Task.isCancelled else { return }
            let message = userFacingError(error)
            stickerStore.setManifestError(message)
            if !silent {
                handleRemoteError(error, fallback: "表情库同步失败")
            }
        }
    }
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

    private func refreshOfficialStickerPacksIfNeeded(force: Bool = false) async {
        guard force || stickerStore.officialPacks.isEmpty else { return }
        let context = apiContext
        guard let binding = activateStickerLibrary() else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        do {
            let packs = try await api.listStickerPacks(context: context)
            guard isCurrentStickerLibrary(binding) else { return }
            let mapped = packs
                .map(StickerPackItem.init(remote:))
                .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "offline" }
            stickerStore.replaceOfficialPacks(mapped)
            if let first = mapped.first {
                await refreshOfficialStickerPack(first.id)
            }
        } catch {
            guard isCurrentStickerLibrary(binding) else { return }
            stickerStore.setOfficialError(userFacingError(error))
        }
    }

    private func refreshOfficialStickerPack(_ packID: String) async {
        let context = apiContext
        guard let binding = activateStickerLibrary() else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        do {
            let packName = stickerStore.officialPacks.first(where: { $0.id == packID })?.name ?? ""
            let remoteStickers = try await api.listStickerPackStickers(context: context, packID: packID)
            guard isCurrentStickerLibrary(binding) else { return }
            let stickers = remoteStickers
                .map { StickerLibraryItem(remote: $0, packName: packName) }
                .filter { $0.isActive || $0.normalizedStatus == "online" }
            stickerStore.replaceOfficialStickers(stickers, packID: packID)
        } catch {
            guard isCurrentStickerLibrary(binding) else { return }
            stickerStore.setOfficialError(userFacingError(error))
        }
    }

    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    func hydrateCachedStickerManifestIfNeeded(
        context: IMAPIContext, binding: StickerManifestBinding, operation: StickerManifestOperation
    ) async {
        guard ownsStickerManifest(operation, binding: binding), !Task.isCancelled else { return }
        let cached = stickerStore.myStickers
        guard cached.contains(where: {
            stickerThumbnailURL(for: $0).isEmpty && !stickerLibraryFileIDs(for: $0).isEmpty
        }) else { return }
        let hydration = StickerManifestHydration(operation: operation, isCurrent: {
            !Task.isCancelled && self.ownsStickerManifest(operation, binding: binding) && self.stickerStore.myStickers == cached
        })
        let hydrated = await hydrateStickerLibraryItems(cached, context: context, manifest: hydration)
        guard hydration.isCurrent() else { return }
        stickerStore.replaceMyStickers(hydrated, binding: binding.runtime) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
    }
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
