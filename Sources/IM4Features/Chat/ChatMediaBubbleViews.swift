import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
public struct StickerMessagePresentation: Equatable {
    public let thumbnailURL: URL?
    public let animationURL: URL?
    public let requestKey: String
    public let animationCacheKey: String

    public init(thumbnailURL: URL? = nil,
        animationURL: URL? = nil,
        requestKey: String,
        animationCacheKey: String) {
        self.thumbnailURL = thumbnailURL
        self.animationURL = animationURL
        self.requestKey = requestKey
        self.animationCacheKey = animationCacheKey
    }
}

public struct AttachmentGIFRenderPresentation: Equatable {
    public let canPlay: Bool
    public let url: URL?
    public let cacheKey: String
    public let playbackPriority: Bool

    public init(canPlay: Bool,
        url: URL? = nil,
        cacheKey: String,
        playbackPriority: Bool) {
        self.canPlay = canPlay
        self.url = url
        self.cacheKey = cacheKey
        self.playbackPriority = playbackPriority
    }
}

public struct VoiceMessagePresentation: Equatable {
    public let isPlaying: Bool
    public let playbackState: VoiceMessagePlaybackState?
    public let progress: Double?
    public let isUploadTransfer: Bool
    public let download: AttachmentDownloadSnapshot?
    public let canRetryUpload: Bool
    public let downloadFailed: Bool

    public init(isPlaying: Bool,
        playbackState: VoiceMessagePlaybackState? = nil,
        progress: Double? = nil,
        isUploadTransfer: Bool,
        download: AttachmentDownloadSnapshot? = nil,
        canRetryUpload: Bool,
        downloadFailed: Bool) {
        self.isPlaying = isPlaying
        self.playbackState = playbackState
        self.progress = progress
        self.isUploadTransfer = isUploadTransfer
        self.download = download
        self.canRetryUpload = canRetryUpload
        self.downloadFailed = downloadFailed
    }
}

public struct StickerMessageContent: View {
    let message: ChatMessage

    private var snapshot: StickerMessageSnapshot? {
        message.stickerSnapshot
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 188
        let maxHeight: CGFloat = 214
        let minSide: CGFloat = 86
        let rawWidth = CGFloat(snapshot?.width ?? 128)
        let rawHeight = CGFloat(snapshot?.height ?? 128)
        let aspect = rawWidth > 0 && rawHeight > 0 ? min(max(rawWidth / rawHeight, 0.58), 2.0) : 1
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: max(minSide, width), height: max(minSide, height))
    }

    let presentation: StickerMessagePresentation
    let resolveAssets: () -> Void
    public var body: some View {
        ChatGIFPlayerView(
            url: presentation.animationURL,
            cacheKey: presentation.animationCacheKey,
            maxPixelSize: Int(max(displaySize.width, displaySize.height) * UIScreen.main.scale)
        ) {
            stickerPlaceholder(thumbnailURLString: presentation.thumbnailURL?.absoluteString ?? "")
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText)
        .task(id: presentation.requestKey) {
            resolveAssets()
        }
    }

    private func stickerPlaceholder(thumbnailURLString: String) -> some View {
        ZStack {
            if thumbnailURLString.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(IMColor.brand.opacity(0.78))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatRemoteImageView(
                    urlString: thumbnailURLString,
                    cacheKey: "sticker-thumbnail|\(snapshot?.cacheIdentity ?? message.id)",
                    contentMode: .fit,
                    // WDT_CHAT_RESOURCE_PERF_20261023
                    maxPixelSize: Int(max(displaySize.width, displaySize.height) * UIScreen.main.scale)
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(2)
            }
        }
    }

    public init(message: ChatMessage,
        presentation: StickerMessagePresentation,
        resolveAssets: @escaping () -> Void) {
        self.message = message
        self.presentation = presentation
        self.resolveAssets = resolveAssets
    }
}

