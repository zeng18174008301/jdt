import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct ChatComposerDisabledNotice: View {
    let isDisabled: Bool
    let showsDisabledNotice: Bool
    let disabledTitle: String
    let disabledReason: String
    let friendActionTitle: String?
    let isApplyingFriend: Bool
    let applyFriend: () -> Void
    @ViewBuilder
    public var body: some View {
            if isDisabled && showsDisabledNotice {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.warning)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(IMColor.warning.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disabledTitle)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(disabledReason)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    if let friendActionTitle {
                        Button {
                            applyFriend()
                        } label: {
                            if isApplyingFriend {
                                ProgressView()
                                    .scaleEffect(0.72)
                                    .tint(.white)
                                    .frame(width: 20, height: 20)
                            } else {
                                Text(friendActionTitle)
                                    .font(.system(size: 12, weight: .black))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isApplyingFriend)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(IMColor.brand))
                        .accessibilityIdentifier("chat_apply_friend_button")
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(IMColor.warning.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.warning.opacity(0.18)))
                )
                .accessibilityIdentifier("chat_composer_disabled_notice")
            }

    }


    public init(isDisabled: Bool,
        showsDisabledNotice: Bool,
        disabledTitle: String,
        disabledReason: String,
        friendActionTitle: String? = nil,
        isApplyingFriend: Bool,
        applyFriend: @escaping () -> Void) {
        self.isDisabled = isDisabled
        self.showsDisabledNotice = showsDisabledNotice
        self.disabledTitle = disabledTitle
        self.disabledReason = disabledReason
        self.friendActionTitle = friendActionTitle
        self.isApplyingFriend = isApplyingFriend
        self.applyFriend = applyFriend
    }
}

public struct ChatComposerVoiceStatus: View {
    let isRecording: Bool
    let elapsedMS: Int
    let waveform: [Int]
    let isCanceling: Bool
    let isVoiceInputMode: Bool
    let feedback: VoiceRecordingComposerFeedback?
    let previewInput: VoiceRecordingPreviewInput?
    let togglePlayback: () -> Void
    let send: () -> Void
    let cancel: () -> Void
    @ViewBuilder
    public var body: some View {
            if isRecording {
                VoiceRecordingOverlay(
                    elapsedMS: elapsedMS,
                    waveform: waveform,
                    isCanceling: isCanceling
                )
            }

            if isVoiceInputMode, let feedback = feedback {
                VoiceRecordingFeedbackPanel(feedback: feedback)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isVoiceInputMode, previewInput != nil {
                VoiceRecordingPreviewPanel(
                    input: previewInput,
                    togglePlayback: togglePlayback,
                    send: send,
                    cancel: cancel
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

    }


    public init(isRecording: Bool,
        elapsedMS: Int,
        waveform: [Int],
        isCanceling: Bool,
        isVoiceInputMode: Bool,
        feedback: VoiceRecordingComposerFeedback? = nil,
        previewInput: VoiceRecordingPreviewInput? = nil,
        togglePlayback: @escaping () -> Void,
        send: @escaping () -> Void,
        cancel: @escaping () -> Void) {
        self.isRecording = isRecording
        self.elapsedMS = elapsedMS
        self.waveform = waveform
        self.isCanceling = isCanceling
        self.isVoiceInputMode = isVoiceInputMode
        self.feedback = feedback
        self.previewInput = previewInput
        self.togglePlayback = togglePlayback
        self.send = send
        self.cancel = cancel
    }
}

public struct ChatComposerReplyPreview<Quote: View>: View {
    let quote: String?
    let content: (String) -> Quote
    let cancel: () -> Void
    @ViewBuilder
    public var body: some View {
	            if let replyQuote = quote {
	                HStack(alignment: .center, spacing: 8) {
                    content(replyQuote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IMColor.muted)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.08)))
            }

    }


    public init(quote: String? = nil, cancel: @escaping () -> Void,
        @ViewBuilder content: @escaping (String) -> Quote) {
        self.quote = quote; self.cancel = cancel; self.content = content
    }
}

public struct ChatComposerToolGrid: View {
    let isVisible: Bool
    let tools: [ChatComposerToolDescriptor]
    let select: (ChatComposerToolAction) -> Void
    let accessibilityHint: (ChatComposerToolDescriptor) -> String
    @Environment(\.sizeCategory) private var sizeCategory
    private var toolGridColumns: [GridItem] {
        let count = sizeCategory.isAccessibilityCategory ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    @ViewBuilder
    public var body: some View {
	            if isVisible {
                LazyVGrid(columns: toolGridColumns, spacing: 14) {
                    ForEach(tools) { tool in
                        Button {
                            select(tool.action)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(width: 46, height: 46)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                Text(tool.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(sizeCategory.isAccessibilityCategory ? 2 : 1)
                                    .minimumScaleFactor(0.8)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(
                                minWidth: 52,
                                minHeight: sizeCategory.isAccessibilityCategory ? 96 : 70
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(tool.accessibilityIdentifier)
                        .accessibilityLabel(tool.accessibilityLabel)
                        .accessibilityHint(accessibilityHint(tool))
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
    }

    public init(isVisible: Bool,
        tools: [ChatComposerToolDescriptor],
        select: @escaping (ChatComposerToolAction) -> Void,
        accessibilityHint: @escaping (ChatComposerToolDescriptor) -> String) {
        self.isVisible = isVisible
        self.tools = tools
        self.select = select
        self.accessibilityHint = accessibilityHint
    }
}

public struct ChatComposerInputBar<VoicePad: View, TextEntry: View>: View {
    let isVoiceInputMode: Bool
    let toggleVoice: () -> Void
    let toggleTools: () -> Void
    let voicePad: () -> VoicePad
    let textEntry: () -> TextEntry
    public init(isVoiceInputMode: Bool, toggleVoice: @escaping () -> Void, toggleTools: @escaping () -> Void,
        @ViewBuilder voicePad: @escaping () -> VoicePad, @ViewBuilder textEntry: @escaping () -> TextEntry) {
        self.isVoiceInputMode = isVoiceInputMode; self.toggleVoice = toggleVoice
        self.toggleTools = toggleTools; self.voicePad = voicePad; self.textEntry = textEntry
    }
    public var body: some View {
        HStack(spacing: 9) {
            Button(action: toggleVoice) {
                Image(systemName: isVoiceInputMode ? "keyboard.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 38, height: 38)
            }
            .accessibilityIdentifier("chat_voice_toggle_button")
            if isVoiceInputMode {
                voicePad()
                Button(action: toggleTools) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(IMColor.brand)
                        .frame(width: 38, height: 38)
                }
                .accessibilityIdentifier("chat_tools_toggle_button")
            } else { textEntry() }
        }
    }
}
