// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import Combine
import Foundation
import SwiftUI
import UIKit
import IM4DesignSystem

enum TenantRelativeImageURLResolver {
    static func request(
        _ rawValue: String,
        routeContext: AvatarImageRouteContext?
    ) -> AvatarRemoteImageRequest? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return .direct(urlString: "https:\(trimmed)")
        }
        guard let parsed = URL(string: trimmed) else { return nil }
        if parsed.scheme?.isEmpty == false {
            if parsed.scheme?.lowercased() == "https",
               parsed.query == nil,
               parsed.fragment == nil,
               routeContext?.matchesRouteOrigin(parsed) == true,
               isStableTenantAvatarPath(parsed.path) {
                return .tenantRelative(path: parsed.path)
            }
            return .direct(urlString: trimmed)
        }
        guard parsed.host == nil else { return nil }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        guard path.hasPrefix("/api/tenant/") else { return nil }
        let relativePath = parsed.query.map { "\(path)?\($0)" } ?? path
        return .tenantRelative(path: relativePath)
    }

    static func isStableTenantAvatarPath(_ path: String) -> Bool {
        let prefixes = [
            "/api/tenant/avatar/",
            "/api/tenant/static/avatars/"
        ]
        return prefixes.contains { prefix in
            path.hasPrefix(prefix) && path.count > prefix.count
        }
    }
}

struct AvatarView: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var badgeColor: Color?
    var imageURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    var imageCacheKey: String = ""
    var retryPolicy: AvatarImageRetryPolicy = .none
    var usesGroupDefaultFallback = false
    var certification: CertificationPresentation?
    var certificationReference: CertificationPillSource.Reference? // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110

    private var maxPixelSize: Int {
        max(96, Int(ceil(size * UIScreen.main.scale * 1.5)))
    }

    private var isCancelledAvatar: Bool {
        isCancelledUserAvatarURL(imageURL)
    }

    private var visibleCertification: CertificationPresentation? {
        isCancelledAvatar || usesGroupDefaultFallback ? nil : certification
    }

    private var resolvedName: String {
        isCancelledAvatar ? cancelledUserDisplayName : name
    }

    var initials: String {
        String(resolvedName.prefix(2))
    }

    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
    var body: some View {
        if let certificationReference, !isCancelledAvatar, !usesGroupDefaultFallback {
            certificationReference.observe { presentation in
                avatarContent(presentation)
            }
        } else {
            avatarContent(visibleCertification)
        }
    }
    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

    private func avatarContent(_ visibleCertification: CertificationPresentation?) -> some View {
        IM4DesignSystem.AvatarDecorationContent(
            size: size, badgeColor: badgeColor, isCancelledAvatar: isCancelledAvatar,
            resolvedName: resolvedName,
            visibleCertification: visibleCertification.map {
                IM4DesignSystem.CertificationDisplay(visibleLabel: $0.visibleLabel, accessibilityLabel: $0.accessibilityLabel)
            }
        ) { avatarBody }
    }

    @ViewBuilder
    private var avatarBody: some View {
        let request = TenantRelativeImageURLResolver.request(
            imageURL,
            routeContext: avatarImageRouteContext
        )
        let explicitCacheKey = imageCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableCacheKey = explicitCacheKey.isEmpty
            ? AvatarImageCache.cacheKey(
                url: request?.stableIdentity ?? "",
                version: avatarVersion,
                updatedAt: avatarUpdatedAt
            )
            : explicitCacheKey
        let storageCacheKey = request?.storageCacheKey(
            stableCacheKey,
            routeContext: avatarImageRouteContext
        )
        let canReadCache = request?.isAuthorized(routeContext: avatarImageRouteContext) == true
        if isCancelledAvatar {
            cancelledFallbackAvatar
        } else if canReadCache,
                  let storageCacheKey,
                  let cached = AvatarImageCache.shared.peekImage(for: storageCacheKey, maxPixelSize: maxPixelSize) {
            IM4DesignSystem.AvatarBitmapContent(image: cached)
        } else if request != nil {
            CachedRemoteImage(
                urlString: imageURL,
                cacheKey: stableCacheKey,
                maxPixelSize: maxPixelSize,
                retryPolicy: retryPolicy
            ) {
                fallbackAvatar
            }
        } else {
            fallbackAvatar
        }
    }

    private var cancelledFallbackAvatar: some View {
        IM4DesignSystem.CancelledAvatarContent(size: size)
    }

    @ViewBuilder
    private var fallbackAvatar: some View {
        if usesGroupDefaultFallback {
            GroupDefaultAvatarView(size: size)
        } else {
            IM4DesignSystem.InitialsAvatarContent(seed: seed, size: size, initials: initials)
        }
    }
}

// WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_BEGIN
@MainActor
final class CertificationPillSource: ObservableObject {
    let scopeRevision: @MainActor () -> Int
    let presentation: @MainActor (String) -> CertificationPresentation?
    let ensure: @MainActor (String) -> Void
    @Published private var revision = 0
    private var observation: AnyCancellable?

    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
    @MainActor
    struct Reference {
        struct ID: Hashable {
            let source: ObjectIdentifier
            let exactUID: String
        }

        let source: CertificationPillSource
        let exactUID: String
        var id: ID { ID(source: ObjectIdentifier(source), exactUID: exactUID) }

        func observe<Content: View>(
            @ViewBuilder content: @escaping (CertificationPresentation?) -> Content
        ) -> some View {
            source.observe({ $0.presentation(exactUID) }, content: content)
                .id(id)
        }
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (CertificationPillSource) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: project(self),
            updates: $revision.map { _ in project(self) }.removeDuplicates().eraseToAnyPublisher(),
            content: content
        )
    }

    func reference(forExactUID uid: String) -> Reference? {
        let exactUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exactUID.isEmpty else { return nil }
        return Reference(source: self, exactUID: exactUID)
    }
    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

    init(
        changes: AnyPublisher<Int, Never>,
        scopeRevision: @escaping @MainActor () -> Int,
        presentation: @escaping @MainActor (String) -> CertificationPresentation?,
        ensure: @escaping @MainActor (String) -> Void
    ) {
        self.scopeRevision = scopeRevision
        self.presentation = presentation
        self.ensure = ensure
        observation = changes.sink { [weak self] revision in
            self?.revision = revision
        }
    }
}

// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
extension View {
    @MainActor
    @ViewBuilder
    func certificationAccessibilityLabel(
        _ leading: String,
        reference: CertificationPillSource.Reference?,
        trailing: String? = nil
    ) -> some View {
        let label: (CertificationPresentation?) -> String = { presentation in
            [leading, presentation?.accessibilityLabel, trailing].compactMap { $0 }.joined(separator: "，")
        }
        if let reference {
            reference.observe { presentation in self.accessibilityLabel(label(presentation)) }
        } else {
            accessibilityLabel(label(nil))
        }
    }
}
// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

private enum CertificationPillSourceKey: EnvironmentKey {
    static let defaultValue: CertificationPillSource? = nil
}

extension EnvironmentValues {
    var certificationPillSource: CertificationPillSource? {
        get { self[CertificationPillSourceKey.self] }
        set { self[CertificationPillSourceKey.self] = newValue }
    }
}

// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
private struct ObservedCertificationPill<Content: View>: View {
    struct Snapshot: Equatable {
        let presentation: CertificationPresentation?
        let scopeRevision: Int
    }

    struct Identity: Hashable {
        let source: ObjectIdentifier
        let exactUID: String
        let usesProvidedPresentation: Bool
    }

    let source: CertificationPillSource
    let exactUID: String
    let presentation: CertificationPresentation?
    let content: (CertificationPresentation?) -> Content

    var body: some View {
        source.observe({ source in
            Snapshot(
                presentation: presentation ?? source.presentation(exactUID),
                scopeRevision: source.scopeRevision()
            )
        }) { snapshot in
            content(presentation ?? snapshot.presentation)
                .task(id: snapshot.scopeRevision) {
                    guard !exactUID.isEmpty else { return }
                    source.ensure(exactUID)
                }
        }
        .id(Identity(source: ObjectIdentifier(source), exactUID: exactUID, usesProvidedPresentation: presentation != nil))
    }
}
// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_END

