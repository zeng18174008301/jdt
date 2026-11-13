// WDT_IOS1_STICKER_STATE_FAMILY_20261110_BEGIN
import Foundation

public enum StickerLibrarySource: String, Codable, Hashable {
    case mine
    case official
}

public enum StickerUploadPhase: String, Codable, Hashable {
    case compressing
    case uploading
    case processing
    case failed

    public var title: String {
        switch self {
        case .compressing: return "压缩中"
        case .uploading: return "上传中"
        case .processing: return "处理中"
        case .failed: return "失败"
        }
    }

    public var statusValue: String {
        switch self {
        case .compressing: return "compressing"
        case .uploading: return "uploading"
        case .processing: return "processing"
        case .failed: return "failed"
        }
    }
}

public struct StickerAssetVariant: Identifiable, Codable, Hashable {
    public var id: String { kind.isEmpty ? fileID : kind }
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
        sizeBytes: Int64?,
        width: Int?,
        height: Int?,
        durationMS: Int?,
        frameCount: Int?,
        thumbnailURL: String,
        cacheKey: String
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



    enum CodingKeys: String, CodingKey {
        case kind
        case fileID
        case mimeType
        case assetURL
        case sizeBytes
        case width
        case height
        case durationMS
        case frameCount
        case thumbnailURL
        case cacheKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "",
            fileID: try c.decodeIfPresent(String.self, forKey: .fileID) ?? "",
            mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "",
            assetURL: try c.decodeIfPresent(String.self, forKey: .assetURL) ?? "",
            sizeBytes: try c.decodeIfPresent(Int64.self, forKey: .sizeBytes),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS),
            frameCount: try c.decodeIfPresent(Int.self, forKey: .frameCount),
            thumbnailURL: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? "",
            cacheKey: try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? ""
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

public struct StickerUploadDraft {
    public init(data: Data, name: String, mimeType: String, conversationID: String) {
        self.data = data
        self.name = name
        self.mimeType = mimeType
        self.conversationID = conversationID
    }
    public let data: Data
    public let name: String
    public let mimeType: String
    public let conversationID: String
}

public struct StickerLibraryItem: Identifiable, Codable, Hashable {
    public static let localUploadIDPrefix = "local-upload-"

    public static func makeLocalUploadID() -> String {
        "\(localUploadIDPrefix)\(UUID().uuidString)"
    }

    public let id: String
    public let stickerID: String
    public let fileID: String
    public let packID: String
    public let source: StickerLibrarySource
    public var status: String
    public var processingStatus: String
    public var sort: Int
    public let mimeType: String
    public let sizeBytes: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMS: Int?
    public let frameCount: Int?
    public let cacheKey: String
    public let version: String
    public let thumbnailURL: String
    public let variants: [StickerAssetVariant]
    public let errorCode: String
    public let errorReason: String
    public let createdAt: String
    public let updatedAt: String
    public let displayName: String
    public let packName: String
    public var uploadPhase: StickerUploadPhase?
    public var uploadProgress: Double?

