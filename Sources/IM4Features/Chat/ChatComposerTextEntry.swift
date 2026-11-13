import IM4Domain
import IM4DesignSystem
import SwiftUI

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN
public struct ChatComposerTextEntryInput: Equatable {
    public let isDisabled: Bool
    public let canSend: Bool

    public init(isDisabled: Bool,
        canSend: Bool) {
        self.isDisabled = isDisabled
        self.canSend = canSend
    }
}

public struct ChatComposerTextEntryActions {
    public let toggleEmoji: () -> Void
    public let toggleTools: () -> Void
    public let send: () -> Void
    public let onBeginEditing: () -> Void
    public let onEditingChanged: (Bool) -> Void

    public init(toggleEmoji: @escaping () -> Void,
        toggleTools: @escaping () -> Void,
        send: @escaping () -> Void,
        onBeginEditing: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void) {
        self.toggleEmoji = toggleEmoji
        self.toggleTools = toggleTools
        self.send = send
        self.onBeginEditing = onBeginEditing
        self.onEditingChanged = onEditingChanged
    }
}

public struct ChatComposerTextEntry: View {
    let input: ChatComposerTextEntryInput
    let text: Binding<String>
    let dynamicHeight: Binding<CGFloat>
    let selection: Binding<NSRange>
    let actions: ChatComposerTextEntryActions

    public var body: some View {
        Group {
            Button(action: actions.toggleEmoji) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 38, height: 38)
            }
            .accessibilityIdentifier("chat_emoji_toggle_button")
            ComposerInputBox(text: text, dynamicHeight: dynamicHeight, selection: selection,
                isDisabled: input.isDisabled, onBeginEditing: actions.onBeginEditing,
                onEditingChanged: actions.onEditingChanged)
                .disabled(input.isDisabled)
                .accessibilityIdentifier("chat_message_input")
            Button(action: actions.toggleTools) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 38, height: 38)
            }
            .accessibilityIdentifier("chat_tools_toggle_button")
            Button(action: actions.send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(input.isDisabled || !input.canSend ? Color(im4Hex: 0xB9C0D6) : IMColor.brand))
            }
            .disabled(input.isDisabled || !input.canSend)
            .accessibilityIdentifier("chat_send_button")
        }
    }

    public init(input: ChatComposerTextEntryInput,
        text: Binding<String>,
        dynamicHeight: Binding<CGFloat>,
        selection: Binding<NSRange>,
        actions: ChatComposerTextEntryActions) {
        self.input = input
        self.text = text
        self.dynamicHeight = dynamicHeight
        self.selection = selection
        self.actions = actions
    }
}
// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END

// Original tail-@ parsing, pure and shared by live render values and actions.
public func chatComposerMentionRange(in input: String) -> Range<String.Index>? {
        guard let atIndex = input.lastIndex(of: "@") else { return nil }
        if atIndex > input.startIndex {
            let previous = input[input.index(before: atIndex)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }
        let queryStart = input.index(after: atIndex)
        let query = input[queryStart...]
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return atIndex..<input.endIndex
    }

public func chatComposerMentionQuery(in input: String) -> String? {
    chatComposerMentionRange(in: input).map { String(input[$0]).dropFirst() }.map(String.init)
}
