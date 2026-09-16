import CryptoKit
import Foundation

enum MediaFileIntegrityError: Error, Equatable, Sendable {
    case missingFile
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
}

struct MediaFileIntegrityAuthority: Equatable, Sendable {
    var expectedSizeBytes: Int64?
    var expectedSHA256: String

    init(expectedSizeBytes: Int64? = nil, expectedSHA256: String = "") {
        self.expectedSizeBytes = expectedSizeBytes.flatMap { $0 > 0 ? $0 : nil }
        self.expectedSHA256 = Self.normalizedSHA256(expectedSHA256)
    }

    var hasChecksum: Bool {
        !expectedSHA256.isEmpty
    }

    func verify(fileAt url: URL, fileManager: FileManager = .default) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MediaFileIntegrityError.missingFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualSize > 0 else {
            throw MediaFileIntegrityError.emptyFile
        }
        if let expectedSizeBytes, actualSize != expectedSizeBytes {
            throw MediaFileIntegrityError.sizeMismatch(expected: expectedSizeBytes, actual: actualSize)
        }
        if hasChecksum {
            let actualChecksum = try Self.sha256Hex(fileAt: url)
            guard actualChecksum == expectedSHA256 else {
                throw MediaFileIntegrityError.checksumMismatch
            }
        }
        return actualSize
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }

    static func normalizedSHA256(_ rawValue: String) -> String {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return ""
        }
        return rawValue
    }
}

enum MediaCacheIdentityError: Error, Equatable, Sendable {
    case invalidRequiredField(String)
    case invalidScopeHash
    case missingStableResourceID
    case missingContentVersion
}

enum MediaCacheResourceIDKind: String, Codable, CaseIterable, Sendable {
    case fileID = "file_id"
    case attachmentID = "attachment_id"
    case mediaID = "media_id"
    case cacheKey = "cache_key"
}

enum MediaCacheContentVersionKind: String, Codable, CaseIterable, Sendable {
    case checksumSHA256 = "checksum_sha256"
    case version
    case sizeCreatedAt = "size_created_at"
}

enum MediaCacheVariant: String, Codable, CaseIterable, Sendable {
    case thumbnail320 = "thumbnail:320"
    case thumbnail640 = "thumbnail:640"
    case preview1600 = "preview:1600"
    case original
    case videoPoster = "video_poster"
}

enum MediaCacheAuthorityState: String, Codable, CaseIterable, Sendable {
    case active
    case processing
    case authorizationStale = "authorization_stale"
    case recalled
    case deleted
    case forbidden
    case expiredBusiness = "expired_business"

    var permitsOpen: Bool { self == .active }
}

enum MediaCacheLocalState: String, Codable, CaseIterable, Sendable {
    case none
    case partial
    case verifiedCached = "verified_cached"
    case evicted
    case corrupt
}

enum MediaCacheTransferState: String, Codable, CaseIterable, Sendable {
    case idle
    case staged
    case queued
    case presigning
    case resolvingURL = "resolving_url"
    case uploading
    case confirming
    case awaitingMessageAck = "awaiting_message_ack"
    case downloading
    case signatureExpired = "signature_expired"
    case refreshingURL = "refreshing_url"
    case verifying
    case committing
    case succeeded
    case failedRetryable = "failed_retryable"
    case failedPermanent = "failed_permanent"
    case cancelled
}

enum IOSMediaOfflinePolicy: String, Codable, Sendable {
    case bounded
    case deny

    var ttl: TimeInterval {
        switch self {
        case .bounded: 86_400
        case .deny: 0
        }
    }
}

struct IOSMediaCacheAuthorityRecord: Equatable, Sendable {
    let scopeHash: String
    let messageID: String
    let attachmentID: String
    let identity: MediaResourceIdentity
    let mimeType: String
    let sizeBytes: Int64
    let checksumSHA256: String?
    let state: MediaCacheAuthorityState
    let authorityVersion: String
    let lastAuthorizedAt: Date?
    let offlineAccessUntil: Date?
    let createdAt: Date?
    let updatedAt: Date

    func permitsOpen(now: Date, allowOffline: Bool) -> Bool {
        guard state.permitsOpen else { return false }
        guard allowOffline else { return true }
        guard let offlineAccessUntil else { return false }
        return offlineAccessUntil >= now
    }
}

struct IOSMediaCacheEntryRecord: Equatable, Sendable {
    let scopeHash: String
    let cacheIdentity: String
    let attachmentID: String
    let variant: MediaCacheVariant
    let relativePath: String
    let localState: MediaCacheLocalState
    let sizeBytes: Int64
    let verifiedSizeBytes: Int64?
    let verifiedChecksumSHA256: String?
    let pinnedByUser: Bool
    let protectionReason: String
    let createdAt: Date
    let lastAccessedAt: Date
}

struct IOSMediaCacheIndexedLookup: Sendable {
    let authority: IOSMediaCacheAuthorityRecord
    let entry: IOSMediaCacheEntryRecord
}

struct IOSMediaCacheStatistics: Equatable, Sendable {
    let fileCount: Int
    let totalBytes: Int64
    let verifiedBytes: Int64
    let corruptCount: Int
}

struct IOSMediaCachePruneCandidate: Equatable, Sendable {
    let cacheIdentity: String
    let relativePath: String
    let sizeBytes: Int64
}

enum MediaCacheCanonicalIdentity {
    static func canonicalData(_ orderedPairs: [(String, String)]) throws -> Data {
        var components: [String] = []
        components.reserveCapacity(orderedPairs.count)
        for (key, value) in orderedPairs {
            try validateRequired(key, field: "canonical_key")
            try validateRequired(value, field: key)
            components.append("\(key.utf8.count):\(key):\(value.utf8.count):\(value)")
        }
        return Data(components.joined(separator: "|").utf8)
    }

    static func digest(_ orderedPairs: [(String, String)]) throws -> String {
        SHA256.hash(data: try canonicalData(orderedPairs))
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }

    static func validateRequired(_ value: String, field: String) throws {
        guard !value.isEmpty else { throw MediaCacheIdentityError.invalidRequiredField(field) }
        guard value.utf8.first.map({ !isASCIIWhitespace($0) }) == true,
              value.utf8.last.map({ !isASCIIWhitespace($0) }) == true else {
            throw MediaCacheIdentityError.invalidRequiredField(field)
        }
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }
}

