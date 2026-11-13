import IM4Features
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

// MARK: - Contacts, Inbox, and Devices

extension AppState {
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
    @discardableResult
    func acceptFriendRequest(_ requestID: String) -> Task<Void, Never>? {
        respondToFriendRequest(requestID, accepting: true)
    }

    @discardableResult
    func rejectFriendRequest(_ requestID: String) -> Task<Void, Never>? {
        respondToFriendRequest(requestID, accepting: false)
    }

    private func respondToFriendRequest(_ requestID: String, accepting: Bool) -> Task<Void, Never>? {
        guard friendRequests.contains(where: { $0.id == requestID }) else { return nil }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let owner = contactRequestOwner(context: context)
        return Task {
            guard let requestContext = contactRequestContext(for: owner) else { return }
            do {
                // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
                try await withContactHTTPRequest(owner: owner, context: requestContext) {
                    if accepting {
                        try await api.acceptFriendApplication(context: requestContext, id: requestID)
                    } else {
                        try await api.rejectFriendApplication(context: requestContext, id: requestID)
                    }
                }
                // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
            } catch {
                guard contactRequestContext(for: owner) != nil, !isContactRequestCancellation(error) else { return }
                if apiContext.isSameAuthAuthority(as: requestContext.authSessionFence) {
                    handleRemoteError(error, fallback: accepting ? "通过好友申请失败" : "拒绝好友申请失败")
                }
                if !isContactSessionFailure(error) {
                    await refreshFriendApplicationsAndRelations(owner: owner)
                }
                return
            }
            await refreshFriendApplicationsAndRelations(owner: owner)
            guard contactRequestContext(for: owner) != nil else { return }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(accepting ? "已通过好友申请" : "已拒绝好友申请")
        }
    }
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END