struct CertificationPillView: View {
    @Environment(\.certificationPillSource) private var source
    @Environment(\.colorScheme) private var colorScheme

    let exactUID: String
    var compact = false
    var maximumLineCount: Int? = 2
    var presentation: CertificationPresentation? = nil
    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PILL_PREFETCH_MODE - 修改开始：支持通讯录行使用已预取认证展示，滚动时不再逐行查询全局状态
    var usesProvidedPresentationOnly = false
    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PILL_PREFETCH_MODE - 修改结束：支持通讯录行使用已预取认证展示，滚动时不再逐行查询全局状态

    private var normalizedUID: String {
        exactUID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_BEGIN
    var body: some View {
        if !usesProvidedPresentationOnly, let source {
            ObservedCertificationPill(
                source: source,
                exactUID: normalizedUID,
                presentation: presentation,
                content: pill
            )
        } else {
            pill(presentation)
        }
    }

    private func pill(_ resolvedPresentation: CertificationPresentation?) -> some View {
        IM4DesignSystem.CertificationPillContent(
            presentation: resolvedPresentation.map {
                IM4DesignSystem.CertificationDisplay(visibleLabel: $0.visibleLabel, accessibilityLabel: $0.accessibilityLabel)
            }, compact: compact, maximumLineCount: maximumLineCount, colorScheme: colorScheme
        )
    }
    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_END
}

struct GroupAvatarView: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let name: String
    let seed: UInt
    var size: CGFloat = 48
    var imageURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    var imageCacheKey: String = ""
    var defaultContentScale: CGFloat = 1

    private var trustedCustomAvatarPath: String? {
        guard !isDefaultGroupAvatarURL(imageURL),
              let request = TenantRelativeImageURLResolver.request(
                imageURL,
                routeContext: avatarImageRouteContext
              ), case let .tenantRelative(relativeValue) = request,
              let parsed = URL(string: relativeValue),
              parsed.host == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              TenantRelativeImageURLResolver.isStableTenantAvatarPath(parsed.path) else {
            return nil
        }
        return parsed.path
    }

    var body: some View {
        if let trustedCustomAvatarPath {
            AvatarView(
                name: name,
                seed: seed,
                size: size,
                imageURL: trustedCustomAvatarPath,
                avatarVersion: avatarVersion,
                avatarUpdatedAt: avatarUpdatedAt,
                imageCacheKey: imageCacheKey,
                retryPolicy: .groupAvatar,
                usesGroupDefaultFallback: true
            )
        } else {
            GroupDefaultAvatarView(size: size, contentScale: defaultContentScale)
                .accessibilityLabel(name)
        }
    }
}

func isDefaultGroupAvatarURL(_ value: String) -> Bool {
    let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowercased.contains("group-default-avatar")
        || lowercased.contains("default-group-avatar")
}

struct GroupDefaultAvatarView: View {
    var size: CGFloat
    var contentScale: CGFloat = 1

    var body: some View {
        IM4DesignSystem.GroupDefaultAvatarContent(image: Image("GroupDefaultAvatar"), size: size, contentScale: contentScale)
    }
}

struct SystemNoticeLogoAvatar: View {
    var size: CGFloat

    var body: some View {
        IM4DesignSystem.SystemNoticeAvatarContent(image: Image("SystemNoticeLogo"), size: size)
    }
}

struct CachedRemoteImageState {
    let identity: String
    let image: UIImage

