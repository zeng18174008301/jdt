import IM4Features
import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

struct TabBarVisibilityController: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        Self.setTabBarsHidden(isHidden, from: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        setTabBarsHidden(false, from: uiViewController)
    }

    private static func setTabBarsHidden(_ hidden: Bool, from uiViewController: UIViewController) {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let candidateControllers = scenes
                .flatMap(\.windows)
                .compactMap(\.rootViewController)
                + [uiViewController]
            for controller in candidateControllers {
                findTabBarControllers(in: controller).forEach { tabController in
                    if tabController.tabBar.isHidden != hidden {
                        tabController.tabBar.isHidden = hidden
                    }
                }
            }
        }
    }

    private static func findTabBarControllers(in controller: UIViewController?) -> [UITabBarController] {
        guard let controller else { return [] }
        var result: [UITabBarController] = []
        if let tab = controller as? UITabBarController {
            result.append(tab)
        }
        if let navigation = controller as? UINavigationController {
            result.append(contentsOf: findTabBarControllers(in: navigation.visibleViewController))
        }
        for child in controller.children {
            result.append(contentsOf: findTabBarControllers(in: child))
        }
        if let presented = controller.presentedViewController {
            result.append(contentsOf: findTabBarControllers(in: presented))
        }
        return result
    }
}

struct SplashOverlay: View {
    let presentation: SplashOverlayPresentation
    let remainingSeconds: Int
    let canSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let screenSize = UIScreen.main.bounds.size
            let topInset = max(proxy.safeAreaInsets.top, 0)
            let bottomInset = max(proxy.safeAreaInsets.bottom, 0)
            let containerSize = CGSize(
                width: max(proxy.size.width, screenSize.width),
                height: max(proxy.size.height + topInset + bottomInset, screenSize.height)
            )
            ZStack(alignment: .topTrailing) {
                splashImageLayer(containerSize: containerSize)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .offset(y: -topInset)
                    .ignoresSafeArea(.all)
                    .allowsHitTesting(false)

                if canSkip {
                    Button(action: onSkip) {
                        HStack(spacing: 6) {
                            Text("跳过")
                            Text("\(max(0, remainingSeconds))s")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.34), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳过启动闪屏")
                    .padding(.top, max(proxy.safeAreaInsets.top + 12, 24))
                    .padding(.trailing, 18)
                    .transition(.opacity)
                }
            }
            .frame(width: max(proxy.size.width, screenSize.width), height: max(proxy.size.height, screenSize.height))
            .clipped()
            .ignoresSafeArea(.all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea(.all))
        .ignoresSafeArea(.all)
        .animation(.easeOut(duration: 0.16), value: canSkip)
    }

    private func splashImageLayer(containerSize: CGSize) -> some View {
        ZStack {
            Color.black

            let image = presentation.image
            let layout = SplashImageCoverLayout.layout(
                imageSize: image.size,
                containerSize: containerSize
            )
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.renderedSize.width, height: layout.renderedSize.height)
                .position(x: containerSize.width / 2, y: containerSize.height / 2)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct AvatarStage4ScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
    @EnvironmentObject private var callStore: CallStore
    let scenario: AvatarStage4ScreenshotScenario

    var body: some View {
        switch scenario {
        case .chatList:
            NavigationStackCompat {
                ConversationListView()
            }
        case .groupChat:
            NavigationStackCompat {
                ChatView(conversationID: "conv-avatar-custom-group")
            }
        case .incomingCall:
            ZStack(alignment: .top) {
                NavigationStackCompat {
                    RTCEntryView()
                }
                if let call = callStore.incomingVoiceCall {
                    IncomingCallScreen(call: call)
                }
            }
        case .activeCall:
            if let session = callStore.activeVoiceCall {
                VoiceCallScreen(session: session)
            } else {
                NavigationStackCompat {
                    RTCEntryView()
                }
            }
        case .callRecords:
            NavigationStackCompat {
                RTCEntryView()
            }
        }
    }
}

struct GroupLifecycleScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GroupLifecycleScreenshotScenario

    private var group: GroupInfo {
        state.group(id: "group-lifecycle-stage4")
            ?? GroupInfo(
                id: "group-lifecycle-stage4",
                name: "群聊退出解散验收群",
                notice: "用于 iOS Stage 4 截图验收。",
                owner: "项目群主",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                memberCount: 0
            )
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: "group-lifecycle-stage4") { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        ZStack {
            GroupDetailView(group: group)
                .environmentObject(state)
            if scenario == .dissolveConfirm {
                VStack {
                    Spacer()
                    GroupDissolveConfirmSheet(
                        group: group,
                        preview: RemoteGroupDissolvePreview(
                            groupID: group.id,
                            memberCount: group.effectiveMemberCount,
                            affectedMembers: group.effectiveMemberCount,
                            confirmationRequired: true,
                            confirmationMode: "button",
                            effects: ["group_hidden", "conversations_removed"]
                        ),
                        isSubmitting: false,
                        onCancel: {},
                        onConfirm: {}
                    )
                    .frame(height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }
                .background(Color.black.opacity(0.08).ignoresSafeArea())
            }
        }
    }
}

struct ForcedAppPolicyAuthFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let requirement: AppPolicyForcedAuthRequirement

    var body: some View {
        ForcedAuthFlowContent(onClose: { dismiss() }) {
            Group {
                switch requirement {
                case .realName:
                    RealNameVerificationFlowView()
                case .phone:
                    PhoneBindingFlowView()
                }
            }
            .environmentObject(state)
        }
    }
}

struct SessionRestoreView: View {
    var body: some View {
        ZStack {
            Image("LaunchBeach")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .white.opacity(0.06),
                    .white.opacity(0.00),
                    .white.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Image("LoginLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 94, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.16), radius: 22, y: 12)
                    .padding(.top, 132)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
