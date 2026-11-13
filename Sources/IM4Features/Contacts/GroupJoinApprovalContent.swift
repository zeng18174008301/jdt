// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupJoinApprovalContent: View {
    @Binding var isOn: Bool
    let onClose: () -> Void

    public init(isOn: Binding<Bool>, onClose: @escaping () -> Void) {
        _isOn = isOn
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(
                    symbol: "person.badge.shield.checkmark.fill",
                    title: "入群审批",
                    subtitle: isOn ? "已开启，普通成员邀请需要审核。" : "未开启，符合条件的邀请可直接生效。",
                    showsCloseButton: true
                )
                VStack(spacing: 0) {
                    GroupToggleRow(
                        title: "开启入群审批",
                        subtitle: isOn ? "普通成员邀请好友入群时，需要群主或管理员审批" : "关闭后，符合条件的邀请会直接生效",
                        isOn: $isOn
                    )
                }
                .im4PlainCard(radius: 24)
                VStack(alignment: .leading, spacing: 10) {
                    Label("仅群主和管理员可以修改入群审批开关。", systemImage: "checkmark.shield.fill")
                    Label("开启后，普通成员邀请好友时会给群主和管理员发送审批卡片。", systemImage: "tray.full.fill")
                    Label("审批通过后，被邀请人才会正式加入群聊。", systemImage: "person.crop.circle.badge.checkmark")
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
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
