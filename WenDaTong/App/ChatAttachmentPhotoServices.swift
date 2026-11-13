import UIKit
import Photos

enum AttachmentPhotoLibrarySaveResult {
    case success
    case denied
    case failed(String)
    case unknownFailure
}

enum AttachmentPhotoLibrarySaver {
    static func saveOriginalImage(at url: URL) async -> AttachmentPhotoLibrarySaveResult {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return .unknownFailure }
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else { return .denied }
        return await performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    static func saveImage(_ image: UIImage) async -> AttachmentPhotoLibrarySaveResult {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return .denied
        }
        return await performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func saveVideo(at url: URL) async -> AttachmentPhotoLibrarySaveResult {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return .denied
        }
        return await performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_PHOTOS_SENDABLE - 修改开始：对齐 Swift 6 Photos 写入闭包并发边界
    private static func performChanges(_ changes: @escaping @Sendable () -> Void) async -> AttachmentPhotoLibrarySaveResult {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume(returning: .success)
                } else if let error {
                    continuation.resume(returning: .failed(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试")))
                } else {
                    continuation.resume(returning: .unknownFailure)
                }
            }
        }
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_PHOTOS_SENDABLE - 修改结束
}
