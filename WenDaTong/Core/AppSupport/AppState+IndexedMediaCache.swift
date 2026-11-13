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
    var mediaCacheScopeContext: IOSMediaCacheScopeContext? {
        let session = apiContext
        guard session.hasIMSession,
              let scope = try? LocalMessageScope(context: session) else {
            resolvedMediaCacheScope = nil
            return nil
        }
        let generation = localMessageSessionGeneration
        // Thumbnail bodies read this repeatedly during scroll. Resolve the
        // filesystem paths and scope digest once per authenticated scope.
        if let cached = resolvedMediaCacheScope,
           cached.scope == scope, cached.context.sessionGeneration == generation {
            return cached.context
        }
        guard let paths = try? MessageDatabasePaths(scope: scope) else { return nil }
        let context = IOSMediaCacheScopeContext(
            scopeHash: scope.scopeHash,
            sessionGeneration: generation,
            rootDirectory: paths.mediaScopeDirectory
        )
        resolvedMediaCacheScope = (scope, context)
        return context
    }

    nonisolated static func mediaOfflinePolicy(
        for policy: RemoteTenantClientPolicy?
    ) -> IOSMediaOfflinePolicy {
        guard let policy,
              policy.mediaOfflinePolicyPresent else { return .bounded }
        switch policy.mediaOfflinePolicy {
        case "deny", "high_sensitivity", "high-sensitivity":
            return .deny
        default:
            return .bounded
        }
    }

    private var effectiveMediaOfflinePolicy: IOSMediaOfflinePolicy {
        Self.mediaOfflinePolicy(for: resolvedTenantClientPolicy)
    }

    func lookupIndexedMediaCache(
        metadata: MediaResourceMetadata,
        messageID: String,
        resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil,
        integrity: MediaFileIntegrityAuthority,
        context: IOSMediaCacheScopeContext,
        offline: Bool,
        offlinePolicy: IOSMediaOfflinePolicy? = nil,
        stickerManifest: StickerManifestHydration? = nil // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    ) async -> URL? {
        guard stickerManifest?.isCurrent() != false else { return nil } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        let resolvedOfflinePolicy = offlinePolicy ?? effectiveMediaOfflinePolicy
        guard !(offline && resolvedOfflinePolicy == .deny) else { return nil }
        let identity = metadata.identity(for: resourceKind, variant: variant)
        guard context.sessionGeneration == localMessageSessionGeneration,
              context.scopeHash == identity.scope,
              let cacheIdentity = identity.persistentCacheIdentity,
              let ticket = try? await currentMediaCacheTicket(context: context),
              let indexed = try? await messagePersistence.mediaCacheLookup(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                messageID: messageID,
                offline: offline
              ) else { return nil }
        guard context.sessionGeneration == localMessageSessionGeneration,
              let indexedURL = mediaCacheURL(
                relativePath: indexed.entry.relativePath,
                context: context
              ),
              indexedURL.standardizedFileURL == identity.cacheFileURL(
                in: context.rootDirectory,
                preferredExtension: metadata.preferredExtension(for: resourceKind)
              ).standardizedFileURL,
              let store = try? await IOSMediaCacheStoreRegistry.shared.store(for: context),
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            return nil
        }
        // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：缓存文件存在性校验放到后台，避免消息滚动时阻塞 MainActor
        let existedBeforeVerification = await MediaCacheFileIO.fileExistsOffMain(indexedURL)
        // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        let indexedIntegrity = MediaFileIntegrityAuthority(
            expectedSizeBytes: indexed.entry.verifiedSizeBytes ?? integrity.expectedSizeBytes,
            expectedSHA256: indexed.entry.verifiedChecksumSHA256 ?? integrity.expectedSHA256
        )
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        guard stickerManifest?.isCurrent() != false else { return nil }
        let operation = stickerManifest?.operation
        let result = await store.verifiedLookup(
            identity: identity,
            preferredExtension: metadata.preferredExtension(for: resourceKind),
            integrity: indexedIntegrity,
            sessionGeneration: context.sessionGeneration,
            isAdmitted: { operation?.isActive != false }
        )
        let acceptsScope = await IOSMediaCacheStoreRegistry.shared.accepts(context)
        guard stickerManifest?.isCurrent() != false else { return nil }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        guard context.sessionGeneration == localMessageSessionGeneration,
              acceptsScope, case let .downloaded(localURL) = result.state else {
            // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
            // A permission failure is retryable; keep the healthy bytes and index instead of marking them corrupt.
            if case .failed = result.state { return nil }
            // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
            try? await messagePersistence.markMediaCacheState(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                state: existedBeforeVerification ? .corrupt : .evicted
            )
            return nil
        }
        if !offline {
            let authorizedAt = Date()
            try? await messagePersistence.renewMediaCacheAuthority(
                ticket: ticket,
                cacheIdentity: cacheIdentity,
                messageID: messageID,
                authorizedAt: authorizedAt,
                offlineAccessUntil: resolvedOfflinePolicy == .bounded
                    ? authorizedAt.addingTimeInterval(resolvedOfflinePolicy.ttl)
                    : nil
            )
        }
        guard stickerManifest?.isCurrent() != false else { return nil } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        try? await messagePersistence.touchMediaCache(
            ticket: ticket,
            cacheIdentity: cacheIdentity
        )
        guard context.sessionGeneration == localMessageSessionGeneration,
              stickerManifest?.isCurrent() != false else { return nil } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        return localURL
    }

    func commitIndexedMediaCache(
        temporaryURL: URL,
        metadata: MediaResourceMetadata,
        resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil,
        integrity: MediaFileIntegrityAuthority,
        messageID: String,
        conversationID: String,
        authorityVersion: String = "0",
        offlinePolicy: IOSMediaOfflinePolicy? = nil,
        protectionReason: String = "",
        context: IOSMediaCacheScopeContext,
        stickerManifest: StickerManifestHydration? = nil // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    ) async throws -> URL {
        guard stickerManifest?.isCurrent() != false else { throw LocalMessageDatabaseError.staleSession } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        let resolvedOfflinePolicy = offlinePolicy ?? effectiveMediaOfflinePolicy
        let identity = metadata.identity(for: resourceKind, variant: variant)
        do {
            try MediaCacheCanonicalIdentity.validateRequired(messageID, field: "message_id")
        } catch {
            throw LocalMessageDatabaseError.identityConflict
        }
        guard let normalizedAuthorityVersion = canonicalMediaAuthorityVersion(authorityVersion) else {
            throw LocalMessageDatabaseError.identityConflict
        }
        guard context.sessionGeneration == localMessageSessionGeneration,
              context.scopeHash == identity.scope,
              let cacheIdentity = identity.persistentCacheIdentity else {
            throw LocalMessageDatabaseError.staleSession
        }
        // Rebind the SQLite writer generation before advancing the file-store
        // generation so an old ticket cannot commit authority rows in between.
        let ticket = try await currentMediaCacheTicket(context: context)
        guard context.sessionGeneration == localMessageSessionGeneration,
              let store = try? await IOSMediaCacheStoreRegistry.shared.store(for: context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let preferredExtension = metadata.preferredExtension(for: resourceKind)
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        guard stickerManifest?.isCurrent() != false else { throw LocalMessageDatabaseError.staleSession }
        let operation = stickerManifest?.operation
        let entry = try await store.saveVerifiedDownloadedFile(
            from: temporaryURL,
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity,
            sessionGeneration: context.sessionGeneration,
            isAdmitted: { operation?.isActive != false }
        )
        // An admitted cache write completes its index update under the original
        // session fence. Supersession must not leave its promoted file unindexed.
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        guard context.sessionGeneration == localMessageSessionGeneration,
              let relativePath = mediaCacheRelativePath(for: entry.localURL, context: context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let now = Date()
        let attachmentID = identity.primaryStableID
        let authority = IOSMediaCacheAuthorityRecord(
            scopeHash: context.scopeHash,
            messageID: messageID,
            attachmentID: attachmentID,
            identity: identity,
            mimeType: metadata.mimeType.isEmpty ? "application/octet-stream" : metadata.mimeType,
            sizeBytes: entry.sizeBytes,
            checksumSHA256: integrity.hasChecksum ? integrity.expectedSHA256 : nil,
            state: .active,
            authorityVersion: normalizedAuthorityVersion,
            lastAuthorizedAt: now,
            offlineAccessUntil: resolvedOfflinePolicy == .bounded
                ? now.addingTimeInterval(resolvedOfflinePolicy.ttl)
                : nil,
            createdAt: nil,
            updatedAt: now
        )
        let indexedEntry = IOSMediaCacheEntryRecord(
            scopeHash: context.scopeHash,
            cacheIdentity: cacheIdentity,
            attachmentID: attachmentID,
            variant: identity.variant,
            relativePath: relativePath,
            localState: .verifiedCached,
            sizeBytes: entry.sizeBytes,
            verifiedSizeBytes: entry.sizeBytes,
            verifiedChecksumSHA256: try MediaFileIntegrityAuthority.sha256Hex(fileAt: entry.localURL),
            pinnedByUser: false,
            protectionReason: protectionReason,
            createdAt: now,
            lastAccessedAt: now
        )
        do {
            let accepted = try await messagePersistence.upsertMediaCache(
                ticket: ticket,
                authority: authority,
                entry: indexedEntry,
                conversationID: conversationID
            )
            guard accepted else {
                throw LocalMessageDatabaseError.authorityRejected
            }
        } catch {
            throw error
        }
        guard context.sessionGeneration == localMessageSessionGeneration else {
            throw LocalMessageDatabaseError.staleSession
        }
        if stickerManifest?.isCurrent() != false { // WDT_IOS1_STICKER_MANIFEST_R2_20261111
            try? await pruneIndexedMediaCacheIfNeeded(ticket: ticket, context: context)
        }
        return entry.localURL
    }

    private func canonicalMediaAuthorityVersion(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty,
              rawValue.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            return nil
        }
        let trimmed = rawValue.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private func currentMediaCacheTicket(
        context: IOSMediaCacheScopeContext
    ) async throws -> LocalMessageSessionTicket {
        if let localMessageTicket,
           localMessageTicket.scopeHash == context.scopeHash,
           localMessageTicket.sessionGeneration == context.sessionGeneration {
            return localMessageTicket
        }
        let ticket = try await messagePersistence.ensureTicket(
            context: apiContext,
            sessionGeneration: context.sessionGeneration
        )
        guard context.sessionGeneration == localMessageSessionGeneration,
              ticket.scopeHash == context.scopeHash else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        return ticket
    }

    private func mediaCacheRelativePath(
        for url: URL,
        context: IOSMediaCacheScopeContext
    ) -> String? {
        let root = context.rootDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        let relative = String(candidate.dropFirst(root.count + 1))
        guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        return relative
    }

    func mediaCacheURL(
        relativePath: String,
        context: IOSMediaCacheScopeContext
    ) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("..") else { return nil }
        let resolved = context.rootDirectory
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard resolved.path.hasPrefix(context.rootDirectory.standardizedFileURL.path + "/") else { return nil }
        return resolved
    }

    private func pruneIndexedMediaCacheIfNeeded(
        ticket: LocalMessageSessionTicket,
        context: IOSMediaCacheScopeContext,
        softQuotaBytes: Int64 = MediaCachePolicy.thumbnailDiskCapacityBytes
            + MediaCachePolicy.previewDiskCapacityBytes
            + MediaCachePolicy.originalDiskCapacityBytes
    ) async throws {
        for (kind, quota) in [
            (MediaResourceKind.thumbnail, MediaCachePolicy.thumbnailDiskCapacityBytes),
            (.preview, MediaCachePolicy.previewDiskCapacityBytes),
            (.original, MediaCachePolicy.originalDiskCapacityBytes)
        ] {
            let tierStats = try await messagePersistence.mediaCacheStatistics(
                ticket: ticket,
                resourceKind: kind
            )
            guard tierStats.totalBytes > quota * 12 / 10 else { continue }
            let candidates = try await messagePersistence.mediaCachePruneCandidates(
                ticket: ticket,
                bytesToFree: tierStats.totalBytes - quota * 11 / 10,
                resourceKind: kind
            )
            try await removeMediaCacheCandidates(candidates, ticket: ticket, context: context)
        }
        let stats = try await messagePersistence.mediaCacheStatistics(ticket: ticket)
        guard stats.totalBytes > softQuotaBytes * 12 / 10 else { return }
        let candidates = try await messagePersistence.mediaCachePruneCandidates(
            ticket: ticket,
            bytesToFree: stats.totalBytes - softQuotaBytes * 11 / 10
        )
        try await removeMediaCacheCandidates(candidates, ticket: ticket, context: context)
    }

    private func removeMediaCacheCandidates(
        _ candidates: [IOSMediaCachePruneCandidate],
        ticket: LocalMessageSessionTicket,
        context: IOSMediaCacheScopeContext
    ) async throws {
        guard context.sessionGeneration == localMessageSessionGeneration,
              await IOSMediaCacheStoreRegistry.shared.accepts(context) else {
            throw LocalMessageDatabaseError.staleSession
        }
        var removedIdentities: [String] = []
        for candidate in candidates {
            guard context.sessionGeneration == localMessageSessionGeneration else {
                throw LocalMessageDatabaseError.staleSession
            }
            guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else { continue }
            // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：媒体缓存删除放到后台，保留原有成功后移除索引的语义
            let removal = await MediaCacheFileIO.removeFileIfExistsOffMain(url)
            guard removal.didComplete else {
                continue
            }
            removedIdentities.append(candidate.cacheIdentity)
            // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        }
        try await messagePersistence.removeMediaCacheEntries(
            ticket: ticket,
            cacheIdentities: removedIdentities
        )
    }

    func invalidateIndexedMediaCache(
        messageID: String,
        state: MediaCacheAuthorityState,
        authorityVersion: String,
        context: IOSMediaCacheScopeContext
    ) {
        guard let normalizedVersion = canonicalMediaAuthorityVersion(authorityVersion) else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  context.sessionGeneration == self.localMessageSessionGeneration,
                  let ticket = try? await self.currentMediaCacheTicket(context: context),
                  let candidates = try? await self.messagePersistence.invalidateMediaCache(
                    ticket: ticket,
                    messageID: messageID,
                    state: state,
                    authorityVersion: normalizedVersion
                  ),
                  context.sessionGeneration == self.localMessageSessionGeneration else { return }
            for candidate in candidates {
                guard let url = self.mediaCacheURL(
                    relativePath: candidate.relativePath,
                    context: context
                ) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：失效缓存文件删除放到后台执行
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
    }

    func invalidateIndexedMediaCache(
        for message: ChatMessage,
        state: MediaCacheAuthorityState
    ) {
        guard let context = mediaCacheScopeContext else { return }
        invalidateIndexedMediaCache(
            messageID: message.id,
            state: state,
            authorityVersion: String(max(message.editRevision, 0)),
            context: context
        )
    }

    func invalidateIndexedMediaCacheIfRemoteTombstone(_ remote: RemoteMessage) {
        let normalizedStatus = remote.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let state: MediaCacheAuthorityState
        if isAdminDeletedRemoteMessage(remote) {
            state = .deleted
        } else if ["recalled", "revoked"].contains(normalizedStatus) {
            state = .recalled
        } else {
            return
        }
        guard let context = mediaCacheScopeContext else { return }
        let payloadVersion = attachmentPayloadString(
            remote.payload,
            ["authority_version", "event_version", "tombstone_version"]
        )
        let authorityVersion = canonicalMediaAuthorityVersion(payloadVersion)
            ?? String(max(remote.editRevision, 0))
        invalidateIndexedMediaCache(
            messageID: remote.messageID,
            state: state,
            authorityVersion: authorityVersion,
            context: context
        )
    }

    func clearCurrentIndexedMediaCache() async -> AppCacheCleanupResult {
        guard let context = mediaCacheScopeContext,
              let ticket = try? await currentMediaCacheTicket(context: context),
              let stats = try? await messagePersistence.mediaCacheStatistics(ticket: ticket),
              stats.totalBytes > 0,
              let candidates = try? await messagePersistence.mediaCachePruneCandidates(
                ticket: ticket,
                bytesToFree: stats.totalBytes
              ),
              context.sessionGeneration == localMessageSessionGeneration else {
            return AppCacheCleanupResult(bytesRemoved: 0, failures: [])
        }
        var removedBytes: Int64 = 0
        var removedIdentities: [String] = []
        var failures: [String] = []
        for candidate in candidates {
            guard context.sessionGeneration == localMessageSessionGeneration else {
                failures.append("统一媒体缓存（会话已切换）")
                break
            }
            guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else {
                failures.append("统一媒体缓存（路径）")
                continue
            }
            // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：清理统一媒体缓存的磁盘删除放到后台
            let removal = await MediaCacheFileIO.removeFileIfExistsOffMain(url)
            guard removal.didComplete else {
                failures.append("统一媒体缓存")
                continue
            }
            if removal.fileExisted {
                removedBytes += max(candidate.sizeBytes, 0)
            }
            removedIdentities.append(candidate.cacheIdentity)
            // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
        }
        do {
            try await messagePersistence.removeMediaCacheEntries(
                ticket: ticket,
                cacheIdentities: removedIdentities
            )
        } catch {
            failures.append("统一媒体缓存（索引）")
        }
        return AppCacheCleanupResult(bytesRemoved: removedBytes, failures: failures)
    }

    func deletePersistedConversationAndMedia(
        ticket: LocalMessageSessionTicket,
        conversationID: String,
        context: IOSMediaCacheScopeContext?
    ) async {
        if let candidates = try? await messagePersistence.removeMediaCacheReferences(
            ticket: ticket,
            conversationID: conversationID
        ), let context,
           context.sessionGeneration == localMessageSessionGeneration {
            for candidate in candidates {
                guard let url = mediaCacheURL(relativePath: candidate.relativePath, context: context) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：删除会话关联媒体文件放到后台执行
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
        try? await messagePersistence.deleteConversation(
            ticket: ticket,
            conversationID: conversationID
        )
    }
    // JHT_MOD_END APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改结束


}
