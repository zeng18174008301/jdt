import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatHistoryReadinessInput {
    public let isLoading: Bool
    public let hasVisibleMessages: Bool
    public let hasHistoryResult: Bool
    public var isReady: Bool { !isLoading && (hasVisibleMessages || hasHistoryResult) }

    public init(isLoading: Bool,
        hasVisibleMessages: Bool,
        hasHistoryResult: Bool) {
        self.isLoading = isLoading
        self.hasVisibleMessages = hasVisibleMessages
        self.hasHistoryResult = hasHistoryResult
    }
}
// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_END
