import Combine
import Foundation

enum StickerLibrarySource: String, Codable, Hashable {
    case mine
    case official
}

enum StickerUploadPhase: String, Codable, Hashable {
    case compressing
    case uploading
    case processing
    case failed

    var title: String {
        switch self {
        case .compressing: return "压缩中"
        case .uploading: return "上传中"
        case .processing: return "处理中"
        case .failed: return "失败"
        }
    }

    var statusValue: String {
        switch self {
        case .compressing: return "compressing"
        case .uploading: return "uploading"
        case .processing: return "processing"
        case .failed: return "failed"
        }
    }
}

struct StickerAssetVariant: Identifiable, Codable, Hashable {
    var id: String { kind.isEmpty ? fileID : kind }
    let kind: String
    let fileID: String
    let mimeType: String
    let assetURL: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let thumbnailURL: String
    let cacheKey: String

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct StickerUploadDraft {
    let data: Data
    let name: String
    let mimeType: String
    let conversationID: String
}

struct StickerLibraryItem: Identifiable, Codable, Hashable {
    static let localUploadIDPrefix = "local-upload-"

    static func makeLocalUploadID() -> String {
        "\(localUploadIDPrefix)\(UUID().uuidString)"
    }

    let id: String
    let stickerID: String
    let fileID: String
    let packID: String
    let source: StickerLibrarySource
    var status: String
    var processingStatus: String
    var sort: Int
    let mimeType: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let cacheKey: String
    let version: String
    let thumbnailURL: String
    let variants: [StickerAssetVariant]
    let errorCode: String
    let errorReason: String
    let createdAt: String
    let updatedAt: String
    let displayName: String
    let packName: String
    var uploadPhase: StickerUploadPhase?
    var uploadProgress: Double?

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedProcessingStatus: String {
        processingStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isActive: Bool {
        normalizedStatus == "active" && (normalizedProcessingStatus.isEmpty || normalizedProcessingStatus == "active")
    }

    var isProcessing: Bool {
        if let uploadPhase, uploadPhase != .failed { return true }
        return ["queued", "pending", "processing", "retrying", "uploading", "compressing"].contains(normalizedStatus)
            || ["queued", "pending", "processing", "retrying", "uploading", "compressing"].contains(normalizedProcessingStatus)
    }

    var isFailed: Bool {
        if uploadPhase == .failed { return true }
        return ["failed", "rejected", "disabled"].contains(normalizedStatus)
            || ["failed", "rejected"].contains(normalizedProcessingStatus)
    }

    var statusTitle: String {
        if let uploadTileTitle { return uploadTileTitle }
        if isActive { return "可用" }
        if normalizedStatus == "rejected" || normalizedProcessingStatus == "rejected" { return "已拒绝" }
        if isFailed { return "失败" }
        if isProcessing { return "处理中" }
        return status.isEmpty ? "待处理" : status
    }

    var isLocalUploadPlaceholder: Bool {
        id.hasPrefix(Self.localUploadIDPrefix)
    }

    var uploadTileTitle: String? {
        guard let uploadPhase else { return nil }
        if uploadPhase == .uploading, let uploadProgress {
            let percentage = Int((max(0, min(uploadProgress, 1)) * 100).rounded())
            return "\(percentage)%"
        }
        return uploadPhase.title
    }

    var uploadSubtitle: String? {
        uploadPhase?.title
    }

    var stableThumbnailCacheKey: String {
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

    var persistentCacheCopy: StickerLibraryItem {
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

    init(
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

    init(localUploadID: String, name: String, mimeType: String, sizeBytes: Int) {
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
        guard let url = URL(string: value), url.scheme != nil else {
            return value
        }
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
        if blockedFragments.contains(where: { query.contains($0) }) {
            return ""
        }
        return value
    }
}

struct StickerPackItem: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let coverURL: String
    let sort: Int
    let status: String
    let createdAt: String
    let updatedAt: String

    init(remote: RemoteStickerPack) {
        id = remote.id
        name = remote.name
        coverURL = remote.coverURL
        sort = remote.sort
        status = remote.status
        createdAt = remote.createdAt
        updatedAt = remote.updatedAt
    }
}

struct CachedStickerManifest: Codable, Equatable {
    let schemaVersion: Int
    let scope: String
    let updatedAt: TimeInterval
    let myStickers: [StickerLibraryItem]
}

@MainActor
final class StickerStore: ObservableObject {
    @Published private(set) var currentScope = ""
    @Published private(set) var myStickers: [StickerLibraryItem] = []
    @Published private(set) var officialPacks: [StickerPackItem] = []
    @Published private(set) var officialStickersByPackID: [String: [StickerLibraryItem]] = [:]
    @Published private(set) var isManifestRefreshing = false
    @Published private(set) var manifestErrorMessage: String?
    @Published private(set) var officialErrorMessage: String?
    @Published private(set) var isUploading = false
    @Published private(set) var uploadProgress: Double?
    @Published private(set) var uploadMessage: String?
    @Published private(set) var deletingIDs: Set<String> = []
    @Published private(set) var sortingIDs: Set<String> = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var uploadDrafts: [String: StickerUploadDraft] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func activate(scope: String) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedScope != currentScope else { return }
        currentScope = normalizedScope
        manifestErrorMessage = nil
        officialErrorMessage = nil
        officialPacks = []
        officialStickersByPackID = [:]
        deletingIDs = []
        sortingIDs = []
        isUploading = false
        uploadProgress = nil
        uploadMessage = nil
        uploadDrafts = [:]
        if normalizedScope.isEmpty {
            myStickers = []
        } else {
            myStickers = loadCachedManifest(scope: normalizedScope)?.myStickers ?? []
        }
    }

    func resetRuntime() {
        currentScope = ""
        myStickers = []
        officialPacks = []
        officialStickersByPackID = [:]
        isManifestRefreshing = false
        manifestErrorMessage = nil
        officialErrorMessage = nil
        isUploading = false
        uploadProgress = nil
        uploadMessage = nil
        deletingIDs = []
        sortingIDs = []
        uploadDrafts = [:]
    }

    func replaceMyStickers(_ items: [StickerLibraryItem], scope: String) {
        activate(scope: scope)
        let localUploads = myStickers.filter(\.isLocalUploadPlaceholder)
        myStickers = Self.sortedUserItems(localUploads + items)
        manifestErrorMessage = nil
        persistManifest(scope: currentScope)
    }

    func upsertPendingSticker(_ item: StickerLibraryItem, scope: String) {
        activate(scope: scope)
        var next = myStickers
        next.removeAll { existing in
            (!item.stickerID.isEmpty && existing.stickerID == item.stickerID)
                || (!item.fileID.isEmpty && existing.fileID == item.fileID)
                || existing.id == item.id
        }
        next.insert(item, at: 0)
        myStickers = Self.sortedUserItems(next)
        persistManifest(scope: currentScope)
    }

    func removeMySticker(id: String, scope: String) {
        activate(scope: scope)
        myStickers.removeAll { $0.id == id || $0.stickerID == id }
        persistManifest(scope: currentScope)
    }

    func replaceOfficialPacks(_ packs: [StickerPackItem]) {
        officialPacks = packs.sorted { lhs, rhs in
            if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        officialErrorMessage = nil
    }

    func replaceOfficialStickers(_ stickers: [StickerLibraryItem], packID: String) {
        officialStickersByPackID[packID] = stickers.sorted { lhs, rhs in
            if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
            return lhs.id < rhs.id
        }
        officialErrorMessage = nil
    }

    func officialStickers(packID: String) -> [StickerLibraryItem] {
        officialStickersByPackID[packID] ?? []
    }

    func setManifestRefreshing(_ refreshing: Bool) {
        isManifestRefreshing = refreshing
        if refreshing {
            manifestErrorMessage = nil
        }
    }

    func setManifestError(_ message: String?) {
        manifestErrorMessage = message
        isManifestRefreshing = false
    }

    func setOfficialError(_ message: String?) {
        officialErrorMessage = message
    }

    func beginUpload(message: String) {
        isUploading = true
        uploadProgress = 0.02
        uploadMessage = message
    }

    func updateUpload(progress: Double, message: String? = nil) {
        uploadProgress = max(0, min(progress, 1))
        if let message {
            uploadMessage = message
        }
    }

    func finishUpload(message: String? = nil) {
        isUploading = false
        uploadProgress = nil
        uploadMessage = message
    }

    func beginLocalUpload(
        id: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        data: Data,
        conversationID: String,
        scope: String
    ) {
        activate(scope: scope)
        let uploadID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uploadID.isEmpty else { return }
        uploadDrafts[uploadID] = StickerUploadDraft(
            data: data,
            name: name,
            mimeType: mimeType,
            conversationID: conversationID
        )
        var next = myStickers
        next.removeAll { $0.id == uploadID }
        next.insert(
            StickerLibraryItem(localUploadID: uploadID, name: name, mimeType: mimeType, sizeBytes: sizeBytes),
            at: 0
        )
        myStickers = Self.sortedUserItems(next)
        recomputeUploadState()
    }

    func updateLocalUpload(id: String, phase: StickerUploadPhase, progress: Double? = nil, scope: String) {
        activate(scope: scope)
        guard let index = myStickers.firstIndex(where: { $0.id == id && $0.isLocalUploadPlaceholder }) else {
            recomputeUploadState()
            return
        }
        myStickers[index].uploadPhase = phase
        myStickers[index].uploadProgress = phase == .uploading ? progress.map { max(0, min($0, 1)) } : nil
        myStickers[index].status = phase.statusValue
        myStickers[index].processingStatus = phase.statusValue
        recomputeUploadState()
    }

    func replaceLocalUpload(id: String, with item: StickerLibraryItem, scope: String) {
        activate(scope: scope)
        uploadDrafts[id] = nil
        var next = myStickers
        let placeholderSort = next.first(where: { $0.id == id })?.sort ?? Int.min
        next.removeAll { existing in
            existing.id == id
                || existing.id == item.id
                || (!item.stickerID.isEmpty && existing.stickerID == item.stickerID)
                || (!item.fileID.isEmpty && existing.fileID == item.fileID)
        }
        var replacement = item
        replacement.sort = placeholderSort
        next.insert(replacement, at: 0)
        myStickers = Self.sortedUserItems(next)
        recomputeUploadState()
        persistManifest(scope: currentScope)
    }

    func failLocalUpload(id: String, scope: String) {
        updateLocalUpload(id: id, phase: .failed, scope: scope)
    }

    func removeLocalUpload(id: String, scope: String) {
        activate(scope: scope)
        uploadDrafts[id] = nil
        myStickers.removeAll { $0.id == id && $0.isLocalUploadPlaceholder }
        recomputeUploadState()
        persistManifest(scope: currentScope)
    }

    func localUploadDraft(id: String) -> StickerUploadDraft? {
        uploadDrafts[id]
    }

    func beginDeleting(id: String) {
        deletingIDs.insert(id)
    }

    func finishDeleting(id: String) {
        deletingIDs.remove(id)
    }

    func beginSorting(ids: [String]) {
        sortingIDs.formUnion(ids)
    }

    func finishSorting(ids: [String]) {
        sortingIDs.subtract(ids)
    }

    func moveUserSticker(id: String, direction: Int, scope: String) -> [String]? {
        activate(scope: scope)
        guard direction != 0,
              let index = myStickers.firstIndex(where: { $0.id == id && !$0.isLocalUploadPlaceholder }) else {
            return nil
        }
        let targetIndex = index + (direction < 0 ? -1 : 1)
        guard myStickers.indices.contains(targetIndex) else { return nil }
        var next = myStickers
        next.swapAt(index, targetIndex)
        for idx in next.indices {
            next[idx].sort = idx + 1
        }
        myStickers = next
        persistManifest(scope: currentScope)
        return next.map(\.id)
    }

    func loadCachedManifest(scope: String) -> CachedStickerManifest? {
        let key = cacheStorageKey(scope: scope)
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let cached = try? decoder.decode(CachedStickerManifest.self, from: data),
              cached.schemaVersion == 1,
              cached.scope == scope else {
            return nil
        }
        return cached
    }

    private func persistManifest(scope: String) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return }
        let manifest = CachedStickerManifest(
            schemaVersion: 1,
            scope: normalizedScope,
            updatedAt: Date().timeIntervalSince1970,
            myStickers: myStickers
                .filter { !$0.isLocalUploadPlaceholder }
                .map(\.persistentCacheCopy)
        )
        guard let data = try? encoder.encode(manifest) else { return }
        defaults.set(data, forKey: cacheStorageKey(scope: normalizedScope))
    }

    private func cacheStorageKey(scope: String) -> String {
        "im2.ios.stickerManifest.\(Self.stableHash(scope))"
    }

    private func recomputeUploadState() {
        let activeUpload = myStickers.first { item in
            item.isLocalUploadPlaceholder && item.uploadPhase != .failed
        }
        isUploading = activeUpload != nil
        uploadProgress = activeUpload?.uploadProgress
        uploadMessage = activeUpload?.uploadPhase?.title
    }

    private static func sortedUserItems(_ items: [StickerLibraryItem]) -> [StickerLibraryItem] {
        items
            .filter { $0.normalizedStatus != "deleted" }
            .sorted { lhs, rhs in
                if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
    }

    private static func stableHash(_ raw: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
