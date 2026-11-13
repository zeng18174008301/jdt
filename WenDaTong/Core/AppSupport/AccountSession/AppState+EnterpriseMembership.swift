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

extension AppState {
    func joinEnterprise(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入企业编码或邀请码")
            return
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先搜索后台已有企业，再提交加入")
    }

    func enterpriseJoinKey(_ enterprise: Enterprise) -> String {
        let id = enterprise.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            return "id:\(id)"
        }
        let code = enterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty {
            return "code:\(code)"
        }
        return "name:\(enterprise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func workspaceDirectoryErrorMessage(_ error: Error, fallback: String) -> String {
        let mapped = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = mapped.isEmpty ? fallback : mapped
        return isRawWorkspaceDirectoryError(candidate) ? fallback : candidate
    }

    private func isRawWorkspaceDirectoryError(_ message: String) -> Bool {
        let lowered = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let rawMarkers = [
            "sqlstate",
            "invalid input syntax",
            "uuid",
            "pq:",
            "duplicate key",
            "could not",
            "stack trace",
            "traceback",
            "syntax error",
            "cast",
            "constraint"
        ]
        return rawMarkers.contains { lowered.contains($0) }
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
    func clearEnterpriseSearch() {
        enterpriseDirectoryStore.clearSearch()
    }

    func searchEnterprises(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearEnterpriseSearch()
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            enterpriseDirectoryStore.clearSearch(message: "请先登录后再搜索或加入企业。")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先登录后再搜索企业")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let requestID = enterpriseDirectoryStore.beginSearch()
        func isCurrentSearch() -> Bool {
            isCurrentRemoteScope(scope) && enterpriseDirectoryStore.ownsSearch(requestID)
        }
        Task {
            defer { enterpriseDirectoryStore.finishSearch(requestID) }
            do {
                let workspaces = try await api.searchWorkspaces(context: context, keyword: trimmed)
                guard isCurrentSearch() else { return }
                let mapped = workspaces.enumerated().map { index, workspace in
                    enterprise(from: workspace, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
                }
                enterpriseDirectoryStore.completeSearch(
                    requestID,
                    results: mapped,
                    message: mapped.isEmpty ? "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。" : nil
                )
                handleWorkspaceApplicationStatus(mapped)
            } catch {
                guard isCurrentSearch() else { return }
                let message: String
                var showsToast = false
                switch error as? IMAPIError {
                case .unauthorized, .forbidden, .securityBlocked:
                    handleRemoteError(error, fallback: "企业搜索失败")
                    guard isCurrentSearch() else { return }
                    message = workspaceDirectoryErrorMessage(error, fallback: "企业搜索失败，请稍后重试")
                case .server(let detail):
                    let lowered = detail.lowercased()
                    if lowered.contains("not found")
                        || lowered.contains("not exist")
                        || lowered.contains("no rows")
                        || lowered.contains("invalid status") {
                        message = "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。"
                    } else {
                        message = workspaceDirectoryErrorMessage(error, fallback: "企业目录暂不可用，请稍后重试")
                        showsToast = true
                    }
                default:
                    message = workspaceDirectoryErrorMessage(error, fallback: "企业搜索失败，请稍后重试")
                    showsToast = true
                }
                enterpriseDirectoryStore.completeSearch(requestID, results: [], message: message)
                if showsToast {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业搜索失败：\(message)")
                }
            }
        }
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
    func joinEnterprise(_ enterprise: Enterprise) {
        guard canUseEnterpriseDirectory else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先登录后再申请加入企业")
            return
        }
        let joinKey = enterpriseJoinKey(enterprise)
        guard enterpriseDirectoryStore.snapshot.results.contains(where: { enterpriseJoinKey($0) == joinKey }) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先搜索后台已有企业，再提交加入")
            return
        }
        if !enterprise.isWorkspaceEnterable, !enterprise.workspaceDisabledDescription.isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(enterprise.workspaceDisabledDescription)
            return
        }
        if enterprise.isWorkspaceJoinPending {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请等待审批中")
            return
        }
        if enterprise.isWorkspaceJoinRejected {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请已被拒绝，请联系企业管理员")
            return
        }
        if enterprise.isWorkspaceJoinApproved || enterprises.contains(where: { ($0.id == enterprise.id || (!$0.code.isEmpty && $0.code == enterprise.code)) && $0.isWorkspaceJoined }) {
            switchEnterprise(enterprise)
            return
        }
        let tenantCode = enterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tenantCode.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业码缺失，请重新搜索后再试")
            return
        }
        guard !enterpriseDirectoryStore.snapshot.isJoining(joinKey) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在提交申请，请稍候")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先登录后再申请加入企业")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let requestID = enterpriseDirectoryStore.beginJoin(key: joinKey) else { return }
        func isCurrentJoin() -> Bool {
            isCurrentRemoteScope(scope) && enterpriseDirectoryStore.ownsJoin(requestID, key: joinKey)
        }

        Task {
            defer { enterpriseDirectoryStore.finishJoin(requestID, key: joinKey) }
            do {
                let result = try await api.joinWorkspace(context: context, tenantCode: tenantCode)
                guard isCurrentJoin() else { return }
                var joinedEnterprise = result.tenant
                    .map { self.enterprise(from: $0, fallbackAccent: enterprise.accentHex) }
                    ?? enterprise
                joinedEnterprise.applicationID = result.application?.id ?? joinedEnterprise.applicationID
                joinedEnterprise.applicationStatus = result.application?.status ?? joinedEnterprise.applicationStatus
                if !result.joinType.isEmpty || result.requiresApproval {
                    let requiresApproval = result.joinType == "approval_required"
                        || result.joinType == "requires_approval"
                        || result.joinType == "approval"
                        || result.requiresApproval
                    joinedEnterprise.approvalRequired = requiresApproval
                    if requiresApproval,
                       joinedEnterprise.joinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       joinedEnterprise.applicationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        joinedEnterprise.joinStatus = "pending"
                        joinedEnterprise.applicationStatus = "pending"
                    }
                }
                if !result.status.isEmpty {
                    joinedEnterprise.joinStatus = result.status
                }
                if joinedEnterprise.applicationStatus.isEmpty, !result.status.isEmpty {
                    joinedEnterprise.applicationStatus = result.status
                }
                if joinedEnterprise.isWorkspaceJoinPending {
                    upsertEnterprise(joinedEnterprise)
                    enterpriseDirectoryStore.upsertSearchResult(joinedEnterprise)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请已提交，等待审批")
                    return
                }
                if joinedEnterprise.isWorkspaceJoinRejected {
                    enterpriseDirectoryStore.upsertSearchResult(joinedEnterprise)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请已被拒绝，请联系企业管理员")
                    return
                }
                if joinedEnterprise.isWorkspaceJoined {
                    let workspaces = try await api.listWorkspaces(context: context)
                    guard isCurrentJoin() else { return }
                    applyWorkspaces(workspaces)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(joinedEnterprise.isWorkspaceJoinApproved ? "入企申请已通过" : "已加入 \(joinedEnterprise.name)")
                    let refreshed = enterprises.first { $0.id == joinedEnterprise.id || (!$0.code.isEmpty && $0.code == joinedEnterprise.code) }
                    let target = refreshed ?? joinedEnterprise
                    if target.isWorkspaceEnterable {
                        switchEnterprise(target)
                    }
                    return
                }
                enterpriseDirectoryStore.upsertSearchResult(joinedEnterprise)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业加入状态已更新")
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_pending" {
                guard isCurrentJoin() else { return }
                var pending = enterprise
                pending.joinStatus = "pending"
                pending.applicationStatus = "pending"
                pending.approvalRequired = true
                pending.canSwitch = false
                upsertEnterprise(pending)
                enterpriseDirectoryStore.upsertSearchResult(pending)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请等待审批中")
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_rejected" {
                guard isCurrentJoin() else { return }
                var rejected = enterprise
                rejected.joinStatus = "rejected"
                rejected.applicationStatus = "rejected"
                rejected.canSwitch = false
                enterpriseDirectoryStore.upsertSearchResult(rejected)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请已被拒绝，请联系企业管理员")
            } catch IMAPIError.conflict(let code, _) where code == "workspace_join_approved" {
                guard isCurrentJoin() else { return }
                var approved = enterprise
                approved.joinStatus = "approved"
                approved.applicationStatus = "approved"
                approved.canSwitch = true
                upsertEnterprise(approved)
                enterpriseDirectoryStore.upsertSearchResult(approved)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入企申请已通过")
            } catch IMAPIError.conflict(let code, _) where code == "workspace_already_joined" {
                guard isCurrentJoin() else { return }
                do {
                    let workspaces = try await api.listWorkspaces(context: context)
                    guard isCurrentJoin() else { return }
                    applyWorkspaces(workspaces)
                    if let joined = enterprises.first(where: { $0.id == enterprise.id || (!$0.code.isEmpty && $0.code == enterprise.code) }) {
                        switchEnterprise(joined)
                    } else {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已加入该企业")
                    }
                } catch {
                    guard isCurrentJoin() else { return }
                    handleRemoteError(error, fallback: "刷新企业列表失败")
                }
            } catch IMAPIError.conflict(let code, _) where code == "workspace_directory_unavailable" || code == "workspace_tenant_unresolved" || code == "workspace_join_forbidden" || code == "workspace_join_bad_request" || code == "bad_workspace_join_request" {
                guard isCurrentJoin() else { return }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceDirectoryErrorMessage(IMAPIError.conflict(code: code, message: ""), fallback: "入企申请暂不可用，请稍后重试"))
            } catch {
                guard isCurrentJoin() else { return }
                if let apiError = error as? IMAPIError,
                   case .unauthorized = apiError {
                    handleRemoteError(apiError, fallback: "企业加入失败")
                } else if let apiError = error as? IMAPIError,
                          case .securityBlocked = apiError {
                    handleRemoteError(apiError, fallback: "企业加入失败")
                } else {
                    let message = workspaceDirectoryErrorMessage(error, fallback: "企业加入失败，请稍后重试")
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message.hasPrefix("企业加入失败") ? message : "企业加入失败：\(message)")
                }
            }
        }
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END

    func registerAndEnterIM(phone: String = "", account: String = "", password: String = "", enterpriseCode: String, captchaCode: String = "") {
        guard isRegistrationEnabledForAuthUI else {
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            return
        }
        guard !isRegistrationSubmissionBlocked, registrationSubmissionTask == nil,
              !isAuthenticated, !apiContext.hasIMSession else { return }
        cancelRegistrationSessionRecovery()
        let submissionID = UUID()
        registrationSubmissionID = submissionID
        authenticationPresentationStore.isLoading = true // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        registrationSubmissionTask = Task { @MainActor in
            defer {
                if registrationSubmissionID == submissionID {
                    registrationSubmissionTask = nil
                    registrationSubmissionID = nil
                    authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                }
            }
            await registerRemotely(
                phone: phone, account: account, password: password,
                enterpriseCode: enterpriseCode, captchaCode: captchaCode
            )
        }
    }

}

// WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_BEGIN
@MainActor
final class EnterpriseDirectoryStore {
    struct Snapshot: Equatable {
        var results: [Enterprise] = []
        var message: String?
        var isSearching = false
        fileprivate var joinIDs: [String: UUID] = [:]

        func isJoining(_ key: String) -> Bool {
            joinIDs[key] != nil
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private var searchID: UUID?

    func clearSearch(message: String? = nil) {
        searchID = nil
        update {
            $0.results = []
            $0.message = message
            $0.isSearching = false
        }
    }

    func beginSearch() -> UUID {
        let id = UUID()
        searchID = id
        update {
            $0.isSearching = true
            $0.message = nil
        }
        return id
    }

    func ownsSearch(_ id: UUID) -> Bool {
        searchID == id
    }

    func completeSearch(_ id: UUID, results: [Enterprise], message: String?) {
        guard ownsSearch(id) else { return }
        searchID = nil
        update {
            $0.results = results
            $0.message = message
            $0.isSearching = false
        }
    }

    func finishSearch(_ id: UUID) {
        guard ownsSearch(id) else { return }
        searchID = nil
        update { $0.isSearching = false }
    }

    func projectSearchResults(_ transform: (Enterprise) -> Enterprise) {
        update { $0.results = $0.results.map(transform) }
    }

    func upsertSearchResult(_ enterprise: Enterprise) {
        update {
            if let index = $0.results.firstIndex(where: { $0.id == enterprise.id }) {
                $0.results[index] = enterprise
            } else {
                $0.results.append(enterprise)
            }
        }
    }

    func beginJoin(key: String) -> UUID? {
        guard !snapshot.isJoining(key) else { return nil }
        let id = UUID()
        update { $0.joinIDs[key] = id }
        return id
    }

    func ownsJoin(_ id: UUID, key: String) -> Bool {
        snapshot.joinIDs[key] == id
    }

    func finishJoin(_ id: UUID, key: String) {
        guard ownsJoin(id, key: key) else { return }
        update { $0.joinIDs[key] = nil }
    }

    func reset() {
        searchID = nil
        update { $0 = Snapshot() }
    }

    private func update(_ mutate: (inout Snapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
    }
}
// WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110_END
