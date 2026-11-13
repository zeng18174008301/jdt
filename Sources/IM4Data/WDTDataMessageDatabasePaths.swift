// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import CryptoKit
import Foundation

public enum LocalMessageDatabaseError: Error, CustomNSError, Equatable, Sendable {
    case invalidScopeField(String)
    case scopeMismatch
    case staleSession
    case staleWriter
    case backupExclusionFailed
    case missingStagedAttachment
    case identityConflict
    case authorityRejected
    case databaseCorrupt

    public static var errorDomain: String { "BlueStoneIM.LocalMessageDatabaseError" }
    public var errorCode: Int {
        switch self {
        case .invalidScopeField: 0
        case .scopeMismatch: 1
        case .staleSession: 2
        case .staleWriter: 3
        case .backupExclusionFailed: 4
        case .missingStagedAttachment: 5
        case .identityConflict: 6
        case .authorityRejected: 7
        case .databaseCorrupt: 8
        }
    }
    public var errorUserInfo: [String: Any] { [:] }

}

public struct LocalMessageScope: Hashable, Sendable {
    public let accountID: String
    public let tenantID: String
    public let appID: String
    public let actorID: String
    public let deviceID: String


    public init(accountID: String, tenantID: String, appID: String, actorID: String, deviceID: String) throws {
        self.accountID = try Self.required(accountID, field: "account_id")
        self.tenantID = try Self.required(tenantID, field: "tenant_id")
        self.appID = try Self.required(appID, field: "app_id")
        self.actorID = try Self.required(actorID, field: "im_uid")
        self.deviceID = try Self.required(deviceID, field: "device_id")
    }

    public var canonicalData: Data {
        let pairs = [
            ("account_id", accountID),
            ("tenant_id", tenantID),
            ("app_id", appID),
            ("im_uid", actorID),
            ("device_id", deviceID)
        ]
        return (try? MediaCacheCanonicalIdentity.canonicalData(pairs)) ?? Data()
    }

