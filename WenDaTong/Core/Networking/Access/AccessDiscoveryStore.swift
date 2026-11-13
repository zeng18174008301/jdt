import CryptoKit
import Foundation
import Network

struct AccessDiscoveryEndpointHealth: Codable, Equatable, Sendable {
    var failureCount: Int = 0
    var quickDisconnectCount: Int = 0
    var cooldownUntil: TimeInterval?
    var lastConnectedAt: TimeInterval?
    var lastStableAt: TimeInterval?

    func isCoolingDown(at now: TimeInterval) -> Bool {
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }
}

struct AccessDiscoveryCachedSnapshot: Codable, Equatable, Sendable {
    var response: RemoteAccessDiscoveryResponse
    var fetchedAt: TimeInterval
    var expiresAt: TimeInterval
    var staleUntil: TimeInterval
    var health: [String: AccessDiscoveryEndpointHealth]
}

struct AccessDiscoveryTrustWatermark: Codable, Equatable, Sendable {
    let recoveryGeneration: UInt64
    let currentFencingGeneration: UInt64
    let keyStateHash: String
    let configGeneration: UInt64
    let contentHash: String
    let configVersion: String
    var publicationRevision: UInt64? = nil
    var publicationID: String? = nil
    var profileFingerprint: String? = nil
    var publicationStatus: String? = nil
    var signingKeyID: String? = nil
    var keysetRevision: UInt64? = nil

    init(
        recoveryGeneration: UInt64,
        currentFencingGeneration: UInt64,
        keyStateHash: String,
        configGeneration: UInt64,
        contentHash: String,
        configVersion: String,
        publicationRevision: UInt64? = nil,
        publicationID: String? = nil,
        profileFingerprint: String? = nil,
        publicationStatus: String? = nil,
        signingKeyID: String? = nil,
        keysetRevision: UInt64? = nil
    ) {
        self.recoveryGeneration = recoveryGeneration
        self.currentFencingGeneration = currentFencingGeneration
        self.keyStateHash = keyStateHash
        self.configGeneration = configGeneration
        self.contentHash = contentHash
        self.configVersion = configVersion
        self.publicationRevision = publicationRevision
        self.publicationID = publicationID
        self.profileFingerprint = profileFingerprint
        self.publicationStatus = publicationStatus
        self.signingKeyID = signingKeyID
        self.keysetRevision = keysetRevision
    }

    init?(response: RemoteAccessDiscoveryResponse) {
        guard let trust = response.trust,
              trust.recoveryGeneration > 0,
              trust.fencingGeneration > 0,
              trust.generation > 0,
              trust.keyStateHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              trust.contentHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !response.configVersion.isEmpty else {
            return nil
        }
        self.init(
            recoveryGeneration: trust.recoveryGeneration,
            currentFencingGeneration: trust.fencingGeneration,
            keyStateHash: trust.keyStateHash,
            configGeneration: trust.generation,
            contentHash: trust.contentHash,
            configVersion: response.configVersion,
            publicationRevision: response.publicationRevision,
            publicationID: response.publicationID,
            profileFingerprint: response.profileFingerprint,
            publicationStatus: response.publicationStatus,
            signingKeyID: trust.keyID,
            keysetRevision: response.keysetRevision
        )
    }

}

func accessDiscoveryTrustWatermarkTransitionAllowed(
    previous: AccessDiscoveryTrustWatermark?,
    candidate: AccessDiscoveryTrustWatermark
) -> Bool {
    guard let previous else { return true }
    if let candidateRevision = candidate.publicationRevision {
        guard let previousRevision = previous.publicationRevision,
              let candidateKeysetRevision = candidate.keysetRevision,
              let previousKeysetRevision = previous.keysetRevision,
              candidateRevision >= previousRevision,
              candidateKeysetRevision >= previousKeysetRevision,
              candidate.recoveryGeneration >= previous.recoveryGeneration,
              candidate.currentFencingGeneration >= previous.currentFencingGeneration else {
            return false
        }
        if candidate.recoveryGeneration == previous.recoveryGeneration,
           candidate.keyStateHash != previous.keyStateHash {
            return false
        }
        if candidate.recoveryGeneration > previous.recoveryGeneration,
           candidate.keyStateHash == previous.keyStateHash {
            return false
        }
        if candidateRevision == previousRevision {
            return candidate.publicationID == previous.publicationID
                && candidate.profileFingerprint == previous.profileFingerprint
                && candidate.publicationStatus == previous.publicationStatus
                && candidate.contentHash == previous.contentHash
                && candidateKeysetRevision == previousKeysetRevision
        }
        return true
    }
    if previous.publicationRevision != nil { return false }
    if candidate.recoveryGeneration < previous.recoveryGeneration ||
        candidate.currentFencingGeneration < previous.currentFencingGeneration ||
        candidate.configGeneration < previous.configGeneration {
        return false
    }
    if candidate.recoveryGeneration == previous.recoveryGeneration,
       candidate.keyStateHash != previous.keyStateHash {
        return false
    }
    if candidate.recoveryGeneration > previous.recoveryGeneration,
       candidate.keyStateHash == previous.keyStateHash {
        return false
    }
    if candidate.configGeneration == previous.configGeneration,
       (candidate.contentHash != previous.contentHash ||
        candidate.configVersion != previous.configVersion) {
        return false
    }
    return true
}

