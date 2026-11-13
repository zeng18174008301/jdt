// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct EnterpriseDefaultWorkspaceContent<Logo: View>: View {
    let name: String
    let displayCode: String?
    let onClear: () -> Void
    let logo: () -> Logo

    public init(name: String, displayCode: String?, onClear: @escaping () -> Void, @ViewBuilder logo: @escaping () -> Logo) {
        self.name = name
        self.displayCode = displayCode
        self.onClear = onClear
        self.logo = logo
    }

    public var body: some View {
        HStack(spacing: 12) {
            logo()
            VStack(alignment: .leading, spacing: 3) {
                Text("默认企业")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                if let displayCode, !displayCode.isEmpty {
                    Text("企业码 \(displayCode)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("清除", action: onClear)
                .font(.system(size: 12, weight: .black))
                .buttonStyle(.bordered)
                .tint(IMColor.brand)
                .accessibilityLabel("清除默认企业")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(IMColor.card)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line, lineWidth: 1))
        )
    }
}

public struct EnterpriseDefaultWorkspaceFallbackIcon: View {
    public init() {}

    public var body: some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(IMColor.brand)
            .frame(width: 34, height: 34)
            .background(Circle().fill(IMColor.brand.opacity(0.10)))
    }
}

public struct EnterpriseSwitcherDirectoryListContent<Rows: View>: View {
    let showingSearchResults: Bool
    let isSearching: Bool
    let rows: () -> Rows

    public init(showingSearchResults: Bool, isSearching: Bool, @ViewBuilder rows: @escaping () -> Rows) {
        self.showingSearchResults = showingSearchResults
        self.isSearching = isSearching
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showingSearchResults ? "搜索结果" : "企业列表")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                if isSearching {
                    ProgressView()
                        .tint(IMColor.brand)
                }
            }
            rows()
        }
    }
}

public struct EnterpriseSwitcherDirectoryRowContent<Card: View>: View {
    let id: String
    let name: String
    let isJoining: Bool
    let onSelect: () -> Void
    let card: () -> Card

    public init(id: String, name: String, isJoining: Bool,
                onSelect: @escaping () -> Void, @ViewBuilder card: @escaping () -> Card) {
        self.id = id
        self.name = name
        self.isJoining = isJoining
        self.onSelect = onSelect
        self.card = card
    }

    public var body: some View {
        Button(action: onSelect, label: card)
            .buttonStyle(.plain)
            .disabled(isJoining)
            .accessibilityIdentifier("enterprise_row_\(id)")
            .accessibilityLabel("企业 \(name)")
    }
}

public struct EnterpriseSwitcherDirectoryEmptyContent: View {
    let message: String?

    public init(message: String?) { self.message = message }

    public var body: some View {
        let identityUnlinked = message == "当前账号企业身份未同步，请联系管理员处理"
        EmptyStateView(
            symbol: identityUnlinked ? "person.crop.circle.badge.exclamationmark" : "building.2.crop.circle",
            title: identityUnlinked ? "企业身份异常" : "搜索无结果",
            subtitle: message ?? "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。",
            actionTitle: nil
        ) {}
    }
}

public struct EnterpriseSwitcherDirectoryPickHint: View {
    public init() {}

    public var body: some View {
        PrimaryButton(title: "请选择要加入的企业", systemImage: "list.bullet", disabled: true) {}
            .accessibilityIdentifier("enterprise_search_pick_result_hint")
    }
}

public struct EnterpriseSwitcherDirectorySearchHint: View {
    let queryIsEmpty: Bool

    public init(queryIsEmpty: Bool) { self.queryIsEmpty = queryIsEmpty }

    public var body: some View {
        PrimaryButton(title: queryIsEmpty ? "输入企业编码或邀请码搜索" : "点击搜索查询企业", systemImage: "magnifyingglass", disabled: true) {}
            .accessibilityIdentifier("enterprise_search_disabled_button")
    }
}

public struct EnterpriseSwitcherDirectoryActionContent: View {
    let name: String
    let unavailableReason: String
    let unavailable: Bool
    let isJoining: Bool
    let pending: Bool
    let rejected: Bool
    let joined: Bool
    let approved: Bool
    let canUseDirectory: Bool
    let membershipAlreadyJoined: Bool
    let onSelect: () -> Void

    public init(name: String, unavailableReason: String, unavailable: Bool, isJoining: Bool,
                pending: Bool, rejected: Bool, joined: Bool, approved: Bool, canUseDirectory: Bool,
                membershipAlreadyJoined: Bool, onSelect: @escaping () -> Void) {
        self.name = name
        self.unavailableReason = unavailableReason
        self.unavailable = unavailable
        self.isJoining = isJoining
        self.pending = pending
        self.rejected = rejected
        self.joined = joined
        self.approved = approved
        self.canUseDirectory = canUseDirectory
        self.membershipAlreadyJoined = membershipAlreadyJoined
        self.onSelect = onSelect
    }

    public var body: some View {
        PrimaryButton(title: presentation.title, systemImage: presentation.symbol,
                      disabled: !canUseDirectory || pending || rejected || unavailable || isJoining,
                      action: onSelect)
            .accessibilityIdentifier(membershipAlreadyJoined ? "enterprise_switch_button" : "enterprise_join_button")
    }

    private var presentation: (title: String, symbol: String) {
        if unavailable {
            return (unavailableReason.isEmpty ? "暂不可切换" : unavailableReason, "exclamationmark.triangle.fill")
        }
        if isJoining { return ("正在提交申请...", "hourglass") }
        if pending { return ("等待审批", "clock.fill") }
        if rejected { return ("申请已拒绝", "xmark.circle.fill") }
        if joined {
            return (approved ? "申请已通过，进入 \(name)" : "切换到 \(name)", "arrow.triangle.2.circlepath")
        }
        return ("申请加入 \(name)", "plus.circle")
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
