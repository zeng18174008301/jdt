import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatHistoryLoadingInput {
    public let isOlderHistoryLoading: Bool
    public let isMessageSyncInFlight: Bool
    public var isLoading: Bool { isOlderHistoryLoading || isMessageSyncInFlight }

    public init(isOlderHistoryLoading: Bool,
        isMessageSyncInFlight: Bool) {
        self.isOlderHistoryLoading = isOlderHistoryLoading
        self.isMessageSyncInFlight = isMessageSyncInFlight
    }
}
// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_END
