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

// WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
@MainActor
final class BiometricAccessStore {
    struct Snapshot: Equatable {
        let settings: BiometricProtectionSettings
        fileprivate var grants: [BiometricProtectedSurface: String] = [:]

        func requiresProtection(_ surface: BiometricProtectedSurface) -> Bool {
            guard settings.enabled else { return false }
            switch surface {
            case .chat: return settings.unlockChats
            case .filePreview: return settings.previewFiles
            }
        }

        func isAuthorized(_ surface: BiometricProtectedSurface, scopeToken: String) -> Bool {
            !requiresProtection(surface) || grants[surface] == scopeToken
        }
    }

    @Published private(set) var snapshot = Snapshot(settings: .disabled)
    private(set) var accessRevision: UInt64 = 0
    // A system prompt itself makes the scene inactive. Only changes to the
    // session or settings invalidate the identity of an in-flight prompt.
    private(set) var authorizationRevision: UInt64 = 0

    func replaceSettings(_ settings: BiometricProtectionSettings) {
        accessRevision &+= 1
        authorizationRevision &+= 1
        let next = Snapshot(settings: settings)
        if snapshot != next { snapshot = next }
    }

    func revokeGrants() {
        accessRevision &+= 1
        if !snapshot.grants.isEmpty {
            snapshot = Snapshot(settings: snapshot.settings)
        }
    }

    fileprivate func grant(_ surface: BiometricProtectedSurface, scopeToken: String) {
        guard snapshot.grants[surface] != scopeToken else { return }
        snapshot.grants[surface] = scopeToken
    }

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
// WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
    var requiresChatBiometricProtection: Bool {
        biometricAccessStore.snapshot.requiresProtection(.chat)
    }

    var requiresFileBiometricProtection: Bool {
        biometricAccessStore.snapshot.requiresProtection(.filePreview)
    }

    var biometricAccessScopeToken: String {
        "\(BiometricProtectionStore.scopeKey(context: apiContext))#\(biometricAccessStore.accessRevision)"
    }

    private var biometricAuthorizationScopeToken: String {
        "\(BiometricProtectionStore.scopeKey(context: apiContext))#\(biometricAccessStore.authorizationRevision)"
    }

    func isProtectedAccessAuthorized(_ surface: BiometricProtectedSurface) -> Bool {
        biometricAccessStore.snapshot.isAuthorized(surface, scopeToken: biometricAccessScopeToken)
    }

    func protectedAccessUpdates(for surface: BiometricProtectedSurface) -> AnyPublisher<Bool, Never> {
        biometricAccessStore.updates { [weak self] snapshot in
            guard let self else { return false }
            return snapshot.isAuthorized(surface, scopeToken: self.biometricAccessScopeToken)
        }
    }

    func observeProtectedAccess<Content: View>(
        _ surface: BiometricProtectedSurface,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: isProtectedAccessAuthorized(surface),
            updates: protectedAccessUpdates(for: surface),
            content: content
        )
    }
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END

    func saveBiometricProtectionSettings(
        enabled: Bool,
        unlockChats: Bool,
        previewFiles: Bool
    ) async -> Bool {
        let context = apiContext
        let scopeKey = BiometricProtectionStore.scopeKey(context: context)
        let requiresEnableAuthentication = enabled && !biometricProtectionSettings.enabled
        if requiresEnableAuthentication {
            do {
                try await biometricAuthenticator.authenticate(reason: "验证身份以启用 Face ID 保护")
            } catch {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(biometricAuthenticationFailureMessage(error))
                return false
            }
        }
        guard BiometricProtectionStore.scopeKey(context: apiContext) == scopeKey else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重新设置 Face ID")
            return false
        }
        let next = BiometricProtectionSettings(
            enabled: enabled,
            unlockChats: unlockChats,
            previewFiles: previewFiles
        )
        do {
            try BiometricProtectionStore.save(next, context: context, defaults: biometricDefaults)
            biometricAccessStore.replaceSettings(next) // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(enabled ? "Face ID 设置已保存" : "Face ID 已关闭")
            return true
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("Face ID 设置保存失败，请重试")
            return false
        }
    }

    func authorizeProtectedAccess(_ surface: BiometricProtectedSurface) async -> Bool {
        let authorizationScopeToken = biometricAuthorizationScopeToken
        guard biometricAccessStore.snapshot.requiresProtection(surface) else { return true } // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110
        do {
            try await biometricAuthenticator.authenticate(reason: surface.reason)
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(biometricAuthenticationFailureMessage(error))
            return false
        }
        guard biometricAuthorizationScopeToken == authorizationScopeToken else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重新验证")
            return false
        }
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
        guard biometricAccessStore.snapshot.requiresProtection(surface) else { return false }
        biometricAccessStore.grant(surface, scopeToken: biometricAccessScopeToken)
        return true
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
    }

    private func biometricAuthenticationFailureMessage(_ error: Error) -> String {
        let code: LAError.Code?
        if let laError = error as? LAError {
            code = laError.code
        } else {
            let nsError = error as NSError
            code = nsError.domain == LAError.errorDomain ? LAError.Code(rawValue: nsError.code) : nil
        }
        guard let code else { return "Face ID 验证失败，请重试" }
        switch code {
        case .biometryNotAvailable: return "此设备不支持 Face ID"
        case .biometryNotEnrolled: return "请先在系统设置中录入 Face ID"
        case .biometryLockout: return "Face ID 已锁定，请先在系统设置中解锁"
        case .userCancel, .appCancel, .systemCancel: return "Face ID 验证已取消"
        default: return "Face ID 验证失败，请重试"
        }
    }

}
