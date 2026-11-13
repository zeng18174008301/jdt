import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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
    func scheduleConversationSnapshotCacheWrite(
        conversationID: String,
        scope: String,
        source: LocalMessageProjectionSource = .localMutation
    ) {
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：单会话本地变更快照投影放到后台，AppState 保留状态入口
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        let input = localMessageProjectionInput(from: cacheableConversation)
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: source,
            projectionInputs: [input],
            actorID: actorID,
            localMutationWindowed: true,
            replaceMissingConversations: false
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
    func persistConversationSnapshotImmediately(
        conversationID: String,
        scope: String,
        source: LocalMessageProjectionSource
    ) async {
        // Other history and local mutation callers retain their best-effort behavior.
        _ = try? await commitConversationSnapshot(conversationID: conversationID,
            scope: scope, source: source, retryProjectionContention: false, isCurrent: { true })
    }

    func commitConversationSnapshot(
        conversationID: String,
        scope: String,
        source: LocalMessageProjectionSource,
        retryProjectionContention: Bool,
        isCurrent: @MainActor () -> Bool
    ) async throws -> Int64 {
        let context = apiContext
        let generation = localMessageSessionGeneration
        func isAdmitted() -> Bool {
            isCurrent() && generation == localMessageSessionGeneration && isCurrentRemoteScope(scope)
        }
        let attempts = retryProjectionContention ? 3 : 1
        for attempt in 0..<attempts {
            guard isAdmitted(), let conversation = conversationStore.conversationMessageSnapshot(id: conversationID)
            else { throw CancellationError() }
            let cacheable = shouldShowGroupMemberCount ? conversation : conversation.scrubbingGroupMemberTotals()
            let input = localMessageProjectionInput(from: cacheable, projectedMessages: cacheable.messages)
            let actorID = (context.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let revision = nextLocalMessageProjectionRevision()
            let existingTicket = localMessageTicket
#if DEBUG
            if retryProjectionContention {
                await realtimeComputeRuntime.beforeRecoveryProjection?(conversationID, revision)
                guard isAdmitted() else { throw CancellationError() }
            }
#endif
            let snapshot = await LocalMessageProjectionBuilder.snapshotOffMain(from: input, actorID: actorID)
            guard isAdmitted() else { throw CancellationError() }
            let ticket: LocalMessageSessionTicket
            if let existingTicket {
                ticket = existingTicket
            } else {
                ticket = try await messagePersistence.ensureTicket(context: context, sessionGeneration: generation)
            }
            guard isAdmitted(), ticket.sessionGeneration == generation else { throw CancellationError() }
            let metrics: LocalMessageMergeMetrics
            do {
                metrics = try await messagePersistence.persist(ticket: ticket, snapshots: [snapshot],
                    source: source, revision: revision, replaceMissingConversations: false)
            } catch LocalMessageDatabaseError.staleSession where attempt + 1 < attempts {
                guard isAdmitted() else { throw CancellationError() }
                // This read checks the exact ticket before and after SQLite. A retired
                // writer cannot be retried. The next iteration captures current rows.
                let floor = try await messagePersistence.projectionRevisionFloor(ticket: ticket)
                guard isAdmitted() else { throw CancellationError() }
                guard floor > revision else { throw LocalMessageDatabaseError.staleSession }
                localMessageProjectionRevision = max(localMessageProjectionRevision, floor)
                continue
            }
            guard isAdmitted() else { throw CancellationError() }
            localMessageTicket = ticket
            // A committed transaction with a message identity conflict may retain
            // the old contiguous sequence. Its requested coverage is unconfirmed.
            guard metrics.conflict == 0 else { throw LocalMessageDatabaseError.identityConflict }
            return snapshot.metadata.messageCoveredThroughSeq ?? 0
        }
        throw LocalMessageDatabaseError.staleSession
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END

    func scheduleLocalMutationSnapshotCacheWriteForVisibleConversations(scope: String) {
        guard isCurrentRemoteScope(scope) else { return }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：全部可见会话本地变更快照投影延后到后台任务
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversationStore.conversationMessageSnapshots()
            : conversationStore.conversationMessageSnapshots().map { $0.scrubbingGroupMemberTotals() }
        let lookup = makeConversationUserLookup()
        let inputs = cacheableConversations.map { conversation in
            localMessageProjectionInput(from: conversation, lookup: lookup)
        }
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: .localMutation,
            projectionInputs: inputs,
            actorID: actorID,
            localMutationWindowed: true,
            replaceMissingConversations: false
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    func scheduleRemoteSnapshotCacheWrite(
        scope: String,
        source: LocalMessageProjectionSource = .localMutation,
        replaceMissingConversations: Bool = false
    ) {
        guard isCurrentRemoteScope(scope),
              !conversationStore.conversations.isEmpty || replaceMissingConversations else { return }
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversationStore.conversationMessageSnapshots()
            : conversationStore.conversationMessageSnapshots().map { $0.scrubbingGroupMemberTotals() }
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：远端快照缓存写入前的批量投影放到后台
        let lookup = makeConversationUserLookup()
        let inputs = cacheableConversations.map { conversation in
            localMessageProjectionInput(from: conversation, lookup: lookup)
        }
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleLocalMessageProjectionWrite(
            scope: scope,
            source: source,
            projectionInputs: inputs,
            actorID: actorID,
            replaceMissingConversations: replaceMissingConversations
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    private func scheduleLocalMessageProjectionWrite(
        scope: String,
        source: LocalMessageProjectionSource,
        snapshots: [LocalMessageConversationSnapshot],
        replaceMissingConversations: Bool
    ) {
        guard isCurrentRemoteScope(scope),
              !snapshots.isEmpty || replaceMissingConversations else { return }
        let context = apiContext
        let generation = localMessageSessionGeneration
        let revision = nextLocalMessageProjectionRevision()
        let existingTicket = localMessageTicket
        Task { [weak self] in
            guard let self else { return }
            do {
                let ticket: LocalMessageSessionTicket
                if let existingTicket {
                    ticket = existingTicket
                } else {
                    ticket = try await self.messagePersistence.ensureTicket(
                        context: context,
                        sessionGeneration: generation
                    )
                }
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                _ = try await self.messagePersistence.persist(
                    ticket: ticket,
                    snapshots: snapshots,
                    source: source,
                    revision: revision,
                    replaceMissingConversations: replaceMissingConversations
                )
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                self.localMessageTicket = ticket
            } catch {
                // The online server remains authoritative; a later sync can retry persistence.
            }
        }
    }

    // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改开始：快照投影可先在后台完成，再复用原有持久化流程
    private func scheduleLocalMessageProjectionWrite(
        scope: String,
        source: LocalMessageProjectionSource,
        projectionInputs: [LocalMessageProjectionInput],
        actorID: String,
        localMutationWindowed: Bool = false,
        requiresServerRevalidation: Bool = false,
        replaceMissingConversations: Bool
    ) {
        guard isCurrentRemoteScope(scope),
              !projectionInputs.isEmpty || replaceMissingConversations else { return }
        let context = apiContext
        let generation = localMessageSessionGeneration
        let revision = nextLocalMessageProjectionRevision()
        let existingTicket = localMessageTicket
        Task { [weak self, projectionInputs, actorID] in
            let snapshots: [LocalMessageConversationSnapshot]
            if localMutationWindowed {
                snapshots = await LocalMessageProjectionBuilder.localMutationSnapshotsOffMain(
                    from: projectionInputs,
                    actorID: actorID
                )
            } else {
                snapshots = await LocalMessageProjectionBuilder.snapshotsOffMain(
                    from: projectionInputs,
                    actorID: actorID,
                    requiresServerRevalidation: requiresServerRevalidation
                )
            }
            guard let self else { return }
            guard generation == self.localMessageSessionGeneration,
                  self.isCurrentRemoteScope(scope),
                  !snapshots.isEmpty || replaceMissingConversations else { return }
            do {
                let ticket: LocalMessageSessionTicket
                if let existingTicket {
                    ticket = existingTicket
                } else {
                    ticket = try await self.messagePersistence.ensureTicket(
                        context: context,
                        sessionGeneration: generation
                    )
                }
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                _ = try await self.messagePersistence.persist(
                    ticket: ticket,
                    snapshots: snapshots,
                    source: source,
                    revision: revision,
                    replaceMissingConversations: replaceMissingConversations
                )
                guard generation == self.localMessageSessionGeneration,
                      self.isCurrentRemoteScope(scope) else { return }
                self.localMessageTicket = ticket
            } catch {
                // The online server remains authoritative; a later sync can retry persistence.
            }
        }
    }
    // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_ASYNC_PERF_20260912 - 修改结束

    func userFacingError(_ error: Error) -> String {
        if DeviceRevocationDetector.matches(error: error) {
            return DeviceRevocationDetector.logoutMessage
        }
        if let securityInfo = securityBlockedInfo(from: error) {
            return securityInfo.userMessage
        }
        if let mutedMessage = sendPolicyMutedMessage(from: error) {
            return mutedMessage
        }
        if let quotaMessage = licenseQuotaUserMessage(from: error) {
            return quotaMessage
        }
        if let code = workspaceAccessCode(from: error) {
            return workspaceAccessMessage(for: code)
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .missingContext(_):
                return "缺少登录会话，请重新登录"
            case .badURL(_):
                return "接口地址配置错误"
            case .unauthorized(_):
                return "登录已失效，请重新登录"
            case .forcedAuthRequired(let requirement):
                return requirement.promptMessage
            case .securityBlocked(let info):
                return info.userMessage
            case .forbidden(let message):
                // WDT_RECEIPT_DETAIL_SCOPE_20261023: legacy unstructured denial is neutral too.
                if message.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() == "permission_denied" {
                    return "无权限执行该操作"
                }
                if message.contains("account_locked") || message.contains("账号已锁定") {
                    return "账号已锁定，请联系商户后台管理员解锁"
                }
                if message.contains("blocked_by_me") {
                    return "你已拉黑对方，无法发送消息"
                }
                if message.contains("blocked_by_target") || message.contains("message_rejected_by_target") || message.contains("消息拒收") {
                    return "消息已被对方拒收"
                }
                if message.contains("workspace_identity_unlinked") {
                    return "当前 IM 用户未绑定平台账号，暂不能切换或加入企业"
                }
                if message.contains("account_disabled") || message.contains("账号已停用") {
                    return "账号已停用，请联系管理员"
                }
                if message.contains("tenant_member_disabled") || message.contains("成员已停用") {
                    return "当前企业成员关系已停用，请切换其他企业"
                }
                if isGroupMemberNotFoundMessage(message) {
                    return groupMemberNotFoundText
                }
                if message.contains("tenant_member_not_found") {
                    return "当前企业成员关系不存在，请切换其他企业"
                }
                if message.contains("tenant_service_stopped") || message.contains("企业已停用") {
                    return "当前企业已停用，请切换其他企业"
                }
                if message.contains("tenant_service_unavailable") || message.contains("企业服务暂不可用") {
                    return "当前企业服务暂不可用，请切换其他企业或稍后重试"
                }
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: message) {
                    return groupLifecycleMessage
                }
                if isMessagePinForbiddenMessage(message) {
                    return messagePinForbiddenText
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                return sanitizeBackendMessage(message, fallback: "无权限执行该操作")
            case .businessForbidden(let code, let message, _):
                let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch normalizedCode {
                // WDT_RECEIPT_DETAIL_SCOPE_20261023: generic permissions have no group lifecycle context.
                case "permission_denied":
                    return "无权限执行该操作"
                case "phone_auth_disabled":
                    return PhoneAuthPresentationPolicy.disabledMessage
                case "group_member_muted":
                    return Self.groupMemberMutedMessage
                case "group_mute_permission_denied":
                    return "禁言名单仅群主或管理员可操作"
                case "group_mute_target_role_not_allowed":
                    return "群主或管理员不能加入禁言名单"
                case "friend_application_cancel_forbidden":
                    return "仅申请发起者可取消该好友申请"
                case "group_owner_transfer_forbidden":
                    return "仅当前群主可以转让群主"
                case "workspace_switch_disabled":
                    return "管理员已关闭企业切换"
                case "tenant_code_required":
                    return "请输入企业编码或邀请码"
                case "entry_code_invalid":
                    return "请输入有效的企业编码或邀请码"
                case "tenant_code_not_found":
                    return "该企业不存在"
                case "identity_prefix_conflict", "enterprise_code_conflict":
                    return "企业身份编码发生冲突，请联系平台管理员"
                case "identity_prefix_locked":
                    return "企业身份前缀已锁定，请联系平台管理员"
                case "user_id_namespace_exhausted", "user_id_idempotency_conflict":
                    return "用户身份暂无法分配，请稍后重试或联系管理员"
                case "member_invite_code_generation_exhausted":
                    return "邀请码暂无法生成，请稍后重试或联系管理员"
                case "member_invite_code_invalid",
                     "member_invite_code_disabled",
                     "member_invite_code_inviter_inactive",
                     "member_invite_code_role_not_allowed",
                     "member_invite_code_app_not_bound":
                    return "邀请码无效或已停用"
                case "member_invite_code_sync_pending",
                     "member_invite_code_sync_unavailable",
                     "member_invite_code_tenant_unavailable",
                     "member_invite_code_unavailable":
                    return "邀请码暂不可用于注册"
                case "member_invite_code_tenant_conflict":
                    return "邀请码和企业不匹配"
                case "registration_tenant_code_probe_rate_limited":
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                case "registered_user_quota_exceeded",
                     "online_quota_exceeded",
                     "online_quota_service_unavailable",
                     "group_member_quota_exceeded":
                    return IMAPIClient.licenseQuotaUserMessage(for: normalizedCode)
                default:
                    break
                }
                if let capabilityMessage = capabilityUserMessage(for: normalizedCode) {
                    return capabilityMessage
                }
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: "\(normalizedCode) \(message)") {
                    return groupLifecycleMessage
                }
                if isGroupMemberNotFoundMessage("\(normalizedCode) \(message)") {
                    return groupMemberNotFoundText
                }
                if let accessCode = workspaceAccessCode(from: normalizedCode) {
                    return workspaceAccessMessage(for: accessCode)
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                return sanitizeBackendMessage(message, fallback: "无权限执行该操作")
            case .conflict(let code, let message):
                switch code {
                case "workspace_join_pending":
                    return "入企申请等待审批中"
                case "workspace_join_rejected":
                    return "入企申请已被拒绝，请联系企业管理员"
                case "workspace_join_approved":
                    return "入企申请已通过"
                case "workspace_already_joined":
                    return "已加入该企业"
                case "workspace_join_forbidden":
                    return "当前账号暂不能申请加入该企业"
                case "workspace_tenant_unresolved":
                    return "企业信息暂未同步，请稍后重试"
                case "workspace_directory_unavailable":
                    return "企业目录暂不可用，请稍后重试"
                case "workspace_join_conflict":
                    return "入企申请状态冲突，请刷新后重试"
                case "workspace_join_bad_request", "bad_workspace_join_request":
                    return "入企申请参数不正确，请重新搜索后再试"
                case "workspace_switch_failed":
                    return "企业存在，但切换失败"
                case "workspace_switch_disabled":
                    return "管理员已关闭企业切换"
                case "tenant_code_required":
                    return "请输入企业编码或邀请码"
                case "entry_code_invalid":
                    return "请输入有效的企业编码或邀请码"
                case "tenant_code_not_found":
                    return "该企业不存在"
                case "identity_prefix_conflict", "enterprise_code_conflict":
                    return "企业身份编码发生冲突，请联系平台管理员"
                case "identity_prefix_locked":
                    return "企业身份前缀已锁定，请联系平台管理员"
                case "user_id_namespace_exhausted", "user_id_idempotency_conflict":
                    return "用户身份暂无法分配，请稍后重试或联系管理员"
                case "member_invite_code_generation_exhausted":
                    return "邀请码暂无法生成，请稍后重试或联系管理员"
                case "member_invite_code_invalid",
                     "member_invite_code_disabled",
                     "member_invite_code_inviter_inactive",
                     "member_invite_code_role_not_allowed",
                     "member_invite_code_app_not_bound":
                    return "邀请码无效或已停用"
                case "member_invite_code_sync_pending",
                     "member_invite_code_sync_unavailable",
                     "member_invite_code_tenant_unavailable",
                     "member_invite_code_unavailable":
                    return "邀请码暂不可用于注册"
                case "member_invite_code_tenant_conflict":
                    return "邀请码和企业不匹配"
                case "registration_tenant_code_probe_rate_limited":
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                case "enterprise_code_search_rate_limited", "tenant_code_search_rate_limited":
                    return "搜索次数过多请晚点再试"
                case "client_registration_rate_limited":
                    return "注册用户今日已达上限"
                case "rate_limit_unavailable":
                    return "服务繁忙，请稍后重试"
                case "default_tenant_not_configured":
                    return "默认商户未配置，请联系管理员"
                case "default_tenant_unavailable":
                    return "默认商户不可用，请联系管理员"
                case "registered_user_quota_exceeded",
                     "online_quota_exceeded",
                     "online_quota_service_unavailable",
                     "group_member_quota_exceeded":
                    return IMAPIClient.licenseQuotaUserMessage(for: code)
                case "user_account_locked":
                    return "用户账号已设置，如需修改请联系管理员/商户后台处理。"
                case "invalid_user_account_format", "invalid_account_format":
                    return "账号必须为 5-10 位数字或英文字母"
                case "invalid_avatar":
                    return "头像格式或尺寸不符合要求，请重新选择图片"
                case "file_not_uploaded":
                    return "文件还未上传完成，请重新上传后再试"
                case "file_not_found":
                    return "文件不存在或已被清理"
                case "file_too_large", "file_size_exceeded":
                    return "文件超过大小限制，请压缩后重试"
                case "file_unavailable":
                    return "文件不可用或无权限访问"
                case "validation_error":
                    return "请求参数不正确，请检查后重试"
                case "avatar_url_unavailable":
                    return "头像地址暂不可用，请稍后重试"
                case "tenant_storage_not_configured":
                    return "企业暂未配置文件存储，请联系管理员"
                case "tenant_storage_resource_unavailable":
                    return "企业存储资源暂不可用，请联系管理员"
                case "tenant_storage_provider_unsupported":
                    return "当前存储服务暂不支持上传"
                case "tenant_storage_secret_unresolved":
                    return "企业存储配置未生效，请联系管理员"
                case "group_not_found", "group_member_not_found", "group_already_dissolved":
                    return "该群聊不存在或已解散"
                case "group_owner_cannot_leave":
                    return "群主需先转让群主或解散该群"
                case "permission_denied":
                    return "无权限执行该操作" // WDT_RECEIPT_DETAIL_SCOPE_20261023
                case "confirmation_required":
                    return "请确认后再解散该群"
                case "invalid_confirmation":
                    return "请确认后再解散该群"
                case "group_dissolve_in_progress":
                    return "群聊正在解散中，请稍后"
                case "group_join_request_not_found":
                    return "入群申请不存在或已失效"
                case "group_unavailable":
                    return "群聊不可用"
                case "group_join_forbidden":
                    return "无权限处理该入群申请"
                case "admin_delete_forbidden", "message_admin_delete_forbidden":
                    return "无权限删除该消息"
                case "message_not_found", "message_not_visible", "message_invisible":
                    return "消息不存在或已不可见"
                case "message_already_deleted":
                    return "该消息已删除"
                case "target_user_not_found":
                    return "目标用户不存在"
                case "target_user_unavailable":
                    return "目标用户状态不可用"
                case "bad_group_join_request":
                    return "入群申请参数不正确"
                case "group_join_conflict":
                    return "入群申请状态冲突，请刷新后重试"
                case "friend_application_terminal":
                    return "好友申请状态已变化，请查看最新状态"
                case "group_owner_transfer_conflict":
                    return "群主状态已变化，请刷新后重试"
                case "group_announcement_revision_conflict":
                    return "公告已被其他管理员更新，请核对后重试"
                case "group_invite_already_processed", "already_processed":
                    return "该入群邀请已处理"
                case "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing":
                    return rtcCapabilityFailureMessage(code: code, media: .generic)
                        ?? "通话媒体服务配置缺失，请联系管理员"
                case "rtc_video_not_supported":
                    return "当前仅支持语音通话"
                case "rtc_group_call_not_supported":
                    return "暂不支持群语音通话"
                case "duplicate_call":
                    return "已有进行中的语音呼叫，请勿重复发起"
                case "caller_busy":
                    return "你正在通话中，请结束后再试"
                case "callee_busy":
                    return "对方正在通话中"
                case "rtc_call_not_found":
                    return "通话不存在或已结束"
                case "rtc_call_forbidden":
                    return "无权限操作该通话"
                case "rtc_call_not_ringing":
                    return "该通话已不在待接听状态"
                case "rtc_call_not_active":
                    return "该通话已结束"
                case "message_recall_window_exceeded":
                    return "已超过当前企业最长时间"
                case "voice_call_not_enabled", "video_call_not_enabled", "rtc_license_capabilities_unavailable":
                    return rtcCapabilityFailureMessage(code: code, media: .generic) ?? "当前企业未开通通话"
                case "read_receipts_not_enabled":
                    return "当前企业未开通"
                case "feature_not_enabled", "group_admin_delete_message_not_enabled":
                    return "当前企业未开通"
                case "mention_all_forbidden":
                    return "仅群主或管理员可以 @所有人"
                case "message_pin_forbidden":
                    return messagePinForbiddenText
                case "message_forward_unsupported":
                    return "该消息类型暂不支持转发"
                case "request_identity_mismatch":
                    return "当前登录身份与请求不匹配，请重新登录后再试"
                case "captcha_config_missing",
                     "captcha_scene_disabled",
                     "captcha_scene_not_enabled",
                     "captcha_channel_unavailable",
                     "tenant_not_found",
                     "sms_provider_not_configured",
                     "invalid_sms_template",
                     "captcha_scene_required",
                     "invalid_captcha_channel",
                     "rate_limited",
                     "captcha_request_rate_limited",
                     "captcha_request_cooldown",
                     "invalid_captcha_request_limit",
                     "invalid_captcha_cooldown",
                     "captcha_invalid",
                     "captcha_expired",
                     "slide_captcha_required",
                     "slide_captcha_invalid",
                     "token_sign_failed":
                    return captchaUserMessage(code: code, reason: message, fallback: "验证码服务暂不可用")
                case "conflict":
                    return registrationConflictMessage(message)
                default:
                    return sanitizeBackendMessage(message, fallback: "操作冲突，请刷新后重试")
                }
            case .loginSecurity(let code, let message, let info):
                return loginSecurityMessage(code: code, message: message, info: info)
            case .server(let message):
                // WDT_RECEIPT_DETAIL_SCOPE_20261023
                if message.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() == "permission_denied" {
                    return "无权限执行该操作"
                }
                if let groupLifecycleMessage = Self.groupLifecycleUserMessage(for: message) {
                    return groupLifecycleMessage
                }
                if let storageMessage = storageFailureMessage(from: message) {
                    return storageMessage
                }
                if message.localizedCaseInsensitiveContains("invalid username or password")
                    || message.localizedCaseInsensitiveContains("unauthorized") {
                    return "账号或密码错误"
                }
                return sanitizeBackendMessage(message, fallback: "服务暂不可用，请稍后重试")
            case .httpStatus(_, let message):
                return sanitizeBackendMessage(message, fallback: "服务暂不可用，请稍后重试")
            case .rateLimited(let code, let message, let retryAfterSeconds, let lockedUntil):
                if code == "login_locked" {
                    return loginLockedMessage(retryAfterSeconds: retryAfterSeconds, lockedUntil: lockedUntil)
                }
                if code == "enterprise_code_search_rate_limited" || code == "tenant_code_search_rate_limited" {
                    return "搜索次数过多请晚点再试"
                }
                if code == "registration_tenant_code_probe_rate_limited" {
                    return "企业编码或邀请码验证次数过多，请稍后再试"
                }
                if code == "client_registration_rate_limited" {
                    return "注册用户今日已达上限"
                }
                if code == "rate_limit_unavailable" {
                    return "服务繁忙，请稍后重试"
                }
                if code == "rate_limited"
                    || code == "captcha_request_cooldown"
                    || code == "captcha_request_rate_limited"
                    || code == "invalid_captcha_request_limit"
                    || code == "invalid_captcha_cooldown" {
                    return captchaUserMessage(code: code, reason: message, fallback: "验证码请求过于频繁，请稍后再试")
                }
                return sanitizeBackendMessage(message, fallback: "操作过于频繁，请稍后再试")
            case .emptyResponse:
                return "接口没有返回有效数据"
            }
        }
        if let localizedDescription = (error as? LocalizedError)?.errorDescription,
           !localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BackendUserMessageSanitizer.sanitize(
                localizedDescription,
                fallback: "网络或服务不可用，请稍后重试"
            )
        }
        return "网络或服务不可用，请稍后重试"
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
