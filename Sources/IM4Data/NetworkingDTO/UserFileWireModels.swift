import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteUserFileDetail: Decodable, Sendable {
    public let file: RemoteUserFileObject
    public let previewAvailable: Bool
    public let downloadAvailable: Bool
    public let previewURL: String
    public let downloadURL: String
    public let contentDisposition: String

    enum CodingKeys: String, CodingKey {
        case file
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case contentDisposition = "content_disposition"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(RemoteUserFileObject.self, forKey: .file)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition)
            ?? file.contentDisposition
    }

    public init(
        file: RemoteUserFileObject,
        previewAvailable: Bool,
        downloadAvailable: Bool,
        previewURL: String,
        downloadURL: String,
        contentDisposition: String
    ) {
        self.file = file
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.contentDisposition = contentDisposition
    }
}

public struct RemoteUserFileObject: Decodable, Sendable {
    public let id: String
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let uploaderUID: String
    public let status: String
    public let createdAt: String?
    public let cacheKey: String
    public let version: String
    public let checksum: String
    public let mediaCategory: String
    public let contentType: String
    public let kind: String
    public let fileExtension: String
    public let thumbnailURL: String
    public let posterURL: String
    public let coverURL: String
    public let previewKind: String
    public let contentDisposition: String
    public let width: Int?
    public let height: Int?
    public let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "file_id"
        case fileName = "file_name"
        case name
        case mimeType = "mime_type"
        case extensionValue = "extension"
        case kind
        case sizeBytes = "size_bytes"
        case size
        case uploaderUID = "uploader_uid"
        case status
        case uploadStatus = "upload_status"
        case createdAt = "created_at"
        case cacheKey = "cache_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case mediaCategory = "media_category"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case thumbnailURL = "thumbnail_url"
        case thumbURL = "thumb_url"
        case thumbnailEndpoint = "thumbnail_endpoint"
        case previewThumbnailURL = "preview_thumbnail_url"
        case thumbnailPreviewURL = "thumbnail_preview_url"
        case posterURL = "poster_url"
        case posterEndpoint = "poster_endpoint"
        case videoPosterURL = "video_poster_url"
        case coverURL = "cover_url"
        case coverEndpoint = "cover_endpoint"
        case videoCoverURL = "video_cover_url"
        case previewKind = "preview_kind"
        case contentDisposition = "content_disposition"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case duration
        case durationMS = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .fileID)
            ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .size)
            ?? 0
        uploaderUID = try c.decodeIfPresent(String.self, forKey: .uploaderUID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .uploadStatus)
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? c.decodeIfPresent(String.self, forKey: .fileVersion)
            ?? c.decodeIfPresent(String.self, forKey: .cacheVersion)
            ?? ""
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        mediaCategory = try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            ?? c.decodeIfPresent(String.self, forKey: .contentTypeCamel)
            ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .extensionValue) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .previewThumbnailURL)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailPreviewURL)
            ?? ""
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL)
            ?? c.decodeIfPresent(String.self, forKey: .posterEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoPosterURL)
            ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
            ?? c.decodeIfPresent(String.self, forKey: .coverEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .videoCoverURL)
            ?? ""
        previewKind = try c.decodeIfPresent(String.self, forKey: .previewKind) ?? ""
        contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition) ?? ""
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        if let seconds = c.decodeLossyDoubleIfPresent(forKey: .durationSeconds)
            ?? c.decodeLossyDoubleIfPresent(forKey: .duration) {
            durationSeconds = seconds
        } else if let milliseconds = c.decodeLossyDoubleIfPresent(forKey: .durationMS) {
            durationSeconds = milliseconds / 1000.0
        } else {
            durationSeconds = nil
        }
    }

    public init(
        id: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int64,
        uploaderUID: String,
        status: String,
        createdAt: String?,
        cacheKey: String,
        version: String,
        checksum: String,
        mediaCategory: String,
        contentType: String,
        kind: String,
        fileExtension: String,
        thumbnailURL: String,
        posterURL: String,
        coverURL: String,
        previewKind: String,
        contentDisposition: String,
        width: Int?,
        height: Int?,
        durationSeconds: Double?
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.uploaderUID = uploaderUID
        self.status = status
        self.createdAt = createdAt
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
        self.mediaCategory = mediaCategory
        self.contentType = contentType
        self.kind = kind
        self.fileExtension = fileExtension
        self.thumbnailURL = thumbnailURL
        self.posterURL = posterURL
        self.coverURL = coverURL
        self.previewKind = previewKind
        self.contentDisposition = contentDisposition
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
