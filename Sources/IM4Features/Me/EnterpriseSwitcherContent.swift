// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct EnterpriseSwitcherContent<DefaultWorkspace: View, DirectoryResults: View>: View {
    @Binding var query: String
    let onClose: () -> Void
    let onSearch: () -> Void
    let onQueryChange: (String) -> Void
    let defaultWorkspace: () -> DefaultWorkspace
    let directoryResults: () -> DirectoryResults

    public init(query: Binding<String>, onClose: @escaping () -> Void, onSearch: @escaping () -> Void,
                onQueryChange: @escaping (String) -> Void, @ViewBuilder defaultWorkspace: @escaping () -> DefaultWorkspace,
                @ViewBuilder directoryResults: @escaping () -> DirectoryResults) {
        _query = query
        self.onClose = onClose
        self.onSearch = onSearch
        self.onQueryChange = onQueryChange
        self.defaultWorkspace = defaultWorkspace
        self.directoryResults = directoryResults
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Capsule()
                                .fill(IMColor.line)
                                .frame(width: 42, height: 5)
                                .frame(maxWidth: .infinity)
                                .padding(.leading, 44)
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.white.opacity(0.78)))
                                    .overlay(Circle().stroke(.white.opacity(0.70), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭企业切换")
                            .accessibilityIdentifier("enterprise_switcher_close_button")
                        }

                        SearchField(text: $query, placeholder: "输入企业编码或邀请码") {
                            onSearch()
                        }
                        .accessibilityIdentifier("enterprise_search_field")
                        .im4OnChangeCompat(of: query) { _, newValue in onQueryChange(newValue) }

                        defaultWorkspace()
                        directoryResults()
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
