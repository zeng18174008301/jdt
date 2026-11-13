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

// WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_BEGIN
@MainActor
final class RegistrationConfirmationPresentationStore {
    struct Snapshot: Equatable {
        var resolution: RegistrationResolutionState?
        var hasTimedOut = false

        func isSubmissionBlocked(isAuthLoading: Bool) -> Bool {
            isAuthLoading || (resolution == .pending && !hasTimedOut)
        }

        var confirmationMessage: String {
            hasTimedOut ? RegistrationConfirmationPolicy.timeoutMessage : RegistrationConfirmationPolicy.pendingMessage
        }

        func submitButtonTitle(isAuthLoading: Bool) -> String {
            if isAuthLoading { return "正在注册…" }
            return isSubmissionBlocked(isAuthLoading: isAuthLoading) ? "正在确认…" : "注册并继续"
        }
    }

    @Published var snapshot = Snapshot()

    func observe<Content: View>(@ViewBuilder content: @escaping (Snapshot) -> Content) -> some View {
        PublisherSnapshotView(initialValue: snapshot, updates: $snapshot.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_END

extension AppState {
    func registerWithDefaultEnterprise(phone: String = "", account: String = "", password: String = "", captchaCode: String = "") {
        registerAndEnterIM(phone: phone, account: account, password: password,
                           enterpriseCode: "", captchaCode: captchaCode)
    }

    private func makePreloginCaptchaValidityCheck(context: IMAPIContext) -> () -> Bool {
        let authGeneration = authFlowGeneration.currentToken()
        let enterpriseGeneration = enterpriseContextGeneration.currentToken()
        let screen = authScreen
        let scope = remoteDataScopeKey(for: context)
        return { [weak self] in
            guard let self, !Task.isCancelled else { return false }
            return self.authFlowGeneration.isCurrent(authGeneration)
                && self.enterpriseContextGeneration.isCurrent(enterpriseGeneration)
                && self.authScreen == screen
                && IMAPIContext.normalizedIOSAppID(self.apiContext.appID) == IMAPIContext.normalizedIOSAppID(context.appID)
                && self.apiContext.deviceID == context.deviceID
                && self.remoteDataScopeKey(for: self.apiContext) == scope
        }
    }

    func sendRegisterCaptcha(phone: String, tenantCode: String = "") async -> Int? {
        guard isRegistrationEnabledForAuthUI else {
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            return nil
        }
        let normalized = normalizedMainlandPhone(phone)
        guard isValidMainlandPhone(normalized) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入正确的手机号")
            return nil
        }
        guard let policy = await ensureCurrentAppPolicyForAuth() else {
            return nil
        }
        guard policy.registrationEnabled else {
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            return nil
        }
        guard policy.phoneAuthEnabled, !isPhoneAuthDisabledByServer else {
            disablePhoneAuthForCurrentApp()
            return nil
        }
        let enterpriseContext = requirePreAuthEnterpriseContextIfConfigured()
        if policy.enterpriseCodeFirst, enterpriseContext == nil { return nil }
        let normalizedTenantCode = enterpriseContext?.tenantCode ?? RegistrationFlowPolicy.submittedEntryCode(tenantCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        if !policy.allowDefaultTenantJoin, normalizedTenantCode.isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入企业编码或邀请码后再获取验证码")
            return nil
        }
        let context = apiContext
        let isCurrent = makePreloginCaptchaValidityCheck(context: context)
        do {
            let required = try await canSendCaptcha(scene: "register", channel: "sms", appID: context.appID, tenantCode: normalizedTenantCode, fallbackToCurrentTenant: false)
            guard isCurrent() else { return nil }
            guard required else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前注册流程无需验证码")
                return nil
            }
            let result = try await api.sendTenantCaptcha(
                phone: normalized,
                scene: "register",
                tenantCode: normalizedTenantCode,
                context: context
            )
            guard isCurrent() else { return nil }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(phoneCodeSuccessMessage(result, fallbackMinutes: 10))
            return phoneCodeCooldownSeconds(result)
        } catch {
            guard isCurrent() else { return nil }
            if !handlePhoneAuthDisabledError(error) {
                handleRemoteError(error, fallback: "验证码发送失败")
            }
            return nil
        }
    }

    func sendPasswordResetCaptcha(account: String) async -> Int? {
        let normalized = normalizedMainlandPhone(account)
        guard isValidMainlandPhone(normalized) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入正确的手机号")
            return nil
        }
        let context = apiContext
        let isCurrent = makePreloginCaptchaValidityCheck(context: context)
        let tenantCode = captchaTenantCode()
        do {
            let required = try await canSendCaptcha(scene: "password_reset", channel: "sms", appID: context.appID, tenantCode: tenantCode)
            guard isCurrent() else { return nil }
            guard required else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前找回密码流程无需验证码")
                return nil
            }
            let result = try await api.sendTenantCaptcha(
                phone: normalized,
                scene: "password_reset",
                tenantCode: tenantCode,
                context: context
            )
            guard isCurrent() else { return nil }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(phoneCodeSuccessMessage(result, fallbackMinutes: 10))
            return phoneCodeCooldownSeconds(result)
        } catch {
            guard isCurrent() else { return nil }
            handleRemoteError(error, fallback: "验证码发送失败")
            return nil
        }
    }

    func resetPassword(account: String, code: String, newPassword: String) async -> Bool {
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN
        let requestAuthority = apiContext.authSessionFence
        let authGeneration = authFlowGeneration.currentToken()
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
        let phone = normalizedMainlandPhone(account)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMainlandPhone(phone) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入正确的手机号")
            return false
        }
        guard normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入 6 位验证码")
            return false
        }
        guard newPassword.count >= 8,
              newPassword.count <= 20,
              newPassword.rangeOfCharacter(from: .letters) != nil,
              newPassword.rangeOfCharacter(from: .decimalDigits) != nil else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("新密码需为 8-20 位字母和数字组合")
            return false
        }
        do {
            let response = try await api.resetPassword(
                phone: phone,
                code: normalizedCode,
                newPassword: newPassword
            )
            guard authFlowGeneration.isCurrent(authGeneration), apiContext.isSameAuthAuthority(as: requestAuthority) else { return false }
            guard response.reset else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("密码重置未完成，请重试")
                return false
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("密码已更新，请重新登录")
            return true
        } catch {
            guard authFlowGeneration.isCurrent(authGeneration), apiContext.isSameAuthAuthority(as: requestAuthority) else { return false }
            handleRemoteError(error, fallback: "密码重置失败，请重试")
            return false
        }
    }

    func clearApplicationCaches() async {
        guard !isClearingApplicationCache else { return }
        isClearingApplicationCache = true
        let indexedResult = await clearCurrentIndexedMediaCache()
        let legacyResult = await AppCacheCleaner.clear()
        let result = AppCacheCleanupResult(
            bytesRemoved: indexedResult.bytesRemoved + legacyResult.bytesRemoved,
            failures: indexedResult.failures + legacyResult.failures
        )
        URLCache.shared.removeAllCachedResponses()
        AvatarImageCache.shared.removeAllImages()
        fileStore.clearLocalAttachmentResources()
        isClearingApplicationCache = false
        let size = ByteCountFormatter.string(fromByteCount: result.bytesRemoved, countStyle: .file)
        if result.failures.isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(result.bytesRemoved > 0 ? "已清理 \(size) 缓存" : "当前没有可清理缓存")
        } else if result.bytesRemoved > 0 {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已清理 \(size)，部分缓存清理失败")
        } else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("缓存清理失败，请稍后重试")
        }
    }

}
