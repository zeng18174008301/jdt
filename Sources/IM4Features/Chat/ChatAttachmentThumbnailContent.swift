import SwiftUI
import IM4DesignSystem

private struct ChatThumbnailLoadingIndicator: View {
    @Environment(\.chatMediaScrollActivity) private var mediaScrollActivity
    @State private var showsIndicator = false

    var body: some View {
        Color.clear
            .overlay {
                if showsIndicator {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.75)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.42)))
                        .accessibilityLabel("封面加载中")
                }
            }
            .allowsHitTesting(false)
            .task {
                // Skip the spinner for quick cache hits and rows scrolled past.
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                if let mediaScrollActivity, !(await mediaScrollActivity.waitUntilIdle()) { return }
                guard !Task.isCancelled else { return }
                showsIndicator = true
            }
    }
}

// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
public struct ServerVideoPosterContent: View {
    let visible: Bool
    let localURL: URL?
    let cacheKey: String
    let scopeGeneration: UInt64
    let isResolvingPoster: Bool

    public var body: some View {
        Group {
            if visible {
                let lookup: (() async -> URL?)? = localURL.map { url in { url } }
                ChatThumbnailImageView(url: localURL, cacheKey: cacheKey, scopeGeneration: scopeGeneration,
                    indexedCacheURL: lookup,
                    placeholder: {
                        Color.clear.overlay(alignment: .topTrailing) {
                            if localURL != nil || isResolvingPoster {
                                ChatThumbnailLoadingIndicator().frame(width: 28, height: 28).padding(8)
                            }
                        }
                    }, failure: { Color.clear })
                    .allowsHitTesting(false)
            }
        }
    }

    public init(visible: Bool,
        localURL: URL? = nil,
        cacheKey: String,
        scopeGeneration: UInt64,
        isResolvingPoster: Bool) {
        self.visible = visible
        self.localURL = localURL
        self.cacheKey = cacheKey
        self.scopeGeneration = scopeGeneration
        self.isResolvingPoster = isResolvingPoster
    }
}

public struct AttachmentOriginalContent: View {
    let visible: Bool
    let thumbnailURL: URL? // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
    let cacheKey: String
    let scopeGeneration: UInt64
    let networkRecoveryGeneration: Int
    let recoveryURL: () async -> URL?
    let indexedCacheURL: () async -> URL?

    public var body: some View {
        Group {
            if visible {
                ChatThumbnailImageView(url: thumbnailURL, cacheKey: cacheKey, scopeGeneration: scopeGeneration, // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
                    networkRecoveryGeneration: networkRecoveryGeneration, recoveryURL: recoveryURL,
                    recoverOnAnyFailure: true, indexedCacheURL: indexedCacheURL,
                    placeholder: { IMColor.ink.opacity(0.08).overlay { ChatThumbnailLoadingIndicator() } },
                    failure: { Text("图片读取失败") })
            }
        }
    }

    public init(visible: Bool,
        thumbnailURL: URL? = nil, // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        cacheKey: String,
        scopeGeneration: UInt64,
        networkRecoveryGeneration: Int,
        recoveryURL: @escaping () async -> URL?,
        indexedCacheURL: @escaping () async -> URL?) {
        self.visible = visible
        self.thumbnailURL = thumbnailURL // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        self.cacheKey = cacheKey
        self.scopeGeneration = scopeGeneration
        self.networkRecoveryGeneration = networkRecoveryGeneration
        self.recoveryURL = recoveryURL
        self.indexedCacheURL = indexedCacheURL
    }
}
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END
