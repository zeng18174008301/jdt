// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
import Foundation

public enum FavoriteAssetCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case pdf
    case image
    case video
    case spreadsheet
    case document
    case archive
    case audio

    public static let displayOrder: [FavoriteAssetCategory] = [
        .all, .pdf, .image, .video, .spreadsheet, .document, .archive, .audio
    ]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .pdf: "PDF"
        case .image: "图片"
        case .video: "视频"
        case .spreadsheet: "表格"
        case .document: "文档"
        case .archive: "压缩包"
        case .audio: "音频"
        }
    }

    public var requestValue: String {
        switch self {
        case .all: "all"
        default: rawValue
        }
    }

    public init(serverValue: String) {
        let normalized = serverValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "all":
            self = .all
        case "pdf":
            self = .pdf
        case "image", "img", "photo":
            self = .image
        case "video":
            self = .video
        case "spreadsheet", "sheet", "excel", "xls", "xlsx", "csv":
            self = .spreadsheet
        case "document", "doc", "word", "ppt", "presentation", "txt", "text":
            self = .document
        case "archive", "zip", "compressed":
            self = .archive
        case "audio", "voice":
            self = .audio
        default:
            self = .all
        }
    }

    public init(displayTitle: String) {
        let normalized = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self = Self.displayOrder.first { $0.title == normalized } ?? .all
    }

    public func matches(file: FileItem) -> Bool {
        guard self != .all else { return true }
        let mediaCategory = file.mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = file.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extensionValue = (file.fileExtension.isEmpty ? (file.name as NSString).pathExtension : file.fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch self {
        case .all:
            return true
        case .pdf:
            return mediaCategory == "pdf" || mimeType.contains("pdf") || type == "pdf" || extensionValue == "pdf"
        case .image:
            return mediaCategory == "image" || mimeType.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(extensionValue)
        case .video:
            return mediaCategory == "video" || mimeType.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(extensionValue)
        case .spreadsheet:
            return mediaCategory == "spreadsheet"
                || mediaCategory == "sheet"
                || mimeType.contains("spreadsheet")
                || mimeType.contains("excel")
                || mimeType.contains("csv")
                || ["xls", "xlsx", "csv", "numbers"].contains(extensionValue)
        case .document:
            return mediaCategory == "document"
                || mimeType.contains("word")
                || mimeType.contains("document")
                || mimeType.contains("presentation")
                || mimeType.contains("powerpoint")
                || ["doc", "docx", "ppt", "pptx", "txt", "md", "pages", "key"].contains(extensionValue)
        case .archive:
            return mediaCategory == "archive" || ["zip", "rar", "7z", "tar", "gz"].contains(extensionValue)
        case .audio:
            return mediaCategory == "audio" || mediaCategory == "voice" || mimeType.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(extensionValue)
        }
    }
}

public struct FavoriteAssetItem: Identifiable, Hashable, Sendable {
    public let messageID: String
    public let tenantID: String
    public let channelID: String
    public let channelType: String
    public let channelSeq: Int64
    public let fromUID: String
    public let contentType: String
    public let status: String
    public let createdAt: String?
    public let favoritedAt: String?
    public let favoriteVersion: Int64
    public let category: FavoriteAssetCategory
    public let displayText: String
    public let cursor: String
    public let file: FileItem
    public let isUnavailable: Bool

    public var id: String { messageID }

    public init(
        messageID: String,
        tenantID: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64,
        fromUID: String,
        contentType: String,
        status: String,
        createdAt: String?,
        favoritedAt: String?,
        favoriteVersion: Int64,
        category: FavoriteAssetCategory,
        displayText: String,
        cursor: String,
        file: FileItem,
        isUnavailable: Bool
    ) {
        self.messageID = messageID
        self.tenantID = tenantID
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.fromUID = fromUID
        self.contentType = contentType
        self.status = status
        self.createdAt = createdAt
        self.favoritedAt = favoritedAt
        self.favoriteVersion = favoriteVersion
        self.category = category
        self.displayText = displayText
        self.cursor = cursor
        self.file = file
        self.isUnavailable = isUnavailable
    }
}

public struct FavoriteAssetsPageResult: Equatable, Sendable {
    public let fetchedCount: Int
    public let nextCursor: String
    public let hasMore: Bool
    public let didSucceed: Bool

    public static let empty = FavoriteAssetsPageResult(
        fetchedCount: 0,
        nextCursor: "",
        hasMore: false,
        didSucceed: false
    )

    public init(
        fetchedCount: Int,
        nextCursor: String,
        hasMore: Bool,
        didSucceed: Bool
    ) {
        self.fetchedCount = fetchedCount
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.didSucceed = didSucceed
    }
}

