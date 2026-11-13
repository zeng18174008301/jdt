import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_LAYOUT_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatReturnToBottomOverlay<Transcript: View>: View {
    let showsControl: Bool
    let pendingUnreadCount: Int
    let returnToBottom: () -> Void
    @ViewBuilder var transcript: () -> Transcript
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            transcript()
            if showsControl {
                ReturnToBottomBar(count: pendingUnreadCount, action: returnToBottom)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    public init(showsControl: Bool,
        pendingUnreadCount: Int,
        returnToBottom: @escaping () -> Void,
        @ViewBuilder transcript: @escaping () -> Transcript) {
        self.showsControl = showsControl
        self.pendingUnreadCount = pendingUnreadCount
        self.returnToBottom = returnToBottom
        self.transcript = transcript
    }
}
// WDT_IOS1_CHAT_LAYOUT_VALUE_BOUNDARY_20261111_END