enum MediaResourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case thumbnail
    case preview
    case original

    var cacheDirectoryName: String {
        switch self {
        case .thumbnail: "thumbnails"
        case .preview: "previews"
        case .original: "originals"
        }
    }

    var displayName: String {
        switch self {
        case .thumbnail: "缩略图"
        case .preview: "预览"
        case .original: "原文件"
        }
    }
}

struct MediaResourceIdentity: Codable, Hashable, Sendable {
    var resourceKind: MediaResourceKind
    var scope: String
    var fileID: String
    var attachmentID: String
    var mediaID: String
    var cacheKey: String
    var version: String
    var checksumSHA256: String
    var createdAt: String
    var variant: MediaCacheVariant
    var mimeType: String
    var sizeBytes: Int64?

    init(
        resourceKind: MediaResourceKind,
        scope: String = "",
        fileID: String = "",
        attachmentID: String = "",
        mediaID: String = "",
        cacheKey: String = "",
        version: String = "",
        checksumSHA256: String = "",
        createdAt: String = "",
        variant: MediaCacheVariant? = nil,
        mimeType: String = "",
        sizeBytes: Int64? = nil
    ) {
        self.resourceKind = resourceKind
        // Contract identity fields are byte-exact.  In particular, silently trimming or
        // URL-normalizing them would allow two server identities to collapse to one cache
        // entry.  `persistentCacheIdentity` performs the fail-closed validation instead.
        self.scope = scope
        self.fileID = fileID
        self.attachmentID = attachmentID
        self.mediaID = mediaID
        self.cacheKey = cacheKey
        self.version = version
        self.checksumSHA256 = checksumSHA256
        self.createdAt = createdAt
        self.variant = variant ?? Self.defaultVariant(for: resourceKind)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sizeBytes = sizeBytes
    }

    var primaryStableID: String {
        [fileID, attachmentID, mediaID, cacheKey]
            .first(where: { !$0.isEmpty }) ?? ""
    }

    var hasStableID: Bool {
        !primaryStableID.isEmpty
    }

    var resourceIDKind: MediaCacheResourceIDKind? {
        if !fileID.isEmpty { return .fileID }
        if !attachmentID.isEmpty { return .attachmentID }
        if !mediaID.isEmpty { return .mediaID }
        if !cacheKey.isEmpty, Self.isPersistentCacheKey(cacheKey) { return .cacheKey }
        return nil
    }

    var contentVersionKindAndValue: (MediaCacheContentVersionKind, String)? {
        if !checksumSHA256.isEmpty {
            guard MediaFileIntegrityAuthority.normalizedSHA256(checksumSHA256) == checksumSHA256 else {
                return nil
            }
            return (.checksumSHA256, checksumSHA256)
        }
        if !version.isEmpty { return (.version, version) }
        if let sizeBytes, sizeBytes >= 0, !createdAt.isEmpty {
            return (.sizeCreatedAt, "size=\(sizeBytes);created_at=\(createdAt)")
        }
        return nil
    }

    var persistentCacheIdentity: String? {
        guard scope.count == 64,
              scope.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              let resourceIDKind,
              let (contentVersionKind, contentVersion) = contentVersionKindAndValue else { return nil }
        return try? MediaCacheCanonicalIdentity.digest([
            ("scope_hash", scope),
            ("resource_id_kind", resourceIDKind.rawValue),
            ("resource_id", primaryStableID),
            ("content_version_kind", contentVersionKind.rawValue),
            ("content_version", contentVersion),
            ("variant", variant.rawValue)
        ])
    }

    var stableCacheKey: String {
        persistentCacheIdentity ?? "invalid-persistent-media-identity"
    }

    func cacheFileURL(in rootDirectory: URL, preferredExtension: String = "") -> URL {
        let directory = rootDirectory.appendingPathComponent(resourceKind.cacheDirectoryName, isDirectory: true)
        let ext = Self.safeCacheComponent(preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines))
        if ext.isEmpty {
            return directory.appendingPathComponent(stableCacheKey, isDirectory: false)
        }
        return directory.appendingPathComponent(stableCacheKey, isDirectory: false).appendingPathExtension(ext)
    }

    private static func safeCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if result.isEmpty {
            return stableHash(value)
        }
        if result.count > 96 {
            return "\(result.prefix(64))_\(stableHash(value))"
        }
        return result
    }

    static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func isPersistentCacheKey(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://"),
              !value.contains("://"),
              !value.contains("?") else { return false }
        return true
    }

    private static func defaultVariant(for resourceKind: MediaResourceKind) -> MediaCacheVariant {
        switch resourceKind {
        case .thumbnail: .thumbnail640
        case .preview: .preview1600
        case .original: .original
        }
    }
}

struct MediaResourceMetadata: Codable, Hashable, Sendable {
    var scope: String
    var fileID: String
    var attachmentID: String
    var mediaID: String
    var cacheKey: String
    var version: String
    var checksumSHA256: String
    var createdAt: String
    var mimeType: String
    var sizeBytes: Int64?
    var fileName: String
    var fileExtension: String
    var thumbnailCacheKey: String
    var thumbnailVersion: String
    var thumbnailMimeType: String
    var thumbnailExtension: String
    var previewCacheKey: String
    var previewVersion: String
    var previewMimeType: String
    var previewExtension: String

    init(
        scope: String = "",
        fileID: String = "",
        attachmentID: String = "",
        mediaID: String = "",
        cacheKey: String = "",
        version: String = "",
        checksumSHA256: String = "",
        createdAt: String = "",
        mimeType: String = "",
        sizeBytes: Int64? = nil,
        fileName: String = "",
        fileExtension: String = "",
        thumbnailCacheKey: String = "",
        thumbnailVersion: String = "",
        thumbnailMimeType: String = "",
        thumbnailExtension: String = "",
        previewCacheKey: String = "",
        previewVersion: String = "",
        previewMimeType: String = "",
        previewExtension: String = ""
    ) {
        self.scope = scope
        self.fileID = fileID
        self.attachmentID = attachmentID
        self.mediaID = mediaID
        self.cacheKey = cacheKey
        self.version = version
        self.checksumSHA256 = checksumSHA256
        self.createdAt = createdAt
        self.mimeType = Self.normalized(mimeType).lowercased()
        self.sizeBytes = sizeBytes
        self.fileName = Self.normalized(fileName)
        self.fileExtension = Self.normalizedExtension(fileExtension)
        self.thumbnailCacheKey = thumbnailCacheKey
        self.thumbnailVersion = thumbnailVersion
        self.thumbnailMimeType = Self.normalized(thumbnailMimeType).lowercased()
        self.thumbnailExtension = Self.normalizedExtension(thumbnailExtension)
        self.previewCacheKey = previewCacheKey
        self.previewVersion = previewVersion
        self.previewMimeType = Self.normalized(previewMimeType).lowercased()
        self.previewExtension = Self.normalizedExtension(previewExtension)
    }

