import SwiftUI
import IM4Domain
import IM4DesignSystem

@MainActor public final class ChatContactPickerPresentationState: ObservableObject {
    @Published public var query = ""
    public init() {}
}
public struct ChatContactCardCandidate: Identifiable {
    let user: IMUser
    let displayName: String
    let certification: ChatCertificationRendering.Reference?
    public var id: String { user.id }
    public init(user: IMUser, displayName: String, certification: ChatCertificationRendering.Reference?) {
        self.user = user; self.displayName = displayName; self.certification = certification
    }
}
public struct ChatContactCardPickerContent: View {
    @Binding var query: String
    let contacts: [ChatContactCardCandidate]
    let select: (IMUser) -> Void
    public init(query: Binding<String>, contacts: [ChatContactCardCandidate], select: @escaping (IMUser) -> Void) {
        self._query = query; self.contacts = contacts; self.select = select
    }
    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "person.crop.rectangle", title: "发送名片", subtitle: "选择联系人，将名片发送到当前会话。", showsCloseButton: true)
                    SearchField(text: $query, placeholder: "搜索联系人、用户ID或拼音")
                        .accessibilityIdentifier("contact_card_search_field")
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(contacts) { candidate in
                                let user = candidate.user
                                let displayName = candidate.displayName
                                Button {
                                    select(user)
                                } label: {
                                    HStack(spacing: 12) {
                                        ChatAvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: candidate.certification) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(displayName)
                                                    .font(.system(size: 15, weight: .black))
                                                    .foregroundStyle(IMColor.ink)
                                                    .lineLimit(1)
                                                ChatCertificationPillView(
                                                    exactUID: user.id,
                                                    compact: true
                                                )
                                            }
                                            Text("联系人名片")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 14, weight: .black))
                                            .foregroundStyle(IMColor.brand)
                                            .frame(width: 34, height: 34)
                                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                    }
                                    .padding(13)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(.white.opacity(0.82))
                                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line))
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("contact_card_user_\(user.id)")
                                .certificationAccessibilityLabel(
                                    "发送 \(displayName) 名片",
                                    reference: candidate.certification
                                ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
