// WDT_IOS1_STICKER_STATE_FAMILY_20261110_BEGIN
import Combine
import Foundation
import IM4Domain
import IM4Data // WDT_IOS1_STICKER_MANIFEST_DATA_20261111

@MainActor
public final class StickerStore: ObservableObject {
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    public struct Binding: Equatable, Sendable {
        public let scope: LocalMessageScope
        fileprivate let legacyKey: String
        fileprivate let generation = UUID()
    }

    public private(set) var activeBinding: Binding?
    public var currentScope: String { activeBinding?.legacyKey ?? "" }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
    @Published public private(set) var myStickers: [StickerLibraryItem] = []
    @Published public private(set) var officialPacks: [StickerPackItem] = []
    @Published public private(set) var officialStickersByPackID: [String: [StickerLibraryItem]] = [:]
    @Published public private(set) var isManifestRefreshing = false
    @Published public private(set) var manifestErrorMessage: String?
    @Published public private(set) var officialErrorMessage: String?
    @Published public private(set) var isUploading = false
    @Published public private(set) var uploadProgress: Double?
    @Published public private(set) var uploadMessage: String?
    @Published public private(set) var deletingIDs: Set<String> = []
    @Published public private(set) var sortingIDs: Set<String> = []

    private let manifestStore: StickerManifestRecordStore // WDT_IOS1_STICKER_MANIFEST_DATA_20261111
    private var uploadDrafts: [String: StickerUploadDraft] = [:]

    public init(defaults: UserDefaults = .standard) {
        manifestStore = StickerManifestRecordStore(defaults: defaults) // WDT_IOS1_STICKER_MANIFEST_DATA_20261111
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    @discardableResult
    public func activate(scope: LocalMessageScope, legacyKey: String) -> Binding {
        let legacyKey = legacyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeBinding, activeBinding.scope == scope, activeBinding.legacyKey == legacyKey {
            return activeBinding
        }
        if activeBinding != nil { resetRuntime() }
        let binding = Binding(scope: scope, legacyKey: legacyKey)
        activeBinding = binding
        myStickers = manifestStore.load(scope: legacyKey)?.myStickers ?? []
        return binding
    }

    public func resetRuntime() {
        activeBinding = nil
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
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

    public func replaceMyStickers(_ items: [StickerLibraryItem], binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        let localUploads = myStickers.filter(\.isLocalUploadPlaceholder)
        myStickers = Self.sortedUserItems(localUploads + items)
        manifestErrorMessage = nil
        persistManifest(binding: binding)
    }

    func upsertPendingSticker(_ item: StickerLibraryItem, binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        var next = myStickers
        next.removeAll { existing in
            (!item.stickerID.isEmpty && existing.stickerID == item.stickerID)
                || (!item.fileID.isEmpty && existing.fileID == item.fileID)
                || existing.id == item.id
        }
        next.insert(item, at: 0)
        myStickers = Self.sortedUserItems(next)
        persistManifest(binding: binding)
    }

    public func removeMySticker(id: String, binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        myStickers.removeAll { $0.id == id || $0.stickerID == id }
        persistManifest(binding: binding)
    }

    public func replaceOfficialPacks(_ packs: [StickerPackItem]) {
        officialPacks = packs.sorted { lhs, rhs in
            if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        officialErrorMessage = nil
    }

    public func replaceOfficialStickers(_ stickers: [StickerLibraryItem], packID: String) {
        officialStickersByPackID[packID] = stickers.sorted { lhs, rhs in
            if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
            return lhs.id < rhs.id
        }
        officialErrorMessage = nil
    }

    public func officialStickers(packID: String) -> [StickerLibraryItem] {
        officialStickersByPackID[packID] ?? []
    }

    public func setManifestRefreshing(_ refreshing: Bool) {
        isManifestRefreshing = refreshing
        if refreshing {
            manifestErrorMessage = nil
        }
    }

    public func setManifestError(_ message: String?) {
        manifestErrorMessage = message
        isManifestRefreshing = false
    }

    public func setOfficialError(_ message: String?) {
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

    public func beginLocalUpload(
        id: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        data: Data,
        conversationID: String,
        binding: Binding
    ) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
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

    public func updateLocalUpload(id: String, phase: StickerUploadPhase, progress: Double? = nil, binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
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

    public func replaceLocalUpload(id: String, with item: StickerLibraryItem, binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
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
        persistManifest(binding: binding)
    }

    public func failLocalUpload(id: String, binding: Binding) {
        updateLocalUpload(id: id, phase: .failed, binding: binding)
    }

    public func removeLocalUpload(id: String, binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        uploadDrafts[id] = nil
        myStickers.removeAll { $0.id == id && $0.isLocalUploadPlaceholder }
        recomputeUploadState()
        persistManifest(binding: binding)
    }

    public func localUploadDraft(id: String) -> StickerUploadDraft? {
        uploadDrafts[id]
    }

    // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
    public func isDeleting(_ item: StickerLibraryItem) -> Bool {
        deletingIDs.contains(item.id) || deletingIDs.contains(item.stickerID)
    }

    public func isSorting(_ item: StickerLibraryItem) -> Bool {
        sortingIDs.contains(item.id)
    }
    // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END

    public func beginDeleting(id: String) {
        deletingIDs.insert(id)
    }

    public func finishDeleting(id: String) {
        deletingIDs.remove(id)
    }

    public func beginSorting(ids: [String]) {
        sortingIDs.formUnion(ids)
    }

    public func finishSorting(ids: [String]) {
        sortingIDs.subtract(ids)
    }

    public func moveUserSticker(id: String, direction: Int, binding: Binding) -> [String]? {
        guard activeBinding == binding else { return nil } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
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
        persistManifest(binding: binding)
        return next.map(\.id)
    }

    private func persistManifest(binding: Binding) {
        guard activeBinding == binding else { return } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        manifestStore.persist(myStickers, scope: binding.legacyKey) // WDT_IOS1_STICKER_MANIFEST_DATA_20261111
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
}

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
@MainActor
public final class StickerMessageAssetStore {
    public init() {}
    public struct Snapshot {
        public internal(set) var generation = UUID()
        public internal(set) var files: [String: StickerResolvedFileAsset] = [:]
    }

    public struct Presentation: Equatable {
        public init(thumbnailURL: URL?, animationURL: URL?, requestKey: String) {
            self.thumbnailURL = thumbnailURL
            self.animationURL = animationURL
            self.requestKey = requestKey
        }
        public let thumbnailURL: URL?
        public let animationURL: URL?
        public let requestKey: String
    }

    @Published public private(set) var snapshot = Snapshot()

    public func upsert(_ asset: StickerResolvedFileAsset, for key: String) {
        guard snapshot.files[key] != asset else { return }
        snapshot.files[key] = asset
    }

    public func reset() {
        snapshot = Snapshot()
    }

    public func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }
}
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END
// WDT_IOS1_STICKER_STATE_FAMILY_20261110_END
