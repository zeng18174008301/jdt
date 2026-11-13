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

// WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_BEGIN
@MainActor
final class LoginWorkspacePresentationStore {
    struct Snapshot: Equatable {
        var message: String?
        var defaultWorkspaceID = ""
    }

    @Published var snapshot = Snapshot()

    // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110_BEGIN
    /// Advances only after the enterprise switch completes its generation and scope checks.
    @Published var switchCompletionRevision: UInt64 = 0
    // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110_END

    func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}
// WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110_END

extension AppState {
    private func workspaceEntryStatusMessage(_ state: RemoteWorkspaceEntryState, fallbackEnterpriseName: String) -> String {
        let name = state.tenantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackEnterpriseName
            : state.tenantName
        switch state.normalizedStatus {
        case "pending_approval":
            return "入企申请等待审批中，审核通过后再进入企业。"
        case "preparing":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业数据正在准备中，请稍候。"
                : "\(name) 数据正在准备中，请稍候。"
        case "ready":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业数据已准备好，正在进入。"
                : "\(name) 已准备好，正在进入。"
        case "entered":
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "企业已确认进入，正在同步。"
                : "\(name) 已确认进入，正在同步。"
        case "failed":
            let reason = state.lastError.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "企业数据准备失败，请稍后重试。" : "企业数据准备失败：\(reason)"
        case "revoked":
            return "该企业进入资格已失效，请选择其他企业。"
        default:
            return "正在确认企业进入状态。"
        }
    }

    private func upsertWorkspaceEntryState(_ state: RemoteWorkspaceEntryState) {
        guard let workspace = state.workspace else { return }
        upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
    }

    private func shouldContinueWorkspaceEntryPolling(
        generation: Int,
        switchGeneration: Int
    ) -> Bool {
        authFlowGeneration.isCurrent(generation)
            && workspaceSwitchGeneration.isCurrent(switchGeneration)
            && authScreen == .workspaceSelection
    }

    private func workspaceEntryPollDelayNanoseconds(_ pollAfterMS: Int) -> UInt64 {
        let bounded = min(max(pollAfterMS, 500), 10_000)
        return UInt64(bounded) * 1_000_000
    }

