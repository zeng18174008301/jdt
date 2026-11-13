// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public struct PendingAttachmentFile: Equatable, Sendable {
    public let url: URL
    public let sizeBytes: Int64

    public init(url: URL, sizeBytes: Int64) {
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

public enum PendingAttachmentFileStore {
    public static let directoryName = "BlueStoneIMPendingAttachments"

    public static func stageFile(
        from sourceURL: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> PendingAttachmentFile {
        let sourceSize = try regularFileSize(at: sourceURL, fileManager: fileManager)

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )

        let destination = directory.appendingPathComponent(
            "\(UUID().uuidString)_\(sanitizedFileName(preferredName))",
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            let destinationSize = try regularFileSize(at: destination, fileManager: fileManager)
            guard destinationSize == sourceSize else {
                throw CocoaError(.fileWriteUnknown)
            }
            return PendingAttachmentFile(url: destination, sizeBytes: destinationSize)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    public static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int64? {
        guard isManagedFile(url, fileManager: fileManager) else {
            return nil
        }
        return try? regularFileSize(at: url, fileManager: fileManager)
    }

    public static func regularFileSize(at url: URL, fileManager: FileManager = .default) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let rawSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return rawSize.int64Value
    }

    public static func removeManagedFile(at url: URL?, fileManager: FileManager = .default) {
        guard let url, isManagedFile(url, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Files in this temporary directory are only sources for the durable
    /// outbox staging copy. No valid ownership survives a process restart.
    public static func removeOrphanedFiles(fileManager: FileManager = .default) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for entry in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try fileManager.removeItem(at: entry)
        }
    }

    public static func isManagedFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent() == directory
    }

    private static func sanitizedFileName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : String(sanitized.prefix(180))
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
