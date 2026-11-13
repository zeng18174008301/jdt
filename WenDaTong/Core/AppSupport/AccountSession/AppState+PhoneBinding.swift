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

// WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_BEGIN
enum RealNameSubmissionOutcome: Equatable {
    case accepted
    case rejected(message: String)
}
// WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_END

extension AppState {
    func isValidAccountUsername(_ username: String) -> Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...10).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }
    }

    func isUserAccountFormatErrorCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "invalid_user_account_format" || normalized == "invalid_account_format"
    }

    func refreshVerificationStatus() async {
        await refreshVerificationStatus(contactOwner: nil)
    }

    // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112
    func refreshVerificationStatus(contactOwner: ContactHTTPRequestOwner?) async {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        do {
            try contactOwner?.check(requiresExactAuthority: true)
            let status: RemoteVerificationStatus
            if let contactOwner, let client = api as? IMAPIClient {
                status = try await client.verificationStatus(context: context, contactOwner: contactOwner)
            } else {
                status = try await api.verificationStatus(context: context)
            }
            try contactOwner?.check(requiresExactAuthority: true)
            guard isCurrentRemoteScope(scope) else { return }
            applyVerificationStatus(status)
        } catch {
            if let contactOwner, (try? contactOwner.check(requiresExactAuthority: true)) == nil { return }
            guard isCurrentRemoteScope(scope) else { return }
            handleRemoteError(error, fallback: "认证状态同步失败")
        }
    }

    func sendPhoneBindingCode(phone: String) async -> Int? {
        let normalized = normalizedMainlandPhone(phone)
        guard isValidMainlandPhone(normalized) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入正确的手机号")
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        guard let sessionScope = PhoneBindingChallengeSessionScope(context: context) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let issueGeneration = beginPhoneBindingChallengeIssue()
        do {
            let tenantCode = captchaTenantCode()
#if DEBUG
            let phoneSuffix = String(normalized.suffix(4))
            captchaLogger.info("phone_bind_captcha start tenantCode=\(tenantCode, privacy: .public) phoneSuffix=\(phoneSuffix, privacy: .public)")
#endif
            guard try await canSendCaptcha(scene: "phone_bind", channel: "sms", appID: context.appID, tenantCode: tenantCode) else {
                guard isCurrentPhoneBindingChallengeIssue(
                    generation: issueGeneration,
                    sessionScope: sessionScope
                ) else { return nil }
#if DEBUG
                captchaLogger.info("phone_bind_captcha not_required")
#endif
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前手机号绑定流程无需验证码")
                return nil
            }
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
#if DEBUG
            captchaLogger.info("phone_bind_captcha sending")
#endif
            let challenge = try await api.sendPhoneBindingChallenge(context: context, phone: normalized)
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
            let requestID = challenge.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard challenge.sent, !requestID.isEmpty else {
                throw IMAPIError.businessForbidden(
                    code: "phone_binding_request_id_missing",
                    message: "手机号验证请求标识缺失，请重新获取验证码",
                    error: nil
                )
            }
            pendingPhoneBindingChallenge = PendingPhoneBindingChallenge(
                sessionScope: sessionScope,
                normalizedPhone: normalized,
                requestID: requestID,
                issueGeneration: issueGeneration
            )
#if DEBUG
            captchaLogger.info("phone_bind_captcha sent cooldown=\(challenge.cooldownSeconds, privacy: .public)")
#endif
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(phoneBindingChallengeSuccessMessage(challenge))
            return phoneBindingChallengeCooldownSeconds(challenge)
        } catch {
            guard isCurrentPhoneBindingChallengeIssue(
                generation: issueGeneration,
                sessionScope: sessionScope
            ) else { return nil }
#if DEBUG
            captchaLogger.error("phone_bind_captcha failed message=\(self.userFacingError(error), privacy: .public)")
#endif
            handleRemoteError(error, fallback: "验证码发送失败")
            return nil
        }
    }

    func captchaTenantCode(_ explicit: String = "", fallbackToCurrentTenant: Bool = true) -> String {
        let provided = explicit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !provided.isEmpty { return provided }
        guard fallbackToCurrentTenant else { return "" }
        return currentEnterprise.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func canSendCaptcha(scene: String, channel: String, appID: String, tenantCode: String = "", fallbackToCurrentTenant: Bool = true) async throws -> Bool {
        let code = scene == "register"
            ? RegistrationFlowPolicy.submittedEntryCode(tenantCode)
            : captchaTenantCode(tenantCode, fallbackToCurrentTenant: fallbackToCurrentTenant) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        let entry = try await api.captchaEntryStatus(scene: scene, channel: channel, tenantCode: code, appID: appID).preferredEntry(scene: scene, channel: channel)
        guard let entry else {
            throw IMAPIError.server("验证码入口状态不可用")
        }
        if !entry.required {
            return false
        }
        guard entry.enabled && entry.available else {
            throw IMAPIError.forbidden(entry.unavailableMessage)
        }
        return true
    }

    func captchaRequired(scene: String, channel: String, appID: String, tenantCode: String = "", fallbackToCurrentTenant: Bool = true) async throws -> Bool {
        let code = scene == "register"
            ? RegistrationFlowPolicy.submittedEntryCode(tenantCode)
            : captchaTenantCode(tenantCode, fallbackToCurrentTenant: fallbackToCurrentTenant) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        let entry = try await api.captchaEntryStatus(scene: scene, channel: channel, tenantCode: code, appID: appID).preferredEntry(scene: scene, channel: channel)
        guard let entry else {
            throw IMAPIError.server("验证码入口状态不可用")
        }
        guard entry.required else {
            return false
        }
        guard entry.enabled && entry.available else {
            throw IMAPIError.forbidden(entry.unavailableMessage)
        }
        return true
    }

    func phoneCodeSuccessMessage(_ result: RemotePhoneCodeResult, fallbackMinutes: Int) -> String {
        var message = "验证码已发送"
        let phoneMasked = result.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneMasked.isEmpty {
            message += "至 \(phoneMasked)"
        }
        let seconds = result.expiresInSeconds
        if seconds > 0 {
            let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
            message += "，\(minutes) 分钟内有效"
        } else if fallbackMinutes > 0 {
            message += "，\(fallbackMinutes) 分钟内有效"
        }
        return message
    }

    func phoneCodeCooldownSeconds(_ result: RemotePhoneCodeResult, fallbackSeconds: Int = 60) -> Int {
        let explicitSeconds = result.cooldownSeconds
        if explicitSeconds > 0 {
            return min(max(explicitSeconds, 1), 3_600)
        }
        return fallbackSeconds
    }

    private func phoneBindingChallengeSuccessMessage(_ challenge: RemotePhoneBindingChallenge) -> String {
        var message = "验证码已发送"
        let phoneMasked = challenge.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneMasked.isEmpty {
            message += "至 \(phoneMasked)"
        }
        if challenge.expiresInSeconds > 0 {
            let minutes = max(1, Int(ceil(Double(challenge.expiresInSeconds) / 60.0)))
            message += "，\(minutes) 分钟内有效"
        }
        return message
    }

    private func phoneBindingChallengeCooldownSeconds(
        _ challenge: RemotePhoneBindingChallenge,
        fallbackSeconds: Int = 60
    ) -> Int {
        guard challenge.cooldownSeconds > 0 else { return fallbackSeconds }
        return min(max(challenge.cooldownSeconds, 1), 3_600)
    }

    private func beginPhoneBindingChallengeIssue() -> UInt64 {
        phoneBindingChallengeIssueGeneration &+= 1
        pendingPhoneBindingChallenge = nil
        return phoneBindingChallengeIssueGeneration
    }

    func invalidatePhoneBindingChallenge(ownedBy scope: PhoneBindingChallengeSessionScope?) {
        phoneBindingChallengeIssueGeneration &+= 1
        guard let scope,
              pendingPhoneBindingChallenge?.sessionScope == scope else {
            return
        }
        pendingPhoneBindingChallenge = nil
    }

    private func isCurrentPhoneBindingChallengeIssue(
        generation: UInt64,
        sessionScope: PhoneBindingChallengeSessionScope
    ) -> Bool {
        phoneBindingChallengeIssueGeneration == generation
            && PhoneBindingChallengeSessionScope(context: apiContext) == sessionScope
    }

    private func isCurrentPhoneBindingChallenge(
        _ challenge: PendingPhoneBindingChallenge
    ) -> Bool {
        pendingPhoneBindingChallenge == challenge
            && phoneBindingChallengeIssueGeneration == challenge.issueGeneration
            && PhoneBindingChallengeSessionScope(context: apiContext) == challenge.sessionScope
    }

    private func clearPhoneBindingChallenge(_ challenge: PendingPhoneBindingChallenge) {
        guard pendingPhoneBindingChallenge == challenge else { return }
        pendingPhoneBindingChallenge = nil
    }

    func verifyPhoneBinding(phone: String, code: String) async -> Bool {
        await verifyPhoneBinding(
            phone: phone,
            code: code,
            requestID: pendingPhoneBindingChallenge?.requestID ?? ""
        )
    }

    func verifyPhoneBinding(phone: String, code: String, requestID: String) async -> Bool {
        let normalizedPhone = normalizedMainlandPhone(phone)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMainlandPhone(normalizedPhone), normalizedCode.count >= 4 else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请填写手机号和验证码")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        guard let sessionScope = PhoneBindingChallengeSessionScope(context: context),
              !normalizedRequestID.isEmpty,
              let challenge = pendingPhoneBindingChallenge,
              challenge.sessionScope == sessionScope,
              challenge.normalizedPhone == normalizedPhone,
              challenge.requestID == normalizedRequestID,
              isCurrentPhoneBindingChallenge(challenge) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("手机号验证码请求已失效，请重新获取")
            return false
        }
        let submittedPhoneMasked = maskedPhoneDisplayText(normalizedPhone)
        do {
            let verifiedUser = try await api.verifyPhoneBinding(
                context: context,
                phone: normalizedPhone,
                code: normalizedCode,
                requestID: normalizedRequestID
            )
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            let verifiedUserIMUID = verifiedUser.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard verifiedUser.phoneBindingKnown,
                  verifiedUser.phoneVerified,
                  verifiedUserIMUID == sessionScope.imUID else {
                clearPhoneBindingChallenge(challenge)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该验证码未建立手机号持有证明，请重新获取短信验证码")
                return false
            }
            let status = try await api.verificationStatus(context: context)
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            let statusIMUID = status.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let statusPhoneMasked = status.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status.phoneBindingKnown,
                  status.phoneBound,
                  statusIMUID == sessionScope.imUID,
                  statusPhoneMasked == submittedPhoneMasked else {
                clearPhoneBindingChallenge(challenge)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("手机号绑定状态校验失败，请重新获取短信验证码")
                return false
            }
            clearPhoneBindingChallenge(challenge)
            guard applyVerificationStatus(
                status,
                preferredPhoneMasked: submittedPhoneMasked
            ) else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("手机号绑定状态校验失败，请重新获取短信验证码")
                return false
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("手机号已绑定")
            return true
        } catch {
            guard isCurrentPhoneBindingChallenge(challenge) else { return false }
            clearPhoneBindingChallenge(challenge)
            handleRemoteError(error, fallback: "手机号绑定失败")
            return false
        }
    }

    // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_BEGIN
    func submitRealNameVerification(realName: String, idNumber: String) async -> RealNameSubmissionOutcome {
        func reject(_ message: String) -> RealNameSubmissionOutcome {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return .rejected(message: message)
        }

        let normalizedName = RealNameValidator.sanitizedName(realName)
        let normalizedID = RealNameValidator.sanitizedIDNumber(idNumber)
        guard RealNameValidator.isValidName(normalizedName) else {
            return reject("真实姓名格式不正确")
        }
        guard RealNameValidator.isValidChineseResidentID(normalizedID) else {
            return reject("身份证号码格式不正确")
        }
        let context = apiContext
        guard context.hasIMSession else {
            return reject("登录会话不可用，请重新登录")
        }
        let scope = remoteDataScopeKey(for: context)
        let staleSubmission = RealNameSubmissionOutcome.rejected(message: "实名认证提交失败，请稍后重试")
        do {
            let status = try await api.submitRealNameVerification(context: context, realName: normalizedName, idNumber: normalizedID)
            guard isCurrentRemoteScope(scope) else { return staleSubmission }
            guard applyVerificationStatus(status) else {
                return reject("实名认证状态校验失败，请稍后重试")
            }
            let normalizedStatus = status.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status.realNameRequirementSatisfied == true {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("实名认证已通过")
                return .accepted
            }
            if normalizedStatus == "rejected" {
                return reject(realNameVerificationFailedText)
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("实名认证申请已提交")
            return .accepted
        } catch {
            guard isCurrentRemoteScope(scope) else { return staleSubmission }
            let message = userFacingError(error)
            handleRemoteError(error, fallback: "实名认证提交失败")
            return reject(message == realNameVerificationFailedText ? message : "实名认证提交失败：\(message)")
        }
    }
    // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_END

    func switchEnterprise(_ enterprise: Enterprise) {
        guard canUseEnterpriseDirectory else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先登录后再切换企业")
            return
        }
        guard !isWorkspaceSwitchDisabledByPolicy else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭企业切换")
            return
        }
        guard enterprise.isWorkspaceJoined || enterprises.contains(where: { $0.id == enterprise.id && $0.isWorkspaceJoined }) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该企业不在当前账号已加入列表，无法切换")
            return
        }
        guard enterprise.isWorkspaceEnterable else {
            let reason = enterprise.workspaceDisabledDescription
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason.isEmpty ? "该企业暂不可进入，请确认成员状态" : reason)
            return
        }
        guard enterprise.canSwitch else {
            let reason = enterprise.workspaceDisabledDescription
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason.isEmpty ? "该企业暂不可切换，请联系管理员确认成员状态" : reason)
            return
        }
        let previousEnterprise = currentEnterprise
        let previousContext = apiContext
        let switchGeneration = workspaceSwitchGeneration.issueToken()
        Task {
            do {
                // 保留账号/租户隔离缓存；仅在当前企业响应确认配置后复用，避免切换时闪现旧图。
                purgeCertificationIdentityRoot(rebindCurrentScope: false)
                prepareSplashForScopeChange(reason: "workspace_switch_start")
                retirePushDevices(for: previousContext)
                disconnectRealtime(shouldReconnect: false)
                EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
                    hasAuthenticatedSession: previousContext.hasIMSession,
                    product: "ios",
                    appID: IMAPIContext.normalizedIOSAppID(previousContext.appID),
                    accountID: previousContext.accountID,
                    tenantID: previousContext.tenantID,
                    imUID: previousContext.imUID
                )
                apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)
                resetAuthenticatedRemoteData(showLoading: true)
                try await switchPlatformTenant(
                    tenantID: enterprise.id,
                    isCurrent: { self.workspaceSwitchGeneration.isCurrent(switchGeneration) }
                )
	                guard workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
	                let switchedContext = apiContext
	                let switchedScope = remoteDataScopeKey(for: switchedContext)
	                bindCallRecordPersistence(for: switchedContext)
	                activateMyInviteCodeForCurrentSession()
	                startSplashConfigurationRefresh(
                    context: switchedContext,
                    intent: .tenantEntry,
                    reason: "workspace_switch"
                )
                _ = await applyCachedRemoteSnapshotIfAvailable(context: switchedContext)
                guard workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(switchedScope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
                guard workspaceSwitchGeneration.isCurrent(switchGeneration),
                      isCurrentRemoteScope(switchedScope) else { return }
                startRealtimeConnection(context: switchedContext)
                registerPendingStandardPushDeviceIfPossible(reason: "workspace_switch")
                registerPendingVoIPDeviceIfPossible(reason: "workspace_switch")
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已切换到 \(enterprise.name)")
                loginWorkspacePresentationStore.switchCompletionRevision &+= 1 // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110
            } catch {
                guard workspaceSwitchGeneration.isCurrent(switchGeneration) else { return }
                let workspaceAccessCode = workspaceAccessCode(from: error)
                apiContext = previousContext
                apiContext.save(sessionStore: protectedSessionStore)
                setCurrentEnterprise(previousEnterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                if workspaceAccessCode != "workspace_switch_disabled" {
                    startSplashConfigurationRefresh(
                        context: previousContext,
                        intent: .refreshOnly,
                        reason: "workspace_switch_rollback"
                    )
                }
                if let securityInfo = securityBlockedInfo(from: error) {
                    let affectsCurrent = handleSecurityBlocked(securityInfo, enterpriseID: enterprise.id)
                    if !affectsCurrent {
                        startRealtimeConnection()
                    }
                    return
                }
                if let code = workspaceAccessCode {
                    if code == "workspace_switch_disabled" {
                        startRealtimeConnection()
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceAccessMessage(for: code))
                        return
                    }
                    guard shouldPersistWorkspaceEntryAccessBlock(code) else {
                        startRealtimeConnection()
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(platformWorkspaceSwitchFailureMessage(error))
                        return
                    }
                    let affectsCurrent = markWorkspaceAccessBlocked(code, enterpriseID: enterprise.id)
                    if affectsCurrent {
                        disconnectRealtime(shouldReconnect: false)
                        forceWorkspaceSelectionForCurrentAccessBlock(code)
                    } else {
                        startRealtimeConnection()
                    }
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceAccessMessage(for: code))
                    return
                }
                startRealtimeConnection()
                handleRemoteError(error, fallback: "企业存在，但切换失败")
            }
        }
    }

}
