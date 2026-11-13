import SwiftUI
import UIKit
import QuickLook
import AVFoundation

enum TenantFileSharePreparer {
    @MainActor
    static func prepare(file: FileItem, state: AppState, scope: String) async throws -> URL {
        guard state.contentCacheScopeKey == scope else { throw CancellationError() }
        return try await state.prepareTenantFileLocalFile(file)
    }
}

enum FilesPreviewCacheAdapter {
    @MainActor
    static func cachedThumbnailURL(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext?
    ) async -> URL? {
        guard let context else { return nil }
        return await state.lookupIndexedMediaCache(
            metadata: thumbnailMetadata(for: file, scope: context.scopeHash),
            messageID: file.remoteLookupID,
            resourceKind: .thumbnail,
            variant: file.visualKind == .video ? .videoPoster : .thumbnail640,
            integrity: MediaFileIntegrityAuthority(),
            context: context,
            offline: true
        )
    }

    @MainActor
    static func cacheDownloadedThumbnail(
        _ data: Data,
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext?
    ) async -> URL? {
        guard !data.isEmpty, let context else { return nil }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-thumbnail-\(UUID().uuidString.lowercased()).jpg", isDirectory: false)
        do {
            try data.write(to: temporaryURL, options: .atomic)
            let committed = try await state.commitIndexedMediaCache(
                temporaryURL: temporaryURL,
                metadata: thumbnailMetadata(for: file, scope: context.scopeHash),
                resourceKind: .thumbnail,
                variant: file.visualKind == .video ? .videoPoster : .thumbnail640,
                integrity: MediaFileIntegrityAuthority(),
                messageID: file.remoteLookupID,
                conversationID: "__files__",
                authorityVersion: "0",
                context: context
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            return committed
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }
    }

    private static func thumbnailMetadata(for file: FileItem, scope: String) -> MediaResourceMetadata {
        var metadata = file.mediaResourceMetadata(scope: scope)
        metadata.thumbnailMimeType = "image/jpeg"
        metadata.thumbnailExtension = "jpg"
        return metadata
    }

    @MainActor
    static func cachedPreviewURL(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL? {
        guard context.isValid else { return nil }
        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        for resourceKind in [file.mediaPipelinePreviewResourceKind, .original] {
            if let localURL = await state.lookupIndexedMediaCache(
                metadata: metadata,
                messageID: file.remoteLookupID,
                resourceKind: resourceKind,
                integrity: integrity(for: file, resourceKind: resourceKind),
                context: context,
                offline: true
            ) {
                return localURL
            }
        }
        return nil
    }

    @MainActor
    static func cacheDownloadedPreview(
        _ localURL: URL,
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL {
        guard context.isValid,
              FileManager.default.fileExists(atPath: localURL.path) else {
            return localURL
        }

        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        let resourceKind = file.mediaPipelinePreviewResourceKind
        let preferredExtension = metadata.preferredExtension(for: resourceKind)
        let temporaryURL = temporaryCopyURL(for: localURL, preferredExtension: preferredExtension)
        let integrity = integrity(for: file, resourceKind: resourceKind)

        do {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.copyItem(at: localURL, to: temporaryURL)
            let committed = try await state.commitIndexedMediaCache(
                temporaryURL: temporaryURL,
                metadata: metadata,
                resourceKind: resourceKind,
                integrity: integrity,
                messageID: file.remoteLookupID,
                conversationID: "__files__",
                authorityVersion: "0",
                context: context
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            SystemPreviewLoader.discardTransient(localURL)
            return committed
        } catch {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return localURL
        }
    }

    private static func temporaryCopyURL(for localURL: URL, preferredExtension: String) -> URL {
        var temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-pipeline-preview-\(UUID().uuidString)", isDirectory: false)
        let ext = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localURL.pathExtension
            : preferredExtension
        if !ext.isEmpty {
            temporaryURL.appendPathExtension(ext)
        }
        return temporaryURL
    }

    /// The pre-contract Files cache was already tenant/user scoped, so it is the only legacy
    /// directory eligible for a bounded lazy migration.  Its FNV-derived filename is used
    /// solely to locate old bytes; it never becomes the new cache identity.
    @MainActor
    static func migrateAuthorizedLegacyPreview(
        for file: FileItem,
        state: AppState,
        context: IOSMediaCacheScopeContext
    ) async -> URL? {
        guard !file.remoteLookupID.isEmpty,
              !file.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let oldScope = state.contentCacheScopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldScope.isEmpty else { return nil }
        let metadata = file.mediaResourceMetadata(scope: context.scopeHash)
        for resourceKind in [file.mediaPipelinePreviewResourceKind, .original] {
            let preferredExtension = metadata.preferredExtension(for: resourceKind)
            let candidate = legacyURL(
                file: file,
                resourceKind: resourceKind,
                scope: oldScope,
                preferredExtension: preferredExtension
            )
            let integrity = integrity(for: file, resourceKind: resourceKind)
            guard (try? integrity.verify(fileAt: candidate)) != nil else { continue }
            do {
                let committed = try await state.commitIndexedMediaCache(
                    temporaryURL: candidate,
                    metadata: metadata,
                    resourceKind: resourceKind,
                    integrity: integrity,
                    messageID: file.remoteLookupID,
                    conversationID: "__files__",
                    authorityVersion: "0",
                    context: context
                )
                if candidate.standardizedFileURL != committed.standardizedFileURL {
                    try? FileManager.default.removeItem(at: candidate)
                }
                return committed
            } catch {
                continue
            }
        }
        return nil
    }

    private static func integrity(
        for file: FileItem,
        resourceKind: MediaResourceKind
    ) -> MediaFileIntegrityAuthority {
        guard resourceKind == .original else { return MediaFileIntegrityAuthority() }
        return MediaFileIntegrityAuthority(
            expectedSizeBytes: file.sizeBytes,
            expectedSHA256: file.checksum
        )
    }

    static func legacyURL(
        file: FileItem,
        resourceKind: MediaResourceKind,
        scope: String,
        preferredExtension: String
    ) -> URL {
        let mimeType = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileID = file.id.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["media", resourceKind.rawValue, "scope-\(legacySafeComponent(scope))", legacySafeComponent(fileID)]
        let version = file.version.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { parts.append("v-\(legacySafeComponent(version))") }
        if let sizeBytes = file.sizeBytes { parts.append("s-\(sizeBytes)") }
        if !mimeType.isEmpty { parts.append("m-\(legacySafeComponent(mimeType))") }
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("BlueStoneIMMediaPipeline", isDirectory: true)
            .appendingPathComponent(resourceKind.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(parts.joined(separator: "_"), isDirectory: false)
        let ext = legacySafeComponent(preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines))
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }

    static func purgeLegacyScope(_ scope: String) {
        let marker = "scope-\(legacySafeComponent(scope))"
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("BlueStoneIMMediaPipeline", isDirectory: true)
        for kind in MediaResourceKind.allCases {
            let directory = root.appendingPathComponent(kind.cacheDirectoryName, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.lastPathComponent.contains(marker) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func legacySafeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if result.isEmpty { return legacyFNV(value) }
        if result.count > 96 { return "\(result.prefix(64))_\(legacyFNV(value))" }
        return result
    }

    private static func legacyFNV(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}
