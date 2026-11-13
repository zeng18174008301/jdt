// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

extension IMUser {
    var avatarCacheKey: String {
        AvatarImageCache.cacheKey(url: avatarURL, version: avatarVersion, updatedAt: avatarUpdatedAt)
    }
}

extension ChatMessage {
    var conversationListPreview: String {
        if let attachmentPreview = conversationAttachmentPreview { return attachmentPreview }
        switch kind {
        case .rtcCallRecord:
            return rtcCallRecord?.presentation(viewerIsCaller: isOutgoing).conversationPreview
                ?? RTCCallRecordPayload.safeFallbackText(payload: [:])
        case .location: return "[位置] \(text)"
        default: return text
        }
    }
}

extension GroupInfo {
    var avatarCacheKey: String {
        AvatarImageCache.cacheKey(url: avatarURL, version: avatarVersion, updatedAt: avatarUpdatedAt)
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
