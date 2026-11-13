import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI

public struct ReactionPickerContent: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let onReact: (String) -> Bool
    let fullPicker: (@escaping () -> Void) -> AnyView?
    let lifecycle: ChatReactionLifecycleInput
    let synchronize: @MainActor () async -> Void
    let signedOut: () -> Void
    let disappeared: () -> Void
    @State private var showFullPicker = false
    private let reactions = ["👍", "❤️", "🔥", "🎉", "😂", "✅", "💡", "👀"]
    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 84), spacing: 12)]

    private var previewText: String {
        if message.kind == .file || message.kind == .contactCard {
            return message.attachmentName ?? message.text
        }
        return message.text
    }


    private var effectiveFullPicker: AnyView? {
        fullPicker {
            showFullPicker = false
            DispatchQueue.main.async { dismiss() }
        }
    }
    private func selectReaction(_ emoji: String) {
        if onReact(emoji) { dismiss() }
    }
    public var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.reaction?(selectReaction)
#endif
        ZStack {
            AuroraBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "face.smiling.fill", title: "表情回应", subtitle: "选择一个表情同步到当前消息。", showsCloseButton: true)

                    Text("快速回应")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(IMColor.ink)
                        .accessibilityAddTraits(.isHeader)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(reactions, id: \.self) { emoji in
                            Button {
                                selectReaction(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(IMColor.brand.opacity(0.10))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                    .stroke(.white.opacity(0.7), lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(emoji))
                            .accessibilityHint("用此 Emoji 回应当前消息")
                            .accessibilityIdentifier("quick_reaction_\(emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_"))")
                        }
                    }

                    if effectiveFullPicker != nil {
                        Button {
                            showFullPicker = true
                        } label: {
                            Label("更多 Emoji", systemImage: "ellipsis.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(IMColor.brand)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(IMColor.brand.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开完整 Unicode Emoji 目录")
                        .accessibilityIdentifier("reaction_more_emoji")
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: message.kind == .file ? "doc.richtext.fill" : (message.kind == .contactCard ? "person.crop.rectangle" : "text.bubble.fill"))
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text(previewText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .task(id: lifecycle) { await synchronize() }
        .im4OnChangeCompat(of: lifecycle.authenticated) { _, authenticated in
            guard !authenticated else { return }
            signedOut()
        }
        .onDisappear { disappeared() }
        .sheet(isPresented: $showFullPicker) {
            if let fullPicker = effectiveFullPicker {
                fullPicker
                    .im4PresentationDetentsCompat([.medium, .large])
                    .im4PresentationDragIndicatorCompat(.visible)
            }
        }
    }

    public init(message: ChatMessage,
        onReact: @escaping (String) -> Bool,
        fullPicker: @escaping (@escaping () -> Void) -> AnyView?,
        lifecycle: ChatReactionLifecycleInput,
        synchronize: @escaping @MainActor () async -> Void,
        signedOut: @escaping () -> Void,
        disappeared: @escaping () -> Void) {
        self.message = message
        self.onReact = onReact
        self.fullPicker = fullPicker
        self.lifecycle = lifecycle
        self.synchronize = synchronize
        self.signedOut = signedOut
        self.disappeared = disappeared
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
