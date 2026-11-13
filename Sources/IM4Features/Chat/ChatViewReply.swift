import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

public struct ChatPinnedContextInput {
    public let text: String
    public let positionText: String?

    public init(text: String,
        positionText: String? = nil) {
        self.text = text
        self.positionText = positionText
    }
}

public struct ChatPinnedContextView: View {
    let input: ChatPinnedContextInput
    let open: () -> Void
    public var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.warning)
                Text(input.text)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .im4ContentTransitionOpacityCompat()
                Spacer()
                if let position = input.positionText {
                    Text(position)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.88)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(IMColor.brand.opacity(0.06))
    }

    public init(input: ChatPinnedContextInput,
        open: @escaping () -> Void) {
        self.input = input
        self.open = open
    }
}
