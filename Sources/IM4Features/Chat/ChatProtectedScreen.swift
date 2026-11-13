import Combine
import IM4DesignSystem
import SwiftUI

// WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_BEGIN
public struct ChatProtectedScreen<UnlockedContent: View>: View {
    private let initiallyAuthorized: Bool
    private let authorizationUpdates: AnyPublisher<Bool, Never>
    private let authenticate: () async -> Void
    private let unlockedContent: () -> UnlockedContent

    public init(
        initiallyAuthorized: Bool,
        authorizationUpdates: AnyPublisher<Bool, Never>,
        authenticate: @escaping () async -> Void,
        @ViewBuilder unlockedContent: @escaping () -> UnlockedContent
    ) {
        self.initiallyAuthorized = initiallyAuthorized
        self.authorizationUpdates = authorizationUpdates
        self.authenticate = authenticate
        self.unlockedContent = unlockedContent
    }

    public var body: some View {
        PublisherSnapshotView(initialValue: initiallyAuthorized, updates: authorizationUpdates) { authorized in
            if !authorized {
                BiometricProtectedContentGate(
                    symbol: "faceid",
                    title: "会话已受保护",
                    subtitle: "通过 Face ID 验证后才能查看聊天内容。",
                    authenticate: authenticate
                )
            } else {
                unlockedContent()
            }
        }
    }
}

public struct BiometricProtectedContentGate: View {
    let symbol: String
    let title: String
    let subtitle: String
    let authenticate: () async -> Void
    @State private var isAuthenticating = false

    public init(symbol: String, title: String, subtitle: String, authenticate: @escaping () async -> Void) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.authenticate = authenticate
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                Text(title)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(
                    title: isAuthenticating ? "正在验证" : "使用 Face ID 解锁",
                    systemImage: "faceid",
                    disabled: isAuthenticating
                ) {
                    guard !isAuthenticating else { return }
                    isAuthenticating = true
                    Task {
                        await authenticate()
                        await MainActor.run { isAuthenticating = false }
                    }
                }
                .frame(maxWidth: 300)
            }
            .padding(24)
        }
    }
}
// WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_END
