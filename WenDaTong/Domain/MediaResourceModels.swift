// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import CryptoKit
import Foundation
import IM4Data // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111

enum MediaFileIntegrityError: Error, Equatable, Sendable {
    case missingFile
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
    static func blobFailure(_ failure: IM4Data.MediaBlobIntegrityError) -> MediaFileIntegrityError {
        switch failure {
        case .missingFile: .missingFile
        case .emptyFile: .emptyFile
        case let .sizeMismatch(expected, actual): .sizeMismatch(expected: expected, actual: actual)
        case .checksumMismatch: .checksumMismatch
        }
    }
    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
}

struct MediaFileIntegrityAuthority: Equatable, Sendable {
    var expectedSizeBytes: Int64?
    var expectedSHA256: String

    init(expectedSizeBytes: Int64? = nil, expectedSHA256: String = "") {
        self.expectedSizeBytes = expectedSizeBytes.flatMap { $0 > 0 ? $0 : nil }
        self.expectedSHA256 = Self.normalizedSHA256(expectedSHA256)
    }

    var hasChecksum: Bool {
        !expectedSHA256.isEmpty
    }

    func verify(fileAt url: URL, fileManager: FileManager = .default) throws -> Int64 {
        do { return try blobExpectation.verify(fileAt: url, fileManager: fileManager) }
        catch let failure as IM4Data.MediaBlobIntegrityError { throw MediaFileIntegrityError.blobFailure(failure) }
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        try IM4Data.MediaBlobIntegrityExpectation.sha256Hex(fileAt: url)
    }

    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
    var blobExpectation: IM4Data.MediaBlobIntegrityExpectation {
        .init(expectedSizeBytes: expectedSizeBytes, expectedSHA256: expectedSHA256)
    }
    // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END

    static func normalizedSHA256(_ rawValue: String) -> String {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return ""
        }
        return rawValue
    }
}

struct MediaResourceMetadata: Codable, Hashable, Sendable {
    var scope: String
    var fileID: String
    var attachmentID: String
    var mediaID: String
    var cacheKey: String
    var version: String
    var checksumSHA256: String
    var createdAt: String
    var mimeType: String
    var sizeBytes: Int64?
    var fileName: String
    var fileExtension: String
    var thumbnailCacheKey: String
    var thumbnailVersion: String
    var thumbnailMimeType: String
    var thumbnailExtension: String
    var previewCacheKey: String
    var previewVersion: String
    var previewMimeType: String
    var previewExtension: String

    init(
        scope: String = "",
        fileID: String = "",
        attachmentID: String = "",
        mediaID: String = "",
        cacheKey: String = "",
        version: String = "",
        checksumSHA256: String = "",
        createdAt: String = "",
        mimeType: String = "",
        sizeBytes: Int64? = nil,
        fileName: String = "",
        fileExtension: String = "",
        thumbnailCacheKey: String = "",
        thumbnailVersion: String = "",
        thumbnailMimeType: String = "",
        thumbnailExtension: String = "",
        previewCacheKey: String = "",
        previewVersion: String = "",
        previewMimeType: String = "",
        previewExtension: String = ""
    ) {
        self.scope = scope
        self.fileID = fileID
        self.attachmentID = attachmentID
        self.mediaID = mediaID
        self.cacheKey = cacheKey
        self.version = version
        self.checksumSHA256 = checksumSHA256
        self.createdAt = createdAt
        self.mimeType = Self.normalized(mimeType).lowercased()
        self.sizeBytes = sizeBytes
        self.fileName = Self.normalized(fileName)
        self.fileExtension = Self.normalizedExtension(fileExtension)
        self.thumbnailCacheKey = thumbnailCacheKey
        self.thumbnailVersion = thumbnailVersion
        self.thumbnailMimeType = Self.normalized(thumbnailMimeType).lowercased()
        self.thumbnailExtension = Self.normalizedExtension(thumbnailExtension)
        self.previewCacheKey = previewCacheKey
        self.previewVersion = previewVersion
        self.previewMimeType = Self.normalized(previewMimeType).lowercased()
        self.previewExtension = Self.normalizedExtension(previewExtension)
    }

    func identity(
        for resourceKind: MediaResourceKind,
        variant: MediaCacheVariant? = nil
    ) -> MediaResourceIdentity {
        MediaResourceIdentity(
            resourceKind: resourceKind,
            scope: scope,
            fileID: fileID,
            attachmentID: attachmentID,
            mediaID: mediaID,
            cacheKey: cacheKey(for: resourceKind),
            version: version(for: resourceKind),
            checksumSHA256: resourceKind == .original ? checksumSHA256 : "",
            createdAt: createdAt,
            variant: variant,
            mimeType: mimeType(for: resourceKind),
            sizeBytes: resourceKind == .original ? sizeBytes : nil
        )
    }

    func preferredExtension(for resourceKind: MediaResourceKind) -> String {
        let explicitExtension: String
        switch resourceKind {
        case .thumbnail:
            explicitExtension = firstNonEmpty(thumbnailExtension, extensionFromMimeType(thumbnailMimeType), extensionFromMimeType(mimeType))
        case .preview:
            explicitExtension = firstNonEmpty(previewExtension, extensionFromMimeType(previewMimeType), fileExtension, extensionFromFileName(fileName), extensionFromMimeType(mimeType))
        case .original:
            explicitExtension = firstNonEmpty(fileExtension, extensionFromFileName(fileName), extensionFromMimeType(mimeType))
        }
        return Self.normalizedExtension(explicitExtension)
    }

    private func cacheKey(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailCacheKey, cacheKey)
        case .preview:
            return firstNonEmpty(previewCacheKey, cacheKey)
        case .original:
            return cacheKey
        }
    }

    private func version(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailVersion, version)
        case .preview:
            return firstNonEmpty(previewVersion, version)
        case .original:
            return version
        }
    }

    private func mimeType(for resourceKind: MediaResourceKind) -> String {
        switch resourceKind {
        case .thumbnail:
            return firstNonEmpty(thumbnailMimeType, mimeType)
        case .preview:
            return firstNonEmpty(previewMimeType, mimeType)
        case .original:
            return mimeType
        }
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    private func extensionFromFileName(_ fileName: String) -> String {
        Self.normalizedExtension((fileName as NSString).pathExtension)
    }

    private func extensionFromMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic", "image/heif":
            return "heic"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        case "text/csv", "application/csv":
            return "csv"
        default:
            return ""
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedExtension(_ value: String) -> String {
        let trimmed = normalized(value).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed = CharacterSet.alphanumerics
        let scalars = trimmed.unicodeScalars.compactMap { scalar -> Character? in
            allowed.contains(scalar) ? Character(scalar) : nil
        }
        return String(scalars).lowercased()
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
// WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
