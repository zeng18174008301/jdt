// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_BEGIN
import Foundation
import Security

/// Mechanical IO failure; the App adapter preserves its existing public error.
public enum PreloginIOError: Error { case unavailable }

public struct PreloginLastGoodEnvelope: Codable, Sendable {
    public let scopeHash: String
    public let artifact: Data
    public let keyState: Data
    public let currentPointer: Data
    public let savedAt: Date

    public init(scopeHash: String, artifact: Data, keyState: Data, currentPointer: Data, savedAt: Date) {
        self.scopeHash = scopeHash
        self.artifact = artifact
        self.keyState = keyState
        self.currentPointer = currentPointer
        self.savedAt = savedAt
    }
}

public struct PreloginTrustCheckpoint: Codable, Equatable, Sendable {
    public let scopeHash: String
    public let recoveryGeneration: UInt64
    public let recoveryHash: String
    public let fencingGeneration: UInt64
    public let configVersion: UInt64
    public let payloadHash: String
    public let lastTrustedWallClock: Date
    public let lastNetworkSavedAt: Date

    public init(scopeHash: String, recoveryGeneration: UInt64, recoveryHash: String, fencingGeneration: UInt64, configVersion: UInt64, payloadHash: String, lastTrustedWallClock: Date, lastNetworkSavedAt: Date) {
        self.scopeHash = scopeHash
        self.recoveryGeneration = recoveryGeneration
        self.recoveryHash = recoveryHash
        self.fencingGeneration = fencingGeneration
        self.configVersion = configVersion
        self.payloadHash = payloadHash
        self.lastTrustedWallClock = lastTrustedWallClock
        self.lastNetworkSavedAt = lastNetworkSavedAt
    }
}

public protocol PreloginLastGoodStoring: Sendable {
    func loadEnvelope() async throws -> PreloginLastGoodEnvelope?
    func loadCheckpoint() async throws -> PreloginTrustCheckpoint?
    func saveEnvelope(_ value: PreloginLastGoodEnvelope) async throws
    func saveCheckpoint(_ value: PreloginTrustCheckpoint) async throws
}

public actor PreloginSecureLastGoodStore: PreloginLastGoodStoring {
    private let fileURL: URL
    private let keychainService: String
    private let keychainAccount: String

    public init(
        scopeHash: String,
        fileURL: URL? = nil,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.wenxintong.unconfigured"
    ) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL
            ?? support.appendingPathComponent(
                "BlueStoneIM/PreloginBootstrap/\(scopeHash)/last-good.json"
            )
        // APP1 and APP2 deliberately use different bundle identifiers and must
        // never share their anti-rollback checkpoint or local device identity.
        // No shared Keychain access group is configured.
        keychainService = Self.keychainServiceName(bundleIdentifier: bundleIdentifier)
        keychainAccount = scopeHash
    }

    public static func keychainServiceName(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).prelogin-bootstrap"
    }

    public func loadEnvelope() throws -> PreloginLastGoodEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try JSONDecoder().decode(PreloginLastGoodEnvelope.self, from: data)
    }

    public func loadCheckpoint() throws -> PreloginTrustCheckpoint? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PreloginIOError.unavailable
        }
        return try JSONDecoder().decode(PreloginTrustCheckpoint.self, from: data)
    }

    public func saveEnvelope(_ value: PreloginLastGoodEnvelope) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    public func saveCheckpoint(_ value: PreloginTrustCheckpoint) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw PreloginIOError.unavailable
            }
        } else if updateStatus != errSecSuccess {
            throw PreloginIOError.unavailable
        }
    }
}

// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_END
