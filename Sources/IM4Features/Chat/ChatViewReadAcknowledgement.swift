import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatVisibleIncomingReadInput {
    public let metrics: ChatScrollMetricsSnapshot
    public let row: ChatIncomingRowPreferenceKey.Value
    public let expectedToken: String
    public let epoch: Int
    public let isActive: Bool
    public let scopeMatches: Bool

    public var observation: (token: String, seq: Int64)? {
        guard metrics.isValid, metrics.contentMaxY <= metrics.viewportHeight + 1 else { return nil }
        guard let seq = chatVisibleIncomingReadSequence(metrics: metrics, row: row,
            expectedToken: expectedToken, epoch: epoch, isActive: isActive, scopeMatches: scopeMatches) else { return nil }
        return (metrics.renderedReadToken, seq)
    }

    public init(metrics: ChatScrollMetricsSnapshot,
        row: ChatIncomingRowPreferenceKey.Value,
        expectedToken: String,
        epoch: Int,
        isActive: Bool,
        scopeMatches: Bool) {
        self.metrics = metrics
        self.row = row
        self.expectedToken = expectedToken
        self.epoch = epoch
        self.isActive = isActive
        self.scopeMatches = scopeMatches
    }
}
// WDT_IOS1_CHAT_RUNTIME_VALUE_BOUNDARY_20261111_END
