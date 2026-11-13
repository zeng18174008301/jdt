import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testFileStorePurgesGroupHistoryBoundaryFilesAndFailsClosedUnsequencedItems() throws {
        let store = FileStore()
        let old = FileItem(
            id: "old",
            name: "old.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group",
            channelSeq: 420
        )
        let visible = FileItem(
            id: "visible",
            name: "visible.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:01",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group",
            channelSeq: 421
        )
        let unsequenced = FileItem(
            id: "unsequenced",
            name: "unknown.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:02",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group"
        )
        let direct = FileItem(
            id: "direct",
            name: "direct.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "私聊",
            time: "10:03",
            scope: "私聊文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "d_1",
            channelType: "direct",
            channelSeq: 1
        )

        store.replaceTenantFiles([old, visible, unsequenced, direct])
        store.replaceGroupFiles([old, visible, unsequenced], groupID: "g_history")

        store.purgeGroupHistoryFiles(groupID: "g_history", fromSeq: 421)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["visible", "direct"])
        XCTAssertEqual(store.files(for: "g_history").map(\.id), ["visible"])

        store.purgeGroupHistoryFiles(groupID: "g_history", fromSeq: 1, clearAll: true)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["direct"])
        XCTAssertEqual(store.files(for: "g_history"), [])
    }

    func testFileStoreTenantFilesSyncStateAndErrorsLifecycle() throws {
        let store = FileStore()
        let file = FileItem(
            id: "file-1",
            name: "report.pdf",
            type: "PDF",
            size: "2 KB",
            owner: "Mia",
            source: "企业文件",
            time: "10:00",
            scope: "企业文件",
            status: "已上传",
            accentHex: 0x6677FF
        )

        XCTAssertFalse(store.hasTenantFiles())
        XCTAssertFalse(store.hasTenantFile(id: "file-1"))
        XCTAssertFalse(store.isTenantFilesSyncing())
        XCTAssertNil(store.tenantFilesSyncError())

        XCTAssertTrue(store.beginTenantFilesSync())
        XCTAssertFalse(store.beginTenantFilesSync())
        XCTAssertTrue(store.isTenantFilesSyncing())

        store.setTenantFilesSyncError("文件同步失败，当前显示上次缓存")
        XCTAssertEqual(store.tenantFilesSyncError(), "文件同步失败，当前显示上次缓存")

        store.replaceTenantFiles([file])
        XCTAssertTrue(store.hasTenantFiles())
        XCTAssertTrue(store.hasTenantFile(id: "file-1"))
        XCTAssertEqual(store.tenantFiles().map(\.id), ["file-1"])

        store.finishTenantFilesSync()
        XCTAssertFalse(store.isTenantFilesSyncing())

        XCTAssertTrue(store.beginTenantFilesSync())
        XCTAssertNil(store.tenantFilesSyncError())
        store.finishTenantFilesSync()

        store.reset()

        XCTAssertFalse(store.hasTenantFiles())
        XCTAssertFalse(store.hasTenantFile(id: "file-1"))
        XCTAssertFalse(store.isTenantFilesSyncing())
        XCTAssertNil(store.tenantFilesSyncError())
    }

    // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_BEGIN
    func testAppStateIgnoresSearchInvalidationFromDifferentTenant() {
        var context = makeIsolatedAPIContext()
        context.tenantID = "tenant-current"
        let state = AppState(apiContextOverride: context)
        state.files = [
            FileItem(
                id: "file-1",
                name: "report.pdf",
                type: "PDF",
                size: "2 KB",
                owner: "Mia",
                source: "企业文件",
                time: "10:00",
                scope: "企业文件",
                status: "已上传",
                accentHex: 0x6677FF
            )
        ]
        var events: [SearchInvalidationEvent] = []
        var appUpdates = 0
        let subscription = state.searchInvalidationStore.updates.sink { events.append($0) }
        let app = state.objectWillChange.sink { appUpdates += 1 }
        defer {
            subscription.cancel()
            app.cancel()
        }

        state.applySearchInvalidation(SearchInvalidationEvent(
            tenantID: "tenant-other",
            invalidationKey: "file:file-1",
            eventType: "file_deleted",
            reason: "deleted",
            fileID: "file-1",
            version: 1
        ))

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.files.map(\.id), ["file-1"])

        let deletion = SearchInvalidationEvent(
            tenantID: "tenant-current",
            invalidationKey: "file:file-1",
            eventType: "file_deleted",
            reason: "deleted",
            fileID: "file-1",
            version: 1
        )
        let recall = SearchInvalidationEvent(
            invalidationKey: "message:message-1", eventType: "message_recalled",
            reason: "recalled", messageID: "message-1", version: 2
        )
        state.applySearchInvalidations([deletion, recall, deletion])
        XCTAssertEqual(events.map(\.invalidationKey), ["file:file-1", "message:message-1"])
        XCTAssertEqual(events.map(\.tenantID), ["tenant-current", "tenant-current"])
        XCTAssertTrue(state.files.isEmpty)
        state.clearTenantScopedSearchState(reason: "test_scope_reset")
        XCTAssertEqual(events.last?.isTenantScopeReset, true)
        state.applySearchInvalidation(deletion)
        XCTAssertEqual(events.last, deletion)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_END

    func testFileStoreUploadConfigLifecycleResetsToDefault() throws {
        let store = FileStore()
        let config = FileUploadConfig(
            maxBytes: 8 * 1024 * 1024,
            maxMB: 8,
            source: "tenant",
            messageRecallMaxMinutes: 15,
            voiceCallEnabled: false,
            videoCallEnabled: false,
            readReceiptsEnabled: false,
            groupAdminDeleteMessageEnabled: true
        )

        XCTAssertEqual(store.currentUploadConfig(), .defaultValue)
        XCTAssertTrue(store.currentUploadConfig().voiceCallEnabled)
        XCTAssertFalse(store.currentUploadConfig().videoCallEnabled)

        store.replaceUploadConfig(config)

        XCTAssertEqual(store.currentUploadConfig(), config)

        store.reset()

        XCTAssertEqual(store.currentUploadConfig(), .defaultValue)
    }

    func testDefaultFileUploadLimitAllowsExactly500MiBAndRejectsOneByteMore() {
        let config = FileUploadConfig.defaultValue
        let exactLimit = Int64(500 * 1024 * 1024)

        XCTAssertEqual(config.maxBytes, exactLimit)
        XCTAssertEqual(config.maxMB, 500)
        XCTAssertTrue(config.allowsUpload(sizeBytes: exactLimit))
        XCTAssertFalse(config.allowsUpload(sizeBytes: exactLimit + 1))
    }

    func testPendingAttachmentManagedFileSurvivesRetryAndIsRemovedOnCancel() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-upload-source-\(UUID().uuidString).gif")
        try Data("GIF89a".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try PendingAttachmentFileStore.stageFile(
            from: source,
            preferredName: "animated.gif"
        )
        let store = FileStore()
        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .image,
            name: "animated.gif",
            mimeType: "image/gif",
            sizeBytes: staged.sizeBytes,
            fileURL: staged.url,
            removeFileWhenFinished: true,
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-file-upload")

        store.finishAttachmentUploadTask(messageID: "local-file-upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        store.cancelAttachmentUpload(messageID: "local-file-upload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testFileStoreCancelAttachmentDownloadTasksClearsDownloadsOnly() throws {
        let store = FileStore()
        let downloadTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            downloadTask.cancel()
            uploadTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: downloadTask)
        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.cancelAttachmentDownloadTasks()

        XCTAssertTrue(downloadTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertFalse(uploadTask.isCancelled)
        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertTrue(store.hasAttachmentUploadTask(messageID: "local-upload-1"))
    }

    func testFileStoreAttachmentDownloadTaskLifecycleReplacesCancelsAndFinishes() throws {
        let store = FileStore()
        let firstTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        let secondTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: firstTask)

        XCTAssertTrue(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertNotNil(store.attachmentDownloadTask(attachmentID: "file-1"))

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: secondTask)

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertNotNil(store.attachmentDownloadTask(attachmentID: "file-1"))

        store.finishAttachmentDownloadTask(attachmentID: "file-1")

        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: secondTask)
        store.cancelAttachmentDownloadTask(attachmentID: "file-1")

        XCTAssertTrue(secondTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
    }

    func testFileStoreAttachmentDownloadProgressAndFailedStateLifecycle() throws {
        let store = FileStore()

        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))

        store.setAttachmentDownloadProgress(0.42, attachmentID: "file-1")
        store.setAttachmentDownloadProgress(0.7, attachmentID: "file-2")
        store.markAttachmentDownloadFailed(attachmentID: "file-1")

        XCTAssertEqual(try XCTUnwrap(store.attachmentDownloadProgress(attachmentID: "file-1")), 0.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.attachmentDownloadProgress(attachmentID: "file-2")), 0.7, accuracy: 0.001)
        XCTAssertTrue(store.isAttachmentDownloadFailed(attachmentID: "file-1"))

        store.clearAttachmentDownloadProgress(attachmentIDs: ["file-1", "file-2"])
        store.clearAttachmentDownloadFailed(attachmentID: "file-1")

        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-2"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))
    }

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    func testFileDownloadProgressObservesOnlyMatchingOriginalAndPreviewKeys() {
        let store = FileStore()
        let keys = FileStore.DownloadKeys(original: "scope-a|original", preview: "scope-a|preview")
        let foreignKey = "scope-b|original"
        let task = Task<URL, Error> { URL(fileURLWithPath: "/tmp/file") }
        let originalToken = UUID()
        let previewToken = UUID()
        let foreignToken = UUID()
        store.replaceAttachmentDownloadTask(attachmentID: keys.original, with: task, token: originalToken)
        store.replaceAttachmentDownloadTask(attachmentID: keys.preview, with: task, token: previewToken)
        store.replaceAttachmentDownloadTask(attachmentID: foreignKey, with: task, token: foreignToken)

        var rendered: [AttachmentDownloadSnapshot] = []
        func progressLabel(_ snapshot: AttachmentDownloadSnapshot) -> some View {
            rendered.append(snapshot)
            return Text(snapshot.label)
        }
        let hosted = hostForSimulatorUI(
            FileDownloadProgress(store: store, keys: keys, content: progressLabel),
            size: CGSize(width: 320, height: 80)
        )
        defer { hosted.window.isHidden = true }
        func renderPendingChanges() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosted.controller.view.layoutIfNeeded()
        }
        let preview = AttachmentDownloadSnapshot(receivedBytes: 15, totalBytes: 100)
        let original = AttachmentDownloadSnapshot(receivedBytes: 100, totalBytes: 100, isCommitting: true)
        XCTAssertTrue(rendered.isEmpty)

        store.setAttachmentDownloadSnapshot(preview, attachmentID: foreignKey, token: foreignToken)
        renderPendingChanges()
        XCTAssertTrue(rendered.isEmpty)

        store.setAttachmentDownloadSnapshot(preview, attachmentID: keys.preview, token: previewToken)
        renderPendingChanges()
        XCTAssertEqual(rendered.last, preview)
        store.setAttachmentDownloadSnapshot(original, attachmentID: keys.original, token: originalToken)
        renderPendingChanges()
        XCTAssertEqual(rendered.last, original)
        store.clearAttachmentDownloadProgress(attachmentID: keys.original)
        renderPendingChanges()
        XCTAssertEqual(rendered.last, preview)
    }
    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

    func testFileStoreAttachmentUploadTaskLifecycleReplacesCancelsAndFinishes() throws {
        let store = FileStore()
        let firstTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let secondTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")

        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertTrue(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))

        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: firstTask)
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: secondTask)

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertTrue(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))

        store.finishAttachmentUploadTask(messageID: "local-upload-1")

        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))

        store.finishAttachmentUpload(messageID: "local-upload-1")

        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testFileStoreCancelAttachmentUploadClearsPendingAndCancelsTask() throws {
        let store = FileStore()
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            uploadTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .image,
            name: "photo.jpg",
            mimeType: "image/jpeg",
            sizeBytes: 5,
            data: Data("image".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.cancelAttachmentUpload(messageID: "local-upload-1")

        XCTAssertTrue(uploadTask.isCancelled)
        XCTAssertFalse(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testFileStoreResetClearsAttachmentUploadRuntimeStateAndCancelsTasks() throws {
        let store = FileStore()
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            uploadTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.reset()

        XCTAssertTrue(uploadTask.isCancelled)
        XCTAssertFalse(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadTask(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testToastDismissTaskStoreReplacesAndCancelsTasks() throws {
        let store = ToastDismissTaskStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
        }

        store.replace(with: first)
        XCTAssertTrue(store.hasTask)

        store.replace(with: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasTask)

        store.cancel()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasTask)
    }

    func testLaunchSplashDismissTaskStoreReplacesAndCancelsTasks() throws {
        let store = LaunchSplashDismissTaskStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
        }

        store.replace(with: first)
        XCTAssertTrue(store.hasTask)

        store.replace(with: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasTask)

        store.cancel()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasTask)
    }

    func testCallStoreVoiceCallWatchdogTaskLifecycleCancelsAndResetClears() throws {
        let store = CallStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let third = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
            third.cancel()
        }

        store.replaceVoiceCallWatchdogTask(first)
        XCTAssertTrue(store.hasVoiceCallWatchdogTask)

        store.replaceVoiceCallWatchdogTask(second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasVoiceCallWatchdogTask)

        store.cancelVoiceCallWatchdogTask()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasVoiceCallWatchdogTask)

        store.replaceVoiceCallWatchdogTask(third)
        store.reset()
        XCTAssertTrue(third.isCancelled)
        XCTAssertFalse(store.hasVoiceCallWatchdogTask)
    }

    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
    func testCallStorePersistsCallRecordsByScopeAndResetKeepsCache() async throws {
        let suiteName = "CallStorePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.test"
        )
        let scope = "tenant-a|uid-a"
        let otherScope = "tenant-b|uid-b"
        let record = CallRecord(
            id: "record-a",
            callID: "call-a",
            peerID: "peer-a",
            peerUserID: "public-a",
            peerAvatarURL: "https://example.com/avatar-a.png",
            peerAvatarVersion: "avatar-v1",
            peerAvatarUpdatedAt: "2026-08-22T10:00:00Z",
            peerAvatarSource: "rtc_profile",
            title: "Alice",
            subtitle: "视频呼出 · 通话已结束",
            time: "10:00",
            status: "已结束",
            direction: .outgoing,
            callType: "视频通话",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 130),
            durationSeconds: 30,
            endReason: "remote_hangup",
            stateVersion: 9
        )

        let store = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(store, scope: scope)
        store.calls = [record]

        store.reset()
        XCTAssertTrue(store.calls.isEmpty)
        let relaunchedStore = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(relaunchedStore, scope: scope)
        let cachedRecord = try XCTUnwrap(backingStore.load(scope: scope).first)
        XCTAssertEqual(cachedRecord.callID, "call-a")
        XCTAssertEqual(cachedRecord.peerID, "peer-a")
        XCTAssertEqual(cachedRecord.peerUserID, "public-a")
        XCTAssertEqual(cachedRecord.peerAvatarURL, "https://example.com/avatar-a.png")
        XCTAssertEqual(cachedRecord.peerAvatarVersion, "avatar-v1")
        XCTAssertEqual(cachedRecord.peerAvatarUpdatedAt, "2026-08-22T10:00:00Z")
        XCTAssertEqual(cachedRecord.peerAvatarSource, "rtc_profile")
        XCTAssertEqual(cachedRecord.callType, "视频通话")
        XCTAssertEqual(cachedRecord.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(cachedRecord.endedAt, Date(timeIntervalSince1970: 130))
        XCTAssertEqual(cachedRecord.durationSeconds, 30)
        XCTAssertEqual(cachedRecord.endReason, "remote_hangup")
        XCTAssertEqual(cachedRecord.stateVersion, 9)

        let relaunchedRecord = try XCTUnwrap(relaunchedStore.calls.first)
        XCTAssertEqual(relaunchedRecord.callID, "call-a")
        XCTAssertEqual(relaunchedRecord.peerID, "peer-a")
        XCTAssertEqual(relaunchedRecord.peerUserID, "public-a")
        XCTAssertEqual(relaunchedRecord.callType, "视频通话")
        XCTAssertEqual(relaunchedRecord.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(relaunchedRecord.endedAt, Date(timeIntervalSince1970: 130))
        XCTAssertEqual(relaunchedRecord.durationSeconds, 30)
        XCTAssertEqual(relaunchedRecord.endReason, "remote_hangup")
        XCTAssertEqual(relaunchedRecord.stateVersion, 9)

        let otherStore = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(otherStore, scope: otherScope)
        XCTAssertTrue(otherStore.calls.isEmpty)
    }

    func testCallStoreMigratesCallRecordsFromFallbackScope() async throws {
        let suiteName = "CallStoreFallbackMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.fallback.test"
        )
        let stableScope = "call-records|tenant-a|uid-a"
        let legacyDeviceScope = "v2|account=account-a|tenant=tenant-a|im=uid-a|app=app-a|device=device-a"
        let record = CallRecord(
            id: "legacy-record",
            callID: "legacy-call",
            peerID: "peer-a",
            title: "Alice",
            subtitle: "视频来电 · 通话已结束",
            time: "11:00",
            status: "已结束",
            direction: .incoming,
            callType: "视频通话",
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 260),
            durationSeconds: 60
        )
        backingStore.save([record], scope: legacyDeviceScope)
        XCTAssertTrue(backingStore.load(scope: stableScope).isEmpty)

        let store = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(store, scope: stableScope, fallbackScopes: [legacyDeviceScope])

        XCTAssertEqual(store.calls.first?.callID, "legacy-call")
        XCTAssertEqual(store.calls.first?.callType, "视频通话")
        XCTAssertEqual(backingStore.load(scope: stableScope).first?.callID, "legacy-call")
        XCTAssertEqual(backingStore.load(scope: legacyDeviceScope).first?.callID, "legacy-call")
    }

    func testCallStoreKeepsAccountHistoryIsolatedAndPreservesUntrustedArchive() async throws {
        let suiteName = "CallStoreAccountScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "call.records.account.test")
        let accountA = "v3|bundle=app1|app=main|account=a|tenant=t|im=u1"
        let accountB = "v3|bundle=app1|app=main|account=b|tenant=t|im=u2"
        let contaminatedAccountB = "v2|bundle=app1|app=main|account=b|tenant=t|im=u2"
        let sharedScope = "v2|bundle=app1|app=main"
        let record = CallRecord(id: "a-record", callID: "a-call", peerID: "peer-a",
                                title: "Fixture A", subtitle: "已结束", time: "12:30", status: "已结束")
        backingStore.save([record], scope: sharedScope)
        backingStore.save([record], scope: contaminatedAccountB)
        let store = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(store, scope: accountA)
        store.calls = [record]
        store.clearCallRecordPersistenceBinding()
        XCTAssertTrue(store.calls.isEmpty)
        await waitForCallArchive(store, scope: accountB)
        XCTAssertEqual(backingStore.load(scope: accountA), [record])
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertTrue(backingStore.load(scope: accountB).isEmpty)
        let ownRecord = CallRecord(id: "b-record", callID: "b-call", peerID: "peer-b",
                                   title: "Fixture B", subtitle: "已结束", time: "12:35", status: "已结束")
        store.calls = [ownRecord]
        await waitForCallArchive(store, scope: accountA)
        XCTAssertEqual(store.calls, [record])
        let relaunched = CallStore(callRecordStore: backingStore)
        await waitForCallArchive(relaunched, scope: accountB)
        XCTAssertEqual(relaunched.calls, [ownRecord])
        XCTAssertEqual(backingStore.load(scope: sharedScope), [record])
        XCTAssertEqual(backingStore.load(scope: contaminatedAccountB), [record])
    }

    // WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111: Cold login and disk archive tests moved to RTCCallRecordProjectionTests.swift.

    private func waitForCallArchive(_ store: CallStore, scope: String, fallbackScopes: [String] = []) async {
        store.bindCallRecordPersistence(scope: scope, fallbackScopes: fallbackScopes)
        let restored = expectation(description: "call archive publishes the binding")
        let observation = store.$calls.dropFirst().prefix(1).sink { _ in restored.fulfill() }
        await fulfillment(of: [restored], timeout: 4)
        observation.cancel()
    }
    // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END

}