    func identity(
        for resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil
    ) -> MediaResourceIdentity {
        MediaResourceIdentity(
            resourceKind: resourceKind,
            scope: scope,
            fileID: fileID,
            attachmentID: attachmentID,
            mediaID: mediaID,
            cacheKey: cacheKey(for: resourceKind),
            version: version(for: resourceKind),
            checksumSHA256: resourceKind == .original ? checksumSHA256 : "",
            createdAt: createdAt,
            variant: variant,
            mimeType: mimeType(for: resourceKind),
            sizeBytes: resourceKind == .original ? sizeBytes : nil
        )
    }

    func preferredExtension(for resourceKind: MediaResourceKind) -> String {
        let explicitExtension: String
        switch resourceKind {
        case .thumbnail:
            explicitExtension = firstNonEmpty(thumbnailExtension, extensionFromMimeType(thumbnailMimeType), extensionFromMimeType(mimeType))
        case .preview:
            explicitExtension = firstNonEmpty(previewExtension, extensionFromMimeType(previewMimeType), fileExtension, extensionFromFileName(fileName), extensionFromMimeType(mimeType))
        case .original:
            explicitExtension = firstNonEmpty(fileExtension, extensionFromFileName(fileName), extensionFromMimeType(mimeType))
        }
        return Self.normalizedExtension(explicitExtension)
    }

    private func cacheKey(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailCacheKey, cacheKey)
        case .preview:
            return firstNonEmpty(previewCacheKey, cacheKey)
        case .original:
            return cacheKey
        }
    }

    private func version(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailVersion, version)
        case .preview:
            return firstNonEmpty(previewVersion, version)
        case .original:
            return version
        }
    }

    private func mimeType(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailMimeType, mimeType)
        case .preview:
            return firstNonEmpty(previewMimeType, mimeType)
        case .original:
            return mimeType
        }
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    private func extensionFromFileName(_ fileName: String) -> String {
        Self.normalizedExtension((fileName as NSString).pathExtension)
    }

    private func extensionFromMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic", "image/heif":
            return "heic"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        case "text/csv", "application/csv":
            return "csv"
        default:
            return ""
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedExtension(_ value: String) -> String {
        let trimmed = normalized(value).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed = CharacterSet.alphanumerics
        let scalars = trimmed.unicodeScalars.compactMap { scalar -> Character? in
            allowed.contains(scalar) ? Character(scalar) : nil
        }
        return String(scalars).lowercased()
    }
}

enum MediaTransferState: Equatable, Sendable {
    case processing
    case readyRemote
    case downloading(progress: Double?)
    case downloaded(localURL: URL)
    case failed(message: String?)
    case signatureExpired

    var isTerminalSuccess: Bool {
        if case .downloaded = self {
            return true
        }
        return false
    }

    var canRetry: Bool {
        switch self {
        case .failed, .signatureExpired:
            return true
        case .processing, .readyRemote, .downloading, .downloaded:
            return false
        }
    }

    var normalizedProgress: Double? {
        guard case let .downloading(progress) = self, let progress else { return nil }
        return min(max(progress, 0), 1)
    }
}

struct MediaCachePolicy: Codable, Equatable, Sendable {
    var memoryCostLimitBytes: Int
    var diskCapacityBytes: Int64
    var maxConcurrentDownloads: Int
    var signatureRefreshLeadTime: TimeInterval
    var allowsCellularAutoDownload: Bool

    static let thumbnailDiskCapacityBytes: Int64 = 256 * 1024 * 1024
    static let previewDiskCapacityBytes: Int64 = 768 * 1024 * 1024
    static let originalDiskCapacityBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let defaultMemoryCostLimitBytes = 64 * 1024 * 1024
    static let defaultMaxConcurrentDownloads = 3
    static let defaultSignatureRefreshLeadTime: TimeInterval = 60

    static func defaultPolicy(for resourceKind: MediaResourceKind) -> MediaCachePolicy {
        let diskCapacity: Int64
        switch resourceKind {
        case .thumbnail:
            diskCapacity = thumbnailDiskCapacityBytes
        case .preview:
            diskCapacity = previewDiskCapacityBytes
        case .original:
            diskCapacity = originalDiskCapacityBytes
        }
        return MediaCachePolicy(
            memoryCostLimitBytes: defaultMemoryCostLimitBytes,
            diskCapacityBytes: diskCapacity,
            maxConcurrentDownloads: defaultMaxConcurrentDownloads,
            signatureRefreshLeadTime: defaultSignatureRefreshLeadTime,
            allowsCellularAutoDownload: resourceKind == .thumbnail
        )
    }
}

struct MediaCacheEntry: Codable, Hashable, Sendable {
    var identity: MediaResourceIdentity
    var localURL: URL
    var sizeBytes: Int64
    var createdAt: Date?
    var lastAccessedAt: Date?

