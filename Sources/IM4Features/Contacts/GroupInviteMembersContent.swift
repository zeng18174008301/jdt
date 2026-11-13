// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupInviteMembersContent<Rows: View>: View {
    @Binding var query: String
    let canManage: Bool
    let isEmpty: Bool
    let selectedCount: Int
    let isSubmitting: Bool
    let onSubmit: () -> Void
    let rows: () -> Rows

    public init(query: Binding<String>, canManage: Bool, isEmpty: Bool, selectedCount: Int,
                isSubmitting: Bool, onSubmit: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        _query = query
        self.canManage = canManage
        self.isEmpty = isEmpty
        self.selectedCount = selectedCount
        self.isSubmitting = isSubmitting
        self.onSubmit = onSubmit
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "person.badge.plus", title: "邀请好友", subtitle: canManage ? "群主和管理员可邀请已知企业成员，成功后直接入群。" : "普通成员邀请好友后，需要群主或管理员审核。", showsCloseButton: true)
                    SearchField(text: $query, placeholder: canManage ? "搜索成员、用户ID或拼音" : "搜索好友、用户ID或拼音")
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if isEmpty {
                                EmptyStateView(symbol: "person.crop.circle.badge.checkmark", title: "没有可邀请成员", subtitle: "当前好友均已在群内，或换个关键词搜索。")
                            } else {
                                rows()
                            }
                        }
                    }
                    PrimaryButton(title: selectedCount == 0 ? "邀请入群" : (canManage ? "邀请入群 \(selectedCount)" : "提交审核 \(selectedCount)"), systemImage: "paperplane.fill", disabled: selectedCount == 0 || isSubmitting) {
                        onSubmit()
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
