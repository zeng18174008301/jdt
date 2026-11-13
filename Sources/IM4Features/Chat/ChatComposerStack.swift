import SwiftUI

public struct ChatComposerStack<Disabled: View, Voice: View, Reply: View, Mention: View, Input: View, Expression: View, Tools: View>: View {
    let disabled: () -> Disabled
    let voice: () -> Voice
    let reply: () -> Reply
    let mention: () -> Mention
    let input: () -> Input
    let expression: () -> Expression
    let tools: () -> Tools
    public init(@ViewBuilder disabled: @escaping () -> Disabled, @ViewBuilder voice: @escaping () -> Voice,
        @ViewBuilder reply: @escaping () -> Reply, @ViewBuilder mention: @escaping () -> Mention,
        @ViewBuilder input: @escaping () -> Input, @ViewBuilder expression: @escaping () -> Expression,
        @ViewBuilder tools: @escaping () -> Tools) {
        self.disabled = disabled; self.voice = voice; self.reply = reply; self.mention = mention
        self.input = input; self.expression = expression; self.tools = tools
    }
    public var body: some View {
        VStack(spacing: 10) {
            disabled(); voice(); reply(); mention(); input(); expression(); tools()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground).opacity(0.96))
    }
}
