import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

public struct AttachmentSendConfirmationContent: View {
    let batch: ChatAttachmentConfirmationInput
    let config: FileUploadConfig
    let onCancel: () -> Void
    let onSend: () -> Void

    private var selections: [ChatAttachmentSelectionInput] {
        batch.selections
    }

    private var primarySelection: ChatAttachmentSelectionInput {
        selections.first ?? ChatAttachmentSelectionInput(id: UUID(), name: "附件", mediaCategory: "file",
            mimeType: "application/octet-stream", effectiveSizeBytes: 0, previewImage: nil)
    }

    private var sizeText: String {
        let size = batch.isMultiple ? batch.totalSizeBytes : primarySelection.effectiveSizeBytes
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
    private func exceedsLimit(using config: FileUploadConfig) -> Bool {
        selections.contains { !config.allowsUpload(sizeBytes: $0.effectiveSizeBytes) }
    }

    public var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.confirmation?(onSend)
#endif
        confirmationContent(config: config)
    }

    private func confirmationContent(config: FileUploadConfig) -> some View {
        let exceedsLimit = exceedsLimit(using: config)
        return NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(
                        symbol: "paperclip.circle.fill",
                        title: batch.title,
                        subtitle: batch.subtitle,
                        showsCloseButton: false
                    )

                    summaryCard(config: config, exceedsLimit: exceedsLimit)

                    HStack(spacing: 12) {
                        Button(action: onCancel) {
                            Text("取消")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                        }
                        .buttonStyle(.plain)

                        PrimaryButton(title: batch.confirmTitle, systemImage: "paperplane.fill") {
                            onSend()
                        }
                        .disabled(exceedsLimit)
                        .accessibilityLabel(batch.confirmTitle)
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func summaryCard(config: FileUploadConfig, exceedsLimit: Bool) -> some View {
        if batch.isMultiple {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selections) { selection in
                            preview(for: selection)
                                .overlay(alignment: .bottomTrailing) {
                                    Text(selection.mediaCategory == "video" ? "视频" : "照片")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.black.opacity(0.46)))
                                        .padding(5)
                                }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(batch.subtitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("总计 \(sizeText)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(exceedsLimit ? IMColor.danger : IMColor.muted)
                    if exceedsLimit {
                        Text(config.overLimitMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.danger)
                    }
                }
            }
            .im4PlainCard(radius: 24)
        } else {
            HStack(alignment: .top, spacing: 14) {
                preview(for: primarySelection)
                VStack(alignment: .leading, spacing: 8) {
                    Text(["image", "video"].contains(primarySelection.mediaCategory)
                        ? chatMediaAttachmentDisplayName(primarySelection.name) : primarySelection.name)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(2)
                    Text("\(primarySelection.typeTitle) · \(sizeText)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(exceedsLimit ? IMColor.danger : IMColor.muted)
                    if exceedsLimit {
                        Text(config.overLimitMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .im4PlainCard(radius: 24)
        }
    }
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END

    @ViewBuilder
    private func preview(for selection: ChatAttachmentSelectionInput) -> some View {
        if let image = selection.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(IMColor.brand.opacity(0.10))
                Image(systemName: selection.symbol)
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(IMColor.brand)
                if selection.mediaCategory == "video" {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.black.opacity(0.48)))
                        .offset(x: 24, y: 24)
                }
            }
            .frame(width: 82, height: 82)
        }
    }

    @ViewBuilder
    private var preview: some View {
        preview(for: primarySelection)
    }

    public init(batch: ChatAttachmentConfirmationInput,
        config: FileUploadConfig,
        onCancel: @escaping () -> Void,
        onSend: @escaping () -> Void) {
        self.batch = batch
        self.config = config
        self.onCancel = onCancel
        self.onSend = onSend
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END


public struct AttachmentLocalPreviewDocument: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public init(url: URL) { self.url = url }
}

public struct AttachmentMediaPreviewItem: Identifiable, Sendable {
    public let message: ChatMessage
    public let localURL: URL

    public var id: String {
        "\(message.id)|\(localURL.absoluteString)"
    }
    public init(message: ChatMessage, localURL: URL) { self.message = message; self.localURL = localURL }
}

public struct AttachmentShareItem: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public init(url: URL) { self.url = url }
}
