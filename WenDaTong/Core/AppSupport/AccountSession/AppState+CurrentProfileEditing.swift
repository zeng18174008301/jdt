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

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
@MainActor
final class CurrentUserPresentationStore {
    struct Identity: Equatable {
        let id: String
        let userID: String
        let username: String
    }

    // Keep the complete user value for existing display helpers. Equality only
    // includes public presentation inputs; private profile changes stay in Me.
    struct Display: Equatable {
        let user: IMUser

        static func == (lhs: Self, rhs: Self) -> Bool {
            let a = lhs.user
            let b = rhs.user
            return a.id == b.id && a.userID == b.userID && a.username == b.username
                && a.name == b.name && a.title == b.title
                && a.department == b.department && a.departmentPathNames == b.departmentPathNames
                && a.status == b.status && a.enterprise == b.enterprise
                && a.avatarSeed == b.avatarSeed && a.avatarURL == b.avatarURL
                && a.avatarVersion == b.avatarVersion && a.avatarUpdatedAt == b.avatarUpdatedAt
                && a.badges == b.badges
        }
    }

    @Published fileprivate(set) var user = IMUser(id: "pending", name: "正在同步", title: "", department: "", phone: "", email: "", status: "同步中", enterprise: "正在同步企业", avatarSeed: 0x5D6BFF, badges: [])

    struct Phone: Equatable {
        let value: String
        let verified: Bool
    }

    struct Verification: Equatable {
        let status: String
        let verified: Bool
    }

    // Consumers receive the original value, with emissions scoped to the fields
    // they display. Action handlers continue reading the live AppState facade.
    func updates<Key: Equatable>(on project: @escaping (IMUser) -> Key) -> AnyPublisher<IMUser, Never> {
        $user.removeDuplicates { project($0) == project($1) }.eraseToAnyPublisher()
    }

    static func phone(_ user: IMUser) -> Phone { Phone(value: user.phone, verified: user.phoneVerified) }
    static func verification(_ user: IMUser) -> Verification {
        Verification(status: user.realNameStatus, verified: user.realNameVerified)
    }

    func updates<Value: Equatable>(_ project: @escaping (IMUser) -> Value) -> AnyPublisher<Value, Never> {
        $user.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (IMUser) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(user), updates: updates(project), content: content)
    }

    static func identity(_ user: IMUser) -> Identity {
        Identity(id: user.id, userID: user.userID, username: user.username)
    }

    static func display(_ user: IMUser) -> Display { Display(user: user) }
}

private struct CurrentUserDisplayEnvironmentKey: EnvironmentKey {
    static let defaultValue: IMUser? = nil
}

