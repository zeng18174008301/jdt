import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatBottomConfirmationInput {
    public let targetSequence: Int64
    public let confirmedSequence: Int64
    public var advancingSequence: Int64? {
        guard targetSequence > 0, targetSequence > confirmedSequence else { return nil }
        return targetSequence
    }

    public init(targetSequence: Int64,
        confirmedSequence: Int64) {
        self.targetSequence = targetSequence
        self.confirmedSequence = confirmedSequence
    }
}
// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_END
