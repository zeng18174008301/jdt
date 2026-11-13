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

// MARK: - AppState MainActor Partition
//
// Tenant switching and tenant-scoped projection remain AppState/MainActor work
// because they mutate apiContext, currentEnterprise, currentUser, contacts,
// groups, inbox, and child stores observed by SwiftUI. Pure payload/message
// decoding lives under MessageMapping as nonisolated helpers.

// MARK: - Tenant Switching and Remote Mapping

extension AppState {
    private func switchToFirstRemoteTenantIfPossible() async throws {
        let targetID = apiContext.tenantID ?? enterprises.first?.id
        guard let targetID else { throw IMAPIError.missingContext("tenant_id") }
        try await switchRemoteTenant(enterpriseID: targetID)
        guard apiContext.hasIMSession else { throw IMAPIError.missingContext("im_session") }
    }

    private func switchRemoteTenant(enterpriseID: String, isCurrent: (() -> Bool)? = nil) async throws {
        let context = apiContext
        guard isCurrent?() ?? true else { throw CancellationError() }
        recordAccessDiagnosticsMerchantResolving(name: currentEnterprise.name)
        let candidates = IMAPIContext.iosAppIDCandidates(preferred: context.appID)
        var lastError: Error?
        for appID in candidates where !appID.isEmpty {
            do {
                let result = try await api.switchWorkspace(context: context, tenantID: enterpriseID, appID: appID, deviceID: context.deviceID)
                guard isCurrent?() ?? true else { throw CancellationError() }
                apiContext.tenantID = result.tenant.id
                apiContext.imUID = result.session.imUID
                apiContext.imToken = result.session.imToken
                apiContext.appID = IMAPIContext.normalizedIOSAppID(result.session.appID)
                apiContext.deviceID = result.session.deviceID.isEmpty ? apiContext.deviceID : result.session.deviceID
                apiContext.persistAuthSession(result.session.authSession, fallbackTokenType: "im", fallbackTenantID: result.tenant.id)
                apiContext.persistAuthSession(result.authSession, fallbackTokenType: "im", fallbackTenantID: result.tenant.id)
                apiContext.save(sessionStore: protectedSessionStore)
                resetInitialSplashOverlayEvaluationState()
                setCurrentEnterprise(enterprise(from: result.tenant, fallbackAccent: currentEnterprise.accentHex, role: result.member.role)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                applyTenantSwitchUser(tenantName: result.tenant.name, member: result.member, user: result.user, imUID: result.session.imUID)
                recordAccessDiagnosticsMerchantEntered()
                clearTenantScopedSearchState(reason: "workspace_switch")
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                if workspaceAccessCode(from: error) == "workspace_switch_disabled" {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError ?? IMAPIError.missingContext("app_id")
    }

    func switchPlatformTenant(tenantID: String, allowLegacyFallback: Bool = true, isCurrent: (() -> Bool)? = nil) async throws {
        guard isCurrent?() ?? true else { throw CancellationError() }
        recordAccessDiagnosticsMerchantResolving(name: currentEnterprise.name)
        var didRetryAfterPlatformSessionRefresh = false

        while true {
            let context = apiContext
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Capture at the original owner/installed-auth phase before its request suspends.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END

            let candidates = IMAPIContext.iosAppIDCandidates(preferred: context.appID).reduce(into: [String]()) { result, raw in
                let normalized = IMAPIContext.normalizedIOSAppID(raw)
                if !normalized.isEmpty, !result.contains(normalized) {
                    result.append(normalized)
                }
            }
            var lastError: Error?
            for appID in candidates where !appID.isEmpty {
                var attemptedTenantExchange = false
                do {
#if DEBUG
                    recordWorkspaceEntryDiagnosticSummary(
                        "enter_start app_id=\(appID) device=\(IMAPIClient.debugDiagnosticFingerprint(context.deviceID))"
                    )
#endif
                    let enter = try await api.enterTenant(
                        tenantID: tenantID,
                        platformToken: context.platformToken,
                        appID: appID,
                        deviceID: context.deviceID, requestAuthority: requestAuthority
                    )
                    guard (isCurrent?() ?? true), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                    let entryTicket = enter.entryTicket.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !entryTicket.isEmpty else {
                        throw IMAPIError.missingContext("entry_ticket")
                    }
					let routeSnapshot = enter.runtimeConfig.runtimeRouteSnapshot
					let expectedAppID = IMAPIContext.normalizedIOSAppID(appID)
					guard enter.runtimeConfig.contractVersion == 2,
					      routeSnapshot.appID == expectedAppID,
					      routeSnapshot.tenantID == tenantID,
					      routeSnapshot.validated(appID: expectedAppID, tenantID: tenantID) != nil else {
						throw IMAPIError.businessForbidden(code: "route_identity_mismatch", message: "服务路由身份不匹配", error: nil)
					}
					let tenantRoute = Self.freshRuntimeEndpoint(routeSnapshot, service: .tenantAPI)
					let imRoute = Self.freshRuntimeEndpoint(routeSnapshot, service: .imAPI)
                    guard let tenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(tenantRoute ?? enter.runtimeConfig.tenantAPIBaseURL) else {
                        throw IMAPIError.missingContext("tenant_api_base_url")
                    }
                    let imBaseURL = IMAPIClient.normalizedIMAPIBaseURL(imRoute ?? enter.runtimeConfig.imAPIBaseURL)
#if DEBUG
                    recordWorkspaceEntryDiagnosticSummary(
                        "platform_entry_start app_id=\(appID) device=\(IMAPIClient.debugDiagnosticFingerprint(context.deviceID)) ticket_present=\(!entryTicket.isEmpty) ticket_length=\(entryTicket.count) ticket=\(IMAPIClient.debugDiagnosticFingerprint(entryTicket)) tenant_host=\(tenantBaseURL.host ?? "unknown")"
                    )
#endif
                    do {
                        attemptedTenantExchange = true
                        let result = try await api.platformEntry(
                            entryTicket: entryTicket,
                            tenantBaseURL: tenantBaseURL,
                            appID: appID,
                            deviceID: context.deviceID, requestAuthority: requestAuthority
                        )
                        guard !result.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw IMAPIError.missingContext("im_token")
                        }
                        guard (isCurrent?() ?? true), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                        if !allowLegacyFallback {
                            guard result.tenant.id == tenantID, result.member.tenantID == tenantID,
                                  result.accountID == context.accountID, result.member.accountID == context.accountID,
                                  !result.imUID.isEmpty, result.imUID == result.member.imUID,
                                  result.appID == appID, result.deviceID == context.deviceID,
                                  let session = result.authSession, session.isUsable,
                                  session.normalizedTokenType == "im", session.tenantID == tenantID,
                                  session.appID == appID, session.deviceID == context.deviceID else {
                                throw IMAPIError.businessForbidden(
                                    code: "registration_entry_identity_mismatch",
                                    message: "注册入企会话身份不匹配", error: nil
                                )
                            }
                        }
                        if !allowLegacyFallback, let nested = result.session {
                            // The decoder retains nested fields even when top-level
                            // authority wins. Reject conflicts before the installer
                            // can publish or persist any part of this response.
                            guard (nested.appID.isEmpty || nested.appID == appID),
                                  (nested.deviceID.isEmpty || nested.deviceID == context.deviceID),
                                  (nested.imUID.isEmpty || nested.imUID == result.imUID),
                                  (nested.imToken.isEmpty || nested.imToken == result.imToken),
                                  nested.authSession.map({
                                      $0.isUsable && $0.normalizedTokenType == "im"
                                          && $0.tenantID == tenantID && $0.appID == appID
                                          && $0.deviceID == context.deviceID
                                  }) ?? true else {
                                throw IMAPIError.businessForbidden(
                                    code: "registration_entry_identity_mismatch",
                                    message: "注册入企会话身份不匹配", error: nil
                                )
                            }
                        }
                        let fallbackEnterprise = enterprises.first { $0.id == tenantID }
                        guard applyPlatformTenantEntryData(
                            result,
                            tenantAPIBaseURL: tenantBaseURL,
                            imAPIBaseURL: imBaseURL,
                            fallbackEnterprise: fallbackEnterprise,
                            useCanonicalSession: !allowLegacyFallback
                        ) else {
                            throw IMAPIError.server("protected_session_persistence_failed")
                        }
                    } catch let error as CancellationError {
                        throw error
                    } catch {
                guard apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
#if DEBUG
                        recordWorkspaceEntryDiagnosticSummary(
                            "platform_entry_failed app_id=\(appID) code=\(appPolicyErrorCode(from: error)) tenant_host=\(tenantBaseURL.host ?? "unknown")"
                        )
#endif
                        guard allowLegacyFallback,
                              shouldFallbackToLegacyTenantSwitchAfterPlatformEntryFailure(error) else {
                            throw error
                        }
                        print("[JHT Auth] platform_entry_fallback_to_legacy_switch reason=entry_ticket_exchange_failed app_id=\(appID)")
                        let result = try await api.switchTenant(
                            tenantID: tenantID,
                            platformToken: context.platformToken,
                            appID: appID,
                            deviceID: context.deviceID, requestAuthority: requestAuthority
                        )
                        guard (isCurrent?() ?? true), apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                        guard applyPlatformTenantSwitchData(result) else {
                            throw IMAPIError.server("protected_session_persistence_failed")
                        }
                    }
                    clearTenantScopedSearchState(reason: "tenant_switch")
                    return
                } catch let error as CancellationError {
                    throw error
                } catch {
                guard apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                    // Tenant ticket rejection is not platform-session expiry.
                    // Registration retries the existing entry path later; it
                    // must not rotate platform credentials or try another issuer.
                    if !allowLegacyFallback, attemptedTenantExchange { throw error }
                    if workspaceAccessCode(from: error) == "workspace_switch_disabled" {
                        throw error
                    }
                    lastError = error
                    if !didRetryAfterPlatformSessionRefresh,
                       shouldRetryPlatformTenantEnterAfterSessionRefresh(error) {
                        break
                    }
                }
            }

            if !didRetryAfterPlatformSessionRefresh,
               shouldRetryPlatformTenantEnterAfterSessionRefresh(lastError) {
                didRetryAfterPlatformSessionRefresh = true
                // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: platform entry uses platform bearer, so refresh platform session only.
                // WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_BEGIN
                let refreshedAuthority = await refreshPlatformAuthSessionAuthorityIfNeeded(
                    reason: "workspace_enter_unauthorized",
                    silent: true,
                    context: context,
                    force: true
                )
                // WDT_IOS_TOKEN_VALIDITY_20260924_END
                guard isCurrent?() ?? true else { throw CancellationError() }
                if let refreshedAuthority {
                    guard apiContext.isSameAuthAuthority(as: refreshedAuthority) else { throw CancellationError() }
                    continue // The next loop captures the validated installed authority before its first await.
                }
                guard apiContext.isSameAuthAuthority(as: requestAuthority) else { throw CancellationError() }
                // WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_END
            }

            throw lastError ?? IMAPIError.missingContext("app_id")
        }
    }

    func shouldRetryPlatformTenantEnterAfterSessionRefresh(_ error: Error?) -> Bool {
        guard let error,
              apiContext.platformAuthSession?.isUsable == true else {
            return false
        }
        return isRefreshableSessionError(error)
    }

    static func freshRuntimeEndpoint(
        _ snapshot: IMRuntimeRouteSnapshot,
        service: IMRuntimeRouteService
    ) -> String? {
        guard let route = snapshot.services[service.rawValue] else { return nil }
        return route.preferred.first ?? route.backups.first
    }

    private func shouldFallbackToLegacyTenantSwitchAfterPlatformEntryFailure(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        let message: String
        switch apiError {
        case .unauthorized(let raw), .forbidden(let raw), .server(let raw), .badURL(let raw):
            message = raw
        case .businessForbidden(let code, let raw, _):
            message = "\(code) \(raw)"
        default:
            return false
        }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("entry_ticket")
            || normalized.contains("invalid ticket")
            || normalized.contains("ticket is invalid")
            || normalized.contains("企业入口票据校验失败")
    }

    private func applyPlatformTenantEntryData(_ data: RemoteTenantPlatformEntryResult, tenantAPIBaseURL: URL, imAPIBaseURL: URL?, fallbackEnterprise: Enterprise?, useCanonicalSession: Bool = false) -> Bool {
        let resolvedTenantID = [
            data.tenant.id,
            data.member.tenantID,
            fallbackEnterprise?.id
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        apiContext.tenantID = resolvedTenantID
        apiContext.accountID = [
            data.accountID,
            data.member.accountID,
            data.user?.accountID,
            apiContext.accountID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        apiContext.imUID = data.imUID.isEmpty ? data.member.imUID : data.imUID
        apiContext.imToken = data.imToken
        apiContext.tenantAPIBaseURL = tenantAPIBaseURL.absoluteString
        apiContext.imAPIBaseURL = imAPIBaseURL?.absoluteString
        apiContext.appID = IMAPIContext.normalizedIOSAppID(data.appID.isEmpty ? apiContext.appID : data.appID)
        apiContext.deviceID = data.deviceID.isEmpty ? apiContext.deviceID : data.deviceID
        // Registration installs only the validated top-level representation.
        // Nested refresh families must never transiently replace platform authority.
        if !useCanonicalSession, let session = data.session {
            apiContext.appID = IMAPIContext.normalizedIOSAppID(session.appID.isEmpty ? apiContext.appID : session.appID)
            apiContext.deviceID = session.deviceID.isEmpty ? apiContext.deviceID : session.deviceID
            apiContext.persistAuthSession(session.authSession, fallbackTokenType: "im", fallbackTenantID: resolvedTenantID)
        }
        apiContext.persistAuthSession(data.authSession, fallbackTokenType: "im", fallbackTenantID: resolvedTenantID)
        let persistenceResult = apiContext.save(sessionStore: protectedSessionStore)
        resetInitialSplashOverlayEvaluationState()

        let remoteEnterprise = enterprise(from: RemoteTenantMembership(tenant: data.tenant, member: data.member), fallbackAccent: currentEnterprise.accentHex)
        var enterprise = remoteEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackEnterprise ?? remoteEnterprise)
            : remoteEnterprise
        // A successful ticket exchange is authoritative access proof. Preserve
        // fallback presentation fields when the compact response omits them, but
        // never carry a prior disabled/service-unavailable projection forward.
        enterprise.joinStatus = "joined"
        enterprise.applicationStatus = ""
        enterprise.approvalRequired = false
        enterprise.canSwitch = true
        enterprise.enterable = true
        enterprise.isCurrent = true
        enterprise.accountStatus = ""
        enterprise.tenantStatus = data.tenant.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "active"
            : data.tenant.status
        enterprise.memberStatus = data.member.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "active"
            : data.member.status
        enterprise.disabledReason = ""
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        if enterprises.contains(where: { $0.id == enterprise.id }) {
            setEnterprises(enterprises.map { $0.id == enterprise.id ? enterprise : $0 }) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        } else {
            updateEnterprises { $0.insert(enterprise, at: 0) } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        let switchedIMUID = apiContext.imUID ?? data.member.imUID
        applyTenantSwitchUser(tenantName: enterprise.name, member: data.member, user: data.user, imUID: switchedIMUID)
        recordAccessDiagnosticsMerchantEntered()
        return persistenceResult.isCommitted
    }

    private func applyTenantSwitchUser(tenantName: String, member: RemoteTenantMember, user: RemoteIMUser?, imUID: String) {
        let resolvedIMUID = preferredDisplayName(
            candidates: [imUID, user?.imUID, member.imUID, currentUser.id],
            fallback: currentUser.id.isEmpty ? "企业成员" : currentUser.id
        )
        let resolvedUserID = preferredDisplayName(
            candidates: [user?.userID, member.userID, currentUser.userID, resolvedIMUID],
            fallback: resolvedIMUID
        )
        let displayName = preferredDisplayName(
            candidates: [
                currentProfileAuthorityDisplayNameCandidate(),
                user?.nickname,
                member.nickname,
                currentUser.name,
                user?.username,
                member.username,
                member.accountID,
                resolvedUserID,
                resolvedIMUID
            ],
            identifiers: [resolvedIMUID, resolvedUserID, member.accountID, currentUser.id, currentUser.userID],
            fallback: resolvedIMUID
        )
        let avatarURL = [
            user?.avatar,
            member.avatar,
            currentUser.avatarURL
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let resolvedAvatarURL = avatarURL.isEmpty ? "" : resolveTenantAssetURL(avatarURL)
        let userPhone = user?.phone.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextPhone: String
        let nextPhoneVerified: Bool
        if let user, user.phoneBindingKnown {
            nextPhoneVerified = user.phoneVerified
            nextPhone = user.phoneVerified ? userPhone : ""
        } else {
            nextPhoneVerified = user?.phoneVerified ?? currentUser.phoneVerified
            nextPhone = userPhone.isEmpty ? currentUser.phone : userPhone
        }
        setCurrentUser(IMUser(
            id: resolvedIMUID,
            userID: resolvedUserID,
            username: preferredDisplayName(candidates: [user?.username, member.username, currentUser.username, member.accountID], fallback: currentUser.username),
            name: displayName,
            title: "",
            department: "",
            phone: nextPhone,
            phoneVerified: nextPhoneVerified,
            realNameVerified: user?.realNameVerified ?? currentUser.realNameVerified,
            realNameStatus: user?.realNameStatus.isEmpty == false ? user!.realNameStatus : currentUser.realNameStatus,
            email: user?.accountID.isEmpty == false ? user!.accountID : (member.accountID.isEmpty ? currentUser.email : member.accountID),
            status: presenceStatusText(
                rawStatus: user?.presenceStatus ?? "",
                online: user?.onlineKnown == true ? user?.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(user?.lastSeenAt),
            enterprise: tenantName,
            avatarSeed: stableSeed(resolvedIMUID),
            avatarURL: resolvedAvatarURL,
            avatarVersion: user?.avatarVersion.isEmpty == false ? user!.avatarVersion : (member.avatarVersion.isEmpty ? currentUser.avatarVersion : member.avatarVersion),
            avatarUpdatedAt: user?.avatarUpdatedAt.isEmpty == false ? user!.avatarUpdatedAt : (member.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : member.avatarUpdatedAt),
            badges: currentUser.badges
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    }

    private func applyPlatformTenantSwitchData(_ data: RemoteTenantSwitchResult) -> Bool {
        apiContext.tenantID = data.tenant.id
        apiContext.imUID = data.imUID.isEmpty ? data.member.imUID : data.imUID
        apiContext.imToken = data.imToken
        if let session = data.session {
            apiContext.appID = IMAPIContext.normalizedIOSAppID(session.appID.isEmpty ? (data.app.appID.isEmpty ? apiContext.appID : data.app.appID) : session.appID)
            apiContext.deviceID = session.deviceID.isEmpty ? apiContext.deviceID : session.deviceID
            apiContext.persistAuthSession(session.authSession, fallbackTokenType: "im", fallbackTenantID: data.tenant.id)
        } else {
            apiContext.appID = IMAPIContext.normalizedIOSAppID(data.app.appID.isEmpty ? apiContext.appID : data.app.appID)
        }
        apiContext.persistAuthSession(data.authSession, fallbackTokenType: "im", fallbackTenantID: data.tenant.id)
        let persistenceResult = apiContext.save(sessionStore: protectedSessionStore)
        resetInitialSplashOverlayEvaluationState()

        let enterprise = enterprise(from: RemoteTenantMembership(tenant: data.tenant, member: data.member), fallbackAccent: currentEnterprise.accentHex)
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        if enterprises.contains(where: { $0.id == enterprise.id }) {
            setEnterprises(enterprises.map { $0.id == enterprise.id ? enterprise : $0 }) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        } else {
            updateEnterprises { $0.insert(enterprise, at: 0) } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        let switchedIMUID = apiContext.imUID ?? data.member.imUID
        applyTenantSwitchUser(tenantName: enterprise.name, member: data.member, user: data.user, imUID: switchedIMUID)
        recordAccessDiagnosticsMerchantEntered()
        return persistenceResult.isCommitted
    }

}
