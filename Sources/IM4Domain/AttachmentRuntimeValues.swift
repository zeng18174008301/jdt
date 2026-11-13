// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
import Foundation

public struct PendingAttachmentUpload {
    public let kind: MessageKind
    public let name: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let data: Data?
    public let fileURL: URL?
    public let removeFileWhenFinished: Bool
    public let conversationID: String
    public let quote: String?
    public let replyContext: MessageReplyContext?
    public let voiceDurationMS: Int?
    public let voiceWaveform: [Int]
    public let onPolicyRejected: (@MainActor () -> Void)?


    public init(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64,
        data: Data? = nil,
        fileURL: URL? = nil,
        removeFileWhenFinished: Bool = false,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext?,
        voiceDurationMS: Int? = nil,
        normalizedVoiceWaveform: [Int],
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) {
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.fileURL = fileURL
        self.removeFileWhenFinished = removeFileWhenFinished
        self.conversationID = conversationID
        self.quote = quote
        self.replyContext = replyContext
        self.voiceDurationMS = voiceDurationMS
        self.voiceWaveform = normalizedVoiceWaveform
        self.onPolicyRejected = onPolicyRejected
    }
}

public struct AttachmentUploadCheckpoint<CompletedFile> {
    public var fileID: String
    public var putCompleted: Bool
    public var completedFile: CompletedFile?
    public var accelerated: Bool = false
    public var standardFallbackUsed: Bool = false
    public var videoVerificationSelected: Bool = false

    public var videoVerificationPhase: String {
        if standardFallbackUsed { return "video_fallback_verifying" }
        return accelerated ? "video_accelerated_verifying" : "video_verifying"
    }

    public init(
        fileID: String,
        putCompleted: Bool,
        completedFile: CompletedFile? = nil,
        accelerated: Bool = false,
        standardFallbackUsed: Bool = false,
        videoVerificationSelected: Bool = false
    ) {
        self.fileID = fileID
        self.putCompleted = putCompleted
        self.completedFile = completedFile
        self.accelerated = accelerated
        self.standardFallbackUsed = standardFallbackUsed
        self.videoVerificationSelected = videoVerificationSelected
    }
}

public struct LocalAttachmentPreviewResources: Equatable, Sendable {
// JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
    public let previewURL: URL?
    public let downloadURL: URL?
    public let thumbnailURL: URL?
    public let width: Int?
    public let height: Int?


    public init(
        previewURL: URL?,
        downloadURL: URL?,
        thumbnailURL: URL?,
        width: Int?,
        height: Int?
    ) {
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
    }
}
