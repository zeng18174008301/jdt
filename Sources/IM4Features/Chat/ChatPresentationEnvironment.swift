import SwiftUI

private struct ChatRenderingProcessingNoticesKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
public extension EnvironmentValues {
    public var chatRenderingShowsMessageProcessingNotices: Bool? {
        get { self[ChatRenderingProcessingNoticesKey.self] }
        set { self[ChatRenderingProcessingNoticesKey.self] = newValue }
    }
}
