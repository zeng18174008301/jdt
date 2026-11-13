// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct GroupMuteAllContent: View {
    @Binding var selectedMode: GroupMuteMode
    @Binding var startAt: Date
    @Binding var endAt: Date
    @State private var showAlwaysConfirmation = false
    @State private var showCloseConfirmation = false
    let status: String
    let endsOnNextDay: Bool
    let schedulePreview: String
    let requiresRepair: Bool
    let inlineMessage: String?
    let canCloseMute: Bool
    let isSubmitting: Bool
    let onModeChange: () -> Void
    let onSubmit: (GroupMuteMode) -> Void

    public init(
        selectedMode: Binding<GroupMuteMode>, startAt: Binding<Date>, endAt: Binding<Date>,
        status: String, endsOnNextDay: Bool, schedulePreview: String, requiresRepair: Bool,
        inlineMessage: String?, canCloseMute: Bool, isSubmitting: Bool,
        onModeChange: @escaping () -> Void, onSubmit: @escaping (GroupMuteMode) -> Void
    ) {
        _selectedMode = selectedMode
        _startAt = startAt
        _endAt = endAt
        self.status = status
        self.endsOnNextDay = endsOnNextDay
        self.schedulePreview = schedulePreview
        self.requiresRepair = requiresRepair
        self.inlineMessage = inlineMessage
        self.canCloseMute = canCloseMute
        self.isSubmitting = isSubmitting
        self.onModeChange = onModeChange
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    SheetHeader(
                        symbol: "speaker.slash.fill",
                        title: "全员禁言",
                        subtitle: status,
                        showsCloseButton: true
                    )

                    VStack(spacing: 12) {
                        GroupMuteModeCard(
                            title: "一直禁言",
                            subtitle: "确认后立即生效，需管理员手动关闭",
                            symbol: "infinity",
                            isSelected: selectedMode == .always
                        ) {
                            selectedMode = .always
                            onModeChange()
                        }
                        GroupMuteModeCard(
                            title: "固定时段",
                            subtitle: "按设置的开始与结束时间自动生效",
                            symbol: "calendar.badge.clock",
                            isSelected: selectedMode == .scheduled
                        ) {
                            selectedMode = .scheduled
                            onModeChange()
                        }
                    }

                    if selectedMode == .scheduled {
                        VStack(spacing: 14) {
                            GroupMuteTimeRow(title: "开始时间", selection: $startAt)
                            Divider()
                            GroupMuteTimeRow(title: "结束时间", selection: $endAt, showsNextDay: endsOnNextDay)
                            HStack(spacing: 8) {
                                Image(systemName: "clock.badge.checkmark.fill")
                                Text("禁言时段：\(schedulePreview)")
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        }
                        .padding(16)
                        .im4PlainCard(radius: 24)
                    }

                    notices
                    actionButtons
                }
                .padding(18)
            }
        }
        .alert("立即开启一直禁言？", isPresented: $showAlwaysConfirmation) {
            Button("取消", role: .cancel) {}
            Button("立即开启") {
                onSubmit(.always)
            }
        } message: {
            Text("确认后立即生效，普通成员将无法发言，群主和管理员仍可继续发言。")
        }
        .alert("关闭全员禁言？", isPresented: $showCloseConfirmation) {
            Button("取消", role: .cancel) {}
            Button("关闭禁言", role: .destructive) {
                onSubmit(.off)
            }
        } message: {
            Text("关闭后普通成员将立即恢复发送权限。")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if requiresRepair {
            Label(
                "当前禁言数据需要管理员重新保存或关闭；修复前普通成员保持禁言。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(IMColor.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger.opacity(0.08)))
        }

        VStack(alignment: .leading, spacing: 10) {
            Label("禁言期间，群主和管理员仍可正常发消息。", systemImage: "checkmark.shield.fill")
            Label("普通成员的文字、表情、附件和语音发送都会被阻止，草稿会保留。", systemImage: "text.bubble.fill")
            Label("固定时段采用服务器时间；结束时间不包含在禁言区间内。", systemImage: "clock.fill")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(IMColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.warning.opacity(0.08)))

        if let message = inlineMessage {
            Text(message)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        PrimaryButton(
            title: isSubmitting
                ? "正在保存…"
                : (selectedMode == .always ? "立即开启" : "保存时段"),
            systemImage: isSubmitting ? nil : "checkmark.shield.fill",
            disabled: isSubmitting
        ) {
            if selectedMode == .always {
                showAlwaysConfirmation = true
            } else {
                onSubmit(.scheduled)
            }
        }

        if canCloseMute {
            Button {
                showCloseConfirmation = true
            } label: {
                Text("关闭禁言")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(IMColor.danger.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityHint("关闭后普通成员立即恢复发送权限")
        }
    }

}

private struct GroupMuteModeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(isSelected ? .white : IMColor.brand)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSelected ? IMColor.brand : IMColor.brand.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isSelected ? IMColor.brand : IMColor.muted.opacity(0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.90))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? IMColor.brand.opacity(0.72) : IMColor.line, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct GroupMuteTimeRow: View {
    let title: String
    @Binding var selection: Date
    var showsNextDay = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            Spacer(minLength: 12)
            if showsNextDay {
                StatusPill(title: "次日", color: IMColor.warning)
            }
            DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