    init(
        identity: MediaResourceIdentity,
        localURL: URL,
        sizeBytes: Int64,
        createdAt: Date? = nil,
        lastAccessedAt: Date? = nil
    ) {
        self.identity = identity
        self.localURL = localURL
        self.sizeBytes = max(sizeBytes, 0)
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

struct MediaCacheLookupResult: Sendable {
    var identity: MediaResourceIdentity
    var state: MediaTransferState
    var entry: MediaCacheEntry?
    var checkedAt: Date

    init(
        identity: MediaResourceIdentity,
        state: MediaTransferState,
        entry: MediaCacheEntry? = nil,
        checkedAt: Date = Date()
    ) {
        self.identity = identity
        self.state = state
        self.entry = entry
        self.checkedAt = checkedAt
    }
}

struct MediaPreviewCacheResolution: Sendable {
    var resourceKind: MediaResourceKind
    var identity: MediaResourceIdentity
    var preferredExtension: String
    var lookupResult: MediaCacheLookupResult

    var state: MediaTransferState {
        lookupResult.state
    }

    var localURL: URL? {
        guard case let .downloaded(localURL) = lookupResult.state else { return nil }
        return localURL
    }

    var isCached: Bool {
        localURL != nil
    }
}

enum MediaPreviewCacheResolver {
    static func lookup(
        resourceKind: MediaResourceKind,
        metadata: MediaResourceMetadata,
        cacheStore: any MediaLayeredCacheManaging,
        downloadState: MediaDownloadTaskState? = nil
    ) async -> MediaPreviewCacheResolution {
        let identity = metadata.identity(for: resourceKind)
        let preferredExtension = metadata.preferredExtension(for: resourceKind)
        let result = await cacheStore.lookup(
            identity: identity,
            preferredExtension: preferredExtension,
            downloadState: downloadState
        )
        return MediaPreviewCacheResolution(
            resourceKind: resourceKind,
            identity: identity,
            preferredExtension: preferredExtension,
            lookupResult: result
        )
    }

    static func lookupAll(
        metadata: MediaResourceMetadata,
        cacheStore: any MediaLayeredCacheManaging,
        resourceKinds: [MediaResourceKind] = [.thumbnail, .preview, .original],
        downloadStatesByKind: [MediaResourceKind: MediaDownloadTaskState] = [:]
    ) async -> [MediaPreviewCacheResolution] {
        var resolutions: [MediaPreviewCacheResolution] = []
        resolutions.reserveCapacity(resourceKinds.count)
        for resourceKind in resourceKinds {
            let resolution = await lookup(
                resourceKind: resourceKind,
                metadata: metadata,
                cacheStore: cacheStore,
                downloadState: downloadStatesByKind[resourceKind]
            )
            resolutions.append(resolution)
        }
        return resolutions
    }

    static func preferredResolution(
        metadata: MediaResourceMetadata,
        cacheStore: any MediaLayeredCacheManaging,
        resourceKinds: [MediaResourceKind] = [.thumbnail, .preview, .original],
        downloadStatesByKind: [MediaResourceKind: MediaDownloadTaskState] = [:]
    ) async -> MediaPreviewCacheResolution? {
        let resolutions = await lookupAll(
            metadata: metadata,
            cacheStore: cacheStore,
            resourceKinds: resourceKinds,
            downloadStatesByKind: downloadStatesByKind
        )
        return resolutions.first(where: \.isCached) ?? resolutions.first
    }
}

struct MediaCacheStatistics: Codable, Hashable, Sendable {
    var resourceKind: MediaResourceKind?
    var fileCount: Int
    var totalBytes: Int64
    var capacityBytes: Int64?
    var generatedAt: Date

    init(
        resourceKind: MediaResourceKind?,
        fileCount: Int,
        totalBytes: Int64,
        capacityBytes: Int64? = nil,
        generatedAt: Date = Date()
    ) {
        self.resourceKind = resourceKind
        self.fileCount = max(fileCount, 0)
        self.totalBytes = max(totalBytes, 0)
        self.capacityBytes = capacityBytes
        self.generatedAt = generatedAt
    }
}

struct MediaCacheEvictionCandidate: Codable, Hashable, Sendable {
    var resourceKind: MediaResourceKind
    var localURL: URL
    var sizeBytes: Int64
    var lastAccessedAt: Date?

    init(
        resourceKind: MediaResourceKind,
        localURL: URL,
        sizeBytes: Int64,
        lastAccessedAt: Date? = nil
    ) {
        self.resourceKind = resourceKind
        self.localURL = localURL
        self.sizeBytes = max(sizeBytes, 0)
        self.lastAccessedAt = lastAccessedAt
    }
}

struct IOSMediaCacheScopeContext: Hashable, Sendable {
    let scopeHash: String
    let sessionGeneration: UInt64
    let rootDirectory: URL

    init(scopeHash: String, sessionGeneration: UInt64, rootDirectory: URL) {
        self.scopeHash = scopeHash
        self.sessionGeneration = sessionGeneration
        self.rootDirectory = rootDirectory
    }

    var isValid: Bool {
        scopeHash.count == 64
            && scopeHash.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }
}

actor IOSMediaCacheStoreRegistry {
    static let shared = IOSMediaCacheStoreRegistry()

    private var storesByScopeHash: [String: MediaLayeredCacheStore] = [:]
    private var currentGenerationByScopeHash: [String: UInt64] = [:]

    func store(for context: IOSMediaCacheScopeContext) async throws -> MediaLayeredCacheStore {
        guard context.isValid else { throw LocalMessageDatabaseError.invalidScopeField("scope_hash") }
        if let currentGeneration = currentGenerationByScopeHash[context.scopeHash],
           context.sessionGeneration < currentGeneration {
            throw LocalMessageDatabaseError.staleSession
        }
        currentGenerationByScopeHash[context.scopeHash] = context.sessionGeneration
        if let existing = storesByScopeHash[context.scopeHash] {
            try await existing.activateSessionGeneration(context.sessionGeneration)
            return existing
        }
        let store = MediaLayeredCacheStore(rootDirectory: context.rootDirectory)
        try await store.activateSessionGeneration(context.sessionGeneration)
        storesByScopeHash[context.scopeHash] = store
        return store
    }

    func accepts(_ context: IOSMediaCacheScopeContext) -> Bool {
        context.isValid && currentGenerationByScopeHash[context.scopeHash] == context.sessionGeneration
    }

    @discardableResult
    func invalidate(scopeHash: String, through generation: UInt64) async -> Bool {
        guard let current = currentGenerationByScopeHash[scopeHash] else {
            currentGenerationByScopeHash[scopeHash] = generation &+ 1
            if let store = storesByScopeHash[scopeHash] {
                try? await store.activateSessionGeneration(generation &+ 1)
            }
            return true
        }
        guard current <= generation else { return false }
        currentGenerationByScopeHash[scopeHash] = generation &+ 1
        if let store = storesByScopeHash[scopeHash] {
            try? await store.activateSessionGeneration(generation &+ 1)
        }
        return true
    }
}

protocol MediaLayeredCacheManaging: Sendable {
    func lookup(
        identity: MediaResourceIdentity,
        preferredExtension: String,
        downloadState: MediaDownloadTaskState?
    ) async -> MediaCacheLookupResult

    func saveDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String
    ) async throws -> MediaCacheEntry

    func remove(identity: MediaResourceIdentity, preferredExtension: String) async throws
    func statistics(for resourceKind: MediaResourceKind?) async throws -> MediaCacheStatistics
    func evictionCandidates(for resourceKind: MediaResourceKind, limitBytes: Int64?) async throws -> [MediaCacheEvictionCandidate]
    func prune(resourceKind: MediaResourceKind, keepingUnder limitBytes: Int64?) async throws -> MediaCacheStatistics
}

actor MediaLayeredCacheStore: MediaLayeredCacheManaging {
    private let rootDirectory: URL
    private let policiesByKind: [MediaResourceKind: MediaCachePolicy]
    private var activeSessionGeneration: UInt64?

    init(
        rootDirectory: URL,
        policiesByKind: [MediaResourceKind: MediaCachePolicy] = Dictionary(
            uniqueKeysWithValues: MediaResourceKind.allCases.map { ($0, MediaCachePolicy.defaultPolicy(for: $0)) }
        )
    ) {
        self.rootDirectory = rootDirectory
        self.policiesByKind = policiesByKind
    }

    func activateSessionGeneration(_ generation: UInt64) throws {
        if let activeSessionGeneration, generation < activeSessionGeneration {
            throw LocalMessageDatabaseError.staleSession
        }
        activeSessionGeneration = generation
    }

    func lookup(
        identity: MediaResourceIdentity,
        preferredExtension: String = "",
        downloadState: MediaDownloadTaskState? = nil
    ) async -> MediaCacheLookupResult {
        guard identity.persistentCacheIdentity != nil else {
            return MediaCacheLookupResult(identity: identity, state: .readyRemote)
        }
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        if let entry = cacheEntry(identity: identity, localURL: localURL) {
            return MediaCacheLookupResult(
                identity: identity,
                state: .downloaded(localURL: entry.localURL),
                entry: entry
            )
        }
        if let downloadState {
            return MediaCacheLookupResult(
                identity: identity,
                state: downloadState.transferState,
                entry: nil,
                checkedAt: downloadState.updatedAt
            )
        }
        return MediaCacheLookupResult(identity: identity, state: .readyRemote)
    }

    func verifiedLookup(
        identity: MediaResourceIdentity,
        preferredExtension: String = "",
        integrity: MediaFileIntegrityAuthority,
        downloadState: MediaDownloadTaskState? = nil
    ) async -> MediaCacheLookupResult {
        verifiedLookupImpl(
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity,
            downloadState: downloadState
        )
    }

    func verifiedLookup(
        identity: MediaResourceIdentity,
        preferredExtension: String = "",
        integrity: MediaFileIntegrityAuthority,
        downloadState: MediaDownloadTaskState? = nil,
        sessionGeneration: UInt64
    ) async -> MediaCacheLookupResult {
        guard activeSessionGeneration == sessionGeneration else {
            return MediaCacheLookupResult(identity: identity, state: .readyRemote)
        }
        return verifiedLookupImpl(
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity,
            downloadState: downloadState
        )
    }

    private func verifiedLookupImpl(
        identity: MediaResourceIdentity,
        preferredExtension: String,
        integrity: MediaFileIntegrityAuthority,
        downloadState: MediaDownloadTaskState?
    ) -> MediaCacheLookupResult {
        guard identity.persistentCacheIdentity != nil else {
            return MediaCacheLookupResult(identity: identity, state: .readyRemote)
        }
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        do {
            let actualSize = try integrity.verify(fileAt: localURL)
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
            let entry = MediaCacheEntry(
                identity: identity,
                localURL: localURL,
                sizeBytes: actualSize,
                createdAt: attributes?[.creationDate] as? Date,
                lastAccessedAt: Date()
            )
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: localURL.path)
            return MediaCacheLookupResult(
                identity: identity,
                state: .downloaded(localURL: localURL),
                entry: entry
            )
        } catch {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: localURL)
            }
        }
        if let downloadState {
            return MediaCacheLookupResult(
                identity: identity,
                state: downloadState.transferState,
                entry: nil,
                checkedAt: downloadState.updatedAt
            )
        }
        return MediaCacheLookupResult(identity: identity, state: .readyRemote)
    }

    func saveDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String = ""
    ) async throws -> MediaCacheEntry {
        guard identity.persistentCacheIdentity != nil else {
            throw MediaCacheIdentityError.missingContentVersion
        }
        let destinationURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return cacheEntry(identity: identity, localURL: destinationURL)
            ?? MediaCacheEntry(identity: identity, localURL: destinationURL, sizeBytes: 0)
    }

    func saveVerifiedDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String = "",
        integrity: MediaFileIntegrityAuthority
    ) async throws -> MediaCacheEntry {
        try saveVerifiedDownloadedFileImpl(
            from: temporaryURL,
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity
        )
    }

    func saveVerifiedDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String = "",
        integrity: MediaFileIntegrityAuthority,
        sessionGeneration: UInt64
    ) async throws -> MediaCacheEntry {
        guard activeSessionGeneration == sessionGeneration else {
            throw LocalMessageDatabaseError.staleSession
        }
        return try saveVerifiedDownloadedFileImpl(
            from: temporaryURL,
            identity: identity,
            preferredExtension: preferredExtension,
            integrity: integrity
        )
    }

    private func saveVerifiedDownloadedFileImpl(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String,
        integrity: MediaFileIntegrityAuthority
    ) throws -> MediaCacheEntry {
        guard identity.persistentCacheIdentity != nil else {
            throw MediaCacheIdentityError.missingContentVersion
        }
        _ = try integrity.verify(fileAt: temporaryURL)
        let destinationURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applyCacheDirectoryProtection(to: rootDirectory)

        let partURL = directory.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).part")
        if fileManager.fileExists(atPath: partURL.path) {
            try fileManager.removeItem(at: partURL)
        }
        do {
            try fileManager.copyItem(at: temporaryURL, to: partURL)
            _ = try integrity.verify(fileAt: partURL)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: partURL.path
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: partURL)
            } else {
                try fileManager.moveItem(at: partURL, to: destinationURL)
            }
        } catch {
            if fileManager.fileExists(atPath: partURL.path) {
                try? fileManager.removeItem(at: partURL)
            }
            throw error
        }
        let actualSize = try integrity.verify(fileAt: destinationURL)
        return MediaCacheEntry(
            identity: identity,
            localURL: destinationURL,
            sizeBytes: actualSize,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
    }

    func remove(identity: MediaResourceIdentity, preferredExtension: String = "") async throws {
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localURL.path) else { return }
        try fileManager.removeItem(at: localURL)
    }

    func statistics(for resourceKind: MediaResourceKind? = nil) async throws -> MediaCacheStatistics {
        let kinds = resourceKind.map { [$0] } ?? MediaResourceKind.allCases
        let candidates = try kinds.flatMap { try files(in: $0) }
        let capacity = resourceKind.flatMap { policiesByKind[$0]?.diskCapacityBytes }
        return MediaCacheStatistics(
            resourceKind: resourceKind,
            fileCount: candidates.count,
            totalBytes: candidates.reduce(Int64(0)) { $0 + $1.sizeBytes },
            capacityBytes: capacity
        )
    }

    func evictionCandidates(for resourceKind: MediaResourceKind, limitBytes: Int64? = nil) async throws -> [MediaCacheEvictionCandidate] {
        let candidates = try files(in: resourceKind).sorted { lhs, rhs in
            switch (lhs.lastAccessedAt, rhs.lastAccessedAt) {
            case let (lhsDate?, rhsDate?):
                return lhsDate < rhsDate
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return lhs.localURL.path < rhs.localURL.path
            }
        }
        guard let limitBytes else { return candidates }
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var bytesToFree = max(totalBytes - limitBytes, 0)
        guard bytesToFree > 0 else { return [] }
        var selected: [MediaCacheEvictionCandidate] = []
        for candidate in candidates {
            selected.append(candidate)
            bytesToFree -= candidate.sizeBytes
            if bytesToFree <= 0 { break }
        }
        return selected
    }

    func prune(resourceKind: MediaResourceKind, keepingUnder limitBytes: Int64? = nil) async throws -> MediaCacheStatistics {
        let targetLimit = limitBytes ?? policiesByKind[resourceKind]?.diskCapacityBytes
        let candidates = try await evictionCandidates(for: resourceKind, limitBytes: targetLimit)
        let fileManager = FileManager.default
        for candidate in candidates where fileManager.fileExists(atPath: candidate.localURL.path) {
            try fileManager.removeItem(at: candidate.localURL)
        }
        return try await statistics(for: resourceKind)
    }

    private func cacheEntry(identity: MediaResourceIdentity, localURL: URL) -> MediaCacheEntry? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localURL.path) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: localURL.path) else {
            return MediaCacheEntry(identity: identity, localURL: localURL, sizeBytes: 0)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let createdAt = attributes[.creationDate] as? Date
        let lastAccessedAt = (attributes[.modificationDate] as? Date) ?? createdAt
        return MediaCacheEntry(
            identity: identity,
            localURL: localURL,
            sizeBytes: size,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    private func files(in resourceKind: MediaResourceKind) throws -> [MediaCacheEvictionCandidate] {
        let directoryURL = rootDirectory.appendingPathComponent(resourceKind.cacheDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        let urls = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            let size = Int64(values.fileSize ?? 0)
            return MediaCacheEvictionCandidate(
                resourceKind: resourceKind,
                localURL: url,
                sizeBytes: size,
                lastAccessedAt: values.contentAccessDate ?? values.contentModificationDate
            )
        }
    }

    private static func applyCacheDirectoryProtection(to root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableRoot.setResourceValues(values)
    }
}

enum MediaDownloadPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case background = 0
    case normal = 10
    case visible = 20
    case userInitiated = 30

    static func < (lhs: MediaDownloadPriority, rhs: MediaDownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MediaDownloadSource: Codable, Hashable, Sendable {
    case endpoint(path: String)
    case provider(key: String)

    var debugDescription: String {
        switch self {
        case .endpoint:
            return "endpoint:<redacted>"
        case .provider(let key):
            return "provider:\(key)"
        }
    }
}

struct MediaDownloadRequest: Codable, Hashable, Sendable {
    var identity: MediaResourceIdentity
    var source: MediaDownloadSource
    var priority: MediaDownloadPriority
    var requestedAt: Date
    var signatureExpiresAt: Date?
    var preferredExtension: String

    init(
        identity: MediaResourceIdentity,
        source: MediaDownloadSource,
        priority: MediaDownloadPriority = .normal,
        requestedAt: Date = Date(),
        signatureExpiresAt: Date? = nil,
        preferredExtension: String = ""
    ) {
        self.identity = identity
        self.source = source
        self.priority = priority
        self.requestedAt = requestedAt
        self.signatureExpiresAt = signatureExpiresAt
        self.preferredExtension = preferredExtension
    }

    var taskID: String {
        identity.stableCacheKey
    }

    func cacheFileURL(in rootDirectory: URL) -> URL {
        identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
    }
}

enum MediaDownloadFailureReason: String, Codable, Hashable, Sendable {
    case network
    case notFound
    case forbidden
    case unauthorized
    case cancelled
    case signatureExpired
    case unknown

    static func normalized(httpStatus: Int?, backendCode: String? = nil) -> MediaDownloadFailureReason {
        let code = backendCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if code.contains("signature_expired") || code.contains("url_expired") || code.contains("signed_url_expired") {
            return .signatureExpired
        }
        if httpStatus == 401 {
            return .unauthorized
        }
        if httpStatus == 403 {
            return .forbidden
        }
        if httpStatus == 404 || code == "not_found" || code.contains("file_not_found") {
            return .notFound
        }
        if code.contains("cancel") {
            return .cancelled
        }
        if let httpStatus, (500...599).contains(httpStatus) {
            return .network
        }
        return code.isEmpty ? .unknown : .forbidden
    }
}

protocol MediaHTTPStatusProvidingError: Error {
    var statusCode: Int { get }
    var requestURL: URL? { get }
}

enum MediaSignedURLRefreshPolicy {
    static func shouldRefresh(
        statusCode: Int,
        requestURL: URL?,
        backendCode: String = ""
    ) -> Bool {
        let code = backendCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.contains("signature_expired")
            || code.contains("url_expired")
            || code.contains("signed_url_expired") {
            return !isAuthenticatedTenantAPIURL(requestURL)
        }
        guard statusCode == 401 || statusCode == 403 else { return false }
        return !isAuthenticatedTenantAPIURL(requestURL) && isSignedObjectStorageURL(requestURL)
    }

    static func isAuthenticatedTenantAPIURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path == "/api/tenant" || path.hasPrefix("/api/tenant/")
    }

    static func isSignedObjectStorageURL(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let names = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        if names.contains("auth_key") || names.contains("x-oss-signature") {
            return true
        }
        return names.contains("ossaccesskeyid") && names.contains("signature")
    }
}

enum MediaSignedURLRecovery {
    @MainActor
    static func perform<Output>(
        initialURL: URL,
        refreshURL: () async throws -> URL,
        operation: (URL) async throws -> Output
    ) async throws -> Output {
        do {
            return try await operation(initialURL)
        } catch {
            guard let statusError = error as? any MediaHTTPStatusProvidingError,
                  MediaSignedURLRefreshPolicy.shouldRefresh(
                      statusCode: statusError.statusCode,
                      requestURL: statusError.requestURL ?? initialURL
                  ) else {
                throw error
            }
            let refreshedURL = try await refreshURL()
            return try await operation(refreshedURL)
        }
    }
}

actor MediaVisibleRecoveryGate {
    static let shared = MediaVisibleRecoveryGate()

    private let cooldown: TimeInterval
    private var lastAttemptsByKey: [String: Date] = [:]

    init(cooldown: TimeInterval = 15) {
        self.cooldown = max(1, cooldown)
    }

    func shouldRetry(key: String, now: Date = Date()) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        if let lastAttempt = lastAttemptsByKey[normalizedKey],
           now.timeIntervalSince(lastAttempt) < cooldown {
            return false
        }
        lastAttemptsByKey[normalizedKey] = now
        if lastAttemptsByKey.count > 512 {
            let cutoff = now.addingTimeInterval(-cooldown * 4)
            lastAttemptsByKey = lastAttemptsByKey.filter { $0.value >= cutoff }
        }
        return true
    }
}