struct AccessDiscoveryKnownKeyset: Codable, Equatable, Sendable {
    let revision: UInt64
    let retiredKeyIDs: Set<String>
    let revokedKeyIDs: Set<String>

    init(revision: UInt64, retiredKeyIDs: Set<String>, revokedKeyIDs: Set<String>) {
        self.revision = revision
        self.retiredKeyIDs = retiredKeyIDs
        self.revokedKeyIDs = revokedKeyIDs
    }

    init?(response: RemoteAccessDiscoveryResponse) {
        guard response.contractVersion == 2,
              let revision = response.keysetRevision,
              revision > 0,
              let proof = response.trust,
              let raw = Data(base64Encoded: proof.keyState.payloadB64),
              let payload = try? PreloginStrictJSON.decodeAccessDiscoveryKeyStatePayload(raw),
              payload.keysetRevision == revision else {
            return nil
        }
        self.revision = revision
        retiredKeyIDs = Set(payload.keys.filter { $0.status == "retired" }.map(\.keyID))
        revokedKeyIDs = Set(payload.keys.filter { $0.status == "revoked" }.map(\.keyID))
    }

    func permitsHistoricalLastGood(signedBy keyID: String) -> Bool {
        !revokedKeyIDs.contains(keyID)
    }
}

func accessDiscoveryKnownKeysetTransitionAllowed(
    previous: AccessDiscoveryKnownKeyset?,
    candidate: AccessDiscoveryKnownKeyset
) -> Bool {
    guard let previous else { return true }
    if candidate.revision < previous.revision { return false }
    if candidate.revision == previous.revision { return candidate == previous }
    return true
}

final class AccessDiscoveryStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let watermarkDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private let watermarkWriter: (Data, URL) throws -> Void

    init(
        baseDirectory: URL = AccessDiscoveryStore.defaultBaseDirectory(),
        watermarkDirectory: URL? = nil,
        fileManager: FileManager = .default,
        watermarkWriter: @escaping (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) {
        self.baseDirectory = baseDirectory
        self.watermarkDirectory = watermarkDirectory ?? baseDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AccessDiscoveryTrustWatermark", isDirectory: true)
        self.fileManager = fileManager
        self.watermarkWriter = watermarkWriter
        encoder.outputFormatting = [.sortedKeys]
    }

    static func defaultBaseDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("AccessDiscoveryLastGood", isDirectory: true)
    }

    static func clearDefaultStore(fileManager: FileManager = .default) {
        let directory = defaultBaseDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func load(key: String) throws -> AccessDiscoveryCachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(AccessDiscoveryCachedSnapshot.self, from: data)
    }

    func save(_ snapshot: AccessDiscoveryCachedSnapshot, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let destination = fileURL(for: key)
        let temporary = baseDirectory.appendingPathComponent("\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        let data = try encoder.encode(snapshot)
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func fileURL(for key: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.cacheFileName(for: key)).json")
    }

    func loadTrustWatermark(key: String) throws -> AccessDiscoveryTrustWatermark? {
        lock.lock()
        defer { lock.unlock() }
        return try loadTrustWatermarkLocked(key: key)
    }

    func advanceTrustWatermark(_ candidate: AccessDiscoveryTrustWatermark, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let previous = try loadTrustWatermarkLocked(key: key) {
            guard accessDiscoveryTrustWatermarkTransitionAllowed(
                previous: previous,
                candidate: candidate
            ) else {
                return false
            }
            if previous == candidate {
                return true
            }
        }
        try fileManager.createDirectory(at: watermarkDirectory, withIntermediateDirectories: true)
        let destination = watermarkFileURL(for: key)
        let data = try encoder.encode(candidate)
        try watermarkWriter(data, destination)
        return true
    }

    func loadKnownKeyset(key: String) throws -> AccessDiscoveryKnownKeyset? {
        lock.lock()
        defer { lock.unlock() }
        let url = knownKeysetFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(AccessDiscoveryKnownKeyset.self, from: Data(contentsOf: url))
    }

    func advanceKnownKeyset(_ candidate: AccessDiscoveryKnownKeyset, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let destination = knownKeysetFileURL(for: key)
        let previous: AccessDiscoveryKnownKeyset?
        if fileManager.fileExists(atPath: destination.path) {
            previous = try decoder.decode(
                AccessDiscoveryKnownKeyset.self,
                from: Data(contentsOf: destination)
            )
        } else {
            previous = nil
        }
        guard accessDiscoveryKnownKeysetTransitionAllowed(previous: previous, candidate: candidate) else {
            return false
        }
        if previous == candidate { return true }
        try fileManager.createDirectory(at: watermarkDirectory, withIntermediateDirectories: true)
        try encoder.encode(candidate).write(to: destination, options: .atomic)
        return true
    }

    private func loadTrustWatermarkLocked(key: String) throws -> AccessDiscoveryTrustWatermark? {
        let url = watermarkFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(AccessDiscoveryTrustWatermark.self, from: data)
    }

    private func watermarkFileURL(for key: String) -> URL {
        watermarkDirectory.appendingPathComponent("\(Self.cacheFileName(for: key)).json")
    }

    private func knownKeysetFileURL(for key: String) -> URL {
        watermarkDirectory.appendingPathComponent("keyset-\(Self.cacheFileName(for: key)).json")
    }

    private static func cacheFileName(for key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
