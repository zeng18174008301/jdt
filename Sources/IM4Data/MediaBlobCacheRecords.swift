// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import Foundation

public struct MediaBlobCacheEntry: Codable, Hashable, Sendable {
    public var identity: MediaResourceIdentity
    public var localURL: URL
    public var sizeBytes: Int64
    public var createdAt: Date?
    public var lastAccessedAt: Date?

    public init(
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

public struct MediaBlobCacheStatistics: Codable, Hashable, Sendable {
    public var resourceKind: MediaResourceKind?
    public var fileCount: Int
    public var totalBytes: Int64
    public var capacityBytes: Int64?
    public var generatedAt: Date

    public init(
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

public struct MediaBlobCacheEvictionCandidate: Codable, Hashable, Sendable {
    public var resourceKind: MediaResourceKind
    public var localURL: URL
    public var sizeBytes: Int64
    public var lastAccessedAt: Date?

    public init(
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

public struct MediaBlobFileRemovalOutcome: Sendable {
    public let didComplete: Bool
    public let fileExisted: Bool
    public init(didComplete: Bool, fileExisted: Bool) {
        self.didComplete = didComplete; self.fileExisted = fileExisted
    }
}
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