    @discardableResult
    func cancelFriendRequest(_ requestID: String) async -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestIndex = friendRequests.firstIndex(where: { $0.id == normalizedID }),
              friendRequests[requestIndex].canCancel else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只有待处理的已发出申请可以取消")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
        guard contactStore.cancellingFriendRequestIDs.insert(normalizedID).inserted else { return false }
        defer { contactStore.cancellingFriendRequestIDs.remove(normalizedID) }
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END
        let scope = remoteDataScopeKey(for: context)
        do {
            let terminal = try await api.cancelFriendApplication(context: context, id: normalizedID)
            guard isCurrentRemoteScope(scope) else { return false }
            let normalizedStatus = terminal.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedStatus == "cancelled" || normalizedStatus == "canceled" else {
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("好友申请状态已变化，请查看最新状态")
                return false
            }
            if let currentIndex = friendRequests.firstIndex(where: { $0.id == normalizedID }) {
                let current = friendRequests[currentIndex]
                friendRequests[currentIndex] = FriendRequest(
                    id: current.id,
                    name: current.name,
                    userID: current.userID,
                    avatarURL: current.avatarURL,
                    source: current.source,
                    message: "申请已取消",
                    status: normalizedStatus,
                    direction: current.direction,
                    tenantReviewStatus: terminal.tenantReviewStatus,
                    peerReviewStatus: terminal.peerReviewStatus,
                    canRespond: false,
                    outcome: terminal.outcome,
                    relationStatus: terminal.relationStatus,
                    friendAction: terminal.friendAction,
                    friendFlow: terminal.friendFlow,
                    directlyEstablished: false,
                    requiresTenantReview: terminal.requiresTenantReview,
                    requiresTargetApproval: terminal.requiresTargetApproval,
                    resolutionMode: terminal.resolutionMode,
                    accepted: false
                )
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已取消好友申请")
            await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            return isCurrentRemoteScope(scope)
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "取消好友申请失败")
            return false
        }
    }

    func removeFromBlacklist(_ itemID: String) {
        guard let item = blacklist.first(where: { $0.id == itemID }) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态失效，请重新登录后移出黑名单")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        profileContactRevisionFence.rebind(scopeHash: scope)
        let mutationKeys = profileContactKeys(kind: "blacklist", identifiers: [item.id])
            .union(profileContactKeys(kind: "contact", identifiers: [item.id]))
        guard let mutationTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: mutationKeys
        ) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重试移出黑名单")
            return
        }
        let previousIndex = blacklist.firstIndex(where: { $0.id == item.id })
        blacklist.removeAll { $0.id == item.id }
        persistProfileContactProjectionIfPossible(
            scope: scope,
            revision: mutationTicket.revision,
            reason: "unblock_optimistic"
        )
        Task {
            do {
                try await api.deleteBlacklist(context: context, userID: item.id)
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == item.id }
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "unblock_authoritative")
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已将 \(item.name) 移出黑名单")
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            } catch {
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == item.id }
                blacklist.insert(item, at: min(previousIndex ?? 0, blacklist.count))
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "unblock_rollback")
                handleRemoteError(error, fallback: "移出黑名单失败")
            }
        }
    }

    func contactRemark(for user: IMUser) -> String {
        contactRemarkValue(matching: userIdentityCandidates(for: user)) ?? "未设置"
    }

    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
    private func canonicalFriendUIDForRemark(
        user: IMUser,
        owner: ContactRequestOwner
    ) async throws -> String {
        guard let context = contactRequestContext(for: owner) else { throw CancellationError() }
        let scope = owner.scope
        if let resolved = contactStore.canonicalFriendUIDForRemark(for: user, in: scope) /* WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112 */ {
            return resolved
        }
        let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
        let relations: [RemoteFriendRelation]
        do {
            relations = try await withContactHTTPRequest(owner: owner, context: context) {
                try await api.friendRelationsForRemarkResolution(context: context)
            }
        } catch {
            if isContactSessionFailure(error), !apiContext.isSameAuthAuthority(as: context.authSessionFence) {
                throw CancellationError()
            }
            throw error
        }
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
        guard contactRequestContext(for: owner) != nil else { throw CancellationError() }
        applyFriendRelations(relations, readStamp: readStamp)
        if let resolved = contactStore.canonicalFriendUIDForRemark(for: user, in: scope) /* WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112 */ {
            return resolved
        }
        throw IMAPIError.businessForbidden(
            code: "friend_identity_unresolved",
            message: "好友资料已变化，请刷新联系人后重试",
            error: nil
        )
    }
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END

    private func shouldConfirmFriendRemarkAfterPatchError(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .httpStatus(let statusCode, _):
            return statusCode == 503
        case .emptyResponse:
            return true
        case .server(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.contains("decode")
                || normalized.contains("empty")
                || normalized.contains("friend_remark_readback_failed")
        default:
            return false
        }
    }

    private func validateFriendRemarkReadback(
        _ profile: RemoteFriendProfile,
        canonicalFriendUID: String,
        normalizedRemark: String
    ) throws {
        let readbackUID = profile.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readbackUID == canonicalFriendUID else {
            throw IMAPIError.server("friend_remark_readback_identity_mismatch")
        }
        let readbackRemark = try FriendRemarkInputPolicy.normalize(profile.remark)
        guard readbackRemark == normalizedRemark else {
            throw IMAPIError.server("friend_remark_readback_stale")
        }
    }

    private func friendRemarkSaveFailure(from error: Error) -> FriendRemarkSaveFailure {
        if let validation = error as? FriendRemarkValidationError {
            return .init(kind: .validation, message: validation.errorDescription ?? "好友备注最多 128 个字符")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dnsLookupFailed:
                return .init(kind: .network, message: "网络连接异常，请稍后重试")
            default:
                return .init(kind: .network, message: "网络或服务不可用，请稍后重试")
            }
        }
        guard let apiError = error as? IMAPIError else {
            return .init(kind: .unexpected, message: "保存失败，请稍后重试")
        }
        switch apiError {
        case .missingContext, .unauthorized:
            return .init(kind: .unauthorized, message: "登录状态已失效，请重新登录")
        case .businessForbidden(let code, let message, _):
            return friendRemarkSaveFailure(code: code, statusCode: nil, message: message)
        case .forbidden:
            return .init(kind: .forbidden, message: "当前好友关系不允许修改备注")
        case .httpStatus(let statusCode, let message):
            return friendRemarkSaveFailure(code: message, statusCode: statusCode, message: message)
        case .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            return friendRemarkSaveFailure(code: code, statusCode: nil, message: message)
        case .server(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("friend_remark_readback") {
                return .init(kind: .readbackPending, message: "结果尚未确认，请刷新后重试")
            }
            return .init(kind: .server, message: "服务返回异常，请刷新后重试")
        case .badURL:
            return .init(kind: .server, message: "服务地址异常，请刷新后重试")
        case .emptyResponse:
            return .init(kind: .server, message: "服务返回异常，请刷新后重试")
        case .forcedAuthRequired:
            return .init(kind: .unauthorized, message: "当前登录状态需要重新验证")
        case .securityBlocked(let info):
            return .init(kind: .forbidden, message: info.userMessage)
        }
    }

    private func friendRemarkSaveFailure(
        code rawCode: String,
        statusCode: Int?,
        message rawMessage: String
    ) -> FriendRemarkSaveFailure {
        let combined = "\(rawCode) \(rawMessage)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if combined.contains("friend_identity_unresolved") {
            return .init(kind: .identity, message: "好友资料已变化，请刷新联系人后重试")
        }
        if statusCode == 401 || combined.contains("unauthorized") || combined.contains("session_expired") {
            return .init(kind: .unauthorized, message: "登录状态已失效，请重新登录")
        }
        if statusCode == 404 || combined.contains("friend_not_found") {
            return .init(kind: .relationChanged, message: "好友关系已变化，请刷新联系人后重试")
        }
        if statusCode == 422 || combined.contains("invalid_friend_remark") {
            return .init(kind: .validation, message: "好友备注最多 128 个字符")
        }
        if statusCode == 503 || combined.contains("friend_remark_readback_failed") {
            return .init(kind: .readbackPending, message: "备注可能已保存，正在重新确认")
        }
        if statusCode == 403 || combined.contains("blocked_by_me") || combined.contains("blocked_by_target") {
            return .init(kind: .forbidden, message: "当前好友关系不允许修改备注")
        }
        let sanitized = sanitizeBackendMessage(rawMessage, fallback: "保存失败，请稍后重试")
        return .init(kind: .server, message: sanitized)
    }

    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
    @discardableResult
    func setContactRemark(
        _ remark: String,
        for user: IMUser,
        completion: (@MainActor (FriendRemarkSaveResult) -> Void)? = nil
    ) -> Task<Void, Never>? {
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态失效，请重新登录后设置备注")
            completion?(.failure(.init(kind: .unauthorized, message: "登录状态已失效，请重新登录")))
            return nil
        }
        let owner = contactRequestOwner(context: context)
        let normalizedRemark: String
        do {
            normalizedRemark = try FriendRemarkInputPolicy.normalize(remark)
        } catch {
            let failure = friendRemarkSaveFailure(from: error)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(failure.message)
            completion?(.failure(failure))
            return nil
        }
        return Task {
            do {
                let canonicalFriendUID = try await canonicalFriendUIDForRemark(user: user, owner: owner)
                await applyContactRemarkMutation(
                    normalizedRemark,
                    user: user,
                    canonicalFriendUID: canonicalFriendUID,
                    owner: owner,
                    completion: completion
                )
            } catch {
                guard contactRequestContext(for: owner) != nil, !isContactRequestCancellation(error) else { return }
                let failure = friendRemarkSaveFailure(from: error)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(failure.message)
                completion?(.failure(failure))
            }
        }
    }

    private func applyContactRemarkMutation(
        _ normalizedRemark: String,
        user: IMUser,
        canonicalFriendUID: String,
        owner: ContactRequestOwner,
        completion: (@MainActor (FriendRemarkSaveResult) -> Void)?
    ) async {
        guard contactRequestContext(for: owner) != nil else { return }
        let scope = owner.scope
        let localRemarkKeys = contactRemarkKeys(for: user, extraIdentifiers: [canonicalFriendUID])
        profileContactRevisionFence.rebind(scopeHash: scope)
        let mutationKeys = profileContactKeys(kind: "remark", identifiers: localRemarkKeys)
            .union(profileContactKeys(kind: "contact", identifiers: localRemarkKeys))
        guard let mutationTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: mutationKeys
        ) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重试保存备注")
            completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
            return
        }
        let previousRemarks = localRemarkKeys.reduce(into: [String: String]()) { result, key in
            if let value = contactRemarks[key] {
                result[key] = value
            }
        }
        let previousContact = contacts.first { candidate in
            localRemarkKeys.contains { self.user(candidate, matchesIdentifier: $0) }
        }
        applyLocalContactRemark(normalizedRemark, keys: localRemarkKeys)
        if let index = contacts.firstIndex(where: { candidate in
            localRemarkKeys.contains { self.user(candidate, matchesIdentifier: $0) }
        }) {
            let originalName = contactCardOriginalName(matching: localRemarkKeys) ?? contacts[index].name
            contacts[index] = contactUser(
                contacts[index],
                replacingDisplayName: normalizedRemark.isEmpty ? originalName : normalizedRemark
            )
        }
        refreshDirectConversationDisplayNames()
        persistProfileContactProjectionIfPossible(
            scope: scope,
            revision: mutationTicket.revision,
            reason: "remark_optimistic"
        )
        guard let patchContext = contactRequestContext(for: owner) else { return }
        var requestAuthority = patchContext.authSessionFence
        do {
            do {
                // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
                _ = try await withContactHTTPRequest(owner: owner, context: patchContext) {
                    try await api.updateFriendRemark(
                        context: patchContext, canonicalFriendUID: canonicalFriendUID, remark: normalizedRemark
                    )
                }
                // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
            } catch {
                guard shouldConfirmFriendRemarkAfterPatchError(error) else { throw error }
            }
            guard let readContext = contactRequestContext(for: owner) else { return }
            guard profileContactRevisionFence.isCurrent(mutationTicket) else {
                completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                return
            }
            requestAuthority = readContext.authSessionFence
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
            let profile = try await withContactHTTPRequest(owner: owner, context: readContext) {
                try await api.friendProfile(context: readContext, canonicalFriendUID: canonicalFriendUID)
            }
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
            guard contactRequestContext(for: owner) != nil else { return }
            guard profileContactRevisionFence.isCurrent(mutationTicket) else {
                completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                return
            }
            try validateFriendRemarkReadback(profile, canonicalFriendUID: canonicalFriendUID, normalizedRemark: normalizedRemark)
            let savedRemark = profile.remark.trimmingCharacters(in: .whitespacesAndNewlines)
            applyLocalContactRemark(
                savedRemark,
                keys: contactRemarkKeys(for: user, extraIdentifiers: [canonicalFriendUID, profile.imUID, profile.userID])
            )
            let remoteDisplayNameSource = profile.displayNameSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let remoteDisplayName = remoteDisplayNameSource.contains("remark")
                ? nil
                : profile.displayName
            let originalName = preferredDisplayName(
                candidates: [profile.rawNickname, profile.nickname, remoteDisplayName, profile.userID],
                identifiers: [user.id, user.userID, profile.imUID, profile.userID],
                fallback: profile.imUID.isEmpty ? (profile.userID.isEmpty ? user.id : profile.userID) : profile.imUID
            )
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
            contactStore.cacheContactCardOriginalName(
                originalName,
                identifiers: [user.id, user.userID, profile.imUID, profile.userID],
                in: scope
            )
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
            if let index = contacts.firstIndex(where: { candidate in
                localRemarkKeys.contains { self.user(candidate, matchesIdentifier: $0) }
            }) {
                let current = contacts[index]
                let fallbackName = profile.rawNickname.isEmpty ? (profile.userID.isEmpty ? user.name : profile.userID) : profile.rawNickname
                let displayName = preferredDisplayName(
                    candidates: [savedRemark, profile.displayName, profile.rawNickname, profile.nickname, profile.userID],
                    identifiers: [current.id, current.userID, profile.imUID, profile.userID],
                    fallback: fallbackName
                )
                let profileDepartmentName = profile.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
                let profileDepartmentPath = profile.departmentPathNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let hasProfileDepartment = !profileDepartmentName.isEmpty || !profileDepartmentPath.isEmpty
                let department = hasProfileDepartment
                    ? normalizedDepartmentName(profile.departmentName, pathNames: profile.departmentPathNames)
                    : current.department
                let departmentPathNames = hasProfileDepartment
                    ? normalizedDepartmentPathNames(profile.departmentPathNames, fallbackName: department)
                    : current.departmentPathNames
                contacts[index] = IMUser(
                    id: current.id,
                    userID: current.userID,
                    username: current.username,
                    name: displayName,
                    title: current.title,
                    department: department,
                    departmentPathNames: departmentPathNames,
                    phone: profile.visiblePhone.isEmpty ? current.phone : profile.visiblePhone,
                    phoneVerified: current.phoneVerified,
                    realNameVerified: current.realNameVerified,
                    realNameStatus: current.realNameStatus,
                    email: current.email,
                    status: current.status,
                    enterprise: current.enterprise,
                    avatarSeed: current.avatarSeed,
                    avatarURL: profile.avatar.isEmpty ? current.avatarURL : resolveTenantAssetURL(profile.avatar),
                    avatarVersion: profile.avatarVersion.isEmpty ? current.avatarVersion : profile.avatarVersion,
                    avatarUpdatedAt: profile.avatarUpdatedAt.isEmpty ? current.avatarUpdatedAt : profile.avatarUpdatedAt,
                    badges: current.badges
                )
            }
            refreshDirectConversationDisplayNames()
            commitAuthoritativeProfileContactProjection(scope: scope, reason: "remark_authoritative")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(savedRemark.isEmpty ? "已清空好友备注" : "已保存好友备注")
            guard contactRequestContext(for: owner) != nil else { return }
            completion?(.success)
            await refreshFriendApplicationsAndRelations(owner: owner)
        } catch {
            guard contactRequestContext(for: owner) != nil, !isContactRequestCancellation(error) else { return }
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
            if isContactSessionFailure(error), !apiContext.isSameAuthAuthority(as: requestAuthority) { return }
            // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
            guard profileContactRevisionFence.isCurrent(mutationTicket) else {
                completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                return
            }
            restoreLocalContactRemarks(previousRemarks, keys: localRemarkKeys)
            if let previousContact,
               let index = contacts.firstIndex(where: { candidate in
                localRemarkKeys.contains { self.user(candidate, matchesIdentifier: $0) }
               }) {
                contacts[index] = previousContact
            }
            refreshDirectConversationDisplayNames()
            commitAuthoritativeProfileContactProjection(scope: scope, reason: "remark_rollback")
            let failure = friendRemarkSaveFailure(from: error)
            if DeviceRevocationDetector.matches(error: error) || securityBlockedInfo(from: error) != nil {
                handleRemoteError(error, fallback: "保存好友备注失败")
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(failure.message)
            }
            guard contactRequestContext(for: owner) != nil else { return }
            completion?(.failure(failure))
        }
    }
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END

    func contactRemarkKeys(for user: IMUser, extraIdentifiers: [String] = []) -> [String] {
        var keys = userIdentityCandidates(for: user) + extraIdentifiers
        if let contact = contacts.first(where: { contact in
            keys.contains { identifier in
                self.user(contact, matchesIdentifier: identifier)
            }
        }) {
            keys.append(contentsOf: [contact.id, contact.userID, contact.username])
        }
        var seen = Set<String>()
        return keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
    func contactCardOriginalName(matching identifiers: [String]) -> String? {
        contactStore.contactCardOriginalName(matching: identifiers, in: remoteDataScopeKey(for: apiContext))
    }
    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END

    private func applyLocalContactRemark(_ remark: String, keys: [String]) {
        let normalizedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keys.isEmpty else { return }
        for key in keys {
            if normalizedRemark.isEmpty {
                contactRemarks.removeValue(forKey: key)
            } else {
                contactRemarks[key] = normalizedRemark
            }
        }
    }

    private func restoreLocalContactRemarks(_ previousRemarks: [String: String], keys: [String]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            if let value = previousRemarks[key] {
                contactRemarks[key] = value
            } else {
                contactRemarks.removeValue(forKey: key)
            }
        }
    }

    private func contactUser(_ user: IMUser, replacingDisplayName displayName: String) -> IMUser {
        IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: displayName,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            lastLoginAt: user.lastLoginAt,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: user.avatarURL,
            avatarVersion: user.avatarVersion,
            avatarUpdatedAt: user.avatarUpdatedAt,
            badges: user.badges
        )
    }

}
