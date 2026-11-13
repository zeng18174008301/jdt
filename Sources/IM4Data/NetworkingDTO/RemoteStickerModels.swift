// WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
import Foundation

public struct RemoteStickerVariant: Decodable, Equatable, Sendable {
    public let kind: String
    public let fileID: String
    public let mimeType: String
    public let url: String
    public let sizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let thumbnailURL: String
    public let cacheKey: String

    enum CodingKeys: String, CodingKey {
        case kind
        case fileID = "file_id"
        case mimeType = "mime_type"
        case url
        case assetURL = "asset_url"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case cacheKey = "cache_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .assetURL)
            ?? c.decodeIfPresent(String.self, forKey: .previewURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
    }
}

public struct RemoteUserSticker: Decodable, Equatable, Sendable {
    public let id: String
    public let stickerID: String
    public let fileID: String
    public let status: String
    public let processingStatus: String
    public let sort: Int
    public let mimeType: String
    public let sizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let cacheKey: String
    public let version: String
    public let thumbnailURL: String
    public let variants: [RemoteStickerVariant]
    public let errorCode: String
    public let errorReason: String
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case stickerID = "sticker_id"
        case fileID = "file_id"
        case status
        case processingStatus = "processing_status"
        case sort
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case cacheKey = "cache_key"
        case version
        case thumbnailURL = "thumbnail_url"
        case variants
        case errorCode = "error_code"
        case errorReason = "error_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        stickerID = try c.decodeIfPresent(String.self, forKey: .stickerID) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        processingStatus = try c.decodeIfPresent(String.self, forKey: .processingStatus) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        variants = try c.decodeIfPresent([RemoteStickerVariant].self, forKey: .variants) ?? []
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        errorReason = try c.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct RemoteStickerPack: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let coverURL: String
    public let sort: Int
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverURL = "cover_url"
        case sort
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct RemoteSticker: Decodable, Equatable, Sendable {
    public let id: String
    public let packID: String
    public let imageURL: String
    public let fileID: String
    public let mimeType: String
    public let sizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let hash: String
    public let cacheKey: String
    public let thumbnailURL: String
    public let variants: [RemoteStickerVariant]
    public let scope: String
    public let status: String
    public let processingStatus: String
    public let sort: Int
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case imageURL = "image_url"
        case fileID = "file_id"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case width
        case height
        case durationMS = "duration_ms"
        case frameCount = "frame_count"
        case hash
        case cacheKey = "cache_key"
        case thumbnailURL = "thumbnail_url"
        case variants
        case scope
        case status
        case processingStatus = "processing_status"
        case sort
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        packID = try c.decodeIfPresent(String.self, forKey: .packID) ?? ""
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
        width = c.decodeLossyIntIfPresent(forKey: .width)
        height = c.decodeLossyIntIfPresent(forKey: .height)
        durationMS = c.decodeLossyIntIfPresent(forKey: .durationMS)
        frameCount = c.decodeLossyIntIfPresent(forKey: .frameCount)
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        variants = try c.decodeIfPresent([RemoteStickerVariant].self, forKey: .variants) ?? []
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        processingStatus = try c.decodeIfPresent(String.self, forKey: .processingStatus) ?? ""
        sort = c.decodeLossyIntIfPresent(forKey: .sort) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct RemoteStickerProcessingTask: Decodable, Equatable, Sendable {
    public let id: String
    public let stickerID: String
    public let fileID: String
    public let status: String
    public let errorCode: String
    public let errorReason: String
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case stickerID = "sticker_id"
        case fileID = "file_id"
        case status
        case errorCode = "error_code"
        case errorReason = "error_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        stickerID = try c.decodeIfPresent(String.self, forKey: .stickerID) ?? ""
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        errorReason = try c.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct RemoteUserStickerCommitResult: Decodable, Equatable, Sendable {
    public let sticker: RemoteSticker
    public let task: RemoteStickerProcessingTask?

    enum CodingKeys: String, CodingKey {
        case sticker
        case task
    }

    public init(sticker: RemoteSticker, task: RemoteStickerProcessingTask?) {
        self.sticker = sticker
        self.task = task
    }
}
// WDT_IOS1_DATA_NETWORK_DTO_20261110_END
