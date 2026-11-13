// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public enum RTCCallActionKind: String, Identifiable {
    case voice
    case video

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voice:
            return "语音通话"
        case .video:
            return "视频通话"
        }
    }

    public var systemImage: String {
        switch self {
        case .voice:
            return "phone.fill"
        case .video:
            return "video.fill"
        }
    }

    public var unavailableSystemImage: String {
        switch self {
        case .voice:
            return "phone.slash"
        case .video:
            return "video.slash"
        }
    }

    public var accentColor: Color {
        switch self {
        case .voice:
            return IMColor.brand
        case .video:
            return IMColor.violet
        }
    }
}
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END