    private func waitForWorkspaceEntryReady(
        initialState: RemoteWorkspaceEntryState,
        fallbackEnterpriseName: String,
        platformToken: String,
        context: IMAPIContext,
        generation: Int,
        switchGeneration: Int
    ) async throws -> Bool {
        var state = initialState
        var remainingPolls = 30
        while true {
            guard shouldContinueWorkspaceEntryPolling(generation: generation, switchGeneration: switchGeneration) else {
                throw CancellationError()
            }
            upsertWorkspaceEntryState(state)
            loginWorkspacePresentationStore.snapshot.message = workspaceEntryStatusMessage(state, fallbackEnterpriseName: fallbackEnterpriseName) // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            switch state.normalizedStatus {
            case "ready", "entered":
                return true
            case "pending_approval":
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请等待审批")
                return false
            case "failed":
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业数据准备失败，请稍后重试")
                return false
            case "revoked":
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业进入资格已失效")
                return false
            case "preparing", "none", "":
                guard remainingPolls > 0 else {
                    loginWorkspacePresentationStore.snapshot.message = "企业数据仍在准备中，请稍后重试。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业数据仍在准备中")
                    return false
                }
                remainingPolls -= 1
                let tenantID = state.effectiveTenantID
                guard !tenantID.isEmpty else {
                    loginWorkspacePresentationStore.snapshot.message = "企业进入状态暂不可确认，请稍后重试。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业进入状态暂不可确认")
                    return false
                }
                try await Task.sleep(nanoseconds: workspaceEntryPollDelayNanoseconds(state.pollAfterMS))
                state = try await api.workspaceEntryStatus(tenantID: tenantID, platformToken: platformToken, context: context)
            default:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业进入状态暂不可用")
                return false
            }
        }
    }

    private func prepareSelectedWorkspaceEntry(
        enterprise: Enterprise,
        generation: Int,
        switchGeneration: Int
    ) async throws -> Bool {
        var platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !platformToken.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话已失效，请重新登录")
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return false
        }
        loginWorkspacePresentationStore.snapshot.message = "正在确认企业数据，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        let idempotencyKey = [
            "ios",
            apiContext.accountID ?? "",
            enterprise.id
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "-")
        let prepared: RemoteWorkspaceEntryState
        do {
            prepared = try await api.prepareWorkspaceEntry(
                tenantID: enterprise.id,
                entryCode: nil,
                entrySource: "workspace_selection",
                idempotencyKey: idempotencyKey.isEmpty ? nil : idempotencyKey,
                platformToken: platformToken,
                context: apiContext
            )
        } catch {
            if shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(error) {
                loginWorkspacePresentationStore.snapshot.message = "正在进入企业，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                return true
            }
            guard shouldRetryPlatformTenantEnterAfterSessionRefresh(error) else {
                throw error
            }
            // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: workspace selection preflight uses platform bearer, refresh platform session only.
            let refreshed = await refreshPlatformAuthSessionIfNeeded(
                reason: "workspace_prepare_unauthorized",
                silent: true,
                context: apiContext,
                force: true
            )
            // WDT_IOS_TOKEN_VALIDITY_20260924_END
            guard authFlowGeneration.isCurrent(generation),
                  workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                throw error
            }
            guard refreshed else {
                loginWorkspacePresentationStore.snapshot.message = "正在进入企业，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                return true
            }
            platformToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !platformToken.isEmpty else {
                loginWorkspacePresentationStore.snapshot.message = "正在进入企业，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                return true
            }
            do {
                prepared = try await api.prepareWorkspaceEntry(
                    tenantID: enterprise.id,
                    entryCode: nil,
                    entrySource: "workspace_selection",
                    idempotencyKey: idempotencyKey.isEmpty ? nil : idempotencyKey,
                    platformToken: platformToken,
                    context: apiContext
                )
            } catch {
                if shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(error) {
                    loginWorkspacePresentationStore.snapshot.message = "正在进入企业，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    return true
                }
                guard shouldRetryPlatformTenantEnterAfterSessionRefresh(error) else {
                    throw error
                }
                loginWorkspacePresentationStore.snapshot.message = "正在进入企业，请稍候。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                return true
            }
        }
        return try await waitForWorkspaceEntryReady(
            initialState: prepared,
            fallbackEnterpriseName: enterprise.name,
            platformToken: platformToken,
            context: apiContext,
            generation: generation,
            switchGeneration: switchGeneration
        )
    }

    private func shouldDeferWorkspaceEntryPreflightUntilPlatformEnter(_ error: Error) -> Bool {
        guard case let IMAPIError.missingContext(field) = error else { return false }
        return field == "tenant_api_base_url"
    }

    func selectLoginWorkspace(_ enterprise: Enterprise, makeDefault: Bool) {
        let hasPlatformSession = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !isWorkspaceSwitchDisabledByPolicy else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭企业切换")
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        guard hasPlatformSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话已失效，请重新登录")
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        guard enterprise.isWorkspaceEnterable, enterprise.canSwitch else {
            let reason = enterprise.workspaceDisabledDescription
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason.isEmpty ? "该企业暂不可进入，请联系管理员确认状态" : reason)
            return
        }
        guard !isAuthLoading else { return }

        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let generation = authFlowGeneration.issueToken()
        let switchGeneration = workspaceSwitchGeneration.issueToken()
        Task {
            defer {
                if authFlowGeneration.isCurrent(generation),
                   workspaceSwitchGeneration.isCurrent(switchGeneration) {
                    authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                }
            }
            do {
                let entryReady = try await prepareSelectedWorkspaceEntry(
                    enterprise: enterprise,
                    generation: generation,
                    switchGeneration: switchGeneration
                )
                guard entryReady,
                      authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                    return
                }
                // 不再清缓存:进入(尤其重进同企业)时保留按 scope 隔离的本地快照,用于秒显。
                disconnectRealtime(shouldReconnect: false)
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                resetAuthenticatedRemoteData(showLoading: true)
                try await switchPlatformTenant(
                    tenantID: enterprise.id,
                    isCurrent: {
                        self.authFlowGeneration.isCurrent(generation)
                            && self.workspaceSwitchGeneration.isCurrent(switchGeneration)
                    }
                )
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else {
                    return
                }
                enterIM(showToast: false)
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: yield after route switch so the entered workbench can render before cached snapshot restore continues.
                await Task.yield()
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END
                // 进入后先用目标租户的本地缓存即时渲染会话列表(含已解析名称),再后台刷新合并。
                let enteredContext = apiContext
                let enteredScope = remoteDataScopeKey(for: enteredContext)
                _ = await applyCachedRemoteSnapshotIfAvailable(context: enteredContext)
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(enteredScope) else { return }
                let fallbackToast = makeDefault
                    ? "已进入 \(currentEnterprise.name)，首屏同步成功后保存默认企业"
                    : "已进入 \(currentEnterprise.name)，聊天数据正在同步"
                startPostLoginRemoteSnapshotRefresh(
                    generation: generation,
                    context: enteredContext,
                    immediateToast: fallbackToast,
                    syncedToast: "已进入 \(currentEnterprise.name)",
                    fallbackToast: fallbackToast
                )
            } catch {
                guard authFlowGeneration.isCurrent(generation),
                      workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
                resetAuthenticatedRemoteData(showLoading: false)
                if isRefreshableSessionError(error) {
                    disableAccessDiagnosticsOverlay()
                    apiContext.clearSession(sessionStore: protectedSessionStore)
                    apiContext.save(sessionStore: protectedSessionStore)
                    setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                    setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                    loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录已失效，请重新登录")
                    return
                }
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                apiContext.save(sessionStore: protectedSessionStore)
                setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                if let securityInfo = securityBlockedInfo(from: error) {
                    handleSecurityBlocked(securityInfo, enterpriseID: enterprise.id)
                    loginWorkspacePresentationStore.snapshot.message = "\(securityInfo.userMessage)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(securityInfo.userMessage)
                } else if let code = workspaceAccessCode(from: error) {
                    if code == "workspace_switch_disabled" {
                        resetAuthenticatedRemoteData(showLoading: false)
                        disableAccessDiagnosticsOverlay()
                        apiContext.clearSession(sessionStore: protectedSessionStore)
                        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceAccessMessage(for: code))
                        return
                    }
                    let message = shouldPersistWorkspaceEntryAccessBlock(code)
                        ? workspaceAccessMessage(for: code)
                        : platformWorkspaceSwitchFailureMessage(error)
                    if shouldPersistWorkspaceEntryAccessBlock(code) {
                        _ = markWorkspaceAccessBlocked(code, enterpriseID: enterprise.id)
                    }
                    loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                } else {
                    let message = platformWorkspaceSwitchFailureMessage(error)
                    loginWorkspacePresentationStore.snapshot.message = "\(message)。请选择其他可进入企业。" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                }
            }
        }
    }

    func cancelLoginWorkspaceSelection() {
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        authFlowGeneration.invalidate()
        stopInboxRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        resetAuthenticatedRemoteData(showLoading: false)
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = "" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
    }

    func clearDefaultWorkspacePreference() {
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        let requestContext = apiContext
        let requestAuthority = requestContext.authSessionFence
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END

        let hasPlatformSession = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasPlatformSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话已失效，请重新登录")
            return
        }
        guard !loginWorkspacePresentationStore.snapshot.defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前没有默认企业")
            return
        }
        Task {
            guard apiContext.isSameAuthAuthority(as: requestAuthority) else { return }
            do {
                let result = try await api.clearDefaultWorkspace(platformToken: requestContext.platformToken, requestAuthority: requestAuthority)
                guard apiContext.isSameAuthAuthority(as: requestAuthority) else { return }
                loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = result.defaultWorkspaceID // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
                if let workspace = result.defaultWorkspace {
                    upsertEnterprise(enterprise(from: workspace, fallbackAccent: currentEnterprise.accentHex))
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(loginWorkspacePresentationStore.snapshot.defaultWorkspaceID.isEmpty ? "已清除默认企业" : "默认企业已更新") // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            } catch {
                guard apiContext.isSameAuthAuthority(as: requestAuthority) else { return }
                handleRemoteError(error, fallback: "清除默认企业失败")
            }
        }
    }

}
