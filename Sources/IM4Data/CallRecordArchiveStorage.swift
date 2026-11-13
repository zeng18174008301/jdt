// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_BEGIN
import Foundation
import IM4Domain

/// Concrete typed archive IO, called synchronously under the original CallStore/App owner.
/// No Sendable conformance or independent queue widens the original serialization contract.
public final class CallRecordArchiveStorage {
    private struct Archive: Codable {
        var schemaVersion: Int
        var recordsByScope: [String: [CallRecord]]
    }

    private static let currentSchemaVersion = 1
    private let defaults: UserDefaults
    private let storageKey: String
    private let archiveURL: URL?
    private let onDiskWriteFailure: ((any Error) -> Void)?

    public init(defaults: UserDefaults, storageKey: String, archiveURL: URL?,
                onDiskWriteFailure: ((any Error) -> Void)? = nil) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.archiveURL = archiveURL
        self.onDiskWriteFailure = onDiskWriteFailure
    }

    public func records(scope: String) -> [CallRecord] {
        loadArchive().recordsByScope[scope, default: []]
    }

    public func save(_ records: [CallRecord], scope: String) {
        var archive = loadArchive()
        if records.isEmpty {
            archive.recordsByScope.removeValue(forKey: scope)
        } else {
            archive.recordsByScope[scope] = records
        }
        persist(archive)
    }

    private func loadArchive() -> Archive {
        if let diskArchive = loadDiskArchive() {
            return diskArchive
        }
        if let defaultsArchive = loadDefaultsArchive() {
            writeDiskArchive(defaultsArchive)
            return defaultsArchive
        }
        return Archive(schemaVersion: Self.currentSchemaVersion, recordsByScope: [:])
    }

    private func persist(_ archive: Archive) {
        guard !archive.recordsByScope.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            defaults.synchronize()
            removeDiskArchive()
            return
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        writeDiskData(data)
    }

    private func loadDiskArchive() -> Archive? {
        guard let archiveURL,
              let data = try? Data(contentsOf: archiveURL),
              let decoded = try? JSONDecoder().decode(Archive.self, from: data),
              decoded.schemaVersion == Self.currentSchemaVersion else {
            return nil
        }
        return decoded
    }

    private func loadDefaultsArchive() -> Archive? {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Archive.self, from: data),
              decoded.schemaVersion == Self.currentSchemaVersion else {
            return nil
        }
        return decoded
    }

    private func writeDiskArchive(_ archive: Archive) {
        guard !archive.recordsByScope.isEmpty,
              let data = try? JSONEncoder().encode(archive) else { return }
        writeDiskData(data)
    }

    private func writeDiskData(_ data: Data) {
        guard let archiveURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: archiveURL, options: [.atomic])
        } catch {
            onDiskWriteFailure?(error)
        }
    }

    private func removeDiskArchive() {
        guard let archiveURL else { return }
        try? FileManager.default.removeItem(at: archiveURL)
    }
}
// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_END
