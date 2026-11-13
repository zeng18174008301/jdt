import IM4Domain
import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

// WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
@MainActor
final class BootstrapPresentationStore {
    struct Launch: Equatable {
        var isRestoringSession = false
        var isShowingLaunchSplash = false
    }

    struct Sync: Equatable {
        var isInitialDataLoading = false
        var isLoadingMoreConversations = false
        var isConversationSnapshotPartial = false
        var hasLoadedRemoteSnapshot = false
        var syncFailureMessage: String?
        var isSyncRetrying = false

        var isInitialLoading: Bool { isInitialDataLoading && !hasLoadedRemoteSnapshot }
    }

    @Published var launch = Launch()
    @Published var sync = Sync()

    func syncUpdates<Value: Equatable>(_ project: @escaping (Sync) -> Value) -> AnyPublisher<Value, Never> {
        $sync.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observeSync<Value: Equatable, Content: View>(
        _ project: @escaping (Sync) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(sync), updates: syncUpdates(project), content: content)
    }
}
// WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END

@MainActor
final class ToastDismissTaskStore {
    private var task: Task<Void, Never>?

    var hasTask: Bool {
        task != nil
    }

    func replace(with newTask: Task<Void, Never>) {
        task?.cancel()
        task = newTask
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_BEGIN
@MainActor
final class ToastPresentationStore {
    @Published private(set) var message: String?
    private let dismissTasks = ToastDismissTaskStore()

    func present(_ message: String?, persists: Bool = false) {
        self.message = message
        guard let message, !message.isEmpty, !persists else {
            dismissTasks.cancel()
            return
        }
        dismissTasks.replace(with: Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.message == message else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.present(nil)
                }
            }
        })
    }

    func observe<Content: View>(@ViewBuilder content: @escaping (String?) -> Content) -> some View {
        PublisherSnapshotView(initialValue: message, updates: $message.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN
extension AppState {
    func setToast(_ message: String?) {
#if DEBUG
        let persists = licenseQuotaScreenshotScenario != nil || registrationResolutionScreenshotScenario != nil
        toastPresentationStore.present(message, persists: persists)
#else
        toastPresentationStore.present(message)
#endif
    }
}
// WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END


@MainActor
final class LaunchSplashDismissTaskStore {
    private var task: Task<Void, Never>?

    var hasTask: Bool {
        task != nil
    }

    func replace(with newTask: Task<Void, Never>) {
        task?.cancel()
        task = newTask
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

final class MainShellBootstrapTraceState {
    private var startedAt: CFAbsoluteTime?
    private var hasLoggedAppearance = false
    private var hasLoggedInteractive = false

    func begin(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        startedAt = now
        hasLoggedAppearance = false
        hasLoggedInteractive = false
    }

    func claimAppearance(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int? {
        guard !hasLoggedAppearance else { return nil }
        hasLoggedAppearance = true
        return elapsedMs(at: now)
    }

    func claimInteractive(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int? {
        guard !hasLoggedInteractive else { return nil }
        hasLoggedInteractive = true
        return elapsedMs(at: now)
    }

    private func elapsedMs(at now: CFAbsoluteTime) -> Int {
        guard let startedAt else { return 0 }
        return Int((now - startedAt) * 1000)
    }
}

let mainTabSelectionLog = OSLog(
    subsystem: "com.jianhuitongqiyetest.app",
    category: "main-tab"
)
let mainTabSelectionLogger = Logger(
    subsystem: "com.jianhuitongqiyetest.app",
    category: "main-tab"
)

@MainActor
final class MainTabSelectionState: ObservableObject {
    private struct PendingTransition {
        let from: MainTab
        let to: MainTab
        let source: String
        let startedAt: CFAbsoluteTime
        let signpostID: OSSignpostID
    }

    @Published private(set) var activeTab: MainTab
    private let now: () -> CFAbsoluteTime
    private var pendingTransition: PendingTransition?

    private(set) var selectionRevision = 0
    private(set) var completedTransitionCount = 0
    private(set) var lastStateChangeElapsedMilliseconds: Int?
    private(set) var lastContentAppearanceElapsedMilliseconds: Int?
    private(set) var maximumContentAppearanceElapsedMilliseconds = 0

    init(
        initialTab: MainTab = .chats,
        now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        activeTab = initialTab
        self.now = now
    }

    var binding: Binding<MainTab> {
        Binding(
            get: { self.activeTab },
            set: { self.select($0, source: "tab_bar") }
        )
    }

    @discardableResult
    func select(_ tab: MainTab, source: String) -> Bool {
        guard tab != activeTab else { return false }
        finishPendingTransitionAsSuperseded()

        let previousTab = activeTab
        let startedAt = now()
        let signpostID = OSSignpostID(log: mainTabSelectionLog)
        os_signpost(
            .begin,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: signpostID,
            "from=%{public}s to=%{public}s source=%{public}s",
            previousTab.rawValue,
            tab.rawValue,
            source
        )
        pendingTransition = PendingTransition(
            from: previousTab,
            to: tab,
            source: source,
            startedAt: startedAt,
            signpostID: signpostID
        )

        activeTab = tab
        selectionRevision += 1
        let stateElapsed = elapsedMilliseconds(since: startedAt)
        lastStateChangeElapsedMilliseconds = stateElapsed
        mainTabSelectionLogger.notice(
            "state_changed from=\(previousTab.rawValue, privacy: .public) to=\(tab.rawValue, privacy: .public) source=\(source, privacy: .public) elapsed_ms=\(stateElapsed)"
        )
        return true
    }

    func noteContentAppeared(_ tab: MainTab) {
        guard let pendingTransition, pendingTransition.to == tab else { return }
        self.pendingTransition = nil

        let elapsed = elapsedMilliseconds(since: pendingTransition.startedAt)
        completedTransitionCount += 1
        lastContentAppearanceElapsedMilliseconds = elapsed
        maximumContentAppearanceElapsedMilliseconds = max(
            maximumContentAppearanceElapsedMilliseconds,
            elapsed
        )
        os_signpost(
            .end,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: pendingTransition.signpostID,
            "from=%{public}s to=%{public}s source=%{public}s elapsed_ms=%{public}d status=appeared",
            pendingTransition.from.rawValue,
            pendingTransition.to.rawValue,
            pendingTransition.source,
            elapsed
        )
        mainTabSelectionLogger.notice(
            "content_appeared from=\(pendingTransition.from.rawValue, privacy: .public) to=\(pendingTransition.to.rawValue, privacy: .public) source=\(pendingTransition.source, privacy: .public) elapsed_ms=\(elapsed)"
        )
    }

    private func finishPendingTransitionAsSuperseded() {
        guard let pendingTransition else { return }
        self.pendingTransition = nil
        let elapsed = elapsedMilliseconds(since: pendingTransition.startedAt)
        os_signpost(
            .end,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: pendingTransition.signpostID,
            "from=%{public}s to=%{public}s source=%{public}s elapsed_ms=%{public}d status=superseded",
            pendingTransition.from.rawValue,
            pendingTransition.to.rawValue,
            pendingTransition.source,
            elapsed
        )
    }

    private func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        max(0, Int(((now() - startedAt) * 1_000).rounded()))
    }
}

final class AuthFlowGenerationState {
    private var generation = 0

    func currentToken() -> Int {
        generation
    }

    @discardableResult
    func issueToken() -> Int {
        generation += 1
        return generation
    }

    func invalidate() {
        generation += 1
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

// JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：临时企业码挑战仅保存在内存中，退出/重登后即丢弃
struct LoginTenantCodeChallenge {
    let generation: Int
    let credentialMode: LoginMode
    let identifier: String
    let password: String
    let context: IMAPIContext

    var appID: String {
        IMAPIContext.normalizedIOSAppID(context.appID)
    }

    var deviceID: String {
        context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isCurrent(
        generation expectedGeneration: Int,
        appID expectedAppID: String,
        deviceID expectedDeviceID: String
    ) -> Bool {
        generation == expectedGeneration
            && appID == IMAPIContext.normalizedIOSAppID(expectedAppID)
            && deviceID == expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

enum SplashPresentationIntent: String, Equatable, Sendable {
    case refreshOnly
    case coldLaunch
    case tenantEntry
    case foregroundColdEquivalent

    var allowsPresentation: Bool {
        switch self {
        case .coldLaunch, .foregroundColdEquivalent:
            return true
        case .refreshOnly, .tenantEntry:
            return false
        }
    }

    var presentationWindowSeconds: TimeInterval? {
        switch self {
        case .refreshOnly, .tenantEntry:
            return nil
        case .coldLaunch:
            return 5
        case .foregroundColdEquivalent:
            return 5
        }
    }
}

enum PostLoginWorkbenchAdmissionOutcome: Equatable {
    case admitted
    case duplicate
    case rejectedMissingSession
}

struct PostLoginWorkbenchAdmissionState {
    private var activeScope: String?

    mutating func consume(hasIMSession: Bool, scope: String) -> PostLoginWorkbenchAdmissionOutcome {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasIMSession, !normalizedScope.isEmpty else {
            return .rejectedMissingSession
        }
        guard activeScope != normalizedScope else {
            return .duplicate
        }
        activeScope = normalizedScope
        return .admitted
    }

    mutating func reset() {
        activeScope = nil
    }
}

final class DeviceRevocationHandlingState {
    private var isHandling = false

    var isHandlingRevocation: Bool {
        isHandling
    }

    func begin() -> Bool {
        guard !isHandling else { return false }
        isHandling = true
        return true
    }

    func finish() {
        isHandling = false
    }
}

// JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DIRECT_FRIEND_CONTEXT_EQUATABLE - 修改开始：支持好友不可用状态去重时识别 action/context 变化
typealias DirectFriendRequestContext = IM4Domain.DirectFriendRequestContext

enum MessageReportSubmissionResult {
    case submitted(RemoteMessageReport)
    case alreadyReported(RemoteMessageReport)
    case failed
}
