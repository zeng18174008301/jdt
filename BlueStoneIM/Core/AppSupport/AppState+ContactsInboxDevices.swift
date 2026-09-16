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
    func acceptFriendRequest(_ requestID: String) {
        guard friendRequests.contains(where: { $0.id == requestID }) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.acceptFriendApplication(context: context, id: requestID)
                guard isCurrentRemoteScope(scope) else { return }
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                toast = "已通过好友申请"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "通过好友申请失败")
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            }
        }
    }

    func rejectFriendRequest(_ requestID: String) {
        guard friendRequests.contains(where: { $0.id == requestID }) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.rejectFriendApplication(context: context, id: requestID)
                guard isCurrentRemoteScope(scope) else { return }
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                toast = "已拒绝好友申请"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "拒绝好友申请失败")
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            }
        }
    }

    func isCancellingFriendRequest(_ requestID: String) -> Bool {
        cancellingFriendRequestIDs.contains(requestID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func cancelFriendRequest(_ requestID: String) async -> Bool {
        let normalizedID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestIndex = friendRequests.firstIndex(where: { $0.id == normalizedID }),
              friendRequests[requestIndex].canCancel else {
            toast = "只有待处理的已发出申请可以取消"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        guard cancellingFriendRequestIDs.insert(normalizedID).inserted else { return false }
        defer { cancellingFriendRequestIDs.remove(normalizedID) }
        let scope = remoteDataScopeKey(for: context)
        do {
            let terminal = try await api.cancelFriendApplication(context: context, id: normalizedID)
            guard isCurrentRemoteScope(scope) else { return false }
            let normalizedStatus = terminal.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedStatus == "cancelled" || normalizedStatus == "canceled" else {
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
                toast = "好友申请状态已变化，请查看最新状态"
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
            toast = "已取消好友申请"
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
            toast = "登录状态失效，请重新登录后移出黑名单"
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
            toast = "登录状态已变化，请重试移出黑名单"
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
                toast = "已将 \(item.name) 移出黑名单"
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

    private func canonicalFriendUIDForRemark(
        user: IMUser,
        context: IMAPIContext,
        scope: String
    ) async throws -> String {
        if let resolved = resolvedCanonicalFriendUIDForRemark(user: user, scope: scope) {
            return resolved
        }
        let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        let relations = try await api.friendRelationsForRemarkResolution(context: context)
        guard isCurrentRemoteScope(scope) else { throw CancellationError() }
        applyFriendRelations(relations, readStamp: readStamp)
        if let resolved = resolvedCanonicalFriendUIDForRemark(user: user, scope: scope) {
            return resolved
        }
        throw IMAPIError.businessForbidden(
            code: "friend_identity_unresolved",
            message: "好友资料已变化，请刷新联系人后重试",
            error: nil
        )
    }

    private func resolvedCanonicalFriendUIDForRemark(user: IMUser, scope: String) -> String? {
        guard canonicalFriendUIDIdentityScope == scope else { return nil }
        let keys = friendRemarkIdentityKeys(for: user)
        let matches = Set(keys.flatMap { canonicalFriendUIDsByIdentity[$0] ?? [] })
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func friendRemarkIdentityKeys(for user: IMUser) -> [FriendIdentityKey] {
        var keys: [FriendIdentityKey] = []
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userID.isEmpty {
            keys.append(.userID(userID))
        }
        let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            keys.append(.username(username))
        }
        let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty,
           canonicalFriendUIDsByIdentity[.imUID(id)] == Set([id]),
           contacts.contains(where: { contact in
               let contactID = contact.id.trimmingCharacters(in: .whitespacesAndNewlines)
               let contactUserID = contact.userID.trimmingCharacters(in: .whitespacesAndNewlines)
               let contactUsername = contact.username.trimmingCharacters(in: .whitespacesAndNewlines)
               return contactID == id
                   && (
                       (!userID.isEmpty && contactUserID == userID)
                       || (!username.isEmpty && contactUsername == username)
                   )
           }) {
            keys.append(.imUID(id))
        }
        var seen = Set<FriendIdentityKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func updateFriendRemarkWithReadback(
        context: IMAPIContext,
        canonicalFriendUID: String,
        normalizedRemark: String
    ) async throws -> RemoteFriendProfile {
        do {
            _ = try await api.updateFriendRemark(
                context: context,
                canonicalFriendUID: canonicalFriendUID,
                remark: normalizedRemark
            )
        } catch {
            guard shouldConfirmFriendRemarkAfterPatchError(error) else { throw error }
        }
        let profile = try await api.friendProfile(
            context: context,
            canonicalFriendUID: canonicalFriendUID
        )
        try validateFriendRemarkReadback(
            profile,
            canonicalFriendUID: canonicalFriendUID,
            normalizedRemark: normalizedRemark
        )
        return profile
    }

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

    func setContactRemark(
        _ remark: String,
        for user: IMUser,
        completion: (@MainActor (FriendRemarkSaveResult) -> Void)? = nil
    ) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录状态失效，请重新登录后设置备注"
            completion?(.failure(.init(kind: .unauthorized, message: "登录状态已失效，请重新登录")))
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let normalizedRemark: String
        do {
            normalizedRemark = try FriendRemarkInputPolicy.normalize(remark)
        } catch {
            let failure = friendRemarkSaveFailure(from: error)
            toast = failure.message
            completion?(.failure(failure))
            return
        }
        Task {
            do {
                let canonicalFriendUID = try await canonicalFriendUIDForRemark(
                    user: user,
                    context: context,
                    scope: scope
                )
                guard isCurrentRemoteScope(scope) else {
                    completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                    return
                }
                applyContactRemarkMutation(
                    normalizedRemark,
                    user: user,
                    canonicalFriendUID: canonicalFriendUID,
                    context: context,
                    scope: scope,
                    completion: completion
                )
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                    return
                }
                let failure = friendRemarkSaveFailure(from: error)
                toast = failure.message
                completion?(.failure(failure))
            }
        }
    }

    private func applyContactRemarkMutation(
        _ normalizedRemark: String,
        user: IMUser,
        canonicalFriendUID: String,
        context: IMAPIContext,
        scope: String,
        completion: (@MainActor (FriendRemarkSaveResult) -> Void)?
    ) {
        let localRemarkKeys = contactRemarkKeys(for: user, extraIdentifiers: [canonicalFriendUID])
        profileContactRevisionFence.rebind(scopeHash: scope)
        let mutationKeys = profileContactKeys(kind: "remark", identifiers: localRemarkKeys)
            .union(profileContactKeys(kind: "contact", identifiers: localRemarkKeys))
        guard let mutationTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: mutationKeys
        ) else {
            toast = "登录状态已变化，请重试保存备注"
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
        Task {
            do {
                let profile = try await updateFriendRemarkWithReadback(
                    context: context,
                    canonicalFriendUID: canonicalFriendUID,
                    normalizedRemark: normalizedRemark
                )
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else {
                    completion?(.failure(.init(kind: .unexpected, message: "登录状态已变化，请重试保存备注")))
                    return
                }
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
                cacheContactCardOriginalName(
                    originalName,
                    identifiers: [user.id, user.userID, profile.imUID, profile.userID]
                )
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
                toast = savedRemark.isEmpty ? "已清空好友备注" : "已保存好友备注"
                completion?(.success)
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            } catch {
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else {
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
                    toast = failure.message
                }
                completion?(.failure(failure))
            }
        }
    }

    private func contactRemarkKeys(for user: IMUser, extraIdentifiers: [String] = []) -> [String] {
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

    func contactCardOriginalNameCacheKey(for identifier: String, scope: String? = nil) -> String? {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else { return nil }
        let resolvedScope = scope ?? remoteDataScopeKey(for: apiContext)
        return "\(resolvedScope)|\(normalizedIdentifier)"
    }

    func cacheContactCardOriginalName(
        _ name: String,
        identifiers: [String?],
        scope: String? = nil,
        in storage: inout [String: String]
    ) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        for identifier in identifiers {
            guard let key = contactCardOriginalNameCacheKey(for: identifier ?? "", scope: scope) else { continue }
            storage[key] = normalizedName
        }
    }

    func cacheContactCardOriginalName(_ name: String, identifiers: [String?], scope: String? = nil) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        for identifier in identifiers {
            guard let key = contactCardOriginalNameCacheKey(for: identifier ?? "", scope: scope) else { continue }
            contactCardOriginalNamesByScopedUserKey[key] = normalizedName
        }
    }

    func contactCardOriginalName(matching identifiers: [String]) -> String? {
        for identifier in identifiers {
            guard let key = contactCardOriginalNameCacheKey(for: identifier) else { continue }
            if let name = contactCardOriginalNamesByScopedUserKey[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        return nil
    }

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

    func shareContactCard(_ user: IMUser, to conversationID: String, quote: String? = nil) {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            toast = "系统通知仅支持阅读"
            return
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return
        }
        guard let contactID = contactCardUID(for: user) else {
            toast = "该联系人缺少用户ID，暂不能发送名片"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_contact_card")
        let localContactName = contactCardLocalDisplayName(for: user)
        let remoteContactName = contactCardExportDisplayName(for: user)
        let messageText = "个人名片：\(localContactName)"
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: messageText,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .contactCard,
            reactions: [],
            readBy: [],
            unreadBy: conversations[cIndex].participants.prefix(3).map { ReadReceipt(id: "card_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: localContactName,
            attachmentMeta: contactID
        )
        message.createdAt = Date()
        guard let conversation = conversationStore.appendLocalOutgoingMessage(
            message,
            to: conversationID,
            preview: messageText
        ) else { return }
        let channelID = remoteChannelID(for: conversation)
        toast = "名片发送中…"
        Task {
            var durableTicket: LocalMessageSessionTicket?
            do {
                durableTicket = try await enqueueDurableOutgoing(
                    messageID: message.id,
                    conversationID: conversationID,
                    operationKind: "send_contact_card",
                    context: context,
                    scope: scope
                )
                let remote = try await api.sendContactCard(
                    context: context,
                    conversation: conversation,
                    channelID: channelID,
                    contactID: contactID,
                    contactName: remoteContactName,
                    contactAvatar: user.avatarURL,
                    quote: quote,
                    clientMessageID: message.id
                )
                guard isCurrentRemoteScope(scope) else { return }
                replaceMessageID(localID: message.id, remote: remote, in: conversationID)
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
                toast = "名片已发送"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if isNotFriendsError(error) {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .failedPermanent)
                    removeMessage(messageID: message.id, in: conversationID)
                    handleNotFriends(for: conversation)
                } else if isSendPolicyForbidden(error) {
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(conversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .cancelled)
                    handleRemoteError(error, fallback: "名片发送失败")
                    removeMessage(messageID: message.id, in: conversationID)
                } else {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleRemoteError(error, fallback: "名片发送失败")
                }
            }
        }
    }

    func blockContact(_ user: IMUser) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录状态失效，请重新登录后拉黑"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        profileContactRevisionFence.rebind(scopeHash: scope)
        let mutationKeys = profileContactMutationKeys(for: user, kinds: ["blacklist", "contact"])
        guard let mutationTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: mutationKeys
        ) else {
            toast = "登录状态已变化，请重试拉黑"
            return
        }
        let previousContact = contacts.first { candidate in
            userIdentityCandidates(for: user).contains { self.user(candidate, matchesIdentifier: $0) }
        }
        let previousBlacklistItem = blacklist.first { $0.id == user.id }
        blacklist.removeAll { $0.id == user.id }
        blacklist.insert(BlacklistItem(id: user.id, name: user.name, reason: "用户主动拉黑"), at: 0)
        removeFriendData(user, removePrivateRemark: false)
        persistProfileContactProjectionIfPossible(
            scope: scope,
            revision: mutationTicket.revision,
            reason: "block_optimistic"
        )
        Task {
            do {
                let relation = try await api.addBlacklist(context: context, userID: user.id, reason: "用户主动拉黑")
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == user.id || $0.id == relation.blockedUID }
                blacklist.insert(BlacklistItem(id: relation.blockedUID, name: user.name, reason: relation.reason.isEmpty ? "用户主动拉黑" : relation.reason), at: 0)
                removeFriendData(user, removePrivateRemark: false)
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "block_authoritative")
                toast = "已拉黑 \(user.name)"
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            } catch {
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == user.id }
                if let previousBlacklistItem {
                    blacklist.insert(previousBlacklistItem, at: 0)
                }
                if let previousContact,
                   !contacts.contains(where: { $0.id == previousContact.id }) {
                    contacts.append(previousContact)
                }
                refreshDirectConversationDisplayNames()
                pruneNonFriendDirectConversations()
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "block_rollback")
                handleRemoteError(error, fallback: "拉黑失败")
            }
        }
    }

    func deleteContact(_ user: IMUser) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录状态失效，请重新登录后删除好友"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.deleteFriend(context: context, userID: user.id)
                guard isCurrentRemoteScope(scope) else { return }
                removeFriendData(user)
                toast = "已删除好友 \(user.name)"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if isDeleteFriendNotFoundError(error) {
                    removeFriendData(user)
                    toast = "已删除好友 \(user.name)"
                    return
                }
                handleRemoteError(error, fallback: "删除好友失败")
            }
        }
    }

    private func isDeleteFriendNotFoundError(_ error: Error) -> Bool {
        if case let IMAPIError.server(message) = error {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "not found"
                || normalized == "not_found"
                || normalized.contains("friend_not_found")
                || normalized.contains("friend relation not found")
        }
        return false
    }

    func removeFriendData(_ user: IMUser, removePrivateRemark: Bool = true) {
        contacts.removeAll { $0.id == user.id }
        if removePrivateRemark {
            for key in contactRemarkKeys(for: user) {
                contactRemarks.removeValue(forKey: key)
            }
        }
        // Removing the relationship must retain readable direct-message history
        // and its participant snapshot. Send/call eligibility is enforced from
        // the authoritative friend relation instead of by deleting history.
        pruneNonFriendDirectConversations()
    }

    func isFriendID(_ id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return contacts.contains { $0.id == normalizedID || $0.userID == normalizedID }
    }

    func userIdentityCandidates(for user: IMUser) -> [String] {
        var seen = Set<String>()
        return [
            user.id,
            user.userID,
            user.username
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
    }

    func directPeerID(for conversation: Conversation) -> String? {
        guard conversation.kind == .direct else { return nil }
        let currentIDs = Set([
            currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines),
            apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].filter { !$0.isEmpty })
        if let participant = conversation.participants.first(where: { user in
            let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && !currentIDs.contains(id)
        }) {
            return participant.id
        }
        let channelParts = conversation.id
            .split(separator: ":")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let peerID = channelParts.first(where: { !currentIDs.contains($0) }) {
            return peerID
        }
        return conversation.participants.first?.id
    }

    private func removeDirectConversation(withPeerID peerID: String) {
        conversationStore.removeDirectConversations(peerID: peerID) { [self] conversation in
            directPeerID(for: conversation)
        }
    }

    func pruneNonFriendDirectConversations() {
        guard contactStore.friendRelationsLoaded() else { return }
        let friendIDs = Set(contacts.map(\.id))
        for index in conversations.indices {
            let conversation = conversations[index]
            guard conversation.kind == .direct else { continue }
            guard let peerID = directPeerID(for: conversation) else {
                let context = DirectFriendRequestContext(
                    targetUID: "",
                    canApplyFriend: nil,
                    friendRequestStatus: "",
                    reasonCode: "friendship_required"
                )
                markDirectConversationUnavailable(conversation, context: context)
                continue
            }
            if friendIDs.contains(peerID) {
                conversationStore.setDirectDisabledMessage(conversationID: conversation.id, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversation.id)
                continue
            }
            let context = DirectFriendRequestContext(
                targetUID: peerID,
                canApplyFriend: nil,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            )
            markDirectConversationUnavailable(conversation, context: context)
        }
    }

    func conversationSendDisabledReason(_ conversationID: String) -> String {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return "" }
        return directSendBlockedMessage(for: conversation)
            ?? localSendPolicyBlockedMessage(for: conversation)
            ?? ""
    }

    func conversationFriendRequestActionTitle(_ conversationID: String) -> String? {
        guard canCurrentUserInitiateFriendRequest,
              let context = conversationStore.directFriendRequestContext(conversationID: conversationID),
              context.allowsApply else {
            return nil
        }
        return context.actionTitle
    }

    func applyFriendFromDisabledConversation(_ conversationID: String) async {
        guard !conversationStore.isApplyingFriend(conversationID: conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        let context = conversationStore.directFriendRequestContext(conversationID: conversationID)
        let targetUID = (context?.targetUID ?? directPeerID(for: conversation) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetUID.isEmpty else {
            toast = "用户信息不完整，无法添加好友"
            return
        }
        if conversation.participants.contains(where: { $0.id == targetUID && $0.isCancelledUser }) {
            toast = "该用户已注销，无法添加好友"
            return
        }
        guard canCurrentUserInitiateFriendRequest else {
            toast = "管理员已关闭好友申请"
            return
        }
        guard context?.allowsApply ?? false else {
            toast = context?.disabledMessage ?? "当前关系状态暂不可申请好友"
            return
        }
        let remoteContext = self.apiContext
        guard remoteContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: remoteContext)
        guard conversationStore.beginApplyingFriend(conversationID: conversationID) else { return }
        defer { conversationStore.finishApplyingFriend(conversationID: conversationID) }
        do {
            let applyResult = try await api.applyFriend(
                context: remoteContext,
                targetUID: targetUID,
                message: "你好，我想添加你为好友",
                source: "direct_chat_not_friends"
            )
            guard isCurrentRemoteScope(scope) else { return }
            let resolution = Self.friendApplyResolution(applyResult)
            if resolution == .established {
                conversationStore.setDirectDisabledMessage(conversationID: conversationID, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversationID)
                toast = FriendAddPresentation.establishedMessage
            } else if resolution == .pending {
                let pendingContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: "pending_out",
                    reasonCode: context?.reasonCode ?? "friendship_required",
                    friendAction: "none",
                    friendFlow: applyResult.friendFlow
                )
                markDirectConversationUnavailable(conversation, context: pendingContext)
                toast = FriendAddPresentation.sentMessage
            } else {
                let terminalContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: applyResult.relationStatus.isEmpty ? "history" : applyResult.relationStatus,
                    reasonCode: applyResult.outcome,
                    friendAction: applyResult.friendAction,
                    friendFlow: applyResult.friendFlow
                )
                markDirectConversationUnavailable(conversation, context: terminalContext)
                toast = Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage
            }
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            if resolution == .established {
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            }
        } catch IMAPIError.conflict(let code, _) {
            guard isCurrentRemoteScope(scope) else { return }
            await refreshFriendApplicationsAndRelations(context: remoteContext, scope: scope)
            guard isCurrentRemoteScope(scope) else { return }
            if isFriendID(targetUID) {
                conversationStore.setDirectDisabledMessage(conversationID: conversationID, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversationID)
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            } else {
                let pendingContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: "pending_out",
                    reasonCode: context?.reasonCode ?? "friendship_required",
                    friendAction: "none",
                    friendFlow: context?.friendFlow ?? ""
                )
                markDirectConversationUnavailable(conversation, context: pendingContext)
            }
            toast = Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            handleRemoteError(error, fallback: "好友申请失败")
        }
    }

    private func markDirectConversationUnavailable(_ conversation: Conversation, message: String) {
        let context = DirectFriendRequestContext(
            targetUID: directPeerID(for: conversation) ?? "",
            canApplyFriend: nil,
            friendRequestStatus: "",
            reasonCode: "friendship_required"
        )
        markDirectConversationUnavailable(conversation, context: context, fallbackMessage: message)
    }

    private func markDirectConversationUnavailable(_ conversation: Conversation, context: DirectFriendRequestContext, fallbackMessage: String? = nil) {
        conversationStore.markDirectConversationUnavailable(
            conversation,
            context: context,
            fallbackMessage: fallbackMessage
        )
    }

    func handleNotFriends(for conversation: Conversation, showToast: Bool = false) {
        handleNotFriends(
            for: conversation,
            context: DirectFriendRequestContext(
                targetUID: directPeerID(for: conversation) ?? "",
                canApplyFriend: nil,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            ),
            showToast: showToast
        )
    }

    func handleNotFriends(for conversation: Conversation, context: DirectFriendRequestContext, showToast _: Bool = false) {
        guard conversation.kind == .direct else {
            return
        }
        markDirectConversationUnavailable(conversation, context: context)
    }

    func directSendBlockedMessage(for conversation: Conversation) -> String? {
        if let message = conversationStore.directDisabledMessage(conversationID: conversation.id),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if conversation.kind == .direct,
           conversation.participants.contains(where: { $0.isCancelledUser }) {
            return "该用户已注销，无法发送消息"
        }
        guard conversation.kind == .direct,
              let peerID = directPeerID(for: conversation),
              blacklist.contains(where: { $0.id == peerID }) else {
            return nil
        }
        return "你已拉黑对方，无法发送消息"
    }

    func reviewGroupInviteApproval(_ approval: GroupInviteApproval, approve: Bool) {
        guard approval.isActionable else {
            toast = "该入群邀请已处理"
            return
        }
        let endpoint = approve ? approval.approveEndpoint : approval.rejectEndpoint
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast = "审批卡片缺少操作地址，请刷新系统通知"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard contactStore.beginGroupInviteApprovalProcessing(requestID: approval.requestID) else { return }
        let nextStatus = approve ? "approved" : "rejected"
        let resultText = approve ? "已通过" : "已拒绝"
        Task {
            defer { contactStore.finishGroupInviteApprovalProcessing(requestID: approval.requestID) }
            do {
                let response = try await api.reviewGroupInviteApproval(context: context, endpoint: endpoint)
                guard isCurrentRemoteScope(scope) else { return }
                markGroupInviteApprovalResolved(
                    requestID: approval.requestID,
                    status: response.resolvedStatus(fallback: nextStatus),
                    approverName: response.resolvedApproverName(fallback: currentUser.name),
                    approverAccountID: response.resolvedApproverAccountID(),
                    decidedAt: displayTime(response.resolvedDecidedAt(fallback: "")),
                    resultText: response.resolvedResultText(fallback: resultText)
                )
                let didMarkRead = await markGroupInviteApprovalInboxReadRemotely(requestID: approval.requestID, context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                if didMarkRead {
                    markGroupInviteApprovalReadLocally(requestID: approval.requestID)
                    toast = approve ? "已通过入群邀请" : "已拒绝入群邀请"
                } else {
                    toast = approve ? "已通过入群邀请，但通知已读同步失败" : "已拒绝入群邀请，但通知已读同步失败"
                }
                await refreshInboxSilently()
                guard isCurrentRemoteScope(scope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
            } catch IMAPIError.conflict(let code, _) where Self.isGroupInviteAlreadyProcessedCode(code) {
                guard isCurrentRemoteScope(scope) else { return }
                toast = "该入群邀请已被其他管理员处理"
                markGroupInviteApprovalResolved(requestID: approval.requestID, status: "processed", resultText: "已处理")
                let didMarkRead = await markGroupInviteApprovalInboxReadRemotely(requestID: approval.requestID, context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                if didMarkRead {
                    markGroupInviteApprovalReadLocally(requestID: approval.requestID)
                } else {
                    toast = "该入群邀请已处理，但通知已读同步失败"
                }
                await refreshInboxSilently()
                guard isCurrentRemoteScope(scope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: approve ? "审批通过失败" : "审批拒绝失败")
                await refreshInboxSilently()
            }
        }
    }

    private static func isGroupInviteAlreadyProcessedCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "already_processed" || normalized == "group_invite_already_processed"
    }

    private func markGroupInviteApprovalResolved(requestID: String, status: String, approverName: String = "", approverAccountID: String = "", decidedAt: String = "", resultText: String = "") {
        guard !requestID.isEmpty else { return }
        var didUpdateInbox = false
        for index in inboxItems.indices {
            guard let approval = inboxItems[index].groupInviteApproval,
                  approval.requestID == requestID else { continue }
            inboxItems[index] = inboxItems[index].withGroupInviteApproval(approval.resolved(status: status, approverName: approverName, approverAccountID: approverAccountID, decidedAt: decidedAt, resultText: resultText))
            didUpdateInbox = true
        }
	        if didUpdateInbox {
	            syncSystemConversationFromInbox(inboxItems)
        }
        conversationStore.resolveGroupInviteApprovalMessages(
            requestID: requestID,
            status: status,
            approverName: approverName,
            approverAccountID: approverAccountID,
            decidedAt: decidedAt,
            resultText: resultText
        )
    }

    private func markGroupInviteApprovalReadLocally(requestID: String) {
        guard !requestID.isEmpty else { return }
        var didUpdateInbox = false
        for index in inboxItems.indices {
            guard !inboxItems[index].isAnnouncement,
                  inboxItems[index].groupInviteApproval?.requestID == requestID else { continue }
            contactStore.rememberSystemInboxReadLocally(id: inboxItems[index].id)
            if !inboxItems[index].isRead {
                inboxItems[index].isRead = true
                didUpdateInbox = true
            }
        }
        if didUpdateInbox {
            syncSystemConversationFromInbox(inboxItems)
        }
    }

    private func markGroupInviteApprovalInboxReadRemotely(requestID: String, context: IMAPIContext, scope: String) async -> Bool {
        guard isCurrentRemoteScope(scope) else { return false }
        let ids = inboxItems.compactMap { item -> String? in
            guard !item.isAnnouncement,
                  item.groupInviteApproval?.requestID == requestID else { return nil }
            return item.id
        }
        guard !ids.isEmpty else { return true }
        for id in ids {
            do {
                try await api.markInboxRead(context: context, id: id)
                guard isCurrentRemoteScope(scope) else { return false }
            } catch {
                guard isCurrentRemoteScope(scope) else { return false }
                handleRemoteError(error, fallback: "通知状态同步失败", silent: true)
                return false
            }
        }
        return true
    }

    func markInboxRead(_ itemID: String) {
        guard let index = inboxItems.firstIndex(where: { $0.id == itemID }) else { return }
        let previousItem = inboxItems[index]
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.markInboxRead(context: context, id: itemID)
                guard isCurrentRemoteScope(scope) else { return }
                if let currentIndex = inboxItems.firstIndex(where: { $0.id == itemID }) {
                    if !inboxItems[currentIndex].isAnnouncement {
                        contactStore.rememberSystemInboxReadLocally(id: inboxItems[currentIndex].id)
                    }
                    inboxItems[currentIndex].isRead = true
                    syncSystemConversationFromInbox(inboxItems)
                }
                await refreshInboxSilently()
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if let currentIndex = inboxItems.firstIndex(where: { $0.id == itemID }) {
                    inboxItems[currentIndex] = previousItem
                }
                handleRemoteError(error, fallback: "通知状态同步失败")
            }
        }
    }

    func markSystemInboxReadLocally() {
        guard !inboxItems.isEmpty else {
            clearConversationUnreadLocally("system_notification")
            return
        }
        var didChange = false
        for index in inboxItems.indices where !inboxItems[index].isAnnouncement {
            contactStore.rememberSystemInboxReadLocally(id: inboxItems[index].id)
            if !inboxItems[index].isRead {
                inboxItems[index].isRead = true
                didChange = true
            }
        }
        if didChange {
            syncSystemConversationFromInbox(inboxItems)
        } else {
            clearConversationUnreadLocally("system_notification")
        }
    }

    func startInboxRefreshLoop() {
        stopInboxRefreshLoop()
        guard apiContext.hasIMSession else { return }
        let syncEngine = remoteSyncEngine
        guard let taskToken = syncEngine.claimInboxRefreshTask() else { return }
        let task = Task { [weak self, syncEngine, taskToken] in
            defer { syncEngine.finishInboxRefreshTask(taskToken) }
            await self?.refreshInboxAndFriendPresenceSilently()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refreshInboxAndFriendPresenceSilently()
            }
        }
        syncEngine.attachInboxRefreshTask(taskToken, task: task)
    }

    func stopInboxRefreshLoop() {
        remoteSyncEngine.cancelInboxRefreshTask()
        stopRTCCallRefreshLoop()
    }

    func startRTCCallRefreshLoop() {
        stopRTCCallRefreshLoop()
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        guard let startupContext = currentRTCSignalingRefreshContext(reason: "loop_start") else { return }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        resetRTCDiscoveryBackoff()
        let refreshGeneration = rtcRefreshGeneration
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        voiceDebug("refresh_loop_start context=\(Self.rtcDebugContextSummary(startupContext.context))")
        rtcSignalingRefreshPendingScope = startupContext.scope
        rtcCallRefreshTask = Task { [weak self] in
            await self?.refreshRTCSignalingUsingCurrentContext(
                requiresPendingWakeup: true,
                generation: refreshGeneration
            )
            while !Task.isCancelled {
                let interval = await MainActor.run { [weak self] () -> UInt64 in
                    guard let self else { return 20_000_000_000 }
                    return self.rtcRefreshLoopIntervalNanoseconds()
                }
                await MainActor.run { [weak self] in
                    self?.voiceDebug("refresh_loop_tick interval_ms=\(interval / 1_000_000)")
                }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self?.refreshRTCSignalingUsingCurrentContext(generation: refreshGeneration)
            }
        }
    }

    func stopRTCCallRefreshLoop() {
        if rtcCallRefreshTask != nil {
            voiceDebug("refresh_loop_stop")
        }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        rtcRefreshGeneration &+= 1
        resetRTCDiscoveryBackoff()
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        rtcCallRefreshTask?.cancel()
        rtcCallRefreshTask = nil
        rtcSignalingWakeTask?.cancel()
        rtcSignalingWakeTask = nil
        rtcSignalingWakeTaskID = nil
        rtcSignalingRefreshPendingScope = nil
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    private func resetRTCDiscoveryBackoff() {
        rtcDiscoveryCallsBackoff.reset()
        rtcDiscoveryEventsBackoff.reset()
    }

    private func rtcRefreshLoopIntervalNanoseconds() -> UInt64 {
        let baseInterval: UInt64
        if activeVoiceCall != nil
            || incomingVoiceCall != nil
            || isStartingVoiceCall
            || isStartingVideoCall {
            baseInterval = activeRTCCallRefreshIntervalNanoseconds
        } else {
            baseInterval = idleRTCCallRefreshIntervalNanoseconds
        }
        guard let backoffDelay = nextRTCDiscoveryBackoffDelayNanoseconds() else {
            return baseInterval
        }
        return max(baseInterval, backoffDelay)
    }

    private func nextRTCDiscoveryBackoffDelayNanoseconds() -> UInt64? {
        let now = rtcRequestNowNanoseconds()
        let endpointDelays = [
            rtcDiscoveryEventsBackoff.remainingDelayNanoseconds(nowNanoseconds: now),
            rtcDiscoveryCallsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        ]
        guard endpointDelays.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return endpointDelays.compactMap { $0 }.min()
    }

    private func discoveryBackoffDelayNanoseconds(for endpoint: RTCRefreshEndpoint) -> UInt64? {
        let now = rtcRequestNowNanoseconds()
        switch endpoint {
        case .events:
            return rtcDiscoveryEventsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        case .calls:
            return rtcDiscoveryCallsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        }
    }

    private func recordRTCDiscoveryRefreshResult(_ result: RTCRefreshResult, endpoint: RTCRefreshEndpoint) {
        let now = rtcRequestNowNanoseconds()
        switch endpoint {
        case .events:
            rtcDiscoveryEventsBackoff.record(
                result,
                endpoint: endpoint,
                nowNanoseconds: now,
                delays: rtcDiscoveryFailureDelayNanoseconds
            )
        case .calls:
            rtcDiscoveryCallsBackoff.record(
                result,
                endpoint: endpoint,
                nowNanoseconds: now,
                delays: rtcDiscoveryFailureDelayNanoseconds
            )
        }
        if let error = result.failedError {
            voiceDebug("refresh_backoff_record endpoint=\(endpoint) error=\(Self.safeVoiceErrorSummary(error))")
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    private func currentRTCSignalingRefreshContext(reason: String) -> (context: IMAPIContext, scope: String)? {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard !isApplicationBackgroundedForRTC else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=background context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard isAuthenticated else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=not_authenticated context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        guard context.hasIMSession else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=no_im_session context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        guard isCurrentRemoteScope(scope) else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=scope_mismatch context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        return (context, scope)
    }

    func refreshRTCSignalingUsingCurrentContext(
        requiresPendingWakeup: Bool = false,
        generation: UInt64? = nil
    ) async {
        let snapshot = await MainActor.run { [weak self] in
            self?.currentRTCSignalingRefreshContext(reason: "loop_tick")
        }
        guard let snapshot else {
            await MainActor.run { [weak self] in
                self?.stopRTCCallRefreshLoop()
            }
            return
        }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let generation, rtcRefreshGeneration != generation {
            return
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        await refreshRTCSignalingSilently(
            context: snapshot.context,
            scope: snapshot.scope,
            requiresPendingWakeup: requiresPendingWakeup,
            generation: generation
        )
    }

    func ensureRTCSignalingRefreshActive(reason: String) {
        voiceDebug("refresh_loop_ensure reason=\(reason) active=\(rtcCallRefreshTask != nil) context=\(Self.rtcDebugContextSummary(apiContext))")
        guard let snapshot = currentRTCSignalingRefreshContext(reason: reason) else { return }
        if rtcCallRefreshTask == nil {
            startRTCCallRefreshLoop()
        }
        rtcSignalingRefreshPendingScope = snapshot.scope
        schedulePendingRTCSignalingRefresh()
    }

    func schedulePendingRTCSignalingRefresh() {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime,
              !isApplicationBackgroundedForRTC,
              let scope = rtcSignalingRefreshPendingScope,
              let snapshot = currentRTCSignalingRefreshContext(reason: "pending_wakeup"),
              snapshot.scope == scope,
              rtcSignalingWakeTask == nil,
              rtcSignalingRefreshInFlightScope != scope,
              rtcEventsRefreshInFlightScope != scope,
              rtcCallsRefreshInFlightScope != scope else { return }
        let operationID = UUID()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        let generation = rtcRefreshGeneration
        let wakeDelay = nextRTCDiscoveryBackoffDelayNanoseconds()
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        rtcSignalingWakeTaskID = operationID
        rtcSignalingWakeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A retired task must not clear a newer wakeup owner.
                if self.rtcSignalingWakeTaskID == operationID {
                    self.rtcSignalingWakeTask = nil
                    self.rtcSignalingWakeTaskID = nil
                    self.schedulePendingRTCSignalingRefresh()
                }
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            if let wakeDelay, wakeDelay > 0 {
                try? await self.rtcRequestSleep(wakeDelay)
            }
            guard self.rtcRefreshGeneration == generation,
                  !self.isApplicationBackgroundedForRTC else { return }
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope),
                  self.rtcSignalingRefreshPendingScope == scope else { return }
            await self.refreshRTCSignalingSilently(
                context: snapshot.context,
                scope: scope,
                requiresPendingWakeup: true,
                generation: generation
            )
        }
    }

    @discardableResult
    func refreshRTCSignalingSilently(
        context: IMAPIContext,
        scope: String,
        requiresPendingWakeup: Bool = false,
        generation: UInt64? = nil,
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        allowBackgroundExecution: Bool = false
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
    ) async -> RTCRefreshBatchResult {
        var result = RTCRefreshBatchResult()
        guard !Task.isCancelled,
              context.hasIMSession,
              isCurrentRemoteScope(scope) else { return result }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            voiceDebug("refresh_signaling_skip gate=background context=\(Self.rtcDebugContextSummary(context))")
            return result
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard !requiresPendingWakeup || rtcSignalingRefreshPendingScope == scope else { return result }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let generation, rtcRefreshGeneration != generation {
            return result
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        // Direct events-only and calls→events callers hold the real RPC slots too.
        // Keep the wake pending until all pre-existing reads have released them.
        guard rtcSignalingRefreshInFlightScope != scope,
              rtcEventsRefreshInFlightScope != scope,
              rtcCallsRefreshInFlightScope != scope else { return result }
        rtcSignalingRefreshInFlightScope = scope
        defer {
            if rtcSignalingRefreshInFlightScope == scope {
                rtcSignalingRefreshInFlightScope = nil
            }
            schedulePendingRTCSignalingRefresh()
        }
        if rtcSignalingRefreshPendingScope == scope {
            rtcSignalingRefreshPendingScope = nil
        }
        voiceDebug("refresh_signaling_start context=\(Self.rtcDebugContextSummary(context))")
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let delay = discoveryBackoffDelayNanoseconds(for: .events) {
            voiceDebug("events_refresh_skip gate=backoff delay_ms=\(delay / 1_000_000)")
        } else {
            result.events = await refreshRTCCallEventsSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: allowBackgroundExecution
            )
            recordRTCDiscoveryRefreshResult(result.events, endpoint: .events)
        }
        guard !Task.isCancelled,
              isCurrentRemoteScope(scope),
              allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            result.events = .cancelled
            return result
        }
        if let generation, rtcRefreshGeneration != generation {
            result.calls = .cancelled
            return result
        }
        if let delay = discoveryBackoffDelayNanoseconds(for: .calls) {
            voiceDebug("calls_refresh_skip gate=backoff delay_ms=\(delay / 1_000_000)")
        } else {
            result.calls = await refreshRTCCallsSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: allowBackgroundExecution
            )
            recordRTCDiscoveryRefreshResult(result.calls, endpoint: .calls)
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        voiceDebug("refresh_signaling_done context=\(Self.rtcDebugContextSummary(context))")
        return result
    }

    func refreshInboxSilently() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else {
            stopInboxRefreshLoop()
            return
        }
        do {
            let inbox = try await api.listInbox(context: context)
            let announcements = (try? await api.listAnnouncementInbox(context: context)) ?? []
            guard isCurrentRemoteScope(scope) else { return }
            applyInbox(Self.mergedInboxEntries(inbox, announcements))
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            // 收件箱刷新是准实时增强；只有企业访问状态码需要同步入口状态。
            if let securityInfo = securityBlockedInfo(from: error) {
                handleSecurityBlocked(securityInfo)
            } else if let code = workspaceAccessCode(from: error) {
                let affectsCurrent = markWorkspaceAccessBlocked(code)
                if affectsCurrent {
                    disconnectRealtime(shouldReconnect: false)
                    syncFailureMessage = workspaceAccessMessage(for: code)
                    forceWorkspaceSelectionForCurrentAccessBlock(code)
                }
                toast = workspaceAccessMessage(for: code)
            }
        }
    }

    private func refreshInboxAndFriendPresenceSilently() async {
        await refreshInboxSilently()
        guard !Task.isCancelled else { return }
        await refreshFriendPresenceSilently()
    }

    private func refreshFriendPresenceSilently() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        profileContactRevisionFence.rebind(scopeHash: scope)
        let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        guard let relations = try? await api.listFriends(context: context),
              isCurrentRemoteScope(scope) else { return }
        applyFriendRelations(relations, readStamp: readStamp)
    }

#if DEBUG
    func refreshFriendPresenceForTesting() async {
        await refreshFriendPresenceSilently()
    }
#endif

    func toggleDeviceBlocked(_ deviceID: String) {
        guard let index = deviceSessions.firstIndex(where: { $0.id == deviceID }) else { return }
        deviceSessions[index].isBlocked.toggle()
        deviceSessions[index].status = deviceSessions[index].isBlocked ? "已封禁" : "可信设备"
        toast = deviceSessions[index].isBlocked ? "已提交设备封禁" : "已解除设备封禁"
    }

}