public struct AttachmentGIFContent<Placeholder: View>: View {
    let presentation: AttachmentGIFRenderPresentation
    let maxPixelSize: Int
    let recoveryURL: () async -> URL?
    @ViewBuilder var placeholder: () -> Placeholder

    public var body: some View {
        Group {
            if presentation.canPlay {
                ChatGIFPlayerView(url: presentation.url, cacheKey: presentation.cacheKey,
                    maxPixelSize: maxPixelSize, requiresGIF: true,
                    playbackPriority: presentation.playbackPriority,
                    recoveryURL: recoveryURL, placeholder: placeholder)
            } else { placeholder() }
        }
    }

    public init(presentation: AttachmentGIFRenderPresentation,
        maxPixelSize: Int,
        recoveryURL: @escaping () async -> URL?,
        @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.presentation = presentation
        self.maxPixelSize = maxPixelSize
        self.recoveryURL = recoveryURL
        self.placeholder = placeholder
    }
}

public struct VoiceMessageContent: View {
    let message: ChatMessage
    let outgoing: Bool
    var conversationID: String = ""

    private var progress: Double? {
        presentation.progress
    }

    private var isUploadTransfer: Bool {
        presentation.isUploadTransfer
    }

    // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110
    private func durationText(playbackState: VoiceMessagePlaybackState?) -> String {
        if let playbackState {
            let remaining = playbackState.remainingLabel
            return remaining.isEmpty ? "0秒" : remaining
        }
        if let seconds = message.attachmentDurationSeconds, seconds > 0 {
            return VoiceMessagePayload.durationLabel(durationMS: VoiceMessagePayload.decodedDurationMS(seconds) ?? 0) // WDT_IOS1_SAFE_NUMERIC_20261023
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "语音" : text
    }

    private var statusColor: Color {
        outgoing ? .white.opacity(0.82) : IMColor.muted
    }

    let presentation: VoiceMessagePresentation
    let onToggle: () -> Void
    let onCancelDownload: () -> Void
    let onCancelTransfer: () -> Void
    let onRetry: () -> Void
    let onDisappear: () -> Void

    public var body: some View {
        // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_BEGIN
        let isPlaying = presentation.isPlaying
        let playbackState = presentation.playbackState
        // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_END
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(outgoing ? IMColor.brand : .white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(outgoing ? .white : IMColor.brand))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat_voice_play_button")
                .accessibilityLabel(isPlaying ? "暂停语音消息" : "播放语音消息")

                VoiceWaveformBars(
                    samples: message.voiceWaveform,
                    active: isPlaying,
                    outgoing: outgoing,
                    height: 26,
                    barCount: 28,
                    fitsAvailableWidth: true // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113
                )

                // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_BEGIN
                Text(durationText(playbackState: playbackState))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(outgoing ? .white : IMColor.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .frame(idealWidth: 198, alignment: .leading)
            // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_END

            if let playbackState {
                HStack(spacing: 8) {
                    ProgressView(value: playbackState.progress)
                        .tint(outgoing ? .white : IMColor.brand)
                        .frame(width: 132)
                    Text("剩余 \(playbackState.remainingLabel.isEmpty ? "0秒" : playbackState.remainingLabel)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("语音播放进度，剩余 \(playbackState.remainingLabel.isEmpty ? "0秒" : playbackState.remainingLabel)")
            }

            HStack(spacing: 8) {
                if let snapshot = presentation.download, !isUploadTransfer {
                    AttachmentDownloadProgressView(snapshot: snapshot) { onCancelDownload() }
                } else if let progress {
                    ProgressView(value: progress)
                        .tint(outgoing ? .white : IMColor.brand)
                        .frame(width: 92)
                    Text(voiceTransferLabel(progress))
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                    Button {
                        onCancelTransfer()
                    } label: {
                        Text("取消")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.danger)
                    }
                    .buttonStyle(.plain)
                } else if message.status == .failed {
                    Button {
                        onRetry()
                    } label: {
                        Label(presentation.canRetryUpload ? "发送失败 · 重试" : "发送失败", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(outgoing ? .white.opacity(0.9) : IMColor.danger)
                    }
                    .buttonStyle(.plain)
                } else if presentation.downloadFailed {
                    Label("下载失败 · 点按重试", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(outgoing ? .white.opacity(0.88) : IMColor.danger)
                } else {
                    Label("语音消息", systemImage: "waveform")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(statusColor)
                }
            }
        }
        .onDisappear {
            onDisappear()
        }
    }

    private func voiceTransferLabel(_ progress: Double) -> String {
        let percent = "\(Int(max(0, min(progress, 1)) * 100))%"
        if isUploadTransfer {
            return progress >= 0.9 ? "处理中" : "上传 \(percent)"
        }
        return progress >= 0.99 ? "打开中" : "下载 \(percent)"
    }

    public init(message: ChatMessage,
        outgoing: Bool,
        conversationID: String = "",
        presentation: VoiceMessagePresentation,
        onToggle: @escaping () -> Void,
        onCancelDownload: @escaping () -> Void,
        onCancelTransfer: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onDisappear: @escaping () -> Void) {
        self.message = message
        self.outgoing = outgoing
        self.conversationID = conversationID
        self.presentation = presentation
        self.onToggle = onToggle
        self.onCancelDownload = onCancelDownload
        self.onCancelTransfer = onCancelTransfer
        self.onRetry = onRetry
        self.onDisappear = onDisappear
    }
}
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END

public enum AttachmentGIFPresentation {
    static public func usesBorderlessContainer(_ message: ChatMessage) -> Bool {
        message.isStickerMessage || ((message.kind == .image || message.kind == .file)
            && isGIF(message) && message.status != .recalled && !message.isDeletedLocally)
    }

    static public func isGIF(_ message: ChatMessage) -> Bool {
        let mime = message.attachmentMimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime == "image/gif" { return true }
        guard mime.isEmpty || mime == "application/octet-stream" else { return false }
        return message.attachmentExtension.lowercased() == "gif"
            || ((message.attachmentName ?? "") as NSString).pathExtension.lowercased() == "gif"
    }

    static public func canPlay(_ message: ChatMessage) -> Bool {
        isGIF(message) && message.status != .recalled && !message.isDeletedLocally
            && (message.attachmentSizeBytes ?? 0) <= 10_485_760
    }

    static public func originalURL(localURL: URL?, downloadURL: URL?, previewURL: URL?, downloadAllowed: Bool = true, previewAllowed: Bool = true) -> URL? {
        // A thumbnail is deliberately not a candidate for animation.
        localURL ?? (downloadAllowed ? downloadURL : nil) ?? (previewAllowed ? previewURL : nil)
    }

    // WDT_IOS1_CHAT_GIF_RENDER_PRESENTATION_20261111_BEGIN
    public static func renderPresentation(
        canPlay: Bool,
        localURL: URL?,
        downloadURL: URL?,
        previewURL: URL?,
        downloadAllowed: Bool,
        previewAllowed: Bool,
        cacheKey: String
    ) -> AttachmentGIFRenderPresentation {
        AttachmentGIFRenderPresentation(
            canPlay: canPlay,
            url: canPlay ? originalURL(
                localURL: localURL,
                downloadURL: downloadURL,
                previewURL: previewURL,
                downloadAllowed: downloadAllowed,
                previewAllowed: previewAllowed
            ) : nil,
            cacheKey: cacheKey,
            playbackPriority: localURL != nil
        )
    }
    // WDT_IOS1_CHAT_GIF_RENDER_PRESENTATION_20261111_END
}

// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
public struct FileMessagePresentation: Equatable {
    public let mediaCategory: String
    public let progress: Double?
    public let isUploadTransfer: Bool
    public let attachmentDownloaded: Bool
    public let download: AttachmentDownloadSnapshot?
    public let canRetryUpload: Bool
    public let downloadFailed: Bool

    public init(mediaCategory: String,
        progress: Double? = nil,
        isUploadTransfer: Bool,
        attachmentDownloaded: Bool,
        download: AttachmentDownloadSnapshot? = nil,
        canRetryUpload: Bool,
        downloadFailed: Bool) {
        self.mediaCategory = mediaCategory
        self.progress = progress
        self.isUploadTransfer = isUploadTransfer
        self.attachmentDownloaded = attachmentDownloaded
        self.download = download
        self.canRetryUpload = canRetryUpload
        self.downloadFailed = downloadFailed
    }
}

public struct FileMessageLayout {
    public let message: ChatMessage
    public let mediaCategory: String

    public var isBorderlessGIF: Bool {
        AttachmentGIFPresentation.usesBorderlessContainer(message)
    }

    public var mediaSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "audio": return "waveform"
        case "archive": return "archivebox.fill"
        default: return "doc.richtext.fill"
        }
    }

    public var mediaTitle: String {
        switch mediaCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        case "audio": return "音频"
        case "archive": return "压缩包"
        default: return "文件"
        }
    }

    public var fileName: String {
        (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名文件"
            : (message.attachmentName ?? message.text)
    }

    var fileSizeText: String {
        if let sizeBytes = message.attachmentSizeBytes, sizeBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        return "大小待同步"
    }

    var fileTypeBadge: String {
        let explicit = message.attachmentExtension.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pathExt = (fileName as NSString).pathExtension.uppercased()
        let category = mediaCategory.uppercased()
        let value = [explicit, pathExt, category].first { !$0.isEmpty && $0 != "FILE" && $0 != "UNKNOWN" } ?? "FILE"
        switch value {
        case "DOCX": return "DOC"
        case "XLSX": return "XLS"
        case "PPTX": return "PPT"
        case "JPEG": return "JPG"
        default: return String(value.prefix(4))
        }
    }

    var mediaAspectRatio: CGFloat {
        if mediaCategory == "video" { return 16.0 / 9.0 }
        if let width = message.attachmentWidth,
           let height = message.attachmentHeight,
           width > 0,
           height > 0 {
            return min(max(CGFloat(width) / CGFloat(height), 0.72), 1.85)
        }
        return 1.45
    }

    public var isMediaMessage: Bool {
        isBorderlessGIF || mediaCategory == "image" || mediaCategory == "video"
    }

    public var mediaFrameSize: CGSize {
        if isBorderlessGIF {
            let width = CGFloat(max(1, message.attachmentWidth ?? 128))
            let height = CGFloat(max(1, message.attachmentHeight ?? 128))
            let scale = min(188 / width, 214 / height)
            return CGSize(width: width * scale, height: height * scale)
        }
        let maxWidth: CGFloat = 204
        let maxHeight: CGFloat = 244
        var width = maxWidth
        var height = width / mediaAspectRatio
        if height > maxHeight {
            height = maxHeight
            width = height * mediaAspectRatio
        }
        return CGSize(width: max(132, width), height: max(118, height))
    }

    public init(message: ChatMessage,
        mediaCategory: String) {
        self.message = message
        self.mediaCategory = mediaCategory
    }
}

public struct FileMessageContent<GIF: View, Poster: View, Original: View, Fallback: View>: View {
    let message: ChatMessage
    let outgoing: Bool
    let presentation: FileMessagePresentation
    let onCancelDownload: () -> Void
    let onCancelTransfer: () -> Void
    let onCancelUpload: () -> Void
    @ViewBuilder var gifContent: () -> GIF
    @ViewBuilder var posterContent: () -> Poster
    @ViewBuilder var originalContent: () -> Original
    @ViewBuilder var fallbackContent: () -> Fallback
    private var layout: FileMessageLayout { FileMessageLayout(message: message, mediaCategory: presentation.mediaCategory) }
    private var progress: Double? { presentation.progress }
    private var isUploadTransfer: Bool { presentation.isUploadTransfer }
    private var mediaCategory: String { presentation.mediaCategory }
    private var isBorderlessGIF: Bool { layout.isBorderlessGIF }
    private var mediaSymbol: String { layout.mediaSymbol }
    private var mediaTitle: String { layout.mediaTitle }
    private var fileName: String { layout.fileName }
    private var fileSizeText: String { layout.fileSizeText }
    private var fileTypeBadge: String { layout.fileTypeBadge }
    private var mediaAspectRatio: CGFloat { layout.mediaAspectRatio }
    private var isMediaMessage: Bool { layout.isMediaMessage }
    private var mediaFrameSize: CGSize { layout.mediaFrameSize }
    public var body: some View { attachmentContent }

    private var usesOutgoingFill: Bool { outgoing && !isBorderlessGIF }

    private var uploadStageLabel: String? {
        guard isUploadTransfer, progress == nil else { return nil }
        let status = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch status {
        case "put", "uploading":
            return "上传中"
        case "uploaded", "finalize", "processing":
            return "处理中"
        case "send", "message_send", "awaiting_ack":
            return "发送中"
        case "retrying":
            return "等待重试"
        default:
            return message.status == .sending ? "准备上传" : nil
        }
    }

    private var attachmentActionLabel: String {
        presentation.attachmentDownloaded ? "保存/分享" : "点击下载"
    }

    private var fileTypeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(outgoing ? .white.opacity(0.18) : IMColor.brand.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(outgoing ? .white.opacity(0.22) : IMColor.brand.opacity(0.18), lineWidth: 1)
                )
            Text(fileTypeBadge)
                .font(.system(size: fileTypeBadge.count > 3 ? 10 : 12, weight: .black, design: .rounded))
                .foregroundStyle(outgoing ? .white : IMColor.brand)
                .padding(.horizontal, 4)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 48, height: 48)
        .accessibilityLabel("文件类型 \(fileTypeBadge)")
    }
    private func transferLabel(_ progress: Double) -> String {
        let percent = "\(Int(max(0, min(progress, 1)) * 100))%"
        if isUploadTransfer {
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_UPLOAD_LABEL_REAL_PERCENT - 修改开始：上传百分比只描述真实 PUT 进度
            return "上传 \(percent)"
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_UPLOAD_LABEL_REAL_PERCENT - 修改结束
        }
        return progress >= 0.99 ? "打开中" : "下载 \(percent)"
    }
    private var attachmentContent: some View {
        let videoDownload = mediaCategory == "video" && !isUploadTransfer ? presentation.download : nil // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113
        return VStack(alignment: .leading, spacing: 9) {
            if isMediaMessage {
                ZStack {
                    if AttachmentGIFPresentation.isGIF(message) {
                        gifContent()
                    } else if mediaCategory == "video" {
                        IMColor.ink.opacity(0.10)
                            .frame(width: mediaFrameSize.width, height: mediaFrameSize.height)
                            .overlay {
                                posterContent()
                            }
                    } else if mediaCategory == "image" {
                        Color.clear
                            .frame(width: mediaFrameSize.width, height: mediaFrameSize.height)
                            .overlay {
                                originalContent()
                            }
                    } else {
                        fallbackContent()
                    }
                    if mediaCategory == "video", videoDownload == nil { // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.42)))
                    }
                }
                .frame(width: mediaFrameSize.width, height: mediaFrameSize.height)
                // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_BEGIN
                .accessibilityLabel(mediaCategory == "video" ? "视频消息，点按播放" : "图片消息，点按查看原图")
                .overlay(alignment: .bottom) {
                    if let videoDownload {
                        AttachmentDownloadProgressView(snapshot: videoDownload, compact: true, onCancel: onCancelDownload)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 10))
                            .padding(6)
                            .accessibilityIdentifier("chat_video_download_progress")
                    }
                }
                // WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_END
                .clipShape(RoundedRectangle(cornerRadius: isBorderlessGIF ? 0 : 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isBorderlessGIF ? .clear : (usesOutgoingFill ? .white.opacity(0.20) : IMColor.brand.opacity(0.12)), lineWidth: 1)
                )
            } else {
                HStack(spacing: 10) {
                    fileTypeIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileName)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.ink)
                            .lineLimit(2)
                        Text([mediaTitle, fileSizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(outgoing ? .white.opacity(0.78) : IMColor.muted)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 210, alignment: .leading)
                .accessibilityLabel("文件 \(fileName)，\(fileSizeText)，\(attachmentActionLabel)")
            }

