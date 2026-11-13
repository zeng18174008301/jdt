// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupHistoryVisibilityContent: View {
    @Binding var isOn: Bool
    let onClose: () -> Void
    @Binding var showEnableConfirm: Bool
    let canManage: Bool
    let onConfirmEnable: () -> Void

    public init(isOn: Binding<Bool>, showEnableConfirm: Binding<Bool>, canManage: Bool, onConfirmEnable: @escaping () -> Void, onClose: @escaping () -> Void) {
        _isOn = isOn
        self.onClose = onClose
        _showEnableConfirm = showEnableConfirm
        self.canManage = canManage
        self.onConfirmEnable = onConfirmEnable
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(
                    symbol: "clock.arrow.circlepath",
                    title: "新成员可查看入群前消息",
                    subtitle: isOn ? "全部可见" : "仅入群后",
                    showsCloseButton: true
                )
                VStack(spacing: 0) {
                    GroupToggleRow(
                        title: "允许查看入群前消息",
                        subtitle: isOn ? "新加入成员可查看入群前消息" : "新加入成员仅可查看入群后的消息",
                        isEnabled: canManage,
                        isOn: $isOn
                    )
                }
                .im4PlainCard(radius: 24)
                VStack(alignment: .leading, spacing: 10) {
                    Label("仅影响之后加入或重新加入的成员。", systemImage: "person.crop.circle.badge.clock")
                    Label("修改后不会改变当前成员已经获得的历史消息权限。", systemImage: "lock.shield.fill")
                    if !canManage {
                        Label("仅群主和管理员可以修改此设置。", systemImage: "checkmark.shield.fill")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.warning.opacity(0.08)))
                PrimaryButton(title: "完成", systemImage: "checkmark.circle.fill") {
                    onClose()
                }
            }
            .padding(18)
        }
        .alert("开启历史消息可见？", isPresented: $showEnableConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认开启") {
                onConfirmEnable()
            }
        } message: {
            Text("仅影响之后加入或重新加入的成员。修改后不会改变当前成员已经获得的历史消息权限。")
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
