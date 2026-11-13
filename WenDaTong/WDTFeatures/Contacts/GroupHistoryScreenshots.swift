// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit

struct GroupHistoryVisibilityScreenshotHost: View {
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @EnvironmentObject private var state: AppState
    let scenario: GroupHistoryVisibilityScreenshotScenario

    private var group: GroupInfo {
        state.group(id: "group-history-boundary")
            ?? GroupInfo(
                id: "group-history-boundary",
                name: "历史边界验收群",
                notice: "用于 iOS 每群历史消息边界真实界面验收。",
                owner: "边界群主",
                ownerID: "im-history-owner",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                allMuteStart: nil,
                allMuteEnd: nil,
                myRole: scenario == .ownerSettings ? "owner" : "member",
                memberCount: 3,
                historyVisible: scenario == .ownerSettings,
                historyVisibleFromSeq: scenario == .episodeWidened ? 1 : 421,
                historyLimited: scenario != .ownerSettings && scenario != .directUnaffected
            )
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: "group-history-boundary") { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        switch scenario {
        case .ownerSettings, .ownerSettingsLimited:
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
        case .memberReadonly:
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
        case .restrictedGroup:
            NavigationStackCompat {
                requiredChatRouting(chatFeatureRouting).makeChat(group.id)
            }
        case .restrictedGroupFiles:
            GroupFilesSheet(group: group)
                .environmentObject(state)
        case .episodeWidened:
            NavigationStackCompat {
                requiredChatRouting(chatFeatureRouting).makeChat(group.id)
            }
        case .directUnaffected:
            NavigationStackCompat {
                requiredChatRouting(chatFeatureRouting).makeChat("direct-history-unaffected") // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110
            }
        }
    }
}

private struct GroupHistorySettingsScreenshotView: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    let roleText: String

    var body: some View {
        ZStack(alignment: .top) {
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
            HStack(spacing: 8) {
                Label(roleText, systemImage: state.canManageGroup(group) ? "checkmark.shield.fill" : "lock.fill")
                Text(group.historyVisibilityStatusText)
            }
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(IMColor.ink.opacity(0.72)))
            .padding(.top, 54)
        }
    }
}

private struct GroupHistoryBoundaryEvidenceView: View {
    enum Mode {
        case restricted
        case episodeWidened
        case direct
    }

    let title: String
    let subtitle: String
    let group: GroupInfo
    let conversation: ConversationMessageSnapshot?
    let files: [FileItem]
    let mode: Mode

    private var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    private var visibleSeqText: String {
        let seqs = messages.map(\.channelSeq).filter { $0 > 0 }
        guard let first = seqs.first, let last = seqs.last else { return "无消息" }
        return first == last ? "seq \(first)" : "seq \(first)-\(last)"
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    statusGrid
                    if mode == .restricted {
                        limitedPrompt
                    }
                    if mode == .episodeWidened {
                        episodeEvidence
                    }
                    messageList
                    if mode != .direct {
                        derivedCacheEvidence
                    }
                    networkContract
                }
                .padding(.horizontal, 18)
                .padding(.top, 58)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(name: mode == .direct ? (conversation?.title ?? "单聊") : group.name, seed: group.historyLimited ? 0xF97316 : 0x5D6BFF, size: 48, badgeColor: group.historyLimited ? IMColor.warning : IMColor.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
            }
            Text(mode == .direct ? "单聊路径不读取群历史边界，也不会裁剪 seq 1/2。" : "本页由真实 App 启动参数注入 fixture，展示同步合同进入本地渲染后的状态。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassCard(radius: 28)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            evidenceStat(title: "边界", value: mode == .direct ? "不适用" : "\(group.historyVisibleFromSeq)", symbol: "number")
            evidenceStat(title: "状态", value: mode == .direct ? "完整" : (group.historyLimited ? "仅入群后" : "全部可见"), symbol: group.historyLimited ? "lock.fill" : "lock.open.fill")
            evidenceStat(title: "首屏消息", value: visibleSeqText, symbol: "bubble.left.and.bubble.right.fill")
            evidenceStat(title: "本地资料", value: mode == .restricted ? "0 条" : "\(files.count) 条", symbol: "folder.fill")
        }
    }

    private func evidenceStat(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.brand)
                .frame(width: 32, height: 32)
                .background(Circle().fill(IMColor.brand.opacity(0.10)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                Text(value)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .plainCard(radius: 18)
    }

    private var limitedPrompt: some View {
        Label("你只能查看本次入群后的消息", systemImage: "lock.shield.fill")
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(IMColor.warning)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(IMColor.warning.opacity(0.12)))
    }

    private var episodeEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("服务端回显 history_visible_from_seq = 1", systemImage: "arrow.triangle.2.circlepath")
            Label("421→1 视为新 membership episode：先清旧 snapshot，再重拉。", systemImage: "trash.slash.fill")
            Label("乱序旧请求通过 generation guard 丢弃。", systemImage: "clock.badge.exclamationmark.fill")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(IMColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.success.opacity(0.10)))
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mode == .direct ? "单聊消息窗口" : "群消息窗口")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text("\(messages.count) 条")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.brand)
            }
            ForEach(messages) { message in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(message.channelSeq)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 28)
                        .background(Capsule().fill(IMColor.brand))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.senderName)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(message.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColor.ink.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.72)))
            }
        }
        .padding(16)
        .plainCard(radius: 24)
    }

    private var derivedCacheEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(mode == .restricted ? "预览/未读：不显示边界前数据" : "预览/未读：随新窗口重新计算", systemImage: "text.bubble.fill")
            Label(mode == .restricted ? "置顶：边界前置顶已被裁剪" : "置顶：重拉后按新边界恢复", systemImage: "pin.fill")
            Label(mode == .restricted ? "资料：边界前文件不闪现" : "资料：只展示新 episode 可见文件", systemImage: "folder.fill")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(IMColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.brand.opacity(0.08)))
    }

    private var networkContract: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络合同")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text(mode == .direct ? "direct conversation DTO 不读取群 history_limited；POST /api/im/sync 的 group 边界只对 group 生效。" : "POST /api/im/sync 顶层返回 items / has_more_before / has_more_after / history_visible_from_seq / history_limited。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .plainCard(radius: 20)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END
