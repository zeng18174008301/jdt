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
    func updateGroupProfile(groupID: String, name: String?, avatarImageData: Data?, mimeType: String = "image/jpeg", width: Int = 512, height: Int = 512) async -> Bool {
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let group = group(id: groupID), canManageGroup(group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅群主或管理员可以编辑群资料")
            return false
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldUpdateName = !trimmedName.isEmpty && trimmedName != group.name
        var avatarFileID: String?

        do {
            if let avatarImageData {
                guard width == height, width >= 128, width <= 2048 else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("头像尺寸不符合要求，请重新裁剪后上传")
                    return false
                }
                guard avatarImageData.count <= 2 * 1024 * 1024 else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("头像图片不能超过 2 MB")
                    return false
                }
                let fileName = mimeType == "image/png" ? "group-avatar.png" : "group-avatar.jpg"
                let presign: RemoteAvatarUploadData
                do {
                    presign = try await api.presignGroupAvatarUpload(
                        context: context,
                        groupID: groupID,
                        fileName: fileName,
                        mimeType: mimeType,
                        sizeBytes: avatarImageData.count,
                        width: width,
                        height: height
                    )
                } catch {
                    throw avatarUploadStageError("获取群头像上传凭证失败", error: error)
                }
                guard isCurrentRemoteScope(scope) else { return false }
                do {
                    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_GROUP_AVATAR_UPLOAD_GUARD - 修改开始：群头像仍要求上传描述，不复用聊天附件 uploaded-without-upload 兼容
                    guard let upload = presign.upload else {
                        throw IMAPIError.server("group_avatar_upload_descriptor_missing")
                    }
                    try await api.uploadGroupAvatarBinary(upload: upload, data: avatarImageData, mimeType: mimeType)
                    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_GROUP_AVATAR_UPLOAD_GUARD - 修改结束
                } catch {
                    throw avatarUploadStageError("群头像图片上传失败", error: error)
                }
                guard isCurrentRemoteScope(scope) else { return false }
                avatarFileID = presign.file.id
            }

            guard shouldUpdateName || avatarFileID != nil else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群资料没有变化")
                return false
            }

            let response: RemoteGroupProfileUpdateResponse
            do {
                response = try await api.updateGroupProfile(
                    context: context,
                    groupID: groupID,
                    name: shouldUpdateName ? trimmedName : nil,
                    avatarFileID: avatarFileID,
                    expectedGroupRevision: group.groupRevision
                )
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return false }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群资料已被其他管理员更新，请核对后重试")
                return false
            } catch {
                throw avatarUploadStageError(avatarFileID == nil ? "保存群资料失败" : "保存群头像资料失败", error: error)
            }
            guard isCurrentRemoteScope(scope) else { return false }
            var mapped = groupInfo(from: response.effectiveGroup, existing: group)
            let committedRevision = response.effectiveGroup.groupRevision
            let acceptsCommittedProfile = group.groupRevision <= 0
                || committedRevision >= group.groupRevision
            if let avatarFileID, acceptsCommittedProfile {
                let committedAvatarPath = authoritativeGroupAvatarPath(response.avatarURL)
                let fallbackAvatarPath = authoritativeGroupAvatarPath(
                    "/api/tenant/avatar/\(avatarFileID.urlPathEncoded)"
                )
                if !committedAvatarPath.isEmpty || !fallbackAvatarPath.isEmpty {
                    mapped.avatarURL = committedAvatarPath.isEmpty ? fallbackAvatarPath : committedAvatarPath
                }
                mapped.avatarVersion = response.avatarVersion.isEmpty ? mapped.avatarVersion : response.avatarVersion
                mapped.avatarUpdatedAt = response.avatarUpdatedAt.isEmpty ? mapped.avatarUpdatedAt : response.avatarUpdatedAt
            }
            if let index = groups.firstIndex(where: { $0.id == groupID }) {
                groups[index] = mapped
            } else {
                groups.append(mapped)
            }
            if let avatarImageData, !mapped.avatarURL.isEmpty {
                storeGroupAvatarImage(avatarImageData, for: mapped)
            }
            ensureGroupConversationExists(mapped)
            await refreshGroupBundle(groupID: groupID, silent: true)
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群资料已更新")
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            let message = userFacingError(error)
            if message.localizedCaseInsensitiveContains("unprocessable")
                || message.localizedCaseInsensitiveContains("尺寸")
                || message.localizedCaseInsensitiveContains("mime")
                || message.localizedCaseInsensitiveContains("format") {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("头像格式或尺寸不符合要求，请重新选择图片")
            } else {
                handleRemoteError(error, fallback: "群资料更新失败")
            }
            return false
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
    func myGroupNickname(groupID: String) -> String {
        contactStore.groupSelfProfiles.snapshot(for: groupMemberProfileCacheKey(groupID: groupID)).nickname
    }

    func myGroupMemberProjection(groupID: String) -> IMUser? {
        contactStore.groupSelfProfiles.snapshot(for: groupMemberProfileCacheKey(groupID: groupID)).member
    }
    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END

    func updateMyGroupNickname(groupID: String, rawValue: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群信息不可用，请刷新后重试")
            return false
        }
        let normalizedNickname: String
        do {
            normalizedNickname = try GroupNicknameInputPolicy.normalize(rawValue)
        } catch let error as GroupNicknameInputError {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(error.userMessage)
            return false
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群昵称格式不正确")
            return false
        }

        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let profileKey = groupMemberProfileCacheKey(groupID: normalizedGroupID, context: context)
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupRefreshEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        let expectedIMUID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let profile = try await api.updateMyGroupNickname(
                context: context,
                groupID: normalizedGroupID,
                groupNickname: normalizedNickname
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return false }
            let responseGroupID = profile.groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard responseGroupID == normalizedGroupID else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群昵称响应与当前群不匹配，请刷新后重试")
                return false
            }
            let responseIMUID = profile.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedIMUID.isEmpty, responseIMUID == expectedIMUID else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群昵称响应与当前账号不匹配，请刷新后重试")
                return false
            }
            groupMemberProfileRefreshEpochByScopedGroupKey[profileKey, default: 0] &+= 1
            let postMutationGroupRefreshEpoch =
                groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
            groupMemberProfileRefreshTasks.removeValue(forKey: profileKey)?.cancel()
            applyMyGroupMemberProfile(profile, fallbackGroupID: normalizedGroupID)
            await refreshGroupBundle(
                groupID: normalizedGroupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: postMutationGroupRefreshEpoch
            ) else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(normalizedNickname.isEmpty ? "群昵称已清除" : "群昵称已更新")
            return true
        } catch {
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return false }
            let normalizedCode = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
            if normalizedCode.contains("invalid_group_nickname") {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群昵称格式不正确，请修改后重试")
            } else if normalizedCode.contains("group_membership_not_found")
                        || isGroupMemberNotFoundMessage(normalizedCode) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("你已不在该群，无法修改群昵称")
            } else {
                handleRemoteError(error, fallback: "群昵称保存失败")
            }
            return false
        }
    }

    func groupMemberProfileCacheKey(groupID: String, context: IMAPIContext? = nil) -> String {
        let resolvedContext = context ?? apiContext
        return "\(remoteDataScopeKey(for: resolvedContext))|\(groupID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func isCurrentGroupMemberProfileRefresh(
        scope: String,
        key: String,
        globalEpoch: UInt64,
        groupEpoch: UInt64
    ) -> Bool {
        isCurrentRemoteScope(scope)
            && groupMemberProfileRefreshEpoch == globalEpoch
            && (groupMemberProfileRefreshEpochByScopedGroupKey[key] ?? 0) == groupEpoch
    }

    func shouldAcceptGroupMemberProfileGeneration(_ generation: Int64, key: String) -> Bool {
        let positiveFloor = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
        guard positiveFloor > 0 else {
            // Compatibility: an older server may omit generations until this
            // scope has observed its first versioned profile.
            return true
        }
        return generation > 0 && generation >= positiveFloor
    }

    func recordAcceptedGroupMemberProfileGeneration(_ generation: Int64, key: String) {
        guard generation > 0 else { return }
        groupMemberProfileGenerationByScopedGroupKey[key] = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            generation
        )
        if generation >= (minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0) {
            minimumGroupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: key)
        }
    }

    func groupMemberProfileGenerationFloor(groupID: String) -> Int64 {
        let key = groupMemberProfileCacheKey(groupID: groupID)
        return max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
    @discardableResult
    func cacheMyGroupSelfProfile(
        nickname: String,
        key: String,
        generation: Int64,
        member: @autoclosure () -> IMUser
    ) -> Bool {
        guard shouldAcceptGroupMemberProfileGeneration(generation, key: key) else { return false }
        let projected = member()
        recordAcceptedGroupMemberProfileGeneration(generation, key: key)
        contactStore.groupSelfProfiles.set(
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            member: projected,
            for: key
        )
        return true
    }

    func applyMyGroupMemberProfile(_ profile: RemoteGroupMemberProfile, fallbackGroupID: String) {
        let groupID = profile.groupID.isEmpty ? fallbackGroupID : profile.groupID
        let generation = max(profile.groupMembershipGeneration, profile.revision)
        let resolvedName = [
            profile.groupNickname,
            profile.rawNickname,
            profile.displayName,
            profile.imUID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "未命名成员"
        guard cacheMyGroupSelfProfile(
            nickname: profile.groupNickname,
            key: groupMemberProfileCacheKey(groupID: groupID),
            generation: generation,
            member: currentUser.withName(resolvedName)
        ) else { return }
        // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END
        // A successful self-profile mutation is authoritative even while the
        // group summary is being materialized or refreshed. Persist the
        // scoped projection before consulting the optional in-memory group so
        // the detail sheet, member list and a subsequently inserted
        // conversation cannot fall back to the stale global nickname.
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let identities = Set([
            profile.imUID,
            apiContext.imUID ?? "",
            currentUser.id,
            currentUser.userID
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        groups[index].members = groups[index].members.map { member in
            identities.contains(member.id) || identities.contains(member.userID)
                ? member.withName(resolvedName)
                : member
        }
        groups[index].admins = groups[index].admins.map { member in
            identities.contains(member.id) || identities.contains(member.userID)
                ? member.withName(resolvedName)
                : member
        }
        conversationStore.setGroupConversationParticipants(
            groupID: groupID,
            groupName: groups[index].name,
            participants: groups[index].members,
            memberCount: shouldShowGroupMemberCount ? groups[index].effectiveMemberCount : nil
        )
    }

    func resolvedAvatarURL(from rawValue: String, fileID: String) -> String {
        let resolved = resolveTenantAssetURL(rawValue)
        if !resolved.isEmpty {
            return resolved
        }
        let trimmedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFileID.isEmpty else { return "" }
        return resolveTenantAssetURL("/api/tenant/avatar/\(trimmedFileID.urlPathEncoded)")
    }

    func authoritativeGroupAvatarPath(_ rawValue: String) -> String {
        guard let request = TenantRelativeImageURLResolver.request(
            rawValue,
            routeContext: avatarImageRouteContext
        ), case let .tenantRelative(relativeValue) = request,
              let parsed = URL(string: relativeValue),
              parsed.host == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              TenantRelativeImageURLResolver.isStableTenantAvatarPath(parsed.path) else {
            return ""
        }
        return parsed.path
    }

    private func storeGroupAvatarImage(_ data: Data, for group: GroupInfo) {
        let cacheKey = groupAvatarCacheKey(
            groupID: group.id,
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt
        )
        guard !cacheKey.isEmpty,
              let request = TenantRelativeImageURLResolver.request(
                group.avatarURL,
                routeContext: avatarImageRouteContext
              ),
              let storageKey = request.storageCacheKey(
                cacheKey,
                routeContext: avatarImageRouteContext
              ) else {
            return
        }
        AvatarImageCache.shared.store(data, for: storageKey)
    }

    func avatarUploadStageError(_ stage: String, error: Error) -> IMAPIError {
        let detail = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return .server(stage) }
        if detail.localizedCaseInsensitiveContains(stage) {
            return .server(detail)
        }
        return .server("\(stage)：\(detail)")
    }

}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
