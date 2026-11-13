import SwiftUI

public enum AuthFlipLayoutPolicy {
    public static let accountLoginPreferredCardHeight: CGFloat = 568
    public static let phoneLoginPreferredCardHeight: CGFloat = 624
    public static let auxiliaryControlLeadingInset: CGFloat = 0
    public static let focusedKeyboardBottomInset: CGFloat = 240

    public static func loginCardHeight(
        phoneAuthEnabled: Bool,
        availableHeight: CGFloat,
        measuredContentHeight: CGFloat = 0
    ) -> CGFloat {
        let preferredHeight = phoneAuthEnabled
            ? phoneLoginPreferredCardHeight
            : accountLoginPreferredCardHeight
        let requiredHeight = max(preferredHeight, measuredContentHeight)
        return min(max(0, availableHeight), requiredHeight)
    }

    public static func contentFitsWithoutScrolling(measuredContentHeight: CGFloat, cardHeight: CGFloat) -> Bool {
        measuredContentHeight > 0 && measuredContentHeight <= cardHeight
    }
}
