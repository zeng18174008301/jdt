// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import CryptoKit
import Foundation



public enum MediaCacheIdentityError: Error, CustomNSError, Equatable, Sendable {
    case invalidRequiredField(String)
    case invalidScopeHash
    case missingStableResourceID
    case missingContentVersion

    public static var errorDomain: String { "BlueStoneIM.MediaCacheIdentityError" }
    public var errorCode: Int {
        switch self {
        case .invalidRequiredField: 0
        case .invalidScopeHash: 1
        case .missingStableResourceID: 2
        case .missingContentVersion: 3
        }
    }
    public var errorUserInfo: [String: Any] { [:] }

}

public enum MediaCacheResourceIDKind: String, Codable, CaseIterable, Sendable {
    case fileID = "file_id"
    case attachmentID = "attachment_id"
    case mediaID = "media_id"
    case cacheKey = "cache_key"
}

public enum MediaCacheContentVersionKind: String, Codable, CaseIterable, Sendable {
    case checksumSHA256 = "checksum_sha256"
    case version
    case sizeCreatedAt = "size_created_at"
}

public enum MediaCacheVariant: String, Codable, CaseIterable, Sendable {
    case thumbnail320 = "thumbnail:320"
    case thumbnail640 = "thumbnail:640"
    case preview1600 = "preview:1600"
    case original
    case videoPoster = "video_poster"
}

public enum MediaCacheAuthorityState: String, Codable, CaseIterable, Sendable {
    case active
    case processing
    case authorizationStale = "authorization_stale"
    case recalled
    case deleted
    case forbidden
    case expiredBusiness = "expired_business"

    public var permitsOpen: Bool { self == .active }
}

public enum MediaCacheLocalState: String, Codable, CaseIterable, Sendable {
    case none
    case partial
    case verifiedCached = "verified_cached"
    case evicted
    case corrupt
}

public enum MediaCacheTransferState: String, Codable, CaseIterable, Sendable {
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

public enum IOSMediaOfflinePolicy: String, Codable, Sendable {
    case bounded
    case deny

    public var ttl: TimeInterval {
        switch self {
        case .bounded: 86_400
        case .deny: 0
        }
    }
}

public struct IOSMediaCacheAuthorityRecord: Equatable, Sendable {
    public let scopeHash: String
    public let messageID: String
    public let attachmentID: String
    public let identity: MediaResourceIdentity
    public let mimeType: String
    public let sizeBytes: Int64
    public let checksumSHA256: String?
    public let state: MediaCacheAuthorityState
    public let authorityVersion: String
    public let lastAuthorizedAt: Date?
    public let offlineAccessUntil: Date?
    public let createdAt: Date?
    public let updatedAt: Date

    public func permitsOpen(now: Date, allowOffline: Bool) -> Bool {
        guard state.permitsOpen else { return false }
        guard allowOffline else { return true }
        guard let offlineAccessUntil else { return false }
        return offlineAccessUntil >= now
    }

