import SwiftUI
import IM4Features

extension AppFeatureComposition {
    static func chatVisualRendering() -> ChatVisualRendering {
        ChatVisualRendering(image: { request, placeholder in
            AnyView(CachedRemoteImage(urlString: request.urlString, cacheKey: request.cacheKey,
                contentMode: request.contentMode, maxPixelSize: request.maxPixelSize) { placeholder })
        }, avatar: { request in AnyView(chatAvatar(request, reference: nil)) },
        groupAvatar: { request in AnyView(GroupAvatarView(name: request.name, seed: request.seed,
            size: request.size, imageURL: request.imageURL, avatarVersion: request.avatarVersion,
            avatarUpdatedAt: request.avatarUpdatedAt, imageCacheKey: request.imageCacheKey,
            defaultContentScale: request.defaultContentScale)) },
        gif: { request, placeholder in
            AnyView(StickerGIFPlayer(url: request.url, cacheKey: request.cacheKey,
                maxPixelSize: request.maxPixelSize, requiresGIF: request.requiresGIF,
                playbackPriority: request.playbackPriority, recoveryURL: request.recoveryURL) { placeholder })
        }, thumbnail: { request, placeholder, failure in
            AnyView(AttachmentThumbnailImage(url: request.url, cacheKey: request.cacheKey,
                scopeGeneration: request.scopeGeneration, networkRecoveryGeneration: request.networkRecoveryGeneration,
                recoveryURL: request.recoveryURL, recoverOnAnyFailure: request.recoverOnAnyFailure,
                indexedCacheURL: request.indexedCacheURL, placeholder: { placeholder }, failure: { failure }))
        })
    }
    static func chatAvatar(_ request: ChatAvatarRequest, reference: CertificationPillSource.Reference?) -> some View {
        AvatarView(name: request.name, seed: request.seed, size: request.size,
            badgeColor: request.badgeColor, imageURL: request.imageURL,
            avatarVersion: request.avatarVersion, avatarUpdatedAt: request.avatarUpdatedAt,
            imageCacheKey: request.imageCacheKey, usesGroupDefaultFallback: request.usesGroupDefaultFallback,
            certificationReference: reference)
    }
    static func chatCertificationRendering(_ source: CertificationPillSource) -> ChatCertificationRendering {
        ChatCertificationRendering(reference: { source.reference(forExactUID: $0).map(\.chatFeatureReference) },
            pill: { uid, compact, lines in AnyView(CertificationPillView(exactUID: uid,
                compact: compact, maximumLineCount: lines)) })
    }
}
extension CertificationPillSource.Reference {
    var chatFeatureReference: ChatCertificationRendering.Reference {
        .init(id: .init(source: ObjectIdentifier(source), exactUID: exactUID),
            avatar: { request in AnyView(AppFeatureComposition.chatAvatar(request, reference: self)) },
            accessibilityLabel: { view, leading, trailing in AnyView(view.certificationAccessibilityLabel(leading, reference: self, trailing: trailing)) })
    }
}
