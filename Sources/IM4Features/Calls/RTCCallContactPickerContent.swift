// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct RTCCallContactPickerContent<Row: View>: View {
    @Binding var query: String
    let isEmpty: Bool
    let hasContacts: Bool
    let preferredKind: RTCCallActionKind
    let onClose: () -> Void
    let rows: () -> Row

    public init(query: Binding<String>, isEmpty: Bool, hasContacts: Bool, preferredKind: RTCCallActionKind,
                onClose: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Row) {
        _query = query
        self.isEmpty = isEmpty
        self.hasContacts = hasContacts
        self.preferredKind = preferredKind
        self.onClose = onClose
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            VStack(spacing: 14) {
                SearchField(text: $query, placeholder: "搜索好友、拼音或用户ID")
                    .accessibilityIdentifier("rtc_call_contact_search_field")
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                Label("本次准备发起\(preferredKind.title)", systemImage: preferredKind.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(preferredKind.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)

                if isEmpty {
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        Image(systemName: !hasContacts ? "person.crop.circle.badge.exclamationmark" : "magnifyingglass")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text(!hasContacts ? "暂无可呼叫好友" : "没有匹配的好友")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(!hasContacts ? "添加好友后即可从这里发起一对一语音或视频通话。" : "可输入姓名、拼音首字母或用户ID继续搜索。") // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            rows()
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
            .background(IMColor.page.ignoresSafeArea())
            .navigationTitle("选择好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        onClose()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }
}

public struct RTCCallContactRowContent<Avatar: View, Certification: View, Voice: View, Video: View>: View {
    let name: String
    let subtitle: String
    let avatar: () -> Avatar
    let certification: () -> Certification
    let voiceAction: () -> Voice
    let videoAction: () -> Video

    public init(name: String, subtitle: String, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                @ViewBuilder voiceAction: @escaping () -> Voice, @ViewBuilder videoAction: @escaping () -> Video) {
        self.name = name
        self.subtitle = subtitle
        self.avatar = avatar
        self.certification = certification
        self.voiceAction = voiceAction
        self.videoAction = videoAction
    }

    public var body: some View {
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                certification()
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                voiceAction()
                videoAction()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line.opacity(0.80), lineWidth: 1))
        )
    }
}

public struct RTCCallContactActionContent: View {
    let kind: RTCCallActionKind
    let userID: String
    let displayName: String
    let unavailableReason: String?
    let onSelect: () -> Void

    public init(kind: RTCCallActionKind, userID: String, displayName: String, unavailableReason: String?,
                onSelect: @escaping () -> Void) {
        self.kind = kind
        self.userID = userID
        self.displayName = displayName
        self.unavailableReason = unavailableReason
        self.onSelect = onSelect
    }

    public var body: some View {
        let isEnabled = unavailableReason == nil
        Button(action: onSelect) {
            Label(
                kind.title,
                systemImage: isEnabled ? kind.systemImage : kind.unavailableSystemImage
            )
            .font(.caption2.weight(.black))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(.white)
            .frame(width: 82)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? kind.accentColor : IMColor.muted.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("rtc_contact_\(kind.rawValue)_call_\(userID)")
        .accessibilityLabel("向\(displayName)发起\(kind.title)")
        .accessibilityHint(isEnabled ? "发起\(kind.title)" : (unavailableReason ?? "暂无法发起\(kind.title)"))
    }
}
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END