    public var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalizedProcessingStatus: String {
        processingStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isActive: Bool {
        normalizedStatus == "active" && (normalizedProcessingStatus.isEmpty || normalizedProcessingStatus == "active")
    }

    public var isProcessing: Bool {
        if let uploadPhase, uploadPhase != .failed { return true }
        return ["queued", "pending", "processing", "retrying", "uploading", "compressing"].contains(normalizedStatus)
            || ["queued", "pending", "processing", "retrying", "uploading", "compressing"].contains(normalizedProcessingStatus)
    }

    public var isFailed: Bool {
        if uploadPhase == .failed { return true }
        return ["failed", "rejected", "disabled"].contains(normalizedStatus)
            || ["failed", "rejected"].contains(normalizedProcessingStatus)
    }

    public var statusTitle: String {
        if let uploadTileTitle { return uploadTileTitle }
        if isActive { return "可用" }
        if normalizedStatus == "rejected" || normalizedProcessingStatus == "rejected" { return "已拒绝" }
        if isFailed { return "失败" }
        if isProcessing { return "处理中" }
        return status.isEmpty ? "待处理" : status
    }

    public var isLocalUploadPlaceholder: Bool {
        id.hasPrefix(Self.localUploadIDPrefix)
    }

    public var uploadTileTitle: String? {
        guard let uploadPhase else { return nil }
        if uploadPhase == .uploading, let uploadProgress {
            let percentage = Int((max(0, min(uploadProgress, 1)) * 100).rounded())
            return "\(percentage)%"
        }
        return uploadPhase.title
    }

    public var uploadSubtitle: String? {
        uploadPhase?.title
    }

    public var stableThumbnailCacheKey: String {
        let variant = variants.first { !$0.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return [
            source.rawValue,
            fileID,
            cacheKey,
            version,
            variant?.kind ?? "",
            variant?.fileID ?? "",
            variant?.cacheKey ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    public var persistentCacheCopy: StickerLibraryItem {
        StickerLibraryItem(
            id: id,
            stickerID: stickerID,
            fileID: fileID,
            packID: packID,
            source: source,
            status: status,
            processingStatus: processingStatus,
            sort: sort,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            width: width,
            height: height,
            durationMS: durationMS,
            frameCount: frameCount,
            cacheKey: cacheKey,
            version: version,
            thumbnailURL: Self.safePersistentURL(thumbnailURL),
            variants: variants.map { variant in
                StickerAssetVariant(
                    kind: variant.kind,
                    fileID: variant.fileID,
                    mimeType: variant.mimeType,
                    assetURL: Self.safePersistentURL(variant.assetURL),
                    sizeBytes: variant.sizeBytes,
                    width: variant.width,
                    height: variant.height,
                    durationMS: variant.durationMS,
                    frameCount: variant.frameCount,
                    thumbnailURL: Self.safePersistentURL(variant.thumbnailURL),
                    cacheKey: variant.cacheKey
                )
            },
            errorCode: errorCode,
            errorReason: errorReason,
            createdAt: createdAt,
            updatedAt: updatedAt,
            displayName: displayName,
            packName: packName,
            uploadPhase: nil,
            uploadProgress: nil
        )
    }

    public init(
        id: String,
        stickerID: String,
        fileID: String,
        packID: String,
        source: StickerLibrarySource,
        status: String,
        processingStatus: String,
        sort: Int,
        mimeType: String,
        sizeBytes: Int64?,
        width: Int?,
        height: Int?,
        durationMS: Int?,
        frameCount: Int?,
        cacheKey: String,
        version: String,
        thumbnailURL: String,
        variants: [StickerAssetVariant],
        errorCode: String = "",
        errorReason: String = "",
        createdAt: String,
        updatedAt: String,
        displayName: String = "",
        packName: String = "",
        uploadPhase: StickerUploadPhase? = nil,
        uploadProgress: Double? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stickerID = stickerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.packID = packID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.status = status.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processingStatus = processingStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sort = sort
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.durationMS = durationMS
        self.frameCount = frameCount
        self.cacheKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.variants = variants
        self.errorCode = errorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorReason = errorReason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.packName = packName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.uploadPhase = uploadPhase
        self.uploadProgress = uploadProgress.map { max(0, min($0, 1)) }
    }







    public init(localUploadID: String, name: String, mimeType: String, sizeBytes: Int) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.init(
            id: localUploadID,
            stickerID: "",
            fileID: localUploadID,
            packID: "",
            source: .mine,
            status: StickerUploadPhase.uploading.statusValue,
            processingStatus: StickerUploadPhase.uploading.statusValue,
            sort: Int.min,
            mimeType: mimeType,
            sizeBytes: Int64(sizeBytes),
            width: nil,
            height: nil,
            durationMS: nil,
            frameCount: nil,
            cacheKey: localUploadID,
            version: "local",
            thumbnailURL: "",
            variants: [],
            createdAt: now,
            updatedAt: now,
            displayName: name,
            uploadPhase: .uploading,
            uploadProgress: 0.02
        )
    }

    private static func safePersistentURL(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        guard let url = URL(string: value) else { return value } // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        let queryNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map { $0.name.lowercased() } ?? [] // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        if queryNames.contains("sig") {
            return ""
        }
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END
        let query = (url.query ?? "").lowercased()
        let blockedFragments = [
            "signature",
            "x-oss",
            "credential",
            "expires",
            "token",
            "access_key",
            "security-token"
        ]
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        if blockedFragments.contains(where: { fragment in
            query.contains(fragment) || queryNames.contains(where: { $0.contains(fragment) })
        }) {
            return ""
        }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        return value
    }
}

public struct StickerPackItem: Identifiable, Codable, Hashable {
    public init(id: String, name: String, coverURL: String, sort: Int, status: String, createdAt: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.sort = sort
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    public let id: String
    public let name: String
    public let coverURL: String
    public let sort: Int
    public let status: String
    public let createdAt: String
    public let updatedAt: String


}

public struct CachedStickerManifest: Codable, Equatable {
    public init(schemaVersion: Int, scope: String, updatedAt: TimeInterval, myStickers: [StickerLibraryItem]) {
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.updatedAt = updatedAt
        self.myStickers = myStickers
    }
    public let schemaVersion: Int
    public let scope: String
    public let updatedAt: TimeInterval
    public let myStickers: [StickerLibraryItem]
}
// WDT_IOS1_STICKER_STATE_FAMILY_20261110_END
