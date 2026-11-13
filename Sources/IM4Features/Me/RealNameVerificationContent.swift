// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct RealNameVerificationContent: View {
    @Binding var realName: String
    @Binding var idNumber: String
    let fieldError: String
    let realNameStatusSymbol: String
    let realNameStatusTitle: String
    let realNameStatusSubtitle: String
    let realNameStatusColor: Color
    let canEditRealName: Bool
    let isSubmitting: Bool
    let canSubmit: Bool
    let onNameChange: () -> Void
    let onIDChange: (String) -> Void
    let onSubmit: () -> Void

    public init(realName: Binding<String>, idNumber: Binding<String>, fieldError: String,
                realNameStatusSymbol: String, realNameStatusTitle: String, realNameStatusSubtitle: String,
                realNameStatusColor: Color, canEditRealName: Bool, isSubmitting: Bool, canSubmit: Bool,
                onNameChange: @escaping () -> Void, onIDChange: @escaping (String) -> Void, onSubmit: @escaping () -> Void) {
        _realName = realName
        _idNumber = idNumber
        self.fieldError = fieldError
        self.realNameStatusSymbol = realNameStatusSymbol
        self.realNameStatusTitle = realNameStatusTitle
        self.realNameStatusSubtitle = realNameStatusSubtitle
        self.realNameStatusColor = realNameStatusColor
        self.canEditRealName = canEditRealName
        self.isSubmitting = isSubmitting
        self.canSubmit = canSubmit
        self.onNameChange = onNameChange
        self.onIDChange = onIDChange
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    RealNameStatusHeroCard(
                        symbol: realNameStatusSymbol,
                        eyebrow: "实名认证",
                        title: realNameStatusTitle,
                        subtitle: realNameStatusSubtitle,
                        color: realNameStatusColor
                    )

                    if canEditRealName {
                        VStack(spacing: 14) {
                            FormInput(title: "真实姓名", placeholder: "请输入真实姓名", text: $realName)
                                .im4OnChangeCompat(of: realName) { _, _ in
                                    onNameChange()
                                }
                            FormInput(title: "身份证号码", placeholder: "请输入15或18位身份证号码", text: $idNumber, keyboard: .asciiCapable)
                                .im4OnChangeCompat(of: idNumber) { _, newValue in
                                    onIDChange(newValue)
                                }

                            if !fieldError.isEmpty { // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text(fieldError)
                                        .font(.system(size: 13, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(IMColor.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                            }

                            PrimaryButton(title: isSubmitting ? "提交中..." : "提交认证", systemImage: "checkmark.seal.fill", disabled: !canSubmit) {
                                onSubmit()
                            }
                        }
                        .im4GlassCard(radius: 28)
                    }

                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
