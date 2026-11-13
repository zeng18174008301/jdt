// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
import Foundation

public struct FileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let size: String
    public var sizeBytes: Int64? = nil
    public let owner: String
    public let source: String
    public let time: String
    public let scope: String
    public let status: String
    public let accentHex: UInt
    public var remoteFileID: String = ""
    public var previewURL: String = ""
    public var downloadURL: String = ""
    public var previewAvailable: Bool = false
    public var downloadAvailable: Bool = false
    public var channelID: String = ""
    public var channelType: String = ""
    public var channelSeq: Int64 = 0
    public var mediaCategory: String = ""
    public var contentType: String = ""
    public var kind: String = ""
    public var mimeType: String = ""
    public var cacheKey: String = ""
    public var version: String = ""
    public var checksum: String = ""
    public var fileExtension: String = ""
    public var thumbnailURL: String = ""
    public var posterURL: String = ""
    public var coverURL: String = ""
    public var previewKind: String = ""
    public var contentDisposition: String = ""
    public var width: Int? = nil
    public var height: Int? = nil
    public var durationSeconds: Double? = nil

    public var remoteLookupID: String {
        let explicit = remoteFileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let fallback = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.hasPrefix("local-attachment|") ? "" : fallback
    }

    public var hasRemoteFileID: Bool {
        !remoteLookupID.isEmpty
    }

    public var isVoiceMessageAsset: Bool {
        VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: contentType,
            mediaCategory: mediaCategory,
            kind: kind,
            previewKind: previewKind,
            type: type,
            name: name,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    public init(
        id: String,
        name: String,
        type: String,
        size: String,
        sizeBytes: Int64? = nil,
        owner: String,
        source: String,
        time: String,
        scope: String,
        status: String,
        accentHex: UInt,
        remoteFileID: String = "",
        previewURL: String = "",
        downloadURL: String = "",
        previewAvailable: Bool = false,
        downloadAvailable: Bool = false,
        channelID: String = "",
        channelType: String = "",
        channelSeq: Int64 = 0,
        mediaCategory: String = "",
        contentType: String = "",
        kind: String = "",
        mimeType: String = "",
        cacheKey: String = "",
        version: String = "",
        checksum: String = "",
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
        self.id = id
        self.name = name
        self.type = type
        self.size = size
        self.sizeBytes = sizeBytes
        self.owner = owner
        self.source = source
        self.time = time
        self.scope = scope
        self.status = status
        self.accentHex = accentHex
        self.remoteFileID = remoteFileID
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.previewAvailable = previewAvailable
        self.downloadAvailable = downloadAvailable
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.mediaCategory = mediaCategory
        self.contentType = contentType
        self.kind = kind
        self.mimeType = mimeType
        self.cacheKey = cacheKey
        self.version = version
        self.checksum = checksum
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

public enum VoiceFileListPolicy {
    public static func isVoiceMessageAsset(
        contentType: String,
        mediaCategory: String,
        kind: String,
        previewKind: String = "",
        type: String = "",
        name: String = "",
        mimeType: String = "",
        fileExtension: String = ""
    ) -> Bool {
        let explicitValues = [contentType, mediaCategory, kind, previewKind, type]
            .map(normalizedMarker)
        if explicitValues.contains(where: isVoiceMarker) {
            return true
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMIME = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedExtension = (fileExtension.isEmpty ? (name as NSString).pathExtension : fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let legacyVoiceName = normalizedName.hasPrefix("voice-")
            || normalizedName.hasPrefix("voice_")
            || normalizedName.hasPrefix("voice.")
        let audioContainer = normalizedMIME.hasPrefix("audio/")
            || ["m4a", "aac", "wav", "ogg", "opus", "webm", "amr"].contains(normalizedExtension)
        return legacyVoiceName && audioContainer
    }

    private static func normalizedMarker(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func isVoiceMarker(_ value: String) -> Bool {
        [
            "voice",
            "voice_message",
            "audio_message",
            "recorded_voice",
            "语音",
            "语音消息"
        ].contains(value)
    }
}

public struct FileUploadConfig: Hashable, Sendable {
    public static let fallbackMaximumBytes: Int64 = 500 * 1024 * 1024

    public static let defaultValue = FileUploadConfig(
        maxBytes: fallbackMaximumBytes,
        maxMB: 500,
        source: "default",
        messageRecallMaxMinutes: 120,
        voiceCallEnabled: true,
        videoCallEnabled: false,
        readReceiptsEnabled: true,
        groupAdminDeleteMessageEnabled: false,
        voiceCallLicenseKnown: false,
        videoCallLicenseKnown: false
    )

    public let maxBytes: Int64
    public let maxMB: Int
    public let source: String
    public let messageRecallMaxMinutes: Int
    public let voiceCallEnabled: Bool
    public let videoCallEnabled: Bool
    public let readReceiptsEnabled: Bool
    public let groupAdminDeleteMessageEnabled: Bool
    // Presence is local decode metadata, not another server permission source.
    public let voiceCallLicenseKnown: Bool
    public let videoCallLicenseKnown: Bool

    public init(
        maxBytes: Int64, maxMB: Int, source: String,
        messageRecallMaxMinutes: Int, voiceCallEnabled: Bool, videoCallEnabled: Bool,
        readReceiptsEnabled: Bool, groupAdminDeleteMessageEnabled: Bool,
        voiceCallLicenseKnown: Bool = true, videoCallLicenseKnown: Bool = true
    ) {
        self.maxBytes = maxBytes
        self.maxMB = maxMB
        self.source = source
        self.messageRecallMaxMinutes = messageRecallMaxMinutes
        self.voiceCallEnabled = voiceCallEnabled
        self.videoCallEnabled = videoCallEnabled
        self.readReceiptsEnabled = readReceiptsEnabled
        self.groupAdminDeleteMessageEnabled = groupAdminDeleteMessageEnabled
        self.voiceCallLicenseKnown = voiceCallLicenseKnown
        self.videoCallLicenseKnown = videoCallLicenseKnown
    }

    public var formattedMaxSize: String {
        let bytes = max(maxBytes, 0)
        let mb = 1024 * 1024
        let kb = 1024
        if bytes >= Int64(mb) {
            let whole = bytes / Int64(mb)
            let remainder = bytes % Int64(mb)
            if remainder == 0 {
                return "\(whole)M"
            }
            let tenths = (bytes * 10 + Int64(mb / 2)) / Int64(mb)
            if tenths % 10 == 0 {
                return "\(tenths / 10)M"
            }
            return "\(tenths / 10).\(tenths % 10)M"
        }
        if bytes >= Int64(kb) {
            let roundedKB = (bytes + Int64(kb - 1)) / Int64(kb)
            return "\(roundedKB)K"
        }
        return "\(bytes)B"
    }

    public var overLimitMessage: String {
        "文件大小超出当前企业限制（\(formattedMaxSize)）"
    }

    public func allowsUpload(sizeBytes: Int64) -> Bool {
        sizeBytes >= 0 && sizeBytes <= maxBytes
    }
}
