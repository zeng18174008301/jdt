import CryptoKit
import Foundation

struct StagedLocalMessageAttachment: Sendable {
    let relativePath: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let checksum: String
    let createdNewFile: Bool
}

enum AttachmentTransferRepository {
    static func stage(
        _ intent: LocalMessageAttachmentIntent,
        clientMessageID: String,
        paths: MessageDatabasePaths,
        fileManager: FileManager = .default
    ) throws -> StagedLocalMessageAttachment {
        try paths.prepare(fileManager: fileManager)
        let destination = paths.stagedAttachmentURL(clientMessageID: clientMessageID)
        if fileManager.fileExists(atPath: destination.path) {
            let existingSize = try fileSize(at: destination, fileManager: fileManager)
            let checksum = try sha256Hex(fileAt: destination)
            let checksumMatches = intent.checksum.isEmpty
                || checksum.caseInsensitiveCompare(intent.checksum) == .orderedSame
            if existingSize == intent.sizeBytes, checksumMatches {
                return StagedLocalMessageAttachment(
                    relativePath: try paths.relativeStagingPath(for: destination),
                    fileName: intent.fileName,
                    mimeType: intent.mimeType,
                    sizeBytes: intent.sizeBytes,
                    checksum: checksum,
                    createdNewFile: false
                )
            }
            try fileManager.removeItem(at: destination)
        }
        do {
            if let sourceURL = intent.fileURL {
                guard try fileSize(at: sourceURL, fileManager: fileManager) == intent.sizeBytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try fileManager.copyItem(at: sourceURL, to: destination)
            } else if let data = intent.data {
                try data.write(to: destination, options: [.atomic])
            } else {
                throw LocalMessageDatabaseError.missingStagedAttachment
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        let stagedSize = try fileSize(at: destination, fileManager: fileManager)
        let checksum = try sha256Hex(fileAt: destination)
        let checksumMatches = intent.checksum.isEmpty
            || checksum.caseInsensitiveCompare(intent.checksum) == .orderedSame
        guard stagedSize == intent.sizeBytes, checksumMatches else {
            try? fileManager.removeItem(at: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        return StagedLocalMessageAttachment(
            relativePath: try paths.relativeStagingPath(for: destination),
            fileName: intent.fileName,
            mimeType: intent.mimeType,
            sizeBytes: intent.sizeBytes,
            checksum: checksum,
            createdNewFile: true
        )
    }

    static func remove(
        _ staged: StagedLocalMessageAttachment,
        paths: MessageDatabasePaths,
        fileManager: FileManager = .default
    ) {
        guard staged.createdNewFile,
              let url = try? paths.resolveScopeRelativePath(staged.relativePath),
              url.deletingLastPathComponent().standardizedFileURL == paths.stagingDirectory.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    static func reconcile(
        activeRelativePaths: Set<String>,
        paths: MessageDatabasePaths,
        fileManager: FileManager = .default
    ) throws {
        let activeURLs = Set(activeRelativePaths.compactMap { relativePath -> URL? in
            guard let url = try? paths.resolveScopeRelativePath(relativePath),
                  url.deletingLastPathComponent().standardizedFileURL == paths.stagingDirectory.standardizedFileURL else {
                return nil
            }
            return url.standardizedFileURL
        })
        let entries = try fileManager.contentsOfDirectory(
            at: paths.stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries {
            let standardized = entry.standardizedFileURL
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard activeURLs.contains(standardized),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                try fileManager.removeItem(at: entry)
                continue
            }
        }
    }

    static func load(
        relativePath: String,
        expectedSizeBytes: Int64,
        expectedChecksum: String,
        paths: MessageDatabasePaths
    ) throws -> Data {
        let url = try paths.resolveScopeRelativePath(relativePath)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) == expectedSizeBytes,
              sha256Hex(data).caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return data
    }

    static func loadFileURL(
        relativePath: String,
        expectedSizeBytes: Int64,
        expectedChecksum: String,
        paths: MessageDatabasePaths,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = try paths.resolveScopeRelativePath(relativePath)
        guard try fileSize(at: url, fileManager: fileManager) == expectedSizeBytes,
              try sha256Hex(fileAt: url).caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return url
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return size.int64Value
    }
}