enum MediaDownloadTaskPhase: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case signatureExpired
}

struct MediaDownloadTaskState: Codable, Hashable, Sendable {
    var request: MediaDownloadRequest
    var phase: MediaDownloadTaskPhase
    var progress: Double?
    var localURL: URL?
    var failureReason: MediaDownloadFailureReason?
    var updatedAt: Date

    init(
        request: MediaDownloadRequest,
        phase: MediaDownloadTaskPhase = .queued,
        progress: Double? = nil,
        localURL: URL? = nil,
        failureReason: MediaDownloadFailureReason? = nil,
        updatedAt: Date = Date()
    ) {
        self.request = request
        self.phase = phase
        self.progress = progress.map { min(max($0, 0), 1) }
        self.localURL = localURL
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }

    var transferState: MediaTransferState {
        switch phase {
        case .queued:
            return .readyRemote
        case .running:
            return .downloading(progress: progress)
        case .completed:
            if let localURL {
                return .downloaded(localURL: localURL)
            }
            return .failed(message: "本地文件不存在")
        case .failed:
            return .failed(message: failureReason?.rawValue)
        case .cancelled:
            return .failed(message: MediaDownloadFailureReason.cancelled.rawValue)
        case .signatureExpired:
            return .signatureExpired
        }
    }
}