    public var scopeHash: String {
        SHA256.hash(data: canonicalData).map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Pre message-media-cache/1 local-message databases used a domain-prefixed,
    /// newline-delimited digest.  Keep the locator only for a one-way, exact-scope
    /// directory/database migration; it must never be used as a media identity.
    public var legacyLocalMessageScopeHash: String {
        var data = Data("wenxintong-local-message-scope-v1\n".utf8)
        for (name, rawValue) in [
            ("account_id", accountID),
            ("tenant_id", tenantID),
            ("app_id", appID),
            ("im_uid", actorID),
            ("device_id", deviceID)
        ] {
            let value = rawValue.precomposedStringWithCanonicalMapping
            let valueData = Data(value.utf8)
            data.append(contentsOf: "\(name):\(valueData.count):".utf8)
            data.append(valueData)
            data.append(0x0A)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func required(_ rawValue: String?, field: String) throws -> String {
        let value = rawValue ?? ""
        do {
            try MediaCacheCanonicalIdentity.validateRequired(value, field: field)
        } catch {
            throw LocalMessageDatabaseError.invalidScopeField(field)
        }
        return value
    }
}

public struct MessageDatabasePaths: Sendable {
    public let localMessageRoot: URL
    public let legacyScopeDirectory: URL
    public let scopeDirectory: URL
    public let databaseURL: URL
    public let stagingDirectory: URL
    public let mediaRoot: URL
    public let mediaScopeDirectory: URL

    public init(
        scope: LocalMessageScope,
        applicationSupportBase: URL? = nil,
        cachesBase: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let supportBase = try applicationSupportBase
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let cacheBase = try cachesBase
            ?? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        localMessageRoot = supportBase
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("LocalMessage", isDirectory: true)
        legacyScopeDirectory = localMessageRoot.appendingPathComponent(
            scope.legacyLocalMessageScopeHash,
            isDirectory: true
        )
        scopeDirectory = localMessageRoot.appendingPathComponent(scope.scopeHash, isDirectory: true)
        databaseURL = scopeDirectory.appendingPathComponent("messages.sqlite", isDirectory: false)
        stagingDirectory = scopeDirectory.appendingPathComponent("outbox-staging", isDirectory: true)
        mediaRoot = cacheBase
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        mediaScopeDirectory = mediaRoot.appendingPathComponent(scope.scopeHash, isDirectory: true)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: localMessageRoot, withIntermediateDirectories: true)
        try excludeFromBackupAndReadBack(localMessageRoot)
        if legacyScopeDirectory.standardizedFileURL != scopeDirectory.standardizedFileURL,
           fileManager.fileExists(atPath: legacyScopeDirectory.path),
           !fileManager.fileExists(atPath: scopeDirectory.path) {
            try fileManager.moveItem(at: legacyScopeDirectory, to: scopeDirectory)
        }
        try fileManager.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        try excludeFromBackupAndReadBack(scopeDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try excludeFromBackupAndReadBack(stagingDirectory)
        try fileManager.createDirectory(at: mediaScopeDirectory, withIntermediateDirectories: true)
        try excludeFromBackupAndReadBack(mediaRoot)
        try excludeFromBackupAndReadBack(mediaScopeDirectory)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mediaRoot.path
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mediaScopeDirectory.path
        )
    }

    public func isBackupExcluded() throws -> Bool {
        try localMessageRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    public func stagedAttachmentURL(clientMessageID: String) -> URL {
        let digest = SHA256.hash(data: Data(clientMessageID.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
        return stagingDirectory.appendingPathComponent("\(digest).pending", isDirectory: false)
    }

    public func relativeStagingPath(for url: URL) throws -> String {
        let rootPath = scopeDirectory.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    public func resolveScopeRelativePath(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        let resolved = scopeDirectory.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        guard resolved.path.hasPrefix(scopeDirectory.standardizedFileURL.path + "/") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return resolved
    }

    public func resolveMediaRelativePath(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        let resolved = mediaScopeDirectory.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        guard resolved.path.hasPrefix(mediaScopeDirectory.standardizedFileURL.path + "/") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return resolved
    }

    // Recovery evidence remains in this exact scope until explicit scope cleanup.
    // Do not read/follow symlinks or treat an unrelated directory as database quarantine.
    func containsQuarantinedDatabase(fileManager: FileManager) throws -> Bool {
        let entries = try fileManager.contentsOfDirectory(at: scopeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for directory in entries where directory.lastPathComponent.hasPrefix("corrupt-") {
            let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { continue }
            let archived = directory.appendingPathComponent(databaseURL.lastPathComponent)
            guard fileManager.fileExists(atPath: archived.path) else { continue }
            let values = try archived.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true { return true }
        }
        return false
    }

    public func quarantineDatabaseSidecars(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: scopeDirectory.path) else { return }
        let quarantine = scopeDirectory.appendingPathComponent(
            "corrupt-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: quarantine.appendingPathComponent(source.lastPathComponent))
        }
    }

    public func purgeExactScope(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: scopeDirectory.path) {
            try fileManager.removeItem(at: scopeDirectory)
        }
        if legacyScopeDirectory.standardizedFileURL != scopeDirectory.standardizedFileURL,
           fileManager.fileExists(atPath: legacyScopeDirectory.path) {
            try fileManager.removeItem(at: legacyScopeDirectory)
        }
        if fileManager.fileExists(atPath: mediaScopeDirectory.path) {
            try fileManager.removeItem(at: mediaScopeDirectory)
        }
        try purgePendingCleanupResidue(fileManager: fileManager)
    }

    public func quarantineExactScopeForPendingCleanup(fileManager: FileManager = .default) throws {
        let suffix = UUID().uuidString.lowercased()
        for source in exactScopeDirectories {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = source.deletingLastPathComponent().appendingPathComponent(
                ".\(source.lastPathComponent).pending-cleanup-\(suffix)",
                isDirectory: true
            )
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    public func hasPendingCleanupResidue(fileManager: FileManager = .default) throws -> Bool {
        for source in exactScopeDirectories {
            let parent = source.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) else { continue }
            let prefix = ".\(source.lastPathComponent).pending-cleanup-"
            if try fileManager.contentsOfDirectory(atPath: parent.path).contains(where: { $0.hasPrefix(prefix) }) {
                return true
            }
        }
        return false
    }

    public func purgePendingCleanupResidue(fileManager: FileManager = .default) throws {
        for source in exactScopeDirectories {
            let parent = source.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) else { continue }
            let prefix = ".\(source.lastPathComponent).pending-cleanup-"
            for name in try fileManager.contentsOfDirectory(atPath: parent.path) where name.hasPrefix(prefix) {
                try fileManager.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    private var exactScopeDirectories: [URL] {
        var seen = Set<String>()
        return [scopeDirectory, legacyScopeDirectory, mediaScopeDirectory].filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    private func excludeFromBackupAndReadBack(_ url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
        let readBack = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard readBack.isExcludedFromBackup == true else {
            throw LocalMessageDatabaseError.backupExclusionFailed
        }
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

// WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_BEGIN
public final class MessagePersistenceCleanupTombstoneStore: @unchecked Sendable {
    private struct Locator {
        let scopeHash: String
        let legacyScopeHash: String
    }

    private let applicationSupportBase: URL?
    private let cachesBase: URL?
    private let forcePersistenceFailure: Bool

    public init(applicationSupportBase: URL?, cachesBase: URL?, forcePersistenceFailure: Bool) {
        self.applicationSupportBase = applicationSupportBase
        self.cachesBase = cachesBase
        self.forcePersistenceFailure = forcePersistenceFailure
    }

    public func persist(
        scopeHash: String,
        legacyScopeHash: String,
        fileManager: FileManager = .default
    ) throws {
        if forcePersistenceFailure {
            throw LocalMessageDatabaseError.backupExclusionFailed
        }
        try validateHash(scopeHash)
        try validateHash(legacyScopeHash)
        let markerURL = try markerURL(scopeHash: scopeHash, fileManager: fileManager)
        let root = markerURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let marker = [
            "message-media-cache/1",
            "scope_hash=\(scopeHash)",
            "legacy_scope_hash=\(legacyScopeHash)",
            ""
        ].joined(separator: "\n")
        try Data(marker.utf8).write(to: markerURL, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: markerURL.path
        )
    }

    /// Runs synchronously when the coordinator is created, before any session is
    /// restored. Markers contain only hashed locators, so logout cleanup does not
    /// depend on recovering the five raw scope fields in a later process.
    public func drainPendingCleanup(fileManager: FileManager = .default) throws -> Set<String> {
        let roots = try storageRoots(fileManager: fileManager)
        var blockedScopeHashes = Set<String>()

        if fileManager.fileExists(atPath: roots.marker.path) {
            for name in try fileManager.contentsOfDirectory(atPath: roots.marker.path) {
                guard name.hasSuffix(".pending") else { continue }
                let scopeHash = String(name.dropLast(".pending".count))
                guard (try? validateHash(scopeHash)) != nil else { continue }
                let markerURL = roots.marker.appendingPathComponent(name, isDirectory: false)
                do {
                    let locator = try readLocator(at: markerURL, expectedScopeHash: scopeHash)
                    try purge(locator: locator, roots: roots, fileManager: fileManager)
                    try fileManager.removeItem(at: markerURL)
                } catch {
                    blockedScopeHashes.insert(scopeHash)
                }
            }
        }

        for root in [roots.localMessage, roots.media] {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            for name in try fileManager.contentsOfDirectory(atPath: root.path) {
                guard let hash = pendingResidueHash(name) else { continue }
                do {
                    try fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
                } catch {
                    blockedScopeHashes.insert(hash)
                }
            }
        }
        return blockedScopeHashes
    }

    public func contains(scopeHash: String, fileManager: FileManager = .default) throws -> Bool {
        fileManager.fileExists(atPath: try markerURL(scopeHash: scopeHash, fileManager: fileManager).path)
    }

    public func clear(scopeHash: String, fileManager: FileManager = .default) throws {
        let markerURL = try markerURL(scopeHash: scopeHash, fileManager: fileManager)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    private func markerURL(scopeHash: String, fileManager: FileManager) throws -> URL {
        try validateHash(scopeHash)
        return try storageRoots(fileManager: fileManager).marker
            .appendingPathComponent("\(scopeHash).pending", isDirectory: false)
    }

    private func storageRoots(fileManager: FileManager) throws -> (
        marker: URL,
        localMessage: URL,
        media: URL
    ) {
        let supportBase = try applicationSupportBase
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let cacheBase = try cachesBase
            ?? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let supportProductRoot = supportBase.appendingPathComponent("BlueStoneIM", isDirectory: true)
        return (
            marker: supportProductRoot.appendingPathComponent(
                "LocalMessagePendingCleanup",
                isDirectory: true
            ),
            localMessage: supportProductRoot.appendingPathComponent("LocalMessage", isDirectory: true),
            media: cacheBase
                .appendingPathComponent("BlueStoneIM", isDirectory: true)
                .appendingPathComponent("Media", isDirectory: true)
        )
    }

    private func readLocator(at markerURL: URL, expectedScopeHash: String) throws -> Locator {
        let contents = try String(contentsOf: markerURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 3,
              lines[0] == "message-media-cache/1",
              lines[1].hasPrefix("scope_hash="),
              lines[2].hasPrefix("legacy_scope_hash=") else {
            throw LocalMessageDatabaseError.invalidScopeField("cleanup_marker")
        }
        let scopeHash = String(lines[1].dropFirst("scope_hash=".count))
        let legacyScopeHash = String(lines[2].dropFirst("legacy_scope_hash=".count))
        try validateHash(scopeHash)
        try validateHash(legacyScopeHash)
        guard scopeHash == expectedScopeHash else {
            throw LocalMessageDatabaseError.scopeMismatch
        }
        return Locator(scopeHash: scopeHash, legacyScopeHash: legacyScopeHash)
    }

    private func purge(
        locator: Locator,
        roots: (marker: URL, localMessage: URL, media: URL),
        fileManager: FileManager
    ) throws {
        var seen = Set<String>()
        for (root, hash) in [
            (roots.localMessage, locator.scopeHash),
            (roots.localMessage, locator.legacyScopeHash),
            (roots.media, locator.scopeHash)
        ] {
            let exactURL = root.appendingPathComponent(hash, isDirectory: true)
            if seen.insert(exactURL.standardizedFileURL.path).inserted,
               fileManager.fileExists(atPath: exactURL.path) {
                try fileManager.removeItem(at: exactURL)
            }
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let prefix = ".\(hash).pending-cleanup-"
            for name in try fileManager.contentsOfDirectory(atPath: root.path)
                where name.hasPrefix(prefix) && pendingResidueHash(name) == hash {
                try fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    private func pendingResidueHash(_ name: String) -> String? {
        guard name.first == ".",
              let range = name.range(of: ".pending-cleanup-") else { return nil }
        let hash = String(name[name.index(after: name.startIndex)..<range.lowerBound])
        let suffix = String(name[range.upperBound...])
        guard (try? validateHash(hash)) != nil,
              UUID(uuidString: suffix) != nil else { return nil }
        return hash
    }

    private func validateHash(_ value: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw LocalMessageDatabaseError.invalidScopeField("scope_hash")
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
// WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_END
