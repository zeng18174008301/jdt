// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ConversationActionSheetContent<Avatar: View, Certification: View, Summary: View>: View {
    let displayTitle: String
    let isDirect: Bool
    let isPinned: Bool
    let isMuted: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let summary: () -> Summary
    let onClose: () -> Void
    let onTogglePinned: () -> Void
    let onToggleMuted: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteAlert = false
    public init(displayTitle: String, isDirect: Bool, isPinned: Bool, isMuted: Bool,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                @ViewBuilder summary: @escaping () -> Summary, onClose: @escaping () -> Void,
                onTogglePinned: @escaping () -> Void, onToggleMuted: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.displayTitle = displayTitle; self.isDirect = isDirect; self.isPinned = isPinned; self.isMuted = isMuted
        self.avatar = avatar; self.certification = certification; self.summary = summary
        self.onClose = onClose; self.onTogglePinned = onTogglePinned; self.onToggleMuted = onToggleMuted; self.onDelete = onDelete
    }
    public var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(IMColor.line)
                .frame(width: 42, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayTitle)
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        if isDirect {
                            certification()
                        }
                    }
                    summary()
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.line.opacity(0.78)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation_action_close")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ConversationActionRow(
                    symbol: isPinned ? "pin.slash.fill" : "pin.fill",
                    title: isPinned ? "取消置顶" : "置顶会话",
                    subtitle: isPinned ? "从置顶会话中移除" : "固定在会话列表顶部",
                    tint: IMColor.warning,
                    identifier: isPinned ? "conversation_action_unpin" : "conversation_action_pin"
                ) {
                    onTogglePinned()
                    onClose()
                }
                Divider().padding(.leading, 64)

                ConversationActionRow(
                    symbol: isMuted ? "bell.fill" : "bell.slash.fill",
                    title: isMuted ? "关闭免打扰" : "开启免打扰",
                    subtitle: isMuted ? "恢复新消息提醒" : "静默接收此会话消息",
                    tint: IMColor.brand,
                    identifier: isMuted ? "conversation_action_unmute" : "conversation_action_mute"
                ) {
                    onToggleMuted()
                    onClose()
                }
                Divider().padding(.leading, 64)

                ConversationActionRow(
                    symbol: "trash.fill",
                    title: "删除会话",
                    subtitle: "仅删除本机列表记录",
                    tint: IMColor.danger,
                    isDestructive: true,
                    identifier: "conversation_action_delete"
                ) {
                    showDeleteAlert = true
                }
            }
        }
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.86), lineWidth: 1)
                )
                .shadow(color: Color(im4Hex: 0x172033, alpha: 0.18), radius: 26, y: 14)
        )
        .padding(.horizontal, 14)
        .alert("删除会话？", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete()
                onClose()
            }
        } message: {
            Text("删除后仅移除本机会话列表记录，不会清空服务端消息。")
        }
    }
}

private struct ConversationActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    var isDestructive = false
    let identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(tint.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(isDestructive ? IMColor.danger : IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

public struct ConversationActionSummaryContent: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IMColor.muted)
            .lineLimit(1)
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
