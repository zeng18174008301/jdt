// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import Foundation

/// Raw operations run on the original caller's actor or existing off-main task.
public enum MediaBlobFileIO {
    public static func writeTemporaryThumbnailData(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-thumbnail-\(UUID().uuidString.lowercased())", isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
            // This UUID file is owned here; never chmod the shared temp directory or borrowed files.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public static func writeReplacingData(_ data: Data, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
    }
    public static func writePendingAttachmentData(_ data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMPendingAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try writeReplacingData(data, at: url)
        return url
    }
    public static func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public static func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    public static func removeFileIfExists(at url: URL) -> MediaBlobFileRemovalOutcome {
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            if existed { try FileManager.default.removeItem(at: url) }
            return MediaBlobFileRemovalOutcome(didComplete: true, fileExisted: existed)
        } catch { return MediaBlobFileRemovalOutcome(didComplete: false, fileExisted: existed) }
    }
}
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