    func visibleImage(currentIdentity: String, isAuthorized: Bool) -> UIImage? {
        guard isAuthorized, identity == currentIdentity else { return nil }
        return image
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext

    let urlString: String
    var cacheKey: String = ""
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int?
    var retryPolicy: AvatarImageRetryPolicy = .none
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loadedState: CachedRemoteImageState?

    private var request: AvatarRemoteImageRequest? {
        TenantRelativeImageURLResolver.request(
            urlString,
            routeContext: avatarImageRouteContext
        )
    }

    private var loadIdentity: String {
        guard let request else { return "invalid|cache=\(cacheKey)|max_px=\(maxPixelSize ?? 0)|attempts=\(retryPolicy.maximumAttempts)" }
        return request.loadIdentity(
            routeContext: avatarImageRouteContext,
            cacheKey: cacheKey,
            maxPixelSize: maxPixelSize
        ) + "|attempts=\(retryPolicy.maximumAttempts)"
    }

    var body: some View {
        IM4DesignSystem.RemoteImageContent(
            image: loadedState?.visibleImage(
                currentIdentity: loadIdentity,
                isAuthorized: request?.isAuthorized(routeContext: avatarImageRouteContext) == true
            ), contentMode: contentMode, placeholder: placeholder
        )
        .task(id: loadIdentity) {
            let requestedIdentity = loadIdentity
            guard let request else {
                loadedState = nil
                return
            }
            guard request.isAuthorized(routeContext: avatarImageRouteContext) else {
                loadedState = nil
                return
            }
            let stableCacheKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? request.stableIdentity
                : cacheKey
            guard let storageCacheKey = request.storageCacheKey(
                stableCacheKey,
                routeContext: avatarImageRouteContext
            ), request.isAuthorized(routeContext: avatarImageRouteContext) else {
                loadedState = nil
                return
            }
            if let cached = AvatarImageCache.shared.image(for: storageCacheKey, maxPixelSize: maxPixelSize) {
                guard requestedIdentity == loadIdentity,
                      request.isAuthorized(routeContext: avatarImageRouteContext) else { return }
                loadedState = CachedRemoteImageState(identity: requestedIdentity, image: cached)
                return
            }
            loadedState = nil
            let loadedImage = await AvatarImageCache.shared.remoteImage(
                for: urlString,
                routeContext: avatarImageRouteContext,
                cacheKey: stableCacheKey,
                maxPixelSize: maxPixelSize,
                retryPolicy: retryPolicy
            )
            guard !Task.isCancelled,
                  requestedIdentity == loadIdentity,
                  request.isAuthorized(routeContext: avatarImageRouteContext) else { return }
            loadedState = loadedImage.map {
                CachedRemoteImageState(identity: requestedIdentity, image: $0)
            }
        }
        }
}

struct EnterpriseLogoView: View {
    let enterprise: Enterprise
    var size: CGFloat
    var cornerRadius: CGFloat = 18
    var cacheKey: String = ""

    private var remoteURL: URL? {
        guard enterprise.isLogoRenderable else { return nil }
        let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("data:image") else { return nil }
        return URL(string: raw)
    }

    private var dataImage: UIImage? {
        guard enterprise.isLogoRenderable else { return nil }
        let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("data:image"),
              let commaIndex = raw.firstIndex(of: ",") else { return nil }
        let encoded = String(raw[raw.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize)
    }

    private var maxPixelSize: Int {
        max(96, Int(ceil(size * UIScreen.main.scale * 1.5)))
    }

    var body: some View {
        IM4DesignSystem.EnterpriseLogoContent(
            accentHex: enterprise.accentHex, size: size, cornerRadius: cornerRadius,
            accessibilityLabel: "\(enterprise.name) Logo"
        ) {
            if let dataImage {
                IM4DesignSystem.EnterpriseClippedContent(size: size, cornerRadius: cornerRadius) {
                    IM4DesignSystem.AvatarBitmapContent(image: dataImage)
                }
            } else if let remoteURL {
                IM4DesignSystem.EnterpriseClippedContent(size: size, cornerRadius: cornerRadius) {
                    CachedRemoteImage(urlString: remoteURL.absoluteString, cacheKey: cacheKey, maxPixelSize: maxPixelSize) {
                        enterpriseFallbackIcon
                    }
                }
            } else {
                enterpriseFallbackIcon
            }
        }
    }

    private var enterpriseFallbackIcon: some View {
        IM4DesignSystem.EnterpriseFallbackIcon(size: size)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
