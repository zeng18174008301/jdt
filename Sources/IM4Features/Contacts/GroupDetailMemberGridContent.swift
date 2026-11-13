// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

import IM4Domain

public struct GroupDetailMemberGridContent<Tile: View>: View {
    let isEmpty: Bool
    let onMembers: () -> Void
    let onReload: () -> Void
    let tiles: () -> Tile

    public init(isEmpty: Bool, onMembers: @escaping () -> Void, onReload: @escaping () -> Void,
                @ViewBuilder tiles: @escaping () -> Tile) {
        self.isEmpty = isEmpty
        self.onMembers = onMembers
        self.onReload = onReload
        self.tiles = tiles
    }

    public var body: some View {
        // WDT_GROUP_DETAIL_LAYOUT_20261021: retain the 5-column member contract with room for names.
        VStack(alignment: .leading, spacing: 18) {
            Text("群成员")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 20) {
                tiles()
                Button(action: onMembers) {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text("成员列表")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 30, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("group_detail_member_list")
            }
            if isEmpty {
                Button("重新加载成员资料") {
                    onReload()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColor.muted)
            }
        }
        .im4PlainCard(radius: 24)
    }
}

public struct GroupDetailMemberTileContent<Avatar: View>: View {
    let name: String
    let rank: Int
    let onSelect: () -> Void
    let avatar: () -> Avatar

    public init(name: String, rank: Int, onSelect: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar) {
        self.name = name
        self.rank = rank
        self.onSelect = onSelect
        self.avatar = avatar
    }

    public var body: some View {
        Button { onSelect() } label: {
            VStack(spacing: 10) {
                avatar()
                    .clipShape(Circle())
                    .overlay(alignment: .bottom) {
                        if rank < 2 {
                            Text(rank == 0 ? "群主" : "管理员")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(rank == 0 ? IMColor.warning : IMColor.brand))
                                .fixedSize()
                                .offset(y: 4)
                        }
                    }
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 30, alignment: .top)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
