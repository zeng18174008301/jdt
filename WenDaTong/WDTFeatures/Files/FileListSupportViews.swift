import SwiftUI
import IM4Features
import IM4Stores
import UIKit
import QuickLook
import AVFoundation

// WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
struct FileDownloadProgress<Content: View>: View {
    let store: FileStore
    let keys: FileStore.DownloadKeys
    let content: (AttachmentDownloadSnapshot) -> Content

    var body: some View {
        PublisherSnapshotView(
            initialValue: store.attachmentDownloadSnapshot(keys: keys),
            updates: store.attachmentDownloadUpdates(keys: keys)
        ) { snapshot in
            if let snapshot { content(snapshot) }
        }
        .id(keys)
    }
}
// WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END

// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
typealias FileRefreshHintView = IM4Features.FileRefreshHintView
typealias FileLoadMoreFooter = IM4Features.FileLoadMoreFooter
typealias FilePreviewOpenState = IM4Features.FilePreviewOpenState
struct FavoriteAssetRenderItem: Identifiable {
    let asset: FavoriteAssetItem
    let presentation: FilePresentation

    var id: String { asset.id }
    var file: FileItem { asset.file }
}

struct FilePresentation {
    let visualKind: FileVisualKind
    let thumbnailURL: URL?
    let videoFrameURL: URL?
    let thumbnailCacheKey: String
    let needsRemotePreviewRefresh: Bool
    let previewRefreshTaskID: String

    init(file: FileItem) {
        let visualKind = file.visualKind
        self.visualKind = visualKind
        self.thumbnailURL = file.thumbnailRemoteURL(for: visualKind)
        self.videoFrameURL = file.videoFrameRemoteURL(for: visualKind)
        self.thumbnailCacheKey = file.mediaThumbnailCacheKey(for: visualKind)
        self.needsRemotePreviewRefresh = [.image, .video].contains(visualKind)
            && self.thumbnailURL == nil
            && self.videoFrameURL == nil
            && file.hasRemoteFileID
        self.previewRefreshTaskID = [
            file.remoteLookupID,
            file.cacheKey,
            file.version,
            file.thumbnailURL,
            file.posterURL,
            file.coverURL,
            file.previewURL,
            file.downloadURL
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }
}

struct FavoriteAssetRow: View {
    let downloadProgress: FileDownloadProgress<AttachmentDownloadProgressView>
    let item: FavoriteAssetRenderItem
    let isPreparingDownload: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onUnfavorite: () -> Void
    var body: some View {
        FavoriteAssetRowContent(downloadProgress: downloadProgress, file: item.file.featureDisplay, isUnavailable: item.asset.isUnavailable,
            isPreparingDownload: isPreparingDownload, thumbnail: { FileThumbnail(file: item.file, presentation: item.presentation, size: 54) },
            onOpen: onOpen, onDownload: onDownload, onShare: onShare, onUnfavorite: onUnfavorite)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END

extension FileItem {
    var featureDisplay: FileDisplayInput {
        FileDisplayInput(name: name, type: type, size: size, owner: owner, source: source,
                         time: time, scope: scope, status: status, accentHex: accentHex,
                         downloadAvailable: downloadAvailable)
    }
}
