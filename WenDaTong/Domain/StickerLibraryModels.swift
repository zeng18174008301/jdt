// WDT_IOS1_STICKER_STATE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

typealias StickerLibrarySource = IM4Domain.StickerLibrarySource
typealias StickerUploadPhase = IM4Domain.StickerUploadPhase
typealias StickerAssetVariant = IM4Domain.StickerAssetVariant
typealias StickerUploadDraft = IM4Domain.StickerUploadDraft
typealias StickerLibraryItem = IM4Domain.StickerLibraryItem
typealias StickerPackItem = IM4Domain.StickerPackItem
typealias CachedStickerManifest = IM4Domain.CachedStickerManifest

extension StickerAssetVariant {
    init(remote: RemoteStickerVariant) {
        self.init(
            kind: remote.kind,
            fileID: remote.fileID,
            mimeType: remote.mimeType,
            assetURL: remote.url,
            sizeBytes: remote.sizeBytes,
            width: remote.width,
            height: remote.height,
            durationMS: remote.durationMS,
            frameCount: remote.frameCount,
            thumbnailURL: remote.thumbnailURL,
            cacheKey: remote.cacheKey
        )
    }
}

extension StickerLibraryItem {
    init(remote: RemoteUserSticker) {
        self.init(
            id: remote.id.isEmpty ? remote.stickerID : remote.id,
            stickerID: remote.stickerID,
            fileID: remote.fileID,
            packID: "",
            source: .mine,
            status: remote.status,
            processingStatus: remote.processingStatus,
            sort: remote.sort,
            mimeType: remote.mimeType,
            sizeBytes: remote.sizeBytes,
            width: remote.width,
            height: remote.height,
            durationMS: remote.durationMS,
            frameCount: remote.frameCount,
            cacheKey: remote.cacheKey,
            version: remote.version,
            thumbnailURL: remote.thumbnailURL,
            variants: remote.variants.map(StickerAssetVariant.init(remote:)),
            errorCode: remote.errorCode,
            errorReason: remote.errorReason,
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt
        )
    }

    init(remote: RemoteSticker, packName: String = "") {
        let thumbnail = remote.thumbnailURL.isEmpty ? remote.imageURL : remote.thumbnailURL
        self.init(
            id: remote.id,
            stickerID: remote.id,
            fileID: remote.fileID,
            packID: remote.packID,
            source: .official,
            status: remote.status,
            processingStatus: remote.processingStatus,
            sort: remote.sort,
            mimeType: remote.mimeType,
            sizeBytes: remote.sizeBytes,
            width: remote.width,
            height: remote.height,
            durationMS: remote.durationMS,
            frameCount: remote.frameCount,
            cacheKey: remote.cacheKey,
            version: "",
            thumbnailURL: thumbnail,
            variants: remote.variants.map(StickerAssetVariant.init(remote:)),
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt,
            packName: packName
        )
    }

    init(commitResult: RemoteUserStickerCommitResult) {
        let remote = commitResult.sticker
        let task = commitResult.task
        let taskStatus = task?.status.isEmpty == false ? task?.status ?? "" : remote.processingStatus
        let submittedStickerID = remote.id.isEmpty ? task?.stickerID ?? "" : remote.id
        self.init(
            id: submittedStickerID.isEmpty ? (remote.fileID.isEmpty ? task?.id ?? "" : remote.fileID) : submittedStickerID,
            stickerID: submittedStickerID,
            fileID: remote.fileID.isEmpty ? task?.fileID ?? "" : remote.fileID,
            packID: remote.packID,
            source: .mine,
            status: remote.status.isEmpty ? "queued" : remote.status,
            processingStatus: taskStatus.isEmpty ? "queued" : taskStatus,
            sort: remote.sort,
            mimeType: remote.mimeType,
            sizeBytes: remote.sizeBytes,
            width: remote.width,
            height: remote.height,
            durationMS: remote.durationMS,
            frameCount: remote.frameCount,
            cacheKey: remote.cacheKey,
            version: "",
            thumbnailURL: remote.thumbnailURL,
            variants: remote.variants.map(StickerAssetVariant.init(remote:)),
            errorCode: task?.errorCode ?? "",
            errorReason: task?.errorReason ?? "",
            createdAt: task?.createdAt.isEmpty == false ? task?.createdAt ?? "" : remote.createdAt,
            updatedAt: task?.updatedAt.isEmpty == false ? task?.updatedAt ?? "" : remote.updatedAt
        )
    }
}

extension StickerPackItem {
    init(remote: RemoteStickerPack) {
        self.init(id: remote.id, name: remote.name, coverURL: remote.coverURL, sort: remote.sort, status: remote.status, createdAt: remote.createdAt, updatedAt: remote.updatedAt)
    }
}
// WDT_IOS1_STICKER_STATE_FAMILY_20261110_END
