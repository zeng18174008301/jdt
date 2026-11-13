// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import Foundation
import Darwin

/// Filesystem mechanics only. The caller retains its original actor, scope/ABA fences and policy.
public struct MediaBlobCacheStorage: Sendable {
    private let rootDirectory: URL
    public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    public func lookupEntry(identity: MediaResourceIdentity, preferredExtension: String = "") throws -> MediaBlobCacheEntry? {
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        return try cacheEntry(identity: identity, localURL: localURL)
    }

    public func verifiedEntry(identity: MediaResourceIdentity, preferredExtension: String = "",
        integrity: MediaBlobIntegrityExpectation) throws -> MediaBlobCacheEntry? {
        guard identity.persistentCacheIdentity != nil else { return nil }
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        if FileManager.default.fileExists(atPath: localURL.path) {
            // Only protection failures escape; corruption/missing bytes still use the original caller fallback.
            try protectManagedFile(at: localURL)
        }
        do {
            let actualSize = try integrity.verify(fileAt: localURL)
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
            let entry = MediaBlobCacheEntry(identity: identity, localURL: localURL, sizeBytes: actualSize,
                createdAt: attributes?[.creationDate] as? Date, lastAccessedAt: Date())
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: localURL.path)
            return entry
        } catch {
            if FileManager.default.fileExists(atPath: localURL.path) { try? FileManager.default.removeItem(at: localURL) }
        }
        return nil
    }

    public func removeCandidates(_ candidates: [MediaBlobCacheEvictionCandidate]) throws {
        let fileManager = FileManager.default
        for candidate in candidates where fileManager.fileExists(atPath: candidate.localURL.path) {
            try fileManager.removeItem(at: candidate.localURL)
        }
    }

    public func saveDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String = ""
    ) throws -> MediaBlobCacheEntry {
        guard identity.persistentCacheIdentity != nil else {
            throw MediaCacheIdentityError.missingContentVersion
        }
        let destinationURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        try prepareManagedDirectory(for: destinationURL)
        let partURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).part")
        do {
            // Ownership transfers only after the caller's temporary file is moved into our managed directory.
            try fileManager.moveItem(at: temporaryURL, to: partURL)
            try promoteManagedFile(from: partURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
        return try cacheEntry(identity: identity, localURL: destinationURL)
            ?? MediaBlobCacheEntry(identity: identity, localURL: destinationURL, sizeBytes: 0)
    }

    public func saveVerifiedDownloadedFile(
        from temporaryURL: URL,
        identity: MediaResourceIdentity,
        preferredExtension: String,
        integrity: MediaBlobIntegrityExpectation
    ) throws -> MediaBlobCacheEntry {
        guard identity.persistentCacheIdentity != nil else {
            throw MediaCacheIdentityError.missingContentVersion
        }
        _ = try integrity.verify(fileAt: temporaryURL)
        let destinationURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try prepareManagedDirectory(for: destinationURL, indexedProtection: true)

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
            try promoteManagedFile(from: partURL, to: destinationURL)
        } catch {
            if fileManager.fileExists(atPath: partURL.path) {
                try? fileManager.removeItem(at: partURL)
            }
            throw error
        }
        let actualSize = try integrity.verify(fileAt: destinationURL)
        return MediaBlobCacheEntry(
            identity: identity,
            localURL: destinationURL,
            sizeBytes: actualSize,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
    }

    public func remove(identity: MediaResourceIdentity, preferredExtension: String = "") throws {
        let localURL = identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localURL.path) else { return }
        try fileManager.removeItem(at: localURL)
    }

    public func statistics(for resourceKind: MediaResourceKind? = nil, capacityBytes: Int64? = nil) throws -> MediaBlobCacheStatistics {
        let kinds = resourceKind.map { [$0] } ?? MediaResourceKind.allCases
        let candidates = try kinds.flatMap { try files(in: $0) }
        let capacity = capacityBytes
        return MediaBlobCacheStatistics(
            resourceKind: resourceKind,
            fileCount: candidates.count,
            totalBytes: candidates.reduce(Int64(0)) { $0 + $1.sizeBytes },
            capacityBytes: capacity
        )
    }

    public func evictionCandidates(for resourceKind: MediaResourceKind, limitBytes: Int64? = nil) throws -> [MediaBlobCacheEvictionCandidate] {
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
        var selected: [MediaBlobCacheEvictionCandidate] = []
        for candidate in candidates {
            selected.append(candidate)
            bytesToFree -= candidate.sizeBytes
            if bytesToFree <= 0 { break }
        }
        return selected
    }

    private func cacheEntry(identity: MediaResourceIdentity, localURL: URL) throws -> MediaBlobCacheEntry? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localURL.path) else { return nil }
        try protectManagedFile(at: localURL)
        guard let attributes = try? fileManager.attributesOfItem(atPath: localURL.path) else {
            return MediaBlobCacheEntry(identity: identity, localURL: localURL, sizeBytes: 0)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let createdAt = attributes[.creationDate] as? Date
        let lastAccessedAt = (attributes[.modificationDate] as? Date) ?? createdAt
        return MediaBlobCacheEntry(
            identity: identity,
            localURL: localURL,
            sizeBytes: size,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    private func files(in resourceKind: MediaResourceKind) throws -> [MediaBlobCacheEvictionCandidate] {
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
            return MediaBlobCacheEvictionCandidate(
                resourceKind: resourceKind,
                localURL: url,
                sizeBytes: size,
                lastAccessedAt: values.contentAccessDate ?? values.contentModificationDate
            )
        }
    }

    private func prepareManagedDirectory(for destination: URL, indexedProtection: Bool = false) throws {
        if indexedProtection { try Self.applyCacheDirectoryProtection(to: rootDirectory) }
        else { try Self.createManagedDirectory(at: rootDirectory, intermediate: true) }
        let directory = destination.deletingLastPathComponent()
        try Self.createManagedDirectory(at: directory, intermediate: false)
        let descriptor = try protectedDirectoryDescriptor(directory)
        close(descriptor)
        if FileManager.default.fileExists(atPath: destination.path) { try protectManagedFile(at: destination) }
    }

    private func protectedDirectoryDescriptor(_ directory: URL) throws -> Int32 {
        guard directory.deletingLastPathComponent().standardizedFileURL == rootDirectory.standardizedFileURL,
              MediaResourceKind.allCases.contains(where: { $0.cacheDirectoryName == directory.lastPathComponent }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let root = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(root) }
        try Self.protectDescriptor(root, mode: 0o700, directory: true)
        let descriptor = openat(root, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do { try Self.protectDescriptor(descriptor, mode: 0o700, directory: true) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private func protectManagedFile(at url: URL) throws {
        let directory = try protectedDirectoryDescriptor(url.deletingLastPathComponent())
        defer { close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try Self.protectDescriptor(descriptor, mode: 0o600, directory: false)
    }

    private static func protectDescriptor(_ descriptor: Int32, mode: mode_t, directory: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let expected = mode_t(directory ? S_IFDIR : S_IFREG)
        // Never follow a symlink or chmod a borrowed hard-linked file outside this cache.
        guard info.st_mode & mode_t(S_IFMT) == expected, directory || info.st_nlink == 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard fchmod(descriptor, mode) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func promoteManagedFile(from part: URL, to destination: URL) throws {
        try protectManagedFile(at: part)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part,
                backupItemName: nil, options: .usingNewMetadataOnly)
        } else { try FileManager.default.moveItem(at: part, to: destination) }
    }

    private static func createManagedDirectory(at url: URL, intermediate: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
            }
            return
        }
        guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediate,
            attributes: [.posixPermissions: 0o700])
    }

    private static func applyCacheDirectoryProtection(to root: URL) throws {
        let fileManager = FileManager.default
        try createManagedDirectory(at: root, intermediate: true)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try protectDescriptor(descriptor, mode: 0o700, directory: true)
        // Keep the existing indexed-cache protection class and backup policy.
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableRoot.setResourceValues(values)
    }
}
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