            if !isBorderlessGIF || progress != nil || presentation.download != nil || uploadStageLabel != nil || message.status == .failed || presentation.downloadFailed {
                HStack(spacing: 8) {
                    if mediaCategory != "video", let snapshot = presentation.download, !isUploadTransfer {
                        AttachmentDownloadProgressView(snapshot: snapshot) { onCancelDownload() }
                    } else if let progress {
                        ProgressView(value: progress)
                            .tint(usesOutgoingFill ? .white : IMColor.brand)
                            .frame(width: 96)
                        Text(transferLabel(progress))
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                        Button {
                            onCancelTransfer()
                        } label: {
                            Text("取消")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(usesOutgoingFill ? .white : IMColor.danger)
                        }
                        .buttonStyle(.plain)
                    } else if let uploadStageLabel {
                        Label(uploadStageLabel, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                        Spacer(minLength: 0)
                        Button {
                            onCancelUpload()
                        } label: {
                            Text("取消")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(usesOutgoingFill ? .white : IMColor.danger)
                        }
                        .buttonStyle(.plain)
                    } else if message.status == .failed {
                        Label(presentation.canRetryUpload ? "发送失败 · 点按查看" : "发送失败", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.88) : IMColor.danger)
                    } else if mediaCategory != "video", presentation.downloadFailed {
                        Label("下载失败 · 点按重试", systemImage: "arrow.clockwise.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.88) : IMColor.danger)
                    } else if !isMediaMessage && message.status != .sending {
                        Label(attachmentActionLabel, systemImage: presentation.attachmentDownloaded ? "square.and.arrow.up.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.84) : IMColor.brand)
                    }
                }
            }
        }
    }

