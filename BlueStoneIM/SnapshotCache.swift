import Foundation
import CryptoKit

protocol MessageStore: Sendable {
    var schemaVersion: Int { get }

    /// Builds a stable, normalized cache scope from the account/tenant/user/app/device identity tuple.
    func scopeKey(for context: IMAPIContext) -> String
    /// Loads a cached snapshot only when the stored schema, scope, age, and content are valid.
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult?
    /// Schedules a write and rejects snapshots whose embedded scope does not match the target scope.
    @discardableResult
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool
    /// Writes immediately and rejects snapshots whose embedded scope does not match the target scope.
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool
    /// Removes only the requested scope.
    func remove(scope: String)
    /// Removes every snapshot owned by this store implementation.
    func removeAll()
}

final class SnapshotCache: MessageStore {
    static let defaultSchemaVersion = 1
    static let defaultMaxAge: TimeInterval = 24 * 60 * 60

    let schemaVersion: Int

    private let maxAge: TimeInterval
    private let directoryOverride: URL?

    init(
        schemaVersion: Int = SnapshotCache.defaultSchemaVersion,
        maxAge: TimeInterval = SnapshotCache.defaultMaxAge,
        directoryURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.maxAge = maxAge
        directoryOverride = directoryURL
    }

    func scopeKey(for context: IMAPIContext) -> String {
        [
            "v2",
            "account=\(Self.scopeComponent(context.accountID))",
            "tenant=\(Self.scopeComponent(context.tenantID))",
            "im=\(Self.scopeComponent(context.imUID))",
            "app=\(Self.scopeComponent(context.appID))",
            "device=\(Self.scopeComponent(context.deviceID))"
        ].joined(separator: "|")
    }

    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? {
        guard let url = cacheFileURL(for: scope) else { return nil }
        let expectedSchemaVersion = schemaVersion
        let expectedMaxAge = maxAge
        return await Self.load(
            from: url,
            scope: scope,
            schemaVersion: expectedSchemaVersion,
            maxAge: expectedMaxAge
        )
    }

    @discardableResult
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool {
        guard let request = makeWriteRequest(snapshot, scope: scope) else { return false }
        SnapshotCacheWriter.schedule(request)
        return true
    }

    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool {
        guard let request = makeWriteRequest(snapshot, scope: scope) else { return false }
        return await SnapshotCacheWriter.writeNow(request)
    }

    func remove(scope: String) {
        guard let url = cacheFileURL(for: scope) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() {
        guard let directory = cacheDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func load(from url: URL, scope: String, schemaVersion: Int, maxAge: TimeInterval) async -> CachedRemoteSnapshotLoadResult? {
        await Task.detached(priority: .userInitiated) {
            let readStart = CFAbsoluteTimeGetCurrent()
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            let readMs = Int((CFAbsoluteTimeGetCurrent() - readStart) * 1000)
            let decodeStart = CFAbsoluteTimeGetCurrent()
            guard let snapshot = try? JSONDecoder().decode(CachedRemoteSnapshot.self, from: data),
                  snapshot.schemaVersion == schemaVersion,
                  snapshot.scope == scope,
                  Date().timeIntervalSince1970 - snapshot.createdAt < maxAge,
                  !snapshot.conversations.isEmpty else {
                return nil
            }
            let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
            let mapStart = CFAbsoluteTimeGetCurrent()
            let conversations = snapshot.conversations
                .map(\.model)
                .sorted(by: cachedConversationListPrecedes)
            let mapSortMs = Int((CFAbsoluteTimeGetCurrent() - mapStart) * 1000)
            return CachedRemoteSnapshotLoadResult(
                conversations: conversations,
                readMs: readMs,
                decodeMs: decodeMs,
                mapSortMs: mapSortMs
            )
        }.value
    }

    private static func cachedConversationListPrecedes(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        let lhsTimestamp = lhs.sortTimestamp
        let rhsTimestamp = rhs.sortTimestamp
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp }
        return lhs.id < rhs.id
    }

    private func makeWriteRequest(_ snapshot: CachedRemoteSnapshot, scope: String) -> SnapshotCacheWriteRequest? {
        guard snapshot.scope == scope,
              let directory = cacheDirectoryURL(),
              let url = cacheFileURL(for: scope) else {
            return nil
        }
        return SnapshotCacheWriteRequest(snapshot: snapshot, directory: directory, url: url)
    }

    private static func scopeComponent(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return Data(trimmed.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func cacheDirectoryURL() -> URL? {
        if let directoryOverride {
            return directoryOverride
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlueStoneIMRemoteSnapshots", isDirectory: true)
    }

    private func cacheFileURL(for scope: String) -> URL? {
        guard let directory = cacheDirectoryURL() else { return nil }
        let digest = SHA256.hash(data: Data(scope.utf8))
        let fileName = digest
            .map { String(format: "%02x", Int($0)) }
            .joined()
        return directory.appendingPathComponent("\(fileName).json")
    }
}

private enum SnapshotCacheWriter {
    static func schedule(_ request: SnapshotCacheWriteRequest) {
        Task.detached(priority: .background) {
            _ = write(request)
        }
    }

    static func writeNow(_ request: SnapshotCacheWriteRequest) async -> Bool {
        await Task.detached(priority: .background) {
            write(request)
        }.value
    }

    private static func write(_ request: SnapshotCacheWriteRequest) -> Bool {
        do {
            try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(request.snapshot)
            try data.write(to: request.url, options: [.atomic])
            return true
        } catch {
            let redactedError = redactedSensitiveLogText(String(describing: error))
            print("[JHT Perf] cached_snapshot_write_failed error=\(redactedError)")
            return false
        }
    }

    private static func redactedSensitiveLogText(_ raw: String) -> String {
        var value = raw
        let jsonPatterns = [
            #"(?i)("(?:password|token|access_token|authorization|secret|captcha_code|slide_token|pass_token|phone|id_card_no)"\s*:\s*")[^"]+(")"#
        ]
        for pattern in jsonPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1redacted$2",
                options: .regularExpression
            )
        }
        let queryPatterns = [
            #"(?i)(token|access_token|authorization|signature|x-oss-signature|credential|expires|captcha|captcha_code|slide_token|pass_token|password|secret|phone|id_card_no)=([^\s&]+)"#
        ]
        for pattern in queryPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1=redacted",
                options: .regularExpression
            )
        }
        return value
    }
}

private struct SnapshotCacheWriteRequest: Sendable {
    let snapshot: CachedRemoteSnapshot
    let directory: URL
    let url: URL
}