    public init(scopeHash: String, messageID: String, attachmentID: String, identity: MediaResourceIdentity, mimeType: String, sizeBytes: Int64, checksumSHA256: String?, state: MediaCacheAuthorityState, authorityVersion: String, lastAuthorizedAt: Date?, offlineAccessUntil: Date?, createdAt: Date?, updatedAt: Date) {
        self.scopeHash = scopeHash
        self.messageID = messageID
        self.attachmentID = attachmentID
        self.identity = identity
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksumSHA256 = checksumSHA256
        self.state = state
        self.authorityVersion = authorityVersion
        self.lastAuthorizedAt = lastAuthorizedAt
        self.offlineAccessUntil = offlineAccessUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct IOSMediaCacheEntryRecord: Equatable, Sendable {
    public let scopeHash: String
    public let cacheIdentity: String
    public let attachmentID: String
    public let variant: MediaCacheVariant
    public let relativePath: String
    public let localState: MediaCacheLocalState
    public let sizeBytes: Int64
    public let verifiedSizeBytes: Int64?
    public let verifiedChecksumSHA256: String?
    public let pinnedByUser: Bool
    public let protectionReason: String
    public let createdAt: Date
    public let lastAccessedAt: Date

    public init(scopeHash: String, cacheIdentity: String, attachmentID: String, variant: MediaCacheVariant, relativePath: String, localState: MediaCacheLocalState, sizeBytes: Int64, verifiedSizeBytes: Int64?, verifiedChecksumSHA256: String?, pinnedByUser: Bool, protectionReason: String, createdAt: Date, lastAccessedAt: Date) {
        self.scopeHash = scopeHash
        self.cacheIdentity = cacheIdentity
        self.attachmentID = attachmentID
        self.variant = variant
        self.relativePath = relativePath
        self.localState = localState
        self.sizeBytes = sizeBytes
        self.verifiedSizeBytes = verifiedSizeBytes
        self.verifiedChecksumSHA256 = verifiedChecksumSHA256
        self.pinnedByUser = pinnedByUser
        self.protectionReason = protectionReason
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

public struct IOSMediaCacheIndexedLookup: Sendable {
    public let authority: IOSMediaCacheAuthorityRecord
    public let entry: IOSMediaCacheEntryRecord

    public init(authority: IOSMediaCacheAuthorityRecord, entry: IOSMediaCacheEntryRecord) {
        self.authority = authority
        self.entry = entry
    }
}

public struct IOSMediaCacheStatistics: Equatable, Sendable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let verifiedBytes: Int64
    public let corruptCount: Int

    public init(fileCount: Int, totalBytes: Int64, verifiedBytes: Int64, corruptCount: Int) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.verifiedBytes = verifiedBytes
        self.corruptCount = corruptCount
    }
}

public struct IOSMediaCachePruneCandidate: Equatable, Sendable {
    public let cacheIdentity: String
    public let relativePath: String
    public let sizeBytes: Int64

    public init(cacheIdentity: String, relativePath: String, sizeBytes: Int64) {
        self.cacheIdentity = cacheIdentity
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
    }
}

public enum MediaCacheCanonicalIdentity {
    public static func canonicalData(_ orderedPairs: [(String, String)]) throws -> Data {
        var components: [String] = []
        components.reserveCapacity(orderedPairs.count)
        for (key, value) in orderedPairs {
            try validateRequired(key, field: "canonical_key")
            try validateRequired(value, field: key)
            components.append("\(key.utf8.count):\(key):\(value.utf8.count):\(value)")
        }
        return Data(components.joined(separator: "|").utf8)
    }

    public static func digest(_ orderedPairs: [(String, String)]) throws -> String {
        SHA256.hash(data: try canonicalData(orderedPairs))
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }

    public static func validateRequired(_ value: String, field: String) throws {
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

public enum MediaResourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case thumbnail
    case preview
    case original

    public var cacheDirectoryName: String {
        switch self {
        case .thumbnail: "thumbnails"
        case .preview: "previews"
        case .original: "originals"
        }
    }

    public var displayName: String {
        switch self {
        case .thumbnail: "缩略图"
        case .preview: "预览"
        case .original: "原文件"
        }
    }
}

public struct MediaResourceIdentity: Codable, Hashable, Sendable {
    public var resourceKind: MediaResourceKind
    public var scope: String
    public var fileID: String
    public var attachmentID: String
    public var mediaID: String
    public var cacheKey: String
    public var version: String
    public var checksumSHA256: String
    public var createdAt: String
    public var variant: MediaCacheVariant
    public var mimeType: String
    public var sizeBytes: Int64?

    public init(
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

    public var primaryStableID: String {
        [fileID, attachmentID, mediaID, cacheKey]
            .first(where: { !$0.isEmpty }) ?? ""
    }

    public var hasStableID: Bool {
        !primaryStableID.isEmpty
    }

    public var resourceIDKind: MediaCacheResourceIDKind? {
        if !fileID.isEmpty { return .fileID }
        if !attachmentID.isEmpty { return .attachmentID }
        if !mediaID.isEmpty { return .mediaID }
        if !cacheKey.isEmpty, Self.isPersistentCacheKey(cacheKey) { return .cacheKey }
        return nil
    }

    public var contentVersionKindAndValue: (MediaCacheContentVersionKind, String)? {
        if !checksumSHA256.isEmpty {
            guard MessageAttachmentChecksum.normalizedSHA256(checksumSHA256) == checksumSHA256 else {
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

    public var persistentCacheIdentity: String? {
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

    public var stableCacheKey: String {
        persistentCacheIdentity ?? "invalid-persistent-media-identity"
    }

    public func cacheFileURL(in rootDirectory: URL, preferredExtension: String = "") -> URL {
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

    public static func stableHash(_ value: String) -> String {
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
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
