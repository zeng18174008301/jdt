// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import CryptoKit
import Foundation
import IM4Data // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
import Darwin
// WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END

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

typealias MediaCacheEntry = IM4Data.MediaBlobCacheEntry

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

typealias MediaCacheStatistics = IM4Data.MediaBlobCacheStatistics

typealias MediaCacheEvictionCandidate = IM4Data.MediaBlobCacheEvictionCandidate

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

    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
#if DEBUG
    func currentGeneration(for scopeHash: String) -> UInt64? {
        currentGenerationByScopeHash[scopeHash]
    }
#endif
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END

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

// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
actor MediaLayeredCacheStore: MediaLayeredCacheManaging {
    private let blobStorage: IM4Data.MediaBlobCacheStorage
    private let policiesByKind: [MediaResourceKind: MediaCachePolicy]
    private var activeSessionGeneration: UInt64?

    init(
        rootDirectory: URL,
        policiesByKind: [MediaResourceKind: MediaCachePolicy] = Dictionary(
            uniqueKeysWithValues: MediaResourceKind.allCases.map { ($0, MediaCachePolicy.defaultPolicy(for: $0)) }
        )
    ) {
        self.blobStorage = IM4Data.MediaBlobCacheStorage(rootDirectory: rootDirectory)
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
        // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN
        do {
            if let entry = try blobStorage.lookupEntry(identity: identity, preferredExtension: preferredExtension) {
                return MediaCacheLookupResult(identity: identity, state: .downloaded(localURL: entry.localURL), entry: entry)
            }
        } catch {
            return MediaCacheLookupResult(identity: identity, state: .failed(message: error.localizedDescription))
        }
        // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
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
        sessionGeneration: UInt64,
        isAdmitted: @Sendable () -> Bool = { true } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    ) async -> MediaCacheLookupResult {
        guard activeSessionGeneration == sessionGeneration, isAdmitted() else { // WDT_IOS1_STICKER_MANIFEST_R2_20261111
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
        do {
            if let entry = try blobStorage.verifiedEntry(identity: identity, preferredExtension: preferredExtension,
                integrity: integrity.blobExpectation) {
                return MediaCacheLookupResult(identity: identity, state: .downloaded(localURL: entry.localURL), entry: entry)
            }
        } catch {
            return MediaCacheLookupResult(identity: identity, state: .failed(message: error.localizedDescription))
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
        try blobStorage.saveDownloadedFile(from: temporaryURL, identity: identity, preferredExtension: preferredExtension)
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
        sessionGeneration: UInt64,
        isAdmitted: @Sendable () -> Bool = { true } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    ) async throws -> MediaCacheEntry {
        guard activeSessionGeneration == sessionGeneration, isAdmitted() else { // WDT_IOS1_STICKER_MANIFEST_R2_20261111
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
        do {
            return try blobStorage.saveVerifiedDownloadedFile(from: temporaryURL, identity: identity,
                preferredExtension: preferredExtension, integrity: integrity.blobExpectation)
        } catch let failure as IM4Data.MediaBlobIntegrityError {
            throw MediaFileIntegrityError.blobFailure(failure)
        }
    }

    func remove(identity: MediaResourceIdentity, preferredExtension: String = "") async throws {
        try blobStorage.remove(identity: identity, preferredExtension: preferredExtension)
    }

    func statistics(for resourceKind: MediaResourceKind? = nil) async throws -> MediaCacheStatistics {
        try blobStorage.statistics(for: resourceKind,
            capacityBytes: resourceKind.flatMap { policiesByKind[$0]?.diskCapacityBytes })
    }

    func evictionCandidates(for resourceKind: MediaResourceKind, limitBytes: Int64? = nil) async throws -> [MediaCacheEvictionCandidate] {
        try blobStorage.evictionCandidates(for: resourceKind, limitBytes: limitBytes)
    }

    func prune(resourceKind: MediaResourceKind, keepingUnder limitBytes: Int64? = nil) async throws -> MediaCacheStatistics {
        let targetLimit = limitBytes ?? policiesByKind[resourceKind]?.diskCapacityBytes
        let candidates = try await evictionCandidates(for: resourceKind, limitBytes: targetLimit)
        try blobStorage.removeCandidates(candidates)
        return try await statistics(for: resourceKind)
    }

    // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN




    // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_BEGIN













    // WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110_END
}
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
