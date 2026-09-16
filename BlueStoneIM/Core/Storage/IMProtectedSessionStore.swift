import Foundation
import Darwin
import Security

protocol IMProtectedSessionStoring: AnyObject {
    func string(forKey key: String) -> String?

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Bool

    @discardableResult
    func deleteString(forKey key: String) -> Bool

    @discardableResult
    func deleteAll() -> Bool
}

#if targetEnvironment(simulator)
/// The unsigned simulator carriers used by the validation lanes do not have an
/// application-identifier entitlement, so Security.framework rejects every
/// Keychain write with `errSecMissingEntitlement`. Keep that environment
/// fail-closed without changing the device build: simulator sessions are stored
/// in one app-sandboxed, atomically replaced, data-protected file instead of
/// falling back to UserDefaults or accepting an unverified write.
final class IMSimulatorProtectedSessionStore: IMProtectedSessionStoring, @unchecked Sendable {
    /// All instances may address the same default sandbox file. A process-wide
    /// lock keeps their read-modify-write cycles atomic, including test stores
    /// that intentionally share an injected URL.
    private static let coordinationLock = NSLock()
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    func string(forKey key: String) -> String? {
        withLock {
            guard let values = readValues() else { return nil }
            return values[key]
        } ?? nil
    }

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Bool {
        guard !key.isEmpty, !value.isEmpty else { return false }
        return withLock {
            guard var values = readValues() else { return false }
            values[key] = value
            return writeValues(values)
        } ?? false
    }

    @discardableResult
    func deleteString(forKey key: String) -> Bool {
        withLock {
            guard var values = readValues() else { return false }
            guard values.removeValue(forKey: key) != nil else { return true }
            return values.isEmpty ? removeFile() : writeValues(values)
        } ?? false
    }

    @discardableResult
    func deleteAll() -> Bool {
        withLock { removeFile() } ?? false
    }

    fileprivate static func defaultFileURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.bluestone.im.ios")
            .replacingOccurrences(of: "/", with: "-")
        return applicationSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("authenticated-session.simulator.json", isDirectory: false)
    }

    private func readValues() -> [String: String]? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
              resourceValues.isSymbolicLink != true,
              let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return values
    }

    private func writeValues(_ values: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(values) else { return false }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: NSNumber(value: Int16(0o700)),
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try fileManager.setAttributes(
                [
                    .posixPermissions: NSNumber(value: Int16(0o600)),
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: fileURL.path
            )
            return readValues() == values
        } catch {
            return false
        }
    }

    private func removeFile() -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return true }
        do {
            try fileManager.removeItem(at: fileURL)
            return !fileManager.fileExists(atPath: fileURL.path)
        } catch {
            return false
        }
    }

    private func withLock<T>(_ body: () -> T) -> T? {
        Self.coordinationLock.lock()
        defer { Self.coordinationLock.unlock() }

        let directoryURL = fileURL.deletingLastPathComponent()
        let lockURL = fileURL.appendingPathExtension("lock")
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            return nil
        }
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { return nil }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        return body()
    }
}
#endif

final class IMKeychainSessionStore: IMProtectedSessionStoring {
    private let service: String

    #if targetEnvironment(simulator)
    private let simulatorStore: IMSimulatorProtectedSessionStore

    init(simulatorFileURL: URL? = nil, registrationRecovery: Bool = false) {
        service = registrationRecovery ? "com.bluestone.im.ios.registration-recovery" : "com.bluestone.im.ios.session"
        let fileURL = simulatorFileURL ?? (registrationRecovery
            ? IMSimulatorProtectedSessionStore.defaultFileURL(fileManager: .default)
                .deletingLastPathComponent().appendingPathComponent("registration-recovery.simulator.json")
            : nil)
        simulatorStore = IMSimulatorProtectedSessionStore(fileURL: fileURL)
    }
    #else
    init(registrationRecovery: Bool = false) {
        service = registrationRecovery ? "com.bluestone.im.ios.registration-recovery" : "com.bluestone.im.ios.session"
    }
    #endif

    func string(forKey key: String) -> String? {
        #if targetEnvironment(simulator)
        return simulatorStore.string(forKey: key)
        #else
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
        #endif
    }

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Bool {
        #if targetEnvironment(simulator)
        return simulatorStore.setString(value, forKey: key)
        #else
        guard let data = value.data(using: .utf8) else { return false }
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        #endif
    }

    @discardableResult
    func deleteString(forKey key: String) -> Bool {
        #if targetEnvironment(simulator)
        return simulatorStore.deleteString(forKey: key)
        #else
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #endif
    }

    @discardableResult
    func deleteAll() -> Bool {
        #if targetEnvironment(simulator)
        return simulatorStore.deleteAll()
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #endif
    }

    #if !targetEnvironment(simulator)
    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
    #endif
}