public struct FavoriteAssetsPageRequestIdentity: Equatable, Sendable {
    public let scope: String
    public let category: FavoriteAssetCategory
    public let cursor: String
    public let generation: UInt64
}

public struct FavoriteAssetsCollectionState {
    public init() {}
    private var cachedItemsByScope: [String: [FavoriteAssetCategory: [FavoriteAssetItem]]] = [:]
    private var activeRequest: FavoriteAssetsPageRequestIdentity?
    public private(set) var activeScope = ""
    public private(set) var activeCategory: FavoriteAssetCategory = .all
    public private(set) var activeItems: [FavoriteAssetItem] = []
    public private(set) var generation: UInt64 = 0

    public mutating func begin(
        scope rawScope: String,
        category: FavoriteAssetCategory,
        cursor rawCursor: String
    ) -> FavoriteAssetsPageRequestIdentity {
        generation &+= 1
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        activeScope = scope
        activeCategory = category
        activeItems = cachedItems(scope: scope, category: category)
        let request = FavoriteAssetsPageRequestIdentity(
            scope: scope,
            category: category,
            cursor: cursor,
            generation: generation
        )
        activeRequest = request
        return request
    }

    public func isCurrent(_ request: FavoriteAssetsPageRequestIdentity) -> Bool {
        activeRequest == request
            && activeScope == request.scope
            && activeCategory == request.category
            && generation == request.generation
    }

    @discardableResult
    public mutating func apply(
        items: [FavoriteAssetItem],
        append: Bool,
        request: FavoriteAssetsPageRequestIdentity
    ) -> Bool {
        guard isCurrent(request) else { return false }
        let existing = cachedItemsByScope[request.scope]?[request.category] ?? activeItems
        let nextItems = append
            ? Self.merged(existing, appending: items)
            : Self.deduplicated(items)
        cachedItemsByScope[request.scope, default: [:]][request.category] = nextItems
        if request.category != .all,
           let allItems = cachedItemsByScope[request.scope]?[.all] {
            cachedItemsByScope[request.scope, default: [:]][.all] = Self.merged(allItems, appending: nextItems)
        }
        activeItems = nextItems
        activeRequest = nil
        return true
    }

    @discardableResult
    public mutating func fail(request: FavoriteAssetsPageRequestIdentity) -> Bool {
        guard isCurrent(request) else { return false }
        activeRequest = nil
        return true
    }

    public mutating func invalidateVisibleItems() {
        generation &+= 1
        activeRequest = nil
        activeScope = ""
        activeCategory = .all
        activeItems = []
    }

    public mutating func purge(scope rawScope: String) {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return }
        cachedItemsByScope.removeValue(forKey: scope)
        guard activeScope == scope else { return }
        invalidateVisibleItems()
    }

    public mutating func remove(
        scope rawScope: String,
        where shouldRemove: (FavoriteAssetItem) -> Bool
    ) {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, var categories = cachedItemsByScope[scope] else { return }
        for category in categories.keys {
            categories[category]?.removeAll(where: shouldRemove)
        }
        cachedItemsByScope[scope] = categories
        if activeScope == scope {
            activeItems.removeAll(where: shouldRemove)
        }
    }

    private func cachedItems(scope: String, category: FavoriteAssetCategory) -> [FavoriteAssetItem] {
        guard !scope.isEmpty else { return [] }
        if let exact = cachedItemsByScope[scope]?[category] {
            return exact
        }
        if category == .all,
           let categories = cachedItemsByScope[scope] {
            return Self.deduplicated(
                FavoriteAssetCategory.displayOrder
                    .filter { $0 != .all }
                    .flatMap { categories[$0] ?? [] }
            )
        }
        guard category != .all,
              let allItems = cachedItemsByScope[scope]?[.all] else {
            return []
        }
        return allItems.filter { category.matches(file: $0.file) }
    }

    private static func merged(
        _ existing: [FavoriteAssetItem],
        appending incoming: [FavoriteAssetItem]
    ) -> [FavoriteAssetItem] {
        deduplicated(existing + incoming)
    }

    private static func deduplicated(_ items: [FavoriteAssetItem]) -> [FavoriteAssetItem] {
        var result: [FavoriteAssetItem] = []
        var indexByMessageID: [String: Int] = [:]
        for item in items {
            let messageID = item.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty else { continue }
            if let index = indexByMessageID[messageID] {
                result[index] = item
            } else {
                indexByMessageID[messageID] = result.count
                result.append(item)
            }
        }
        return result
    }
}
