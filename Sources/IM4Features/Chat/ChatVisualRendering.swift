import SwiftUI
import IM4Domain
import IM4DesignSystem

// Specific UI builders keep network/certificate/GIF SDK adapters in App.
@MainActor public struct ChatRemoteImageRequest {
    public let urlString: String
    public let cacheKey: String
    public let contentMode: ContentMode
    public let maxPixelSize: Int?
}
@MainActor public struct ChatAvatarRequest {
    public let name: String
    public let seed: UInt
    public let size: CGFloat
    public let badgeColor: Color?
    public let imageURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let imageCacheKey: String
    public let usesGroupDefaultFallback: Bool
}
@MainActor public struct ChatGroupAvatarRequest {
    public let name: String
    public let seed: UInt
    public let size: CGFloat
    public let imageURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let imageCacheKey: String
    public let defaultContentScale: CGFloat
}
@MainActor public struct ChatGIFRequest {
    public let url: URL?
    public let cacheKey: String
    public let maxPixelSize: Int
    public let requiresGIF: Bool
    public let playbackPriority: Bool
    public let recoveryURL: (@MainActor () async -> URL?)?
}
@MainActor public struct ChatThumbnailRequest {
    public let url: URL?
    public let cacheKey: String
    public let scopeGeneration: UInt64
    public let networkRecoveryGeneration: Int
    public let recoveryURL: (() async -> URL?)?
    public let recoverOnAnyFailure: Bool
    public let indexedCacheURL: (() async -> URL?)?
}
@MainActor public struct ChatVisualRendering {
    public let image: (ChatRemoteImageRequest, AnyView) -> AnyView
    public let avatar: (ChatAvatarRequest) -> AnyView
    public let groupAvatar: (ChatGroupAvatarRequest) -> AnyView
    public let gif: (ChatGIFRequest, AnyView) -> AnyView
    public let thumbnail: (ChatThumbnailRequest, AnyView, AnyView) -> AnyView
    public init(image: @escaping (ChatRemoteImageRequest, AnyView) -> AnyView,
        avatar: @escaping (ChatAvatarRequest) -> AnyView,
        groupAvatar: @escaping (ChatGroupAvatarRequest) -> AnyView,
        gif: @escaping (ChatGIFRequest, AnyView) -> AnyView,
        thumbnail: @escaping (ChatThumbnailRequest, AnyView, AnyView) -> AnyView) {
        self.image = image; self.avatar = avatar; self.groupAvatar = groupAvatar
        self.gif = gif; self.thumbnail = thumbnail
    }
}
private struct ChatVisualRenderingKey: EnvironmentKey {
    static let defaultValue: ChatVisualRendering? = nil
}
public extension EnvironmentValues {
    public var chatVisualRendering: ChatVisualRendering? {
        get { self[ChatVisualRenderingKey.self] }
        set { self[ChatVisualRenderingKey.self] = newValue }
    }
}
@MainActor public struct ChatCertificationRendering {
    public struct ID: Hashable, Sendable {
        let source: ObjectIdentifier
        let exactUID: String
        public init(source: ObjectIdentifier, exactUID: String) {
            self.source = source; self.exactUID = exactUID
        }
    }
    public struct Reference: Identifiable {
        public let id: ID
        let avatar: (ChatAvatarRequest) -> AnyView
        let accessibilityLabel: (AnyView, String, String?) -> AnyView
        public init(id: ID, avatar: @escaping (ChatAvatarRequest) -> AnyView,
            accessibilityLabel: @escaping (AnyView, String, String?) -> AnyView) {
            self.id = id; self.avatar = avatar; self.accessibilityLabel = accessibilityLabel
        }
    }
    let reference: (String) -> Reference?
    let pill: (String, Bool, Int?) -> AnyView
    public init(reference: @escaping (String) -> Reference?,
        pill: @escaping (String, Bool, Int?) -> AnyView) {
        self.reference = reference; self.pill = pill
    }
    public func reference(forExactUID uid: String) -> Reference? { reference(uid) }
}
private struct ChatCertificationRenderingKey: EnvironmentKey {
    static let defaultValue: ChatCertificationRendering? = nil
}
public extension EnvironmentValues {
    public var chatCertificationRendering: ChatCertificationRendering? {
        get { self[ChatCertificationRenderingKey.self] }
        set { self[ChatCertificationRenderingKey.self] = newValue }
    }
}
struct ChatRemoteImageView<Placeholder: View>: View {
    let urlString: String
    var cacheKey = ""
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int?
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.chatVisualRendering) private var rendering
    var body: some View {
        if let rendering { rendering.image(.init(urlString: urlString, cacheKey: cacheKey,
            contentMode: contentMode, maxPixelSize: maxPixelSize), AnyView(placeholder())) }
        else { placeholder() }
    }
}
struct ChatAvatarView: View {
    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var badgeColor: Color?
    var imageURL = ""
    var avatarVersion = ""
    var avatarUpdatedAt = ""
    var imageCacheKey = ""
    var usesGroupDefaultFallback = false
    var certificationReference: ChatCertificationRendering.Reference?
    @Environment(\.chatVisualRendering) private var rendering
    private var request: ChatAvatarRequest { .init(name: name, seed: seed, size: size,
        badgeColor: badgeColor, imageURL: imageURL, avatarVersion: avatarVersion,
        avatarUpdatedAt: avatarUpdatedAt, imageCacheKey: imageCacheKey,
        usesGroupDefaultFallback: usesGroupDefaultFallback) }
    var body: some View {
        if let certificationReference { certificationReference.avatar(request) }
        else if let rendering { rendering.avatar(request) }
        else { InitialsAvatarContent(seed: seed, size: size, initials: String(name.prefix(2))) }
    }
}
struct ChatGroupAvatarView: View {
    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var imageURL = ""
    var avatarVersion = ""
    var avatarUpdatedAt = ""
    var imageCacheKey = ""
    var defaultContentScale: CGFloat = 1
    @Environment(\.chatVisualRendering) private var rendering
    var body: some View {
        if let rendering { rendering.groupAvatar(.init(name: name, seed: seed, size: size,
            imageURL: imageURL, avatarVersion: avatarVersion, avatarUpdatedAt: avatarUpdatedAt,
            imageCacheKey: imageCacheKey, defaultContentScale: defaultContentScale)) }
        else { GroupDefaultAvatarContent(image: Image("GroupDefaultAvatar", bundle: .main), size: size, contentScale: defaultContentScale) }
    }
}
struct ChatCertificationPillView: View {
    let exactUID: String
    var compact = false
    var maximumLineCount: Int? = 2
    @Environment(\.chatCertificationRendering) private var rendering
    var body: some View { if let rendering { rendering.pill(exactUID, compact, maximumLineCount) } }
}
struct ChatGIFPlayerView<Placeholder: View>: View {
    let url: URL?
    let cacheKey: String
    var maxPixelSize = 360
    var requiresGIF = false
    var playbackPriority = false
    var recoveryURL: (@MainActor () async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.chatVisualRendering) private var rendering
    var body: some View {
        if let rendering { rendering.gif(.init(url: url, cacheKey: cacheKey, maxPixelSize: maxPixelSize,
            requiresGIF: requiresGIF, playbackPriority: playbackPriority, recoveryURL: recoveryURL), AnyView(placeholder())) }
        else { placeholder() }
    }
}
struct ChatThumbnailImageView<Placeholder: View, Failure: View>: View {
    let url: URL?
    let cacheKey: String
    let scopeGeneration: UInt64
    var networkRecoveryGeneration = 0
    var recoveryURL: (() async -> URL?)? = nil
    var recoverOnAnyFailure = false
    var indexedCacheURL: (() async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure
    @Environment(\.chatVisualRendering) private var rendering
    var body: some View {
        if let rendering { rendering.thumbnail(.init(url: url, cacheKey: cacheKey,
            scopeGeneration: scopeGeneration, networkRecoveryGeneration: networkRecoveryGeneration,
            recoveryURL: recoveryURL, recoverOnAnyFailure: recoverOnAnyFailure, indexedCacheURL: indexedCacheURL),
            AnyView(placeholder()), AnyView(failure())) }
        else { placeholder() }
    }
}

extension View {
    @MainActor @ViewBuilder
    func certificationAccessibilityLabel(_ leading: String, reference: ChatCertificationRendering.Reference?, trailing: String? = nil) -> some View {
        if let reference { reference.accessibilityLabel(AnyView(self), leading, trailing) }
        else { accessibilityLabel([leading, trailing].compactMap { $0 }.joined(separator: "，")) }
    }
}
