// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import Combine
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct EnterpriseHeaderCardContent<Logo: View, Trailing: View>: View {
    let name: String
    let displayCode: String
    let disabledDescription: String
    let isSwitchingEnabled: Bool
    let action: () -> Void
    let logo: () -> Logo
    let trailing: () -> Trailing

    public init(name: String, displayCode: String, disabledDescription: String, isSwitchingEnabled: Bool,
                action: @escaping () -> Void, @ViewBuilder logo: @escaping () -> Logo,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.name = name
        self.displayCode = displayCode
        self.disabledDescription = disabledDescription
        self.isSwitchingEnabled = isSwitchingEnabled
        self.action = action
        self.logo = logo
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 13) {
            logo()

            if isSwitchingEnabled {
                Button(action: action) {
                    enterpriseContent
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("enterprise_switcher_entry")
                .accessibilityLabel("切换企业 \(name)")
            } else {
                enterpriseContent
                    .accessibilityIdentifier("enterprise_current_entry")
                    .accessibilityLabel("当前企业 \(name)")
            }

            trailing()
        }
        .im4GlassCard(radius: 26)
    }

    private var enterpriseContent: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                if !displayCode.isEmpty {
                    Text("企业码 \(displayCode)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                if !disabledDescription.isEmpty {
                    Label(disabledDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isSwitchingEnabled {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

public struct ConversationAnnouncementBannerContent: View {
    let items: [InboxItem]
    @Binding var selection: Int
    @Binding var selectedItem: InboxItem?
    let onDismiss: () -> Void // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110

    private let timer = Timer.publish(every: 5.5, on: .main, in: .common).autoconnect()

    public init(items: [InboxItem], selection: Binding<Int>, selectedItem: Binding<InboxItem?>,
                onDismiss: @escaping () -> Void) {
        self.items = items
        _selection = selection
        _selectedItem = selectedItem
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if items.isEmpty {
                EmptyView()
            } else {
                let safeIndex = items.indices.contains(selection) ? selection : 0
                let item = items[safeIndex]
                HStack(spacing: 10) {
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.brand))

                    Button {
                        selectedItem = item
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("公告")
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(IMColor.brand)
                                    if !item.isRead {
                                        Circle()
                                            .fill(IMColor.danger)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                Text(item.title)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IMColor.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(item.time)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(height: 58)
                    .onReceive(timer) { _ in
                        guard items.count > 1 else { return }
                        selection = (selection + 1) % items.count
                    }

                    Spacer()

                    Button(action: onDismiss) { // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.brand.opacity(0.09)))
            }
        }
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
