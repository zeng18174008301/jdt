// WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
import Foundation

public struct RemoteAvatarUploadData: Decodable, Sendable {
    public let file: RemoteAvatarFile
    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_UPLOAD - 修改开始：兼容 presign 返回 file.status=uploaded 且不带 upload 描述
    public let upload: RemoteSignedUpload?
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_UPLOAD - 修改结束

    public init(file: RemoteAvatarFile, upload: RemoteSignedUpload?) {
        self.file = file
        self.upload = upload
    }
}

public struct RemoteUploadedFileResponse: Decodable, Sendable {
    public let file: RemoteAvatarFile

    enum CodingKeys: String, CodingKey {
        case file
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try c.decodeIfPresent(RemoteAvatarFile.self, forKey: .file) {
            file = nested
        } else {
            file = try RemoteAvatarFile(from: decoder)
        }
    }
}

public struct RemoteAvatarFile: Decodable, Sendable {
    public let id: String
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int
    public let status: String
    public let uploadStatus: String
    public let previewAvailable: Bool
    public let downloadAvailable: Bool
    public let previewURL: String
    public let downloadURL: String
    public let downloadEndpoint: String
    public let detailEndpoint: String
    public let cacheKey: String
    public let version: String
    public let checksum: String
    public let mediaCategory: String
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
        case sizeBytes = "size_bytes"
        case size
        case status
        case uploadStatus = "upload_status"
        case previewAvailable = "preview_available"
        case downloadAvailable = "download_available"
        case previewURL = "preview_url"
        case downloadURL = "download_url"
        case downloadPublic = "download_public"
        case downloadEndpoint = "download_endpoint"
        case detailEndpoint = "detail_endpoint"
        case cacheKey = "cache_key"
        case thumbObjectKey = "thumb_object_key"
        case thumbnailObjectKey = "thumbnail_object_key"
        case objectKey = "object_key"
        case version
        case fileVersion = "file_version"
        case cacheVersion = "cache_version"
        case checksum
        case checksumSHA256 = "checksum_sha256"
        case mediaCategory = "media_category"
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .fileID)
            ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
            ?? c.decodeIfPresent(Int.self, forKey: .size)
            ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        uploadStatus = try c.decodeIfPresent(String.self, forKey: .uploadStatus) ?? status
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        downloadAvailable = try c.decodeIfPresent(Bool.self, forKey: .downloadAvailable) ?? false
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPublic)
            ?? ""
        downloadEndpoint = try c.decodeIfPresent(String.self, forKey: .downloadEndpoint) ?? ""
        detailEndpoint = try c.decodeIfPresent(String.self, forKey: .detailEndpoint) ?? ""
        let objectKey = try c.decodeIfPresent(String.self, forKey: .thumbObjectKey)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailObjectKey)
            ?? c.decodeIfPresent(String.self, forKey: .objectKey)
            ?? ""
        cacheKey = try c.decodeIfPresent(String.self, forKey: .cacheKey) ?? objectKey
        version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? c.decodeIfPresent(String.self, forKey: .fileVersion)
            ?? c.decodeIfPresent(String.self, forKey: .cacheVersion)
            ?? ""
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum)
            ?? c.decodeIfPresent(String.self, forKey: .checksumSHA256) ?? ""
        mediaCategory = try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? ""
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

    public func merged(with fallback: RemoteAvatarFile) -> RemoteAvatarFile {
        RemoteAvatarFile(
            id: id.isEmpty ? fallback.id : id,
            fileName: fileName.isEmpty ? fallback.fileName : fileName,
            mimeType: mimeType.isEmpty ? fallback.mimeType : mimeType,
            sizeBytes: sizeBytes > 0 ? sizeBytes : fallback.sizeBytes,
            status: status.isEmpty ? fallback.status : status,
            uploadStatus: uploadStatus.isEmpty ? fallback.uploadStatus : uploadStatus,
            previewAvailable: previewAvailable || fallback.previewAvailable,
            downloadAvailable: downloadAvailable || fallback.downloadAvailable,
            previewURL: previewURL.isEmpty ? fallback.previewURL : previewURL,
            downloadURL: downloadURL.isEmpty ? fallback.downloadURL : downloadURL,
            downloadEndpoint: downloadEndpoint.isEmpty ? fallback.downloadEndpoint : downloadEndpoint,
            detailEndpoint: detailEndpoint.isEmpty ? fallback.detailEndpoint : detailEndpoint,
            cacheKey: cacheKey.isEmpty ? fallback.cacheKey : cacheKey,
            version: version.isEmpty ? fallback.version : version,
            checksum: checksum.isEmpty ? fallback.checksum : checksum,
            mediaCategory: mediaCategory.isEmpty ? fallback.mediaCategory : mediaCategory,
            fileExtension: fileExtension.isEmpty ? fallback.fileExtension : fileExtension,
            thumbnailURL: thumbnailURL.isEmpty ? fallback.thumbnailURL : thumbnailURL,
            posterURL: posterURL.isEmpty ? fallback.posterURL : posterURL,
            coverURL: coverURL.isEmpty ? fallback.coverURL : coverURL,
            previewKind: previewKind.isEmpty ? fallback.previewKind : previewKind,
            contentDisposition: contentDisposition.isEmpty ? fallback.contentDisposition : contentDisposition,
            width: width ?? fallback.width,
            height: height ?? fallback.height,
            durationSeconds: durationSeconds ?? fallback.durationSeconds
        )
    }

    public init(
        id: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        status: String,
        uploadStatus: String,
        previewAvailable: Bool,
        downloadAvailable: Bool,
        previewURL: String,
        downloadURL: String,
        downloadEndpoint: String,
        detailEndpoint: String,
        cacheKey: String,
        version: String,
        checksum: String,
        mediaCategory: String,
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
        self.status = status
        self.uploadStatus = uploadStatus
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.downloadEndpoint = downloadEndpoint
        self.detailEndpoint = detailEndpoint
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
        self.mediaCategory = mediaCategory
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

public struct RemoteSignedUpload: Decodable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let transport: String

    enum CodingKeys: String, CodingKey {
        case url
        case method
        case headers
        case transport
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""
    }
}

public struct RemoteAvatarCommitData: Decodable, Sendable {
    public let profile: RemoteAvatarProfile
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case profile
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatar
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(RemoteAvatarProfile.self, forKey: .profile) ?? RemoteAvatarProfile()
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .avatar)
            ?? profile.avatar
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? profile.avatarVersion
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? profile.avatarUpdatedAt
    }
}

public struct RemoteAvatarProfile: Decodable, Sendable {
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
    }

    public init(avatar: String = "", avatarVersion: String = "", avatarUpdatedAt: String = "") {
        self.avatar = avatar
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
            ?? ""
        avatarVersion = try c.decodeIfPresent(String.self, forKey: .avatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .version)
            ?? ""
        avatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ""
    }
}
// WDT_IOS1_DATA_NETWORK_DTO_20261110_END