    public init(message: ChatMessage,
        outgoing: Bool,
        presentation: FileMessagePresentation,
        onCancelDownload: @escaping () -> Void,
        onCancelTransfer: @escaping () -> Void,
        onCancelUpload: @escaping () -> Void,
        @ViewBuilder gifContent: @escaping () -> GIF,
        @ViewBuilder posterContent: @escaping () -> Poster,
        @ViewBuilder originalContent: @escaping () -> Original,
        @ViewBuilder fallbackContent: @escaping () -> Fallback) {
        self.message = message
        self.outgoing = outgoing
        self.presentation = presentation
        self.onCancelDownload = onCancelDownload
        self.onCancelTransfer = onCancelTransfer
        self.onCancelUpload = onCancelUpload
        self.gifContent = gifContent
        self.posterContent = posterContent
        self.originalContent = originalContent
        self.fallbackContent = fallbackContent
    }
}

public struct FileAttachmentPlaceholder: View {
    let symbol: String
    let title: String
    let status: String
    let usesOutgoingFill: Bool
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .bold))
            Text(status)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(usesOutgoingFill ? .white.opacity(0.72) : IMColor.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(usesOutgoingFill ? .white.opacity(0.12) : IMColor.brand.opacity(0.08)))
    }

    public init(symbol: String,
        title: String,
        status: String,
        usesOutgoingFill: Bool) {
        self.symbol = symbol
        self.title = title
        self.status = status
        self.usesOutgoingFill = usesOutgoingFill
    }
}
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END
