// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public struct StickerMessageVariantSnapshot: Codable, Hashable, Sendable {
    public let kind: String
    public let fileID: String
    public let mimeType: String
    public let assetURL: String
    public let sizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let thumbnailURL: String
    public let cacheKey: String

    public init(
        kind: String,
        fileID: String,
        mimeType: String,
        assetURL: String = "",
        sizeBytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMS: Int? = nil,
        frameCount: Int? = nil,
        thumbnailURL: String = "",
        cacheKey: String = ""
    ) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assetURL = assetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.durationMS = durationMS
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cacheKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var dictionary: [String: Any] {
        var output: [String: Any] = [
            "kind": kind,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "cache_key": cacheKey
        ]
        if !assetURL.isEmpty { output["url"] = assetURL }
        if let sizeBytes { output["size_bytes"] = sizeBytes }
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        return output
    }

    public var messageSendDictionary: [String: Any] {
        var output: [String: Any] = [
            "kind": kind,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "cache_key": cacheKey
        ]
        if let sizeBytes { output["size_bytes"] = sizeBytes }
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        return output
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case fileID
        case legacyFileID = "file_id"
        case mimeType
        case legacyMimeType = "mime_type"
        case assetURL
        case url
        case legacyAssetURL = "asset_url"
        case downloadURL = "download_url"
        case sizeBytes
        case legacySizeBytes = "size_bytes"
        case width
        case height
        case durationMS
        case legacyDurationMS = "duration_ms"
        case frameCount
        case legacyFrameCount = "frame_count"
        case thumbnailURL
        case legacyThumbnailURL = "thumbnail_url"
        case cacheKey
        case legacyCacheKey = "cache_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "",
            fileID: try c.decodeIfPresent(String.self, forKey: .fileID)
                ?? c.decodeIfPresent(String.self, forKey: .legacyFileID)
                ?? "",
            mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType)
                ?? c.decodeIfPresent(String.self, forKey: .legacyMimeType)
                ?? "",
            assetURL: try c.decodeIfPresent(String.self, forKey: .assetURL)
                ?? c.decodeIfPresent(String.self, forKey: .url)
                ?? c.decodeIfPresent(String.self, forKey: .legacyAssetURL)
                ?? c.decodeIfPresent(String.self, forKey: .downloadURL)
                ?? "",
            sizeBytes: try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
                ?? c.decodeIfPresent(Int64.self, forKey: .legacySizeBytes),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS)
                ?? c.decodeIfPresent(Int.self, forKey: .legacyDurationMS),
            frameCount: try c.decodeIfPresent(Int.self, forKey: .frameCount)
                ?? c.decodeIfPresent(Int.self, forKey: .legacyFrameCount),
            thumbnailURL: try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
                ?? c.decodeIfPresent(String.self, forKey: .legacyThumbnailURL)
                ?? "",
            cacheKey: try c.decodeIfPresent(String.self, forKey: .cacheKey)
                ?? c.decodeIfPresent(String.self, forKey: .legacyCacheKey)
                ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileID, forKey: .fileID)
        try c.encode(mimeType, forKey: .mimeType)
        if !assetURL.isEmpty { try c.encode(assetURL, forKey: .assetURL) }
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(durationMS, forKey: .durationMS)
        try c.encodeIfPresent(frameCount, forKey: .frameCount)
        try c.encode(thumbnailURL, forKey: .thumbnailURL)
        try c.encode(cacheKey, forKey: .cacheKey)
    }
}

public struct StickerMessageSnapshot: Codable, Hashable, Sendable {
    public static let fallbackText = "[GIF表情]"

    public let stickerID: String
    public let packID: String
    public let fileID: String
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let thumbnailURL: String
    public let variants: [StickerMessageVariantSnapshot]
    public let fallbackText: String

    public init(
        stickerID: String,
        packID: String = "",
        fileID: String,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMS: Int? = nil,
        frameCount: Int? = nil,
        thumbnailURL: String = "",
        variants: [StickerMessageVariantSnapshot] = [],
        fallbackText: String = StickerMessageSnapshot.fallbackText
    ) {
        self.stickerID = stickerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.packID = packID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.width = width
        self.height = height
        self.durationMS = durationMS
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.variants = variants
        self.fallbackText = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.fallbackText : fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var dictionary: [String: Any] {
        var output: [String: Any] = [
            "type": "sticker",
            "sticker_id": stickerID,
            "pack_id": packID,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "fallback_text": fallbackText
        ]
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        output["variants"] = variants.map(\.dictionary)
        return output
    }

    public var messageSendDictionary: [String: Any] {
        var output: [String: Any] = [
            "type": "sticker",
            "sticker_id": stickerID,
            "pack_id": packID,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "fallback_text": fallbackText
        ]
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        output["variants"] = variants.map(\.messageSendDictionary)
        return output
    }

    public var cacheIdentity: String {
        let variant = variants.first { !$0.kind.isEmpty || !$0.cacheKey.isEmpty || !$0.fileID.isEmpty }
        return [
            fileID,
            variant?.cacheKey ?? "",
            variant?.kind ?? "",
            stickerID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }
}

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
public struct StickerResolvedFileAsset: Equatable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        fileID: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int64,
        cacheKey: String,
        version: String,
        checksum: String,
        thumbnailURL: String,
        previewURL: String,
        downloadURL: String,
        localThumbnailURL: String = "",
        localPreviewURL: String = "",
        localDownloadURL: String = ""
    ) {
        self.fileID = fileID
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.localThumbnailURL = localThumbnailURL
        self.localPreviewURL = localPreviewURL
        self.localDownloadURL = localDownloadURL
    }
    public let fileID: String
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let cacheKey: String
    public let version: String
    public let checksum: String
    public let thumbnailURL: String
    public let previewURL: String
    public let downloadURL: String
    public var localThumbnailURL: String = ""
    public var localPreviewURL: String = ""
    public var localDownloadURL: String = ""
}
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
