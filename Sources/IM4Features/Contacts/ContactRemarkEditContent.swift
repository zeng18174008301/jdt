// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ContactRemarkEditContent: View {
    @Binding var draftRemark: String
    let remarkCount: Int
    let maximumLength: Int
    let validationMessage: String?
    let saveErrorMessage: String?
    let isSaving: Bool
    let onSave: (String) -> Void

    public init(draftRemark: Binding<String>, remarkCount: Int, maximumLength: Int, validationMessage: String?,
                saveErrorMessage: String?, isSaving: Bool, onSave: @escaping (String) -> Void) {
        _draftRemark = draftRemark
        self.remarkCount = remarkCount
        self.maximumLength = maximumLength
        self.validationMessage = validationMessage
        self.saveErrorMessage = saveErrorMessage
        self.isSaving = isSaving
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(symbol: "pencil", title: "设置备注", subtitle: "备注仅自己可见，用于通讯录和资料页识别。", showsCloseButton: true)
            FormInput(title: "好友备注", placeholder: "输入备注名称", text: $draftRemark)
                .disabled(isSaving)
            HStack {
                Spacer()
                Text("\(remarkCount)/\(maximumLength)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(validationMessage == nil ? IMColor.muted : IMColor.danger)
                    .accessibilityLabel("已输入 \(remarkCount) 个字符，最多 \(maximumLength) 个")
            }
            if let message = saveErrorMessage ?? validationMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .accessibilityIdentifier("contact_remark_save_error")
            }
            HStack(spacing: 10) {
                Button {
                    draftRemark = ""
                    onSave("")
                } label: {
                    Text("清空")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.page))
                }
                .disabled(isSaving)
                .accessibilityIdentifier("contact_remark_clear_button")
                PrimaryButton(
                    title: isSaving ? "保存中" : "保存",
                    systemImage: isSaving ? "clock" : "checkmark",
                    disabled: isSaving || validationMessage != nil
                ) {
                    onSave(draftRemark)
                }
                .accessibilityIdentifier("contact_remark_save_button")
            }
        }
        .padding(20)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
