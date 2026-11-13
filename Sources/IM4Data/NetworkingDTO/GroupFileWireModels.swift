import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteGroupFile: Decodable, Sendable {
    public let fileID: String
    public let name: String
    public let type: String
    public let mimeType: String
    public let category: String
    public let size: Int64
    public let uploaderUID: String
    public let uploaderName: String
    public let channelID: String
    public let channelType: String
    public let channelSeq: Int64
    public let groupID: String
    public let sourceName: String
    public let createdAt: String?
    public let previewAvailable: Bool
    public let downloadAvailable: Bool
    public let previewURL: String
    public let downloadURL: String
    public let status: String
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
        case fileID = "file_id"
        case id
        case name
        case fileName = "file_name"
        case type
        case mimeType = "mime_type"
        case category
        case size
        case sizeBytes = "size_bytes"
        case uploaderUID = "uploader_uid"
        case uploaderName = "uploader_name"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case seq
        case groupID = "group_id"
        case sourceName = "source_name"
        case createdAt = "created_at"
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case status
        case uploadStatus = "upload_status"
        case cacheKey = "cache_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case mediaCategory = "media_category"
        case contentType = "content_type"
        case contentTypeCamel = "contentType"
        case kind
        case fileExtension = "extension"
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

    public init(
        fileID: String,
        name: String,
        type: String,
        mimeType: String,
        category: String,
        size: Int64,
        uploaderUID: String,
        uploaderName: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64 = 0,
        groupID: String,
        sourceName: String,
        createdAt: String?,
        previewAvailable: Bool,
        downloadAvailable: Bool,
        previewURL: String,
        downloadURL: String,
        status: String,
        cacheKey: String = "",
        version: String = "",
        checksum: String = "",
        mediaCategory: String = "",
        contentType: String = "",
        kind: String = "",
        fileExtension: String = "",
        thumbnailURL: String = "",
        posterURL: String = "",
        coverURL: String = "",
        previewKind: String = "",
        contentDisposition: String = "",
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        self.fileID = fileID
        self.name = name
        self.type = type
        self.mimeType = mimeType
        self.category = category
        self.size = size
        self.uploaderUID = uploaderUID
        self.uploaderName = uploaderName
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.groupID = groupID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.status = status
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .fileName)
            ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
            ?? c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            ?? 0
        uploaderUID = try c.decodeIfPresent(String.self, forKey: .uploaderUID) ?? ""
        uploaderName = try c.decodeIfPresent(String.self, forKey: .uploaderName) ?? ""
        let decodedGroupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        let decodedChannelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? (decodedGroupID.isEmpty ? "" : "group")
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
            ?? c.decodeLossyInt64IfPresent(forKey: .seq)
            ?? 0
        groupID = decodedGroupID
        channelID = decodedChannelID.isEmpty ? decodedGroupID : decodedChannelID
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .uploadStatus)
            ?? ""
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
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
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
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
