// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct GroupFileForwardContent<Rows: View>: View {
    let fileName: String
    @Binding var query: String
    @Binding var selectedTab: BatchForwardTargetTab
    let rows: () -> Rows

    public init(fileName: String, query: Binding<String>, selectedTab: Binding<BatchForwardTargetTab>,
                @ViewBuilder rows: @escaping () -> Rows) {
        self.fileName = fileName
        _query = query
        _selectedTab = selectedTab
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "arrowshape.turn.up.right.fill", title: "转发文件", subtitle: fileName, showsCloseButton: true)
                    Picker("目标类型", selection: $selectedTab) {
                        Text("好友").tag(BatchForwardTargetTab.friend)
                        Text("群聊").tag(BatchForwardTargetTab.group)
                    }
                    .pickerStyle(.segmented)
                    SearchField(text: $query, placeholder: "搜索目标会话") {}
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            rows()
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

public struct GroupFileForwardRowContent<Avatar: View>: View {
    let name: String
    let subtitle: String
    let isSubmitting: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let avatar: () -> Avatar

    public init(name: String, subtitle: String, isSubmitting: Bool, isDisabled: Bool,
                onSelect: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar) {
        self.name = name
        self.subtitle = subtitle
        self.isSubmitting = isSubmitting
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        self.avatar = avatar
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
                if isSubmitting {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill").foregroundStyle(IMColor.brand)
                }
            }
            .padding(12)
            .im4PlainCard(radius: 18)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
