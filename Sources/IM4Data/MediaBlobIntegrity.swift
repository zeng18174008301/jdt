// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
import Foundation
import CryptoKit

public enum MediaBlobIntegrityError: Error, Equatable, Sendable {
    case missingFile
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
}

public struct MediaBlobIntegrityExpectation: Equatable, Sendable {
    public let expectedSizeBytes: Int64?
    public let expectedSHA256: String
    public init(expectedSizeBytes: Int64?, expectedSHA256: String) {
        // Preserve the caller's exact content expectations, including mutations after its initializer.
        self.expectedSizeBytes = expectedSizeBytes; self.expectedSHA256 = expectedSHA256
    }
    private var hasChecksum: Bool { !expectedSHA256.isEmpty }
    public func verify(fileAt url: URL, fileManager: FileManager = .default) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MediaBlobIntegrityError.missingFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualSize > 0 else {
            throw MediaBlobIntegrityError.emptyFile
        }
        if let expectedSizeBytes, actualSize != expectedSizeBytes {
            throw MediaBlobIntegrityError.sizeMismatch(expected: expectedSizeBytes, actual: actualSize)
        }
        if hasChecksum {
            let actualChecksum = try Self.sha256Hex(fileAt: url)
            guard actualChecksum == expectedSHA256 else {
                throw MediaBlobIntegrityError.checksumMismatch
            }
        }
        return actualSize
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }
}
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
