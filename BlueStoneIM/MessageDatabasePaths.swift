import CryptoKit
import Foundation

enum LocalMessageDatabaseError: Error, Equatable, Sendable {
    case invalidScopeField(String)
    case scopeMismatch
    case staleSession
    case staleWriter
    case backupExclusionFailed
    case missingStagedAttachment
    case identityConflict
    case authorityRejected
    case databaseCorrupt
}

struct LocalMessageScope: Hashable, Sendable {
    let accountID: String
    let tenantID: String
    let appID: String
    let actorID: String
    let deviceID: String

    init(context: IMAPIContext) throws {
        accountID = try Self.required(context.accountID, field: "account_id")
        tenantID = try Self.required(context.tenantID, field: "tenant_id")
        appID = try Self.required(IMAPIContext.normalizedIOSAppID(context.appID), field: "app_id")
        actorID = try Self.required(context.imUID, field: "im_uid")
        deviceID = try Self.required(context.deviceID, field: "device_id")
    }

    init(accountID: String, tenantID: String, appID: String, actorID: String, deviceID: String) throws {
        self.accountID = try Self.required(accountID, field: "account_id")
        self.tenantID = try Self.required(tenantID, field: "tenant_id")
        self.appID = try Self.required(appID, field: "app_id")
        self.actorID = try Self.required(actorID, field: "im_uid")
        self.deviceID = try Self.required(deviceID, field: "device_id")
    }

    var canonicalData: Data {
        let pairs = [
            ("account_id", accountID),
            ("tenant_id", tenantID),
            ("app_id", appID),
            ("im_uid", actorID),
            ("device_id", deviceID)
        ]
        return (try? MediaCacheCanonicalIdentity.canonicalData(pairs)) ?? Data()
    }

    var scopeHash: String {
        SHA256.hash(data: canonicalData).map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Pre message-media-cache/1 local-message databases used a domain-prefixed,
    /// newline-delimited digest.  Keep the locator only for a one-way, exact-scope
    /// directory/database migration; it must never be used as a media identity.
    var legacyLocalMessageScopeHash: String {
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

struct MessageDatabasePaths: Sendable {
    let localMessageRoot: URL
    let legacyScopeDirectory: URL
    let scopeDirectory: URL
    let databaseURL: URL
    let stagingDirectory: URL
    let mediaRoot: URL
    let mediaScopeDirectory: URL

    init(
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

    func prepare(fileManager: FileManager = .default) throws {
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

    func isBackupExcluded() throws -> Bool {
        try localMessageRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    func stagedAttachmentURL(clientMessageID: String) -> URL {
        let digest = SHA256.hash(data: Data(clientMessageID.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
        return stagingDirectory.appendingPathComponent("\(digest).pending", isDirectory: false)
    }

    func relativeStagingPath(for url: URL) throws -> String {
        let rootPath = scopeDirectory.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    func resolveScopeRelativePath(_ path: String) throws -> URL {
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

    func resolveMediaRelativePath(_ path: String) throws -> URL {
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

    func quarantineDatabaseSidecars(fileManager: FileManager = .default) throws {
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

    func purgeExactScope(fileManager: FileManager = .default) throws {
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

    func quarantineExactScopeForPendingCleanup(fileManager: FileManager = .default) throws {
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

    func hasPendingCleanupResidue(fileManager: FileManager = .default) throws -> Bool {
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

    func purgePendingCleanupResidue(fileManager: FileManager = .default) throws {
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
