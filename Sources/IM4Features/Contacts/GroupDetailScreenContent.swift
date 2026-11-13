// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum GroupDetailMenuAction {
    case announcement, files, pinnedMessages, togglePinned, muteAll, muteList, mute
    case joinApproval, memberFriendApply, historyVisibility, dissolve, leave
}

public struct GroupDetailScreenContent<Summary: View, Members: View, Menu: View>: View {
    let summary: Summary
    let members: () -> Members
    let menu: Menu
    let onClose: () -> Void

    public init(summary: Summary, @ViewBuilder members: @escaping () -> Members, menu: Menu, onClose: @escaping () -> Void) {
        self.summary = summary
        self.members = members
        self.menu = menu
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                // WDT_GROUP_DETAIL_LAYOUT_20261021: spacing and alignment only.
                VStack(spacing: 20) {
                    summary

                    members()

                    menu

                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            VStack {
                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.94)))
                            .overlay(Circle().stroke(IMColor.line, lineWidth: 1))
                            .shadow(color: IMColor.brand.opacity(0.10), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("关闭群详情")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                Spacer()
            }
                .zIndex(5)
            }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
