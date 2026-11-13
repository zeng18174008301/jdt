// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthPageContent<Content: View>: View {
    let showsBack: Bool
    let scrollToBottomTrigger: Int
    let onBack: () -> Void
    let content: Content

    public init(showsBack: Bool, scrollToBottomTrigger: Int, onBack: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.showsBack = showsBack
        self.scrollToBottomTrigger = scrollToBottomTrigger
        self.onBack = onBack
        self.content = content()
    }

    public var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if showsBack {
                        HStack {
                            IconButton(symbol: "chevron.left") {
                                onBack() // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                            }
                            Spacer()
                        }
                        .padding(.top, 12)
                    }

                    content
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
                Color.clear
                    .frame(height: 1)
                    .id("auth_page_bottom_anchor")
            }
            .authInteractiveKeyboardDismiss()
            .im4OnChangeCompat(of: scrollToBottomTrigger) { _, trigger in
                guard trigger > 0 else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    scrollProxy.scrollTo("auth_page_bottom_anchor", anchor: .bottom)
                }
            }
        }
    }
}


public struct AuthWorkspaceRowInput: Identifiable {
    public let id: String
    let canEnter: Bool
    let accessibilityLabel: String

    public init(id: String, canEnter: Bool, accessibilityLabel: String) {
        self.id = id
        self.canEnter = canEnter
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct AuthWorkspaceSelectionContent<Row: View>: View {
    @Binding var makeDefaultWorkspace: Bool
    let message: String?
    let isLoading: Bool
    let rows: [AuthWorkspaceRowInput]
    let row: (String) -> Row
    let onSelect: (String, Bool) -> Void
    let onCancel: () -> Void

    public init(makeDefaultWorkspace: Binding<Bool>, message: String?, isLoading: Bool, rows: [AuthWorkspaceRowInput],
                @ViewBuilder row: @escaping (String) -> Row, onSelect: @escaping (String, Bool) -> Void,
                onCancel: @escaping () -> Void) {
        _makeDefaultWorkspace = makeDefaultWorkspace
        self.message = message
        self.isLoading = isLoading
        self.rows = rows
        self.row = row
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择企业")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(message ?? "该账号可进入多个企业，请选择本次要进入的企业。") // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $makeDefaultWorkspace) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设为默认企业")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                    Text("勾选后保存偏好，下次登录按企业状态自动进入。")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: IMColor.brand))
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.card))
            .accessibilityLabel("设为默认企业")

            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂无可选择企业")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("当前账号没有返回企业列表，请稍后重试或联系管理员。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.card))
            } else {
                VStack(spacing: 10) {
                    ForEach(rows) { item in
                        Button {
                            onSelect(item.id, makeDefaultWorkspace)
                        } label: {
                            row(item.id)
                                .opacity(item.canEnter ? 1 : 0.64)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || !item.canEnter)
                        .accessibilityLabel(item.accessibilityLabel)
                    }
                }
            }

            Button {
                onCancel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("返回登录")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isLoading) // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 436, maxHeight: 560, alignment: .top)
        .authGlass()
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
