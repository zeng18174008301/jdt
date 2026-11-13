import SwiftUI
import UIKit
import UniformTypeIdentifiers

// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
extension ChatComposer {
    func composerMediaPresentation<Content: View>(_ content: Content, origin: ChatBubbleSessionIdentity) -> some View {
        content
        .sheet(isPresented: $presentation.showPhotoPicker) {
            PhotoLibraryPickerCompat(
                selectionLimit: 9,
                filter: .any(of: [.images, .videos]),
                prefersFileBackedItems: true
            ) { items in
                guard inputActionIsCurrent(origin) else {
                    items.forEach { PendingAttachmentFileStore.removeManagedFile(at: $0.fileURL) }
                    return
                }
                handlePickedAttachmentItems(items)
            }
        }
        .sheet(isPresented: $presentation.showStickerPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                performInputAction(origin: origin) { handlePickedStickerItems(items) }
            }
        }
        .sheet(isPresented: $presentation.showContactPicker) {
            ContactCardPickerSheet(
                contactsStore: services.contacts,
                remarkPreferredDisplayName: { user in services.remarkPreferredDisplayName(user) },
                candidate: { user in services.contactCandidate(user) },
                canSend: { inputActionIsCurrent(origin) },
                share: { user, quote in services.shareContactCard(user, conversationID, quote) },
                replyQuote: $replyQuote,
                replyContext: $replyContext,
                showTools: $showTools,
                // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SHEET_PASS - 修改开始：名片发送页接收回到底部回调
                onSendStarted: requestLatestScrollForComposerAction
                // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SHEET_PASS - 修改结束：名片发送页接收回到底部回调
            )
                .presentationDetentsCompat([.medium, .large])
                .presentationDragIndicatorCompat(.visible)
        }
        .sheet(item: $pendingAttachmentSelection) { batch in
            AttachmentSendConfirmationSheet(batch: batch) {
                batch.removeOwnedFiles()
                pendingAttachmentSelection = nil
            } onSend: {
                guard inputActionIsCurrent(origin) else { return }
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_ATTACHMENT_CONFIRM - 修改开始：定位确认发送附件时同步入队耗时
                let attachmentConfirmDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
                chatBackStuckDiagnostic(
                    "attachment_confirm_send_begin",
                    force: true,
                    extra: "count=\(batch.selections.count)"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_ATTACHMENT_CONFIRM - 修改结束：定位确认发送附件时同步入队耗时
                // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_ATTACHMENT_CONFIRM_SEND - 修改开始：附件确认发送时回到最新消息
                requestLatestScrollForComposerAction()
                // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_ATTACHMENT_CONFIRM_SEND - 修改结束：附件确认发送时回到最新消息
                let sentReplyQuote = replyQuote
                let sentReplyContext = sentReplyQuote == nil ? nil : replyContext
                var startedAny = false
                var queuedMessageIDs: [String] = []
                let sendInSelectionOrder = batch.selections.count > 1
                for selection in batch.selections {
                    let didStart = services.media.sendAttachment(selection, conversationID, sentReplyQuote,
                        sentReplyContext, !sendInSelectionOrder, {
                            if replyQuote == nil {
                                replyQuote = sentReplyQuote
                                replyContext = sentReplyContext
                            }
                            let existing = pendingAttachmentSelection?.selections ?? []
                            if !existing.contains(where: { $0.id == selection.id }) {
                                pendingAttachmentSelection = PendingAttachmentSelectionBatch(selections: existing + [selection])
                            }
                        }, { queuedMessageIDs.append($0) })
                    if !didStart {
                        selection.removeOwnedFile()
                    }
                    startedAny = startedAny || didStart
                }
                if sendInSelectionOrder, !queuedMessageIDs.isEmpty {
                    services.media.startQueuedAttachments(queuedMessageIDs, conversationID)
                }
                if startedAny {
                    replyQuote = nil
                    replyContext = nil
                }
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_ATTACHMENT_CONFIRM_END - 修改开始：记录附件确认发送同步入队结果
                chatBackStuckDiagnostic(
                    "attachment_confirm_send_end",
                    force: startedAny,
                    extra: "started=\(startedAny) queued=\(queuedMessageIDs.count) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: attachmentConfirmDiagnosticStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_ATTACHMENT_CONFIRM_END - 修改结束：记录附件确认发送同步入队结果
                showTools = false
                pendingAttachmentSelection = nil
            }
            .presentationDetentsCompat([.medium])
            .presentationDragIndicatorCompat(.visible)
            .interactiveDismissDisabled(true)
        }
    }

    func composerFilePresentation<Content: View>(_ content: Content, origin: ChatBubbleSessionIdentity) -> some View {
        content
        .fileImporter(isPresented: $presentation.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard inputActionIsCurrent(origin) else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in
                    guard inputActionIsCurrent(origin) else { return }
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let stagedFile: PendingAttachmentFile
                    do {
                        stagedFile = try await Task.detached(priority: .userInitiated) {
                            try PendingAttachmentFileStore.stageFile(
                                from: url,
                                preferredName: url.lastPathComponent
                            )
                        }.value
                    } catch {
                        guard inputActionIsCurrent(origin) else { return }
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("文件数据读取失败，请重新选择")
                        return
                    }
                    guard inputActionIsCurrent(origin) else {
                        PendingAttachmentFileStore.removeManagedFile(at: stagedFile.url)
                        return
                    }
                    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_FILE_PICKED - 修改开始：选择文件后回到最新消息
                    requestLatestScrollForComposerAction()
                    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_FILE_PICKED - 修改结束：选择文件后回到最新消息
                    pendingAttachmentSelection = PendingAttachmentSelection(
                        kind: .file,
                        name: url.lastPathComponent,
                        mimeType: url.mimeTypeForImport(),
                        sizeBytes: stagedFile.sizeBytes,
                        fileURL: stagedFile.url,
                        ownsFileURL: true,
                        previewImage: nil
                    ).asBatch
                    showTools = false
                }
            case .failure(let error):
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("文件选择失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重新选择"))")
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showTools)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showEmoji)
    }
}
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

private extension URL {
    func mimeTypeForImport() -> String {
        if let type = UTType(filenameExtension: pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END