extension EnvironmentValues {
    var currentUserDisplay: IMUser? {
        get { self[CurrentUserDisplayEnvironmentKey.self] }
        set { self[CurrentUserDisplayEnvironmentKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
    func setCurrentUser(_ user: IMUser) {
        currentUserPresentationStore.user = user
        let overlaid = presentationOverlaidUser(currentUser)
        if overlaid != currentUser {
            currentUserPresentationStore.user = overlaid
        }
        if !suppressCurrentUserIdentityPersistence {
            persistCurrentUserIdentityIfPossible()
        }
    }
    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

    private func applyCurrentUserProfileLocally(
        name: String? = nil,
        username: String? = nil,
        avatarSeed: UInt? = nil,
        avatarURL: String? = nil,
        avatarVersion: String? = nil,
        avatarUpdatedAt: String? = nil
    ) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName?.isEmpty == false ? trimmedName! : currentUser.name
        let nextUsername = trimmedUsername ?? currentUser.username
        let trimmedAvatarURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAvatarURL = trimmedAvatarURL.map { resolveTenantAssetURL($0) }
        let nextAvatarVersion = avatarVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAvatarUpdatedAt = avatarUpdatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appliedAvatarVersion = nextAvatarVersion?.isEmpty == false
            ? nextAvatarVersion!
            : currentUser.avatarVersion
        let appliedAvatarUpdatedAt = nextAvatarUpdatedAt?.isEmpty == false
            ? nextAvatarUpdatedAt!
            : currentUser.avatarUpdatedAt

        setCurrentUser(IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: nextUsername,
            name: nextName,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            enterprise: currentUser.enterprise,
            avatarSeed: avatarSeed ?? currentUser.avatarSeed,
            avatarURL: resolvedAvatarURL?.isEmpty == false ? resolvedAvatarURL! : currentUser.avatarURL,
            avatarVersion: appliedAvatarVersion,
            avatarUpdatedAt: appliedAvatarUpdatedAt,
            badges: currentUser.badges
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        if let resolvedAvatarURL, !resolvedAvatarURL.isEmpty {
            propagateCurrentUserAvatarLocally(
                resolvedAvatarURL,
                avatarVersion: appliedAvatarVersion,
                avatarUpdatedAt: appliedAvatarUpdatedAt
            )
        }
    }

    func resolveTenantAssetURL(_ rawValue: String, context: IMAPIContext? = nil) -> String {
        api.resolveTenantAssetURL(rawValue, context: context ?? apiContext)
    }

    private func propagateCurrentUserAvatarLocally(_ avatarURL: String, avatarVersion: String = "", avatarUpdatedAt: String = "") {
        let trimmedAvatarURL = avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAvatarURL.isEmpty else { return }
        let trimmedVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = currentUserIdentitySet()

        func updatedAvatarUser(_ user: IMUser) -> IMUser {
            guard userIdentityCandidates(for: user).contains(where: { currentIDs.contains($0) }) else {
                return user
            }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: user.username,
                name: user.name,
                title: user.title,
                department: user.department,
                departmentPathNames: user.departmentPathNames,
                phone: user.phone,
                phoneVerified: user.phoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.email,
                status: user.status,
                enterprise: user.enterprise,
                avatarSeed: user.avatarSeed,
                avatarURL: trimmedAvatarURL,
                avatarVersion: trimmedVersion.isEmpty ? user.avatarVersion : trimmedVersion,
                avatarUpdatedAt: trimmedUpdatedAt.isEmpty ? user.avatarUpdatedAt : trimmedUpdatedAt,
                badges: user.badges
            )
        }

        contacts = contacts.map(updatedAvatarUser)
        for index in groups.indices {
            groups[index].members = groups[index].members.map(updatedAvatarUser)
            groups[index].admins = groups[index].admins.map(updatedAvatarUser)
        }
        conversationStore.updateConversationParticipants(updatedAvatarUser)
    }

    private func recordCurrentUserAvatarCommitAuthority(
        context: IMAPIContext,
        resolvedAvatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) {
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionUID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUID = currentUser.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = sessionUID.isEmpty ? currentUID : sessionUID
        guard !tenantID.isEmpty, !uid.isEmpty else { return }

        let retired = avatarRealtimeProjection.retireExactUIDAfterLocalCommit(uid)
        let checkpoint = currentProfileAuthorityCheckpoint()
        avatarLocalCommitAuthorityFence.record(
            tenantID: tenantID,
            uid: uid,
            resolvedURL: resolvedAvatarURL,
            cacheVersion: avatarVersion,
            updatedAt: avatarUpdatedAt,
            minimumRemoteRevision: max(
                retired?.revision ?? 0,
                checkpoint?.userRevision ?? 0
            ),
            minimumRemoteGeneration: max(
                retired?.generation ?? 0,
                checkpoint?.identityGeneration ?? 0
            )
        )
        _ = beginCurrentProfileMutation(context: context)
        avatarSearchPresentationStore.revision &+= 1 // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110
        queueAvatarAuthorityRefetch([uid])
    }

    func replaceCurrentUserAndProject(_ nextUser: IMUser, persistIdentity: Bool = true) {
        let previousIdentity = currentUserIdentitySet()

        func projected(_ user: IMUser) -> IMUser {
            guard userIdentityCandidates(for: user).contains(where: { previousIdentity.contains($0) }) else {
                return user
            }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: nextUser.username.isEmpty ? user.username : nextUser.username,
                name: nextUser.name,
                title: nextUser.title,
                department: nextUser.department,
                departmentPathNames: nextUser.departmentPathNames,
                phone: nextUser.phone,
                phoneVerified: nextUser.phoneVerified,
                realNameVerified: nextUser.realNameVerified,
                realNameStatus: nextUser.realNameStatus,
                email: nextUser.email,
                status: nextUser.status,
                lastLoginAt: nextUser.lastLoginAt,
                enterprise: nextUser.enterprise,
                avatarSeed: nextUser.avatarSeed,
                avatarURL: nextUser.avatarURL,
                avatarVersion: nextUser.avatarVersion,
                avatarUpdatedAt: nextUser.avatarUpdatedAt,
                badges: nextUser.badges
            )
        }

        suppressCurrentUserIdentityPersistence = !persistIdentity
        setCurrentUser(nextUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        suppressCurrentUserIdentityPersistence = false
        contacts = contacts.map(projected)
        for index in groups.indices {
            groups[index].members = groups[index].members.map(projected)
            groups[index].admins = groups[index].admins.map(projected)
        }
        conversationStore.updateConversationParticipants(projected)
    }

    private func rollbackCurrentUserProfileIfCurrent(
        _ previousUser: IMUser,
        ticket: ProfileContactMutationTicket,
        scope: String
    ) {
        guard isCurrentRemoteScope(scope),
              profileContactRevisionFence.isCurrent(ticket) else { return }
        replaceCurrentUserAndProject(previousUser)
    }

    func updateCurrentUserProfile(name: String? = nil, username: String? = nil) async -> Bool {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedUsername = trimmedUsername ?? ""
        let currentUsername = currentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard trimmedName?.isEmpty == false || trimmedUsername?.isEmpty == false else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入要保存的资料")
            return false
        }
        if let trimmedUsername, !trimmedUsername.isEmpty, !currentUsername.isEmpty, trimmedUsername != currentUsername {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户账号已设置，如需修改请联系管理员/商户后台处理。")
            return false
        }
        if let trimmedUsername, !trimmedUsername.isEmpty, !isValidAccountUsername(trimmedUsername) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号必须为 5-10 位数字或英文字母")
            return false
        }
        guard let mutationRequest = beginCurrentProfileMutation(context: context) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        profileContactRevisionFence.rebind(scopeHash: scope)
        guard let projectionTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: ["profile:self"]
        ) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重试保存资料")
            return false
        }
        let previousUser = currentUser
        let optimisticUser = IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: trimmedUsername ?? currentUser.username,
            name: trimmedName ?? currentUser.name,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            lastLoginAt: currentUser.lastLoginAt,
            enterprise: currentUser.enterprise,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: currentUser.avatarURL,
            avatarVersion: currentUser.avatarVersion,
            avatarUpdatedAt: currentUser.avatarUpdatedAt,
            badges: currentUser.badges
        )
        replaceCurrentUserAndProject(optimisticUser, persistIdentity: false)

        do {
            let profile = try await api.updateMeProfile(context: context, nickname: trimmedName, username: trimmedUsername)
            guard isCurrentRemoteScope(scope),
                  profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            let responseUsername = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUsername != nil,
               !responseUsername.isEmpty,
               responseUsername.localizedCaseInsensitiveCompare(requestedUsername) != .orderedSame {
                rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
                await refreshRemoteSnapshot(silent: true, force: true)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户账号保存失败，请稍后重试")
                return false
            }
            var acceptedProfile = applyMeProfile(
                profile,
                authorityRequest: mutationRequest,
                usernameFallback: trimmedUsername,
                nicknameFallback: trimmedName
            )
            if let readbackRequest = beginCurrentProfileRead(context: context) {
                do {
                    let readback = try await api.meProfile(context: context)
                    guard isCurrentRemoteScope(scope),
                          profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
                    if applyMeProfile(readback, authorityRequest: readbackRequest) {
                        acceptedProfile = true
                    }
                } catch {
                    logSyncEndpointFailure("/api/tenant/me/profile", error: error)
                }
            }
            guard profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            guard acceptedProfile else {
                rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
                await refreshRemoteSnapshot(silent: true, force: true)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("个人资料保存失败，请稍后重试")
                return false
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(trimmedUsername != nil && trimmedName == nil ? "用户账号已更新" : "个人资料已更新")
            return true
        } catch IMAPIError.conflict(let code, _) where code.localizedCaseInsensitiveCompare("user_account_locked") == .orderedSame {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户账号已设置，如需修改请联系管理员/商户后台处理。")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.conflict(let code, _) where isUserAccountFormatErrorCode(code) {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号必须为 5-10 位数字或英文字母")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.conflict {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户账号已被占用")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.server(let message) where message.localizedCaseInsensitiveContains("invalid_account_format")
            || message.localizedCaseInsensitiveContains("invalid_user_account_format")
            || message.localizedCaseInsensitiveContains("5-10") {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号必须为 5-10 位数字或英文字母")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch IMAPIError.server(let message) where message.localizedCaseInsensitiveContains("validation_error")
            || message.localizedCaseInsensitiveContains("username") {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户账号格式不正确")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        } catch {
            guard isCurrentRemoteScope(scope), profileContactRevisionFence.isCurrent(projectionTicket) else { return false }
            rollbackCurrentUserProfileIfCurrent(previousUser, ticket: projectionTicket, scope: scope)
            handleRemoteError(error, fallback: "个人资料保存失败")
            await refreshRemoteSnapshot(silent: true, force: true)
            return false
        }
    }

    func changeMyPassword(currentPassword: String, newPassword: String) async -> Bool {
        let current = currentPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入当前密码")
            return false
        }
        guard next.count >= 8, next.count <= 20,
              next.rangeOfCharacter(from: .letters) != nil,
              next.rangeOfCharacter(from: .decimalDigits) != nil else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("新密码需为8-20位并包含字母和数字")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        do {
            let result = try await api.changeMyPassword(context: context, currentPassword: current, newPassword: next)
            guard isCurrentRemoteScope(scope) else { return false }
            if let profile = result.profile {
                applyMeProfile(profile, authorityRequest: profileAuthorityRequest)
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("密码已更新")
            return result.updated || result.sessionRemainsActive
        } catch IMAPIError.unauthorized(let message) where message.contains("当前密码") || message.localizedCaseInsensitiveContains("current_password_incorrect") {
            guard isCurrentRemoteScope(scope) else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前密码错误")
            return false
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
            if code.contains("current_password_incorrect") || code.contains("当前密码") {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前密码错误")
            } else if code.contains("weak_password") {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("新密码需为8-20位并包含字母和数字")
            } else if code.contains("workspace_directory_unavailable") || code.contains("account_password_sync_failed") {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("密码同步暂不可用，请稍后重试")
            } else {
                handleRemoteError(error, fallback: "密码保存失败，请稍后重试")
            }
            return false
        }
    }

    func uploadCurrentUserAvatar(imageData: Data, mimeType: String, width: Int, height: Int) async -> Bool {
        await uploadCurrentUserAvatarResult(
            imageData: imageData,
            mimeType: mimeType,
            width: width,
            height: height
        ).success
    }

    func uploadCurrentUserAvatarResult(
        imageData: Data,
        mimeType: String,
        width: Int,
        height: Int
    ) async -> AvatarUploadResult {
        guard !imageData.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择头像图片")
            return .failed(.unknown, safeCode: "empty_image")
        }
        guard imageData.count <= 2 * 1024 * 1024 else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("头像图片不能超过 2 MB")
            return .failed(.unknown, safeCode: "image_too_large")
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return .failed(.unknown, safeCode: "missing_session")
        }
        let scope = remoteDataScopeKey(for: context)
        let fileName = mimeType == "image/png" ? "avatar.png" : "avatar.jpg"
        let presign: RemoteAvatarUploadData
        do {
            presign = try await api.presignAvatarUpload(
                context: context,
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: imageData.count,
                width: width,
                height: height
            )
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .presign, label: "获取头像上传凭证失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        do {
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_AVATAR_UPLOAD_GUARD - 修改开始：头像仍要求后端返回上传描述，避免公共媒体兼容影响既有头像流程
            guard let upload = presign.upload else {
                throw IMAPIError.server("avatar_upload_descriptor_missing")
            }
            try await api.uploadAvatarBinary(upload: upload, data: imageData, mimeType: mimeType)
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_AVATAR_UPLOAD_GUARD - 修改结束
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .put, label: "头像图片上传失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        let commit: RemoteAvatarCommitData
        do {
            commit = try await api.commitAvatar(context: context, fileID: presign.file.id)
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
            return avatarUploadFailure(stage: .commit, label: "保存头像资料失败", error: error)
        }
        guard isCurrentRemoteScope(scope) else { return .failed(.unknown, safeCode: "scope_changed") }
        let avatarURL = commit.avatarURL.isEmpty ? commit.profile.avatar : commit.avatarURL
        let resolvedAvatarURL = resolvedAvatarURL(from: avatarURL, fileID: presign.file.id)
        guard !resolvedAvatarURL.isEmpty else {
            return avatarUploadFailure(
                stage: .commit,
                label: "保存头像资料失败",
                error: IMAPIError.server("后端未返回头像地址")
            )
        }
        AvatarImageCache.shared.store(imageData, for: resolvedAvatarURL)
        let avatarCacheKey = AvatarImageCache.cacheKey(
            url: resolvedAvatarURL,
            version: commit.avatarVersion,
            updatedAt: commit.avatarUpdatedAt
        )
        AvatarImageCache.shared.store(imageData, for: avatarCacheKey)
        recordCurrentUserAvatarCommitAuthority(
            context: context,
            resolvedAvatarURL: resolvedAvatarURL,
            avatarVersion: commit.avatarVersion,
            avatarUpdatedAt: commit.avatarUpdatedAt
        )
        applyCurrentUserProfileLocally(
            avatarURL: resolvedAvatarURL,
            avatarVersion: commit.avatarVersion,
            avatarUpdatedAt: commit.avatarUpdatedAt
        )
        Task { await refreshRemoteSnapshot(silent: true, force: true) }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("头像已更新")
        return .succeeded
    }

    private func avatarUploadFailure(
        stage: AvatarUploadFailureStage,
        label: String,
        error: Error
    ) -> AvatarUploadResult {
        handleRemoteError(avatarUploadStageError(label, error: error), fallback: "头像上传失败")
        let metadata = Self.avatarUploadFailureMetadata(error)
        return .failed(stage, safeCode: metadata.safeCode, status: metadata.status)
    }

    nonisolated static func avatarUploadFailureMetadata(_ error: Error) -> (safeCode: String?, status: Int?) {
        let rawCode: String?
        var status: Int?
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .businessForbidden(let code, _, _), .conflict(let code, _),
                 .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
                rawCode = code
            case .httpStatus(let value, _):
                rawCode = "http_status"
                status = value
            case .missingContext:
                rawCode = "missing_context"
            case .badURL:
                rawCode = "invalid_url"
            case .unauthorized:
                rawCode = "unauthorized"
            case .forbidden:
                rawCode = "forbidden"
            case .forcedAuthRequired:
                rawCode = "forced_auth_required"
            case .server(let message):
                rawCode = "server_error"
                status = httpStatusFromSafeMessage(message)
            case .securityBlocked:
                rawCode = "security_blocked"
            case .emptyResponse:
                rawCode = "empty_response"
            }
        } else if let urlError = error as? URLError {
            rawCode = urlError.code == .timedOut ? "network_timeout" : "network_error"
        } else {
            rawCode = "unknown"
        }
        let code = rawCode.flatMap(sanitizedAvatarUploadSafeCode) ?? "unknown"
        return (code, status.flatMap { (100...599).contains($0) ? $0 : nil })
    }

    nonisolated private static func sanitizedAvatarUploadSafeCode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
                      || scalar.value == 95 || scalar.value == 45 || scalar.value == 46
              }) else { return nil }
        return value
    }

    nonisolated private static func httpStatusFromSafeMessage(_ message: String) -> Int? {
        let tokens = message.uppercased().split { !$0.isLetter && !$0.isNumber }
        for index in tokens.indices where tokens[index] == "HTTP" {
            let next = tokens.index(after: index)
            if next < tokens.endIndex, let status = Int(tokens[next]), (100...599).contains(status) {
                return status
            }
        }
        return nil
    }

}