actor MediaDownloadManager {
    private let rootDirectory: URL
    private let policy: MediaCachePolicy
    private var statesByTaskID: [String: MediaDownloadTaskState] = [:]

    init(rootDirectory: URL, policy: MediaCachePolicy) {
        self.rootDirectory = rootDirectory
        self.policy = policy
    }

    var maxConcurrentDownloads: Int {
        policy.maxConcurrentDownloads
    }

    func enqueue(_ request: MediaDownloadRequest, now: Date = Date()) -> MediaDownloadTaskState {
        if var existing = statesByTaskID[request.taskID] {
            if request.priority > existing.request.priority {
                existing.request.priority = request.priority
                existing.updatedAt = now
                statesByTaskID[request.taskID] = existing
            }
            return existing
        }

        let phase: MediaDownloadTaskPhase = MediaPipelineCore.shouldRefreshSignature(
            expiresAt: request.signatureExpiresAt,
            now: now,
            policy: policy
        ) ? .signatureExpired : .queued
        let state = MediaDownloadTaskState(
            request: request,
            phase: phase,
            failureReason: phase == .signatureExpired ? .signatureExpired : nil,
            updatedAt: now
        )
        statesByTaskID[request.taskID] = state
        return state
    }

    func cancel(taskID: String, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        state.phase = .cancelled
        state.progress = nil
        state.failureReason = .cancelled
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func markRunning(taskID: String, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID], state.phase == .queued else { return nil }
        state.phase = .running
        state.progress = state.progress ?? 0
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func updateProgress(taskID: String, progress: Double, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID], state.phase == .running else { return nil }
        state.progress = min(max(progress, 0), 1)
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func complete(taskID: String, localURL: URL? = nil, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        state.phase = .completed
        state.progress = 1
        state.localURL = localURL ?? state.request.cacheFileURL(in: rootDirectory)
        state.failureReason = nil
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func fail(
        taskID: String,
        httpStatus: Int? = nil,
        backendCode: String? = nil,
        now: Date = Date()
    ) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        let reason = MediaDownloadFailureReason.normalized(httpStatus: httpStatus, backendCode: backendCode)
        state.phase = reason == .signatureExpired ? .signatureExpired : .failed
        state.failureReason = reason
        state.progress = nil
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func stateSnapshot() -> [MediaDownloadTaskState] {
        statesByTaskID.values.sorted { lhs, rhs in
            if lhs.phase != rhs.phase {
                return lhs.phase.sortRank < rhs.phase.sortRank
            }
            if lhs.request.priority != rhs.request.priority {
                return lhs.request.priority > rhs.request.priority
            }
            return lhs.request.requestedAt < rhs.request.requestedAt
        }
    }

    func runnableTaskIDs() -> [String] {
        let runningCount = statesByTaskID.values.filter { $0.phase == .running }.count
        let capacity = max(policy.maxConcurrentDownloads - runningCount, 0)
        guard capacity > 0 else { return [] }
        return stateSnapshot()
            .filter { $0.phase == .queued }
            .prefix(capacity)
            .map(\.request.taskID)
    }

    func cachedURL(for request: MediaDownloadRequest) -> URL {
        request.cacheFileURL(in: rootDirectory)
    }
}

struct MediaSignedDownloadEndpoint: Sendable {
    var url: URL
    var headers: [String: String]
    var expiresAt: Date?

    init(url: URL, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

protocol MediaSignedURLProviding: Sendable {
    func signedEndpoint(for request: MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint
}

struct MediaSignedURLProvider: MediaSignedURLProviding {
    private let resolver: @Sendable (MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint

    init(resolver: @escaping @Sendable (MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint) {
        self.resolver = resolver
    }

    func signedEndpoint(for request: MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint {
        try await resolver(request)
    }
}

struct MediaDownloadResumeMetadata: Codable, Hashable, Sendable {
    var identity: MediaResourceIdentity
    var partialFileURL: URL
    var bytesWritten: Int64
    var expectedBytes: Int64?
    var entityTag: String?
    var updatedAt: Date

    init(
        identity: MediaResourceIdentity,
        partialFileURL: URL,
        bytesWritten: Int64,
        expectedBytes: Int64? = nil,
        entityTag: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.partialFileURL = partialFileURL
        self.bytesWritten = max(bytesWritten, 0)
        self.expectedBytes = expectedBytes
        self.entityTag = entityTag
        self.updatedAt = updatedAt
    }

    var rangeHeaderValue: String? {
        guard bytesWritten > 0 else { return nil }
        return "bytes=\(bytesWritten)-"
    }
}

enum MediaDownloadExecutorEvent: Sendable {
    case started(taskID: String)
    case progress(taskID: String, fraction: Double?)
    case completed(taskID: String, localURL: URL)
    case failed(taskID: String, reason: MediaDownloadFailureReason)
    case cancelled(taskID: String)
    case signatureExpired(taskID: String)
}

protocol MediaDownloadExecuting: Sendable {
    func events(
        for request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata?
    ) async -> AsyncStream<MediaDownloadExecutorEvent>

    func cancel(taskID: String) async
}

actor MediaURLSessionDownloadExecutor: MediaDownloadExecuting {
    private let session: URLSession
    private let policy: MediaCachePolicy
    private var tasksByID: [String: Task<Void, Never>] = [:]

    init(session: URLSession = .shared, policy: MediaCachePolicy) {
        self.session = session
        self.policy = policy
    }

    func events(
        for request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata? = nil
    ) async -> AsyncStream<MediaDownloadExecutorEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(
                    request: request,
                    provider: provider,
                    cacheRoot: cacheRoot,
                    resumeMetadata: resumeMetadata,
                    continuation: continuation
                )
            }
            register(task, for: request.taskID)
            continuation.onTermination = { @Sendable _ in
                Task { await self.cancel(taskID: request.taskID) }
            }
        }
    }

    func cancel(taskID: String) async {
        tasksByID[taskID]?.cancel()
        tasksByID[taskID] = nil
    }

    private func register(_ task: Task<Void, Never>, for taskID: String) {
        tasksByID[taskID]?.cancel()
        tasksByID[taskID] = task
    }

    private func unregister(taskID: String) {
        tasksByID[taskID] = nil
    }

    private func run(
        request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata?,
        continuation: AsyncStream<MediaDownloadExecutorEvent>.Continuation
    ) async {
        let taskID = request.taskID
        defer {
            continuation.finish()
            unregister(taskID: taskID)
        }

        do {
            continuation.yield(.started(taskID: taskID))
            var refreshAttempted = false
            while true {
                let endpoint = try await provider.signedEndpoint(for: request)
                if MediaPipelineCore.shouldRefreshSignature(expiresAt: endpoint.expiresAt, policy: policy) {
                    if !refreshAttempted {
                        refreshAttempted = true
                        continue
                    }
                    continuation.yield(.signatureExpired(taskID: taskID))
                    return
                }

                var urlRequest = URLRequest(url: endpoint.url)
                for (field, value) in endpoint.headers {
                    urlRequest.setValue(value, forHTTPHeaderField: field)
                }
                if let rangeHeader = resumeMetadata?.rangeHeaderValue {
                    urlRequest.setValue(rangeHeader, forHTTPHeaderField: "Range")
                }

                let (data, response) = try await session.data(for: urlRequest)
                try Task.checkCancellation()
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.yield(.failed(taskID: taskID, reason: .unknown))
                    return
                }

                switch httpResponse.statusCode {
                case 200, 206:
                    continuation.yield(.progress(taskID: taskID, fraction: nil))
                    let localURL = try moveDownloadedData(data, for: request, cacheRoot: cacheRoot)
                    continuation.yield(.completed(taskID: taskID, localURL: localURL))
                    return
                default:
                    if !refreshAttempted,
                       MediaSignedURLRefreshPolicy.shouldRefresh(
                           statusCode: httpResponse.statusCode,
                           requestURL: endpoint.url
                       ) {
                        refreshAttempted = true
                        continue
                    }
                    let reason = MediaSignedURLRefreshPolicy.shouldRefresh(
                        statusCode: httpResponse.statusCode,
                        requestURL: endpoint.url
                    )
                        ? MediaDownloadFailureReason.signatureExpired
                        : MediaDownloadFailureReason.normalized(httpStatus: httpResponse.statusCode)
                    if reason == .signatureExpired {
                        continuation.yield(.signatureExpired(taskID: taskID))
                    } else {
                        continuation.yield(.failed(taskID: taskID, reason: reason))
                    }
                    return
                }
            }
        } catch is CancellationError {
            continuation.yield(.cancelled(taskID: taskID))
        } catch {
            continuation.yield(.failed(taskID: taskID, reason: .network))
        }
    }

    private nonisolated func moveDownloadedData(
        _ data: Data,
        for request: MediaDownloadRequest,
        cacheRoot: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let destinationURL = request.cacheFileURL(in: cacheRoot)
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("media-download-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}

private extension MediaDownloadTaskPhase {
    var sortRank: Int {
        switch self {
        case .running:
            return 0
        case .queued:
            return 1
        case .signatureExpired:
            return 2
        case .failed:
            return 3
        case .cancelled:
            return 4
        case .completed:
            return 5
        }
    }
}

enum MediaPipelineCore {
    static func identity(
        kind: MediaResourceKind,
        scope: String = "",
        fileID: String = "",
        attachmentID: String = "",
        mediaID: String = "",
        cacheKey: String = "",
        version: String = "",
        checksumSHA256: String = "",
        createdAt: String = "",
        variant: MediaCacheVariant? = nil,
        mimeType: String = "",
        sizeBytes: Int64? = nil
    ) -> MediaResourceIdentity {
        MediaResourceIdentity(
            resourceKind: kind,
            scope: scope,
            fileID: fileID,
            attachmentID: attachmentID,
            mediaID: mediaID,
            cacheKey: cacheKey,
            version: version,
            checksumSHA256: checksumSHA256,
            createdAt: createdAt,
            variant: variant,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
    }

    static func shouldRefreshSignature(expiresAt: Date?, now: Date = Date(), policy: MediaCachePolicy) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= policy.signatureRefreshLeadTime
    }

    static func cacheFileURL(
        for identity: MediaResourceIdentity,
        in rootDirectory: URL,
        preferredExtension: String = ""
    ) -> URL {
        identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
    }
}
