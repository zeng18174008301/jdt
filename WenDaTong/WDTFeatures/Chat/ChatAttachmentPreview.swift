// WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111_BEGIN
import SwiftUI
import UIKit
import Photos
import AVFoundation
import AVKit
import IM4Features

typealias AttachmentImagePreviewInput = IM4Features.AttachmentImagePreviewInput
typealias AttachmentImagePreviewActions = IM4Features.AttachmentImagePreviewActions
typealias AttachmentImagePreviewContent<ImageContent: View> = IM4Features.AttachmentImagePreviewContent<ImageContent>
typealias AttachmentVideoPreviewContent = IM4Features.AttachmentVideoPreviewContent

typealias AttachmentMediaPreviewItem = IM4Features.AttachmentMediaPreviewItem

enum AttachmentSaveCapabilityPolicy {
    private static let saveableMediaCategories: Set<String> = [
        "image", "video", "file", "document", "pdf", "spreadsheet", "archive"
    ]

    static func canSave(
        kind: MessageKind,
        mediaCategory: String,
        status: MessageDelivery,
        isDeletedLocally: Bool,
        hasResolvableAsset: Bool
    ) -> Bool {
        guard status != .sending,
              status != .failed,
              status != .recalled,
              !isDeletedLocally,
              hasResolvableAsset else {
            return false
        }
        let normalizedCategory = mediaCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if saveableMediaCategories.contains(normalizedCategory) {
            return true
        }
        return kind == .file || kind == .image || kind == .video
    }
}

typealias AttachmentShareItem = IM4Features.AttachmentShareItem

struct AttachmentActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onComplete: ((Bool, Error?) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async {
                onComplete?(completed, error)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111_END
