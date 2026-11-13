// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ContactCardShareContent<Avatar: View, Certification: View, Rows: View>: View {
    let displayName: String
    let avatar: () -> Avatar
    let certification: () -> Certification
    let rows: () -> Rows

    public init(displayName: String, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification, @ViewBuilder rows: @escaping () -> Rows) {
        self.displayName = displayName
        self.avatar = avatar
        self.certification = certification
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(symbol: "person.text.rectangle", title: "发送名片", subtitle: "选择一个会话，将该好友名片发送到聊天中。", showsCloseButton: true)
                        HStack(spacing: 12) {
                            avatar()
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(displayName)
                                        .font(.system(size: 18, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    certification()
                                }
                                Text("企业名片")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                            StatusPill(title: "名片", color: IMColor.brand)
                        }
                        .im4PlainCard(radius: 22)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("发送到")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            rows()
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

public struct ContactCardShareTargetContent<Avatar: View, Certification: View>: View {
    let name: String
    let tag: (title: String, color: Color)?
    let onSelect: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(name: String, tag: (title: String, color: Color)?, onSelect: @escaping () -> Void,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification) {
        self.name = name
        self.tag = tag
        self.onSelect = onSelect
        self.avatar = avatar
        self.certification = certification
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                    if let conversationTag = tag {
                        StatusPill(title: conversationTag.title, color: conversationTag.color)
                    }
                }
                Spacer()
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColor.brand)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.88)))
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
