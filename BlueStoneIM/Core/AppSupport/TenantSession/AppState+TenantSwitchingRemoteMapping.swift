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
                currentEnterprise = enterprise(from: result.tenant, fallbackAccent: currentEnterprise.accentHex, role: result.member.role)
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
                        deviceID: context.deviceID
                    )
                    guard isCurrent?() ?? true else { throw CancellationError() }
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
                            deviceID: context.deviceID
                        )
                        guard !result.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw IMAPIError.missingContext("im_token")
                        }
                        guard isCurrent?() ?? true else { throw CancellationError() }
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
                            deviceID: context.deviceID
                        )
                        guard isCurrent?() ?? true else { throw CancellationError() }
                        guard applyPlatformTenantSwitchData(result) else {
                            throw IMAPIError.server("protected_session_persistence_failed")
                        }
                    }
                    clearTenantScopedSearchState(reason: "tenant_switch")
                    return
                } catch let error as CancellationError {
                    throw error
                } catch {
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
                let refreshed = await refreshStoredAuthSessionIfNeeded(
                    reason: "workspace_enter_unauthorized",
                    silent: true,
                    context: apiContext
                )
                guard isCurrent?() ?? true else { throw CancellationError() }
                if refreshed {
                    continue
                }
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
        currentEnterprise = enterprise
        if enterprises.contains(where: { $0.id == enterprise.id }) {
            enterprises = enterprises.map { $0.id == enterprise.id ? enterprise : $0 }
        } else {
            enterprises.insert(enterprise, at: 0)
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
        currentUser = IMUser(
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
        )
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
        currentEnterprise = enterprise
        if enterprises.contains(where: { $0.id == enterprise.id }) {
            enterprises = enterprises.map { $0.id == enterprise.id ? enterprise : $0 }
        } else {
            enterprises.insert(enterprise, at: 0)
        }
        let switchedIMUID = apiContext.imUID ?? data.member.imUID
        applyTenantSwitchUser(tenantName: enterprise.name, member: data.member, user: data.user, imUID: switchedIMUID)
        recordAccessDiagnosticsMerchantEntered()
        return persistenceResult.isCommitted
    }

    func applyTenantMemberships(_ memberships: [RemoteTenantMembership]) {
        let scopedMemberships = memberships.filter { $0.isVisibleInAppScope(currentAppID) }
        guard !scopedMemberships.isEmpty else {
            enterprises = []
            currentEnterprise = Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)
            return
        }
        let mapped = scopedMemberships.enumerated().map { index, membership in
            enterprise(from: membership, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
        }
        enterprises = mapped
        if let remoteCurrent = mapped.first(where: { $0.id == apiContext.tenantID && $0.isWorkspaceJoined && $0.isWorkspaceEnterable })
            ?? mapped.first(where: { $0.isWorkspaceJoined && $0.isWorkspaceEnterable }) {
            currentEnterprise = remoteCurrent
        }
    }

    private func resolvedEnterpriseLogoURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return resolveTenantAssetURL(trimmed)
    }

    func enterprise(from membership: RemoteTenantMembership, fallbackAccent: UInt) -> Enterprise {
        let joinStatus = membership.joinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? membership.member.status : membership.joinStatus
        let resolvedRole = authoritativeTenantRole(forTenantID: membership.tenant.id) ?? membership.member.role
        let pendingOrRejected = Enterprise(
            id: membership.tenant.id,
            name: membership.tenant.name,
            code: membership.tenant.tenantCode,
            role: resolvedRole,
            status: membership.member.status,
            memberCount: 0,
            isDefault: membership.tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(membership.tenant.logoURL),
            logoStatus: membership.tenant.logoStatus,
            logoVersion: membership.tenant.logoVersion,
            logoUpdatedAt: membership.tenant.logoUpdatedAt,
            logoCacheKey: membership.tenant.logoCacheKey,
            logoMime: membership.tenant.logoMime,
            logoWidth: membership.tenant.logoWidth,
            logoHeight: membership.tenant.logoHeight,
            joinStatus: joinStatus,
            applicationID: membership.applicationID,
            applicationStatus: membership.applicationStatus,
            approvalRequired: membership.approvalRequired,
            canSwitch: membership.canSwitch ?? true,
            enterable: membership.enterable,
            accountStatus: "",
            tenantStatus: membership.tenant.status,
            memberStatus: membership.member.status,
            disabledReason: membership.disabledReason
        )
        let blockedByApplication = pendingOrRejected.isWorkspaceJoinPending || pendingOrRejected.isWorkspaceJoinRejected
        return Enterprise(
            id: membership.tenant.id,
            name: membership.tenant.name,
            code: membership.tenant.tenantCode,
            role: resolvedRole,
            status: membership.member.status,
            memberCount: 0,
            isDefault: membership.tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(membership.tenant.logoURL),
            logoStatus: membership.tenant.logoStatus,
            logoVersion: membership.tenant.logoVersion,
            logoUpdatedAt: membership.tenant.logoUpdatedAt,
            logoCacheKey: membership.tenant.logoCacheKey,
            logoMime: membership.tenant.logoMime,
            logoWidth: membership.tenant.logoWidth,
            logoHeight: membership.tenant.logoHeight,
            joinStatus: joinStatus,
            applicationID: membership.applicationID,
            applicationStatus: membership.applicationStatus,
            approvalRequired: membership.approvalRequired,
            canSwitch: blockedByApplication ? false : (membership.canSwitch ?? true),
            enterable: blockedByApplication ? false : membership.enterable,
            tenantStatus: membership.tenant.status,
            memberStatus: membership.member.status,
            disabledReason: blockedByApplication && membership.disabledReason.isEmpty ? (pendingOrRejected.isWorkspaceJoinPending ? "pending" : "rejected") : membership.disabledReason
        )
    }

    func applyWorkspaces(_ workspaces: [RemoteWorkspaceTenant]) {
        let mapped = workspaces.enumerated().map { index, workspace in
            enterprise(from: workspace, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
        }
        if enterprises != mapped {
            enterprises = mapped
        }
        handleWorkspaceApplicationStatus(mapped)
        if let remoteCurrent = mapped.first(where: { ($0.isCurrent || $0.id == apiContext.tenantID) && $0.isWorkspaceJoined && $0.isWorkspaceEnterable })
            ?? mapped.first(where: { $0.isWorkspaceJoined && $0.isWorkspaceEnterable }) {
            if currentEnterprise != remoteCurrent {
                currentEnterprise = remoteCurrent
            }
        }
    }

    func handleWorkspaceApplicationStatus(_ items: [Enterprise]) {
        let rejectedIDs = Set(items.filter { $0.isWorkspaceJoinRejected }.map(\.id))
        guard !rejectedIDs.isEmpty else { return }
        enterpriseSearchResults = enterpriseSearchResults.map { existing in
            if let updated = items.first(where: { $0.id == existing.id }) {
                return updated
            }
            return existing
        }
        if items.contains(where: { rejectedIDs.contains($0.id) }) {
            toast = "系统通知：入企申请已被拒绝"
        }
    }

    func upsertEnterpriseSearchResult(_ enterprise: Enterprise) {
        if let index = enterpriseSearchResults.firstIndex(where: { $0.id == enterprise.id }) {
            enterpriseSearchResults[index] = enterprise
        } else {
            enterpriseSearchResults.append(enterprise)
        }
    }

    func upsertEnterprise(_ enterprise: Enterprise) {
        if let index = enterprises.firstIndex(where: { $0.id == enterprise.id }) {
            enterprises[index] = enterprise
        } else {
            enterprises.append(enterprise)
        }
    }

    func enterprise(from tenant: RemoteTenant, fallbackAccent: UInt) -> Enterprise {
        Enterprise(
            id: tenant.id,
            name: tenant.name,
            code: tenant.tenantCode,
            role: "",
            status: tenant.status,
            memberCount: 0,
            isDefault: tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(tenant.logoURL),
            logoStatus: tenant.logoStatus,
            logoVersion: tenant.logoVersion,
            logoUpdatedAt: tenant.logoUpdatedAt,
            logoCacheKey: tenant.logoCacheKey,
            logoMime: tenant.logoMime,
            logoWidth: tenant.logoWidth,
            logoHeight: tenant.logoHeight,
            searchEntryType: tenant.entryType,
            searchInviterName: [tenant.inviterNickname, tenant.inviterDisplayName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        )
    }

    func enterprise(from workspace: RemoteWorkspaceTenant, fallbackAccent: UInt, role overrideRole: String? = nil) -> Enterprise {
        Enterprise(
            id: workspace.id,
            name: workspace.name,
            code: workspace.tenantCode,
            role: overrideRole ?? authoritativeTenantRole(forTenantID: workspace.id) ?? workspace.memberRole,
            status: workspace.status,
            memberCount: 0,
            isDefault: workspace.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(workspace.logoURL),
            logoStatus: workspace.logoStatus,
            logoVersion: workspace.logoVersion,
            logoUpdatedAt: workspace.logoUpdatedAt,
            logoCacheKey: workspace.logoCacheKey,
            logoMime: workspace.logoMime,
            logoWidth: workspace.logoWidth,
            logoHeight: workspace.logoHeight,
            joinStatus: workspace.joinStatus,
            applicationID: workspace.applicationID,
            applicationStatus: workspace.applicationStatus,
            approvalRequired: workspace.approvalRequired,
            canSwitch: workspace.canSwitch,
            enterable: workspace.enterable,
            isCurrent: workspace.current,
            accountStatus: workspace.accountStatus,
            tenantStatus: workspace.tenantStatus,
            memberStatus: workspace.memberStatus,
            disabledReason: workspace.disabledReason
        )
    }

    private func authoritativeTenantRole(forTenantID rawTenantID: String) -> String? {
        guard let authority = tenantContextRoleAuthority else { return nil }
        let tenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentIMUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tenantID.isEmpty,
              authority.appID == currentAppID,
              authority.tenantID == tenantID,
              authority.tenantID == currentTenantID,
              authority.imUID == currentIMUID,
              !authority.role.isEmpty else {
            return nil
        }
        return authority.role
    }

    private func enterprise(_ source: Enterprise, replacingRole role: String) -> Enterprise {
        guard source.role != role else { return source }
        return Enterprise(
            id: source.id,
            name: source.name,
            code: source.code,
            role: role,
            status: source.status,
            memberCount: source.memberCount,
            isDefault: source.isDefault,
            accentHex: source.accentHex,
            logoURL: source.logoURL,
            logoStatus: source.logoStatus,
            logoVersion: source.logoVersion,
            logoUpdatedAt: source.logoUpdatedAt,
            logoCacheKey: source.logoCacheKey,
            logoMime: source.logoMime,
            logoWidth: source.logoWidth,
            logoHeight: source.logoHeight,
            joinStatus: source.joinStatus,
            applicationID: source.applicationID,
            applicationStatus: source.applicationStatus,
            approvalRequired: source.approvalRequired,
            canSwitch: source.canSwitch,
            enterable: source.enterable,
            isCurrent: source.isCurrent,
            accountStatus: source.accountStatus,
            tenantStatus: source.tenantStatus,
            memberStatus: source.memberStatus,
            disabledReason: source.disabledReason,
            searchEntryType: source.searchEntryType,
            searchInviterName: source.searchInviterName
        )
    }

    private func applyTenantContextRoleAuthority(_ user: RemoteIMUser, context: RemoteTenantContext) {
        let role = user.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantID = [context.tenantID, context.tenant.tenantID, apiContext.tenantID ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let contextIMUID = context.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let userIMUID = user.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIMUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imUID = [userIMUID, contextIMUID, currentIMUID].first { !$0.isEmpty } ?? ""
        let contextAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = IMAPIContext.normalizedIOSAppID(contextAppID.isEmpty ? apiContext.appID : contextAppID)
        let currentTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !role.isEmpty,
              !tenantID.isEmpty,
              !imUID.isEmpty,
              tenantID == currentTenantID,
              imUID == currentIMUID,
              (userIMUID.isEmpty || userIMUID == currentIMUID),
              (contextIMUID.isEmpty || contextIMUID == currentIMUID),
              appID == currentAppID else {
            tenantContextRoleAuthority = nil
            return
        }
        tenantContextRoleAuthority = TenantContextRoleAuthority(
            appID: appID,
            tenantID: tenantID,
            imUID: imUID,
            role: role
        )
        let nextCurrent = enterprise(currentEnterprise, replacingRole: role)
        if nextCurrent != currentEnterprise {
            currentEnterprise = nextCurrent
        }
        enterprises = enterprises.map { item in
            item.id == tenantID ? enterprise(item, replacingRole: role) : item
        }
    }

    func reconcileTenantContextRoleAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard tenantContextRoleAuthority != nil else { return }
        let oldBinding = [
            IMAPIContext.normalizedIOSAppID(oldContext.appID),
            oldContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            oldContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        let newBinding = [
            IMAPIContext.normalizedIOSAppID(newContext.appID),
            newContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            newContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        if oldBinding != newBinding {
            tenantContextRoleAuthority = nil
        }
    }

    func applyTenantProfile(_ profile: RemoteTenantProfile) {
        let tenantID = profile.tenantID.isEmpty ? (apiContext.tenantID ?? currentEnterprise.id) : profile.tenantID
        let tenantCode = profile.tenantCode.isEmpty ? currentEnterprise.code : profile.tenantCode
        let currentName = currentEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameCurrentEnterprise = !tenantID.isEmpty && tenantID == currentEnterprise.id
        let tenantName = sameCurrentEnterprise && !currentName.isEmpty ? currentName : (profile.name.isEmpty ? currentEnterprise.name : profile.name)
        let status = profile.status.isEmpty ? currentEnterprise.status : profile.status
        let profileLogoStatus = profile.logoStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogoStatus = profileLogoStatus.lowercased()
        let logoCleared = ["empty", "unsafe", "cleared", "removed"].contains(normalizedLogoStatus)
        let rawLogoURL = profile.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let logoURL = rawLogoURL.isEmpty ? (logoCleared ? "" : currentEnterprise.logoURL) : resolvedEnterpriseLogoURL(rawLogoURL)
        let logoStatus = profileLogoStatus.isEmpty ? (logoCleared ? "empty" : currentEnterprise.logoStatus) : profileLogoStatus
        let logoVersion = profile.logoVersion.isEmpty ? (logoCleared ? "" : currentEnterprise.logoVersion) : profile.logoVersion
        let logoUpdatedAt = profile.logoUpdatedAt.isEmpty ? (logoCleared ? "" : currentEnterprise.logoUpdatedAt) : profile.logoUpdatedAt
        let logoCacheKey = profile.logoCacheKey.isEmpty ? (logoCleared ? "" : currentEnterprise.logoCacheKey) : profile.logoCacheKey
        let logoMime = profile.logoMime.isEmpty ? (logoCleared ? "" : currentEnterprise.logoMime) : profile.logoMime
        let logoWidth = profile.logoWidth ?? (logoCleared ? nil : currentEnterprise.logoWidth)
        let logoHeight = profile.logoHeight ?? (logoCleared ? nil : currentEnterprise.logoHeight)
        let enterprise = Enterprise(
            id: tenantID,
            name: tenantName,
            code: tenantCode,
            role: currentEnterprise.role,
            status: status,
            memberCount: currentEnterprise.memberCount,
            isDefault: currentEnterprise.isDefault || tenantCode.uppercased() == "DEFAULT",
            accentHex: currentEnterprise.accentHex,
            logoURL: logoURL,
            logoStatus: logoStatus,
            logoVersion: logoVersion,
            logoUpdatedAt: logoUpdatedAt,
            logoCacheKey: logoCacheKey,
            logoMime: logoMime,
            logoWidth: logoWidth,
            logoHeight: logoHeight,
            joinStatus: currentEnterprise.joinStatus,
            applicationID: currentEnterprise.applicationID,
            applicationStatus: currentEnterprise.applicationStatus,
            approvalRequired: currentEnterprise.approvalRequired,
            canSwitch: currentEnterprise.canSwitch,
            enterable: currentEnterprise.enterable,
            isCurrent: currentEnterprise.isCurrent,
            accountStatus: currentEnterprise.accountStatus,
            tenantStatus: currentEnterprise.tenantStatus,
            memberStatus: currentEnterprise.memberStatus,
            disabledReason: currentEnterprise.disabledReason
        )
        if currentEnterprise != enterprise {
            currentEnterprise = enterprise
        }
        if let index = enterprises.firstIndex(where: { $0.id == enterprise.id }) {
            if enterprises[index] != enterprise {
                enterprises[index] = enterprise
            }
        } else {
            enterprises.insert(enterprise, at: 0)
        }
        if currentUser.id == apiContext.imUID, currentUser.enterprise != enterprise.name {
            currentUser = IMUser(
                id: currentUser.id,
                userID: currentUser.userID,
                username: currentUser.username,
                name: currentUser.name,
                title: "",
                department: "",
                phone: currentUser.phone,
                phoneVerified: currentUser.phoneVerified,
                realNameVerified: currentUser.realNameVerified,
                realNameStatus: currentUser.realNameStatus,
                email: currentUser.email,
                status: currentUser.status,
                enterprise: enterprise.name,
                avatarSeed: currentUser.avatarSeed,
                avatarURL: currentUser.avatarURL,
                avatarVersion: currentUser.avatarVersion,
                avatarUpdatedAt: currentUser.avatarUpdatedAt,
                badges: []
            )
        }
    }

    static func validateAuthenticatedTenantContextBinding(
        _ context: RemoteTenantContext,
        expected: IMAPIContext
    ) -> AuthenticatedTenantContextBindingValidation {
        guard expected.hasIMSession else { return .incomplete }
        let expectedTenantID = expected.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedIMUID = expected.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedAppID = IMAPIContext.normalizedIOSAppID(expected.appID)
        let expectedDeviceID = expected.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedAccountID = expected.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let tenantIDs = [context.tenantID, context.tenant.tenantID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let imUIDs = [context.imUID, context.user?.imUID ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let responseAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedTenantID.isEmpty,
              !expectedIMUID.isEmpty,
              !expectedAppID.isEmpty,
              !tenantIDs.isEmpty,
              !imUIDs.isEmpty,
              !responseAppID.isEmpty else {
            return .incomplete
        }
        guard tenantIDs.allSatisfy({ $0 == expectedTenantID }),
              imUIDs.allSatisfy({ $0 == expectedIMUID }),
              IMAPIContext.normalizedIOSAppID(responseAppID) == expectedAppID else {
            return .mismatch
        }
        let responseDeviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseDeviceID.isEmpty, responseDeviceID != expectedDeviceID {
            return .mismatch
        }
        let responseAccountID = context.user?.accountID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedAccountID.isEmpty,
           !responseAccountID.isEmpty,
           responseAccountID != expectedAccountID {
            return .mismatch
        }
        return .verified
    }

    @discardableResult
    func applyTenantContext(_ context: RemoteTenantContext) -> Bool {
        applyTenantContext(context, devicePolicyAuthority: nil)
    }

    @discardableResult
    func applyTenantContext(
        _ context: RemoteTenantContext,
        devicePolicyAuthority: TenantDevicePolicyRequestAuthority?,
        profileAuthorityRequest: CurrentProfileAuthorityRequest? = nil
    ) -> Bool {
        switch Self.validateAuthenticatedTenantContextBinding(context, expected: apiContext) {
        case .verified:
            break
        case .incomplete:
            print("[JHT Auth] tenant_context_ignored reason=incomplete_binding")
            return false
        case .mismatch:
            handleVerifiedTenantContextBindingMismatch()
            return false
        }
        // A coalesced tenant-context response can still carry valid profile,
        // workspace and ordinary client-policy data after a newer device-policy
        // refresh has taken authority.  Fence only the multi-device projection;
        // dropping the whole response makes the older refresh report a false
        // failure and discards unrelated authoritative context.
        let applicableDevicePolicyAuthority: TenantDevicePolicyRequestAuthority?
        if let devicePolicyAuthority,
           isCurrentTenantDevicePolicyRequest(devicePolicyAuthority),
           tenantContextMatchesDevicePolicyAuthority(
                context,
                authority: devicePolicyAuthority
           ) {
            applicableDevicePolicyAuthority = devicePolicyAuthority
        } else {
            applicableDevicePolicyAuthority = nil
        }
        let previousTenantID = apiContext.tenantID
        let previousIMUID = apiContext.imUID
        if !context.tenantID.isEmpty {
            apiContext.tenantID = context.tenantID
        }
        if !context.imUID.isEmpty {
            apiContext.imUID = context.imUID
        }
        if !context.appID.isEmpty {
            apiContext.appID = IMAPIContext.normalizedIOSAppID(context.appID)
        }
        if !context.deviceID.isEmpty {
            apiContext.deviceID = context.deviceID
        }
        apiContext.save(sessionStore: protectedSessionStore)
        let didChangeInviteAuthority = previousTenantID != apiContext.tenantID || previousIMUID != apiContext.imUID
        if didChangeInviteAuthority {
            resetAuthenticatedRemoteData(invalidateRefresh: false, showLoading: true)
        }
        applyTenantClientPolicy(
            context.clientPolicy,
            context: apiContext,
            devicePolicyAuthority: applicableDevicePolicyAuthority
        )
        if let departmentEnabled = context.departmentEnabled {
            tenantDepartmentEnabled = departmentEnabled
            if !departmentEnabled {
                clearOrganizationDirectory(disabled: true)
            }
        }
        applyTenantProfile(context.tenant)
        if let user = context.user {
            applyTenantContextRoleAuthority(user, context: context)
            if let profileAuthorityRequest {
                let snapshot = currentProfileAuthoritySnapshot(
                    from: user,
                    context: context,
                    request: profileAuthorityRequest
                )
                guard acceptsCurrentProfileAuthority(snapshot, request: profileAuthorityRequest) else {
                    if didChangeInviteAuthority {
                        activateMyInviteCodeForCurrentSession()
                    }
                    return true
                }
            }
            let resolvedIMUID = user.imUID.isEmpty ? currentUser.id : user.imUID
            let resolvedUserID = user.userID.isEmpty ? (user.imUID.isEmpty ? currentUser.userID : user.imUID) : user.userID
            let resolvedUsername = resolvedCurrentUserUsername(remoteUsername: user.username, currentUsername: currentUser.username)
            let displayName = preferredDisplayName(
                candidates: [currentProfileAuthorityDisplayNameCandidate(), user.nickname, currentUser.name, resolvedUsername, user.userID, user.imUID],
                identifiers: [resolvedIMUID, resolvedUserID, currentUser.id, currentUser.userID],
                fallback: currentUser.name.isEmpty ? resolvedIMUID : currentUser.name
            )
            let userPhone = user.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextPhone = user.phoneBindingKnown
                ? (user.phoneVerified ? userPhone : "")
                : (userPhone.isEmpty ? currentUser.phone : userPhone)
            let nextPhoneVerified = user.phoneBindingKnown ? user.phoneVerified : currentUser.phoneVerified
            currentUser = IMUser(
                id: resolvedIMUID,
                userID: resolvedUserID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: normalizedDepartmentName(user.departmentName, pathNames: user.departmentPathNames),
                departmentPathNames: normalizedDepartmentPathNames(user.departmentPathNames, fallbackName: user.departmentName),
                phone: nextPhone,
                phoneVerified: nextPhoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.accountID.isEmpty ? currentUser.email : user.accountID,
                status: presenceStatusText(
                    rawStatus: user.presenceStatus,
                    online: user.onlineKnown ? user.online : nil
                ),
                lastLoginAt: resolvedLastLoginText(user.lastSeenAt),
                enterprise: currentEnterprise.name,
                avatarSeed: stableSeed(user.imUID.isEmpty ? currentUser.id : user.imUID),
                avatarURL: user.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(user.avatar),
                avatarVersion: user.avatarVersion.isEmpty ? currentUser.avatarVersion : user.avatarVersion,
                avatarUpdatedAt: user.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : user.avatarUpdatedAt,
                badges: currentUser.badges
            )
        }
        if didChangeInviteAuthority {
            activateMyInviteCodeForCurrentSession()
        }
        return true
    }

    private func handleVerifiedTenantContextBindingMismatch() {
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        isRestoringSession = false
        isAuthenticated = false
        activeTab = .chats
        authScreen = .accountLogin
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        toast = "登录身份校验不一致，请重新登录"
    }

    @discardableResult
    func applyMeProfile(
        _ profile: RemoteMeProfile,
        authorityRequest: CurrentProfileAuthorityRequest? = nil,
        usernameFallback: String? = nil,
        nicknameFallback: String? = nil
    ) -> Bool {
        if let authorityRequest {
            let snapshot = currentProfileAuthoritySnapshot(from: profile, request: authorityRequest)
            guard acceptsCurrentProfileAuthority(snapshot, request: authorityRequest) else {
                return false
            }
        }
        let resolvedIMUID = profile.imUID.isEmpty ? currentUser.id : profile.imUID
        let resolvedUserID = profile.userID.isEmpty ? (profile.imUID.isEmpty ? currentUser.userID : profile.imUID) : profile.userID
        let resolvedUsername = resolvedCurrentUserUsername(
            remoteUsername: profile.username,
            fallbackUsername: usernameFallback,
            currentUsername: currentUser.username
        )
        let profilePhone = profile.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextPhone = profile.phoneBindingKnown
            ? (profile.phoneVerified ? profilePhone : "")
            : (profilePhone.isEmpty ? currentUser.phone : profilePhone)
        let nextPhoneVerified = profile.phoneBindingKnown
            ? profile.phoneVerified
            : (currentUser.phoneVerified || !nextPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let displayName = preferredDisplayName(
            candidates: [currentProfileAuthorityDisplayNameCandidate(), profile.nickname, nicknameFallback, currentUser.name, resolvedUsername, profile.userID, profile.imUID],
            identifiers: [resolvedIMUID, resolvedUserID, currentUser.id, currentUser.userID],
            fallback: currentUser.name.isEmpty ? resolvedIMUID : currentUser.name
        )
        let nextUser = IMUser(
            id: resolvedIMUID,
            userID: resolvedUserID,
            username: resolvedUsername,
            name: displayName,
            title: "",
            department: normalizedDepartmentName(profile.departmentName, pathNames: profile.departmentPathNames),
            departmentPathNames: normalizedDepartmentPathNames(profile.departmentPathNames, fallbackName: profile.departmentName),
            phone: nextPhone,
            phoneVerified: nextPhoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: presenceStatusText(
                rawStatus: profile.presenceStatus,
                online: profile.onlineKnown ? profile.online : nil
            ),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(profile.imUID.isEmpty ? currentUser.id : profile.imUID),
            avatarURL: profile.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(profile.avatar),
            avatarVersion: profile.avatarVersion.isEmpty ? currentUser.avatarVersion : profile.avatarVersion,
            avatarUpdatedAt: profile.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : profile.avatarUpdatedAt,
            badges: currentUser.badges
        )
        replaceCurrentUserAndProject(nextUser)
        reconcileForcedAppPolicyAuthState(for: nextUser)
        return true
    }

    func applyFriendRelations(
        _ relations: [RemoteFriendRelation],
        readStamp: ProfileContactReadStamp?
    ) {
        let applyStart = CFAbsoluteTimeGetCurrent()
        print("[JHT Perf] contacts_apply_start input=\(relations.count) existing=\(contacts.count) blacklist=\(blacklist.count)")
        let existing = contacts.reduce(into: [String: IMUser]()) { result, user in
            let key = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = user
        }
        let existingByUserID = contacts.reduce(into: [String: IMUser]()) { result, user in
            let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userID.isEmpty, result[userID] == nil {
                result[userID] = user
            }
        }
        let blockedIDs = Set(
            blacklist
                .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var nextRemarks: [String: String] = [:]
        let scope = remoteDataScopeKey(for: apiContext)
        let currentScopePrefix = "\(scope)|"
        var nextContactCardOriginalNames = contactCardOriginalNamesByScopedUserKey.filter { key, _ in
            !key.hasPrefix(currentScopePrefix)
        }
        var nextCanonicalFriendUIDsByIdentity: [FriendIdentityKey: Set<String>] = [:]
        func recordCanonicalFriendUID(_ canonicalFriendUID: String, for key: FriendIdentityKey) {
            let normalizedUID = canonicalFriendUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedUID.isEmpty else { return }
            var values = nextCanonicalFriendUIDsByIdentity[key] ?? []
            values.insert(normalizedUID)
            nextCanonicalFriendUIDsByIdentity[key] = values
        }
        var seenFriendUIDs: Set<String> = []
        var droppedDuplicateCount = 0
        var nextContacts: [IMUser] = relations.compactMap { relation in
            let friendUID = relation.friendUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !friendUID.isEmpty, !blockedIDs.contains(friendUID) else { return nil }
            guard seenFriendUIDs.insert(friendUID).inserted else {
                droppedDuplicateCount += 1
                return nil
            }
            let rawNickname = relation.rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = preferredDisplayName(
                candidates: [relation.remark, relation.displayName, rawNickname, relation.friendNickname, relation.friendUserID],
                identifiers: [friendUID, relation.friendUserID],
                fallback: relation.friendUID
            )
            if let remark = relation.remark?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                nextRemarks[friendUID] = remark
            }
            if let canonicalFriendUID = relation.authoritativeFriendUID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonicalFriendUID.isEmpty,
               canonicalFriendUID == friendUID {
                recordCanonicalFriendUID(canonicalFriendUID, for: .imUID(canonicalFriendUID))
                let friendUserID = relation.authoritativeFriendUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !friendUserID.isEmpty {
                    recordCanonicalFriendUID(canonicalFriendUID, for: .userID(friendUserID))
                }
            }
            let remoteDisplayNameSource = relation.displayNameSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let remoteDisplayName = remoteDisplayNameSource.contains("remark")
                ? nil
                : relation.displayName
            let originalName = preferredDisplayName(
                candidates: [rawNickname, relation.friendNickname, remoteDisplayName, relation.friendUserID],
                identifiers: [friendUID, relation.friendUserID],
                fallback: relation.friendUID
            )
            cacheContactCardOriginalName(
                originalName,
                identifiers: [friendUID, relation.friendUserID],
                scope: scope,
                in: &nextContactCardOriginalNames
            )
            let existingUser = existing[friendUID] ?? existingByUserID[relation.friendUserID]
            let avatar = relation.friendAvatar.isEmpty ? existingUser?.avatarURL ?? "" : resolveTenantAssetURL(relation.friendAvatar)
            let relationDepartmentName = relation.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let relationDepartmentPath = relation.departmentPathNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hasRelationDepartment = !relationDepartmentName.isEmpty || !relationDepartmentPath.isEmpty
            let department = hasRelationDepartment
                ? normalizedDepartmentName(relation.departmentName, pathNames: relation.departmentPathNames)
                : existingUser?.department ?? ""
            let departmentPathNames = hasRelationDepartment
                ? normalizedDepartmentPathNames(relation.departmentPathNames, fallbackName: department)
                : existingUser?.departmentPathNames ?? []
            return IMUser(
                id: friendUID,
                userID: relation.friendUserID.isEmpty ? friendUID : relation.friendUserID,
                name: displayName,
                title: "",
                department: department,
                departmentPathNames: departmentPathNames,
                phone: relation.visiblePhone,
                email: "",
                status: presenceStatusText(
                    rawStatus: relation.friendStatus,
                    online: relation.friendOnlineKnown ? relation.friendOnline : nil
                ),
                lastLoginAt: resolvedLastLoginText(relation.friendLastSeenAt),
                enterprise: currentEnterprise.name,
                avatarSeed: existingUser?.avatarSeed ?? stableSeed(friendUID),
                avatarURL: avatar,
                avatarVersion: relation.friendAvatarVersion.isEmpty ? existingUser?.avatarVersion ?? "" : relation.friendAvatarVersion,
                avatarUpdatedAt: relation.friendAvatarUpdatedAt.isEmpty ? existingUser?.avatarUpdatedAt ?? "" : relation.friendAvatarUpdatedAt,
                badges: existingUser?.badges ?? []
            )
        }
        let currentContacts = contacts
        for current in currentContacts {
            let identifiers = userIdentityCandidates(for: current)
            let wasMutated = identifiers.contains { identifier in
                profileContactRevisionFence.wasMutated(
                    profileContactKey("contact", identifier: identifier),
                    after: readStamp
                ) || profileContactRevisionFence.wasMutated(
                    profileContactKey("remark", identifier: identifier),
                    after: readStamp
                )
            }
            guard wasMutated else { continue }
            for identifier in identifiers {
                guard let cacheKey = contactCardOriginalNameCacheKey(for: identifier, scope: scope) else {
                    continue
                }
                if let currentOriginalName = contactCardOriginalNamesByScopedUserKey[cacheKey] {
                    nextContactCardOriginalNames[cacheKey] = currentOriginalName
                } else {
                    nextContactCardOriginalNames.removeValue(forKey: cacheKey)
                }
            }
            let isBlocked = blockedIDs.contains { blockedID in
                identifiers.contains(blockedID)
            }
            if isBlocked {
                nextContacts.removeAll { candidate in
                    identifiers.contains { user(candidate, matchesIdentifier: $0) }
                }
            } else if let index = nextContacts.firstIndex(where: { candidate in
                identifiers.contains { user(candidate, matchesIdentifier: $0) }
            }) {
                nextContacts[index] = current
            } else {
                nextContacts.append(current)
            }
        }
        nextContacts.removeAll { candidate in
            let identifiers = userIdentityCandidates(for: candidate)
            let wasMutated = identifiers.contains { identifier in
                profileContactRevisionFence.wasMutated(
                    profileContactKey("contact", identifier: identifier),
                    after: readStamp
                ) || profileContactRevisionFence.wasMutated(
                    profileContactKey("remark", identifier: identifier),
                    after: readStamp
                )
            }
            guard wasMutated else { return false }
            return !currentContacts.contains { current in
                identifiers.contains { user(current, matchesIdentifier: $0) }
            }
        }
        let remarkKeys = Set(nextRemarks.keys).union(contactRemarks.keys)
        for key in remarkKeys where profileContactRevisionFence.wasMutated(
            profileContactKey("remark", identifier: key),
            after: readStamp
        ) {
            if let current = contactRemarks[key] {
                nextRemarks[key] = current
            } else {
                nextRemarks.removeValue(forKey: key)
            }
        }
        if droppedDuplicateCount > 0 {
            print("[JHT Perf] contacts_sync_dedupe dropped=\(droppedDuplicateCount) input=\(relations.count)")
        }
        let mapMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        print("[JHT Perf] contacts_apply_rows_ready count=\(nextContacts.count) map_ms=\(mapMs)")
        contacts = nextContacts
        contactRemarks = nextRemarks
        contactCardOriginalNamesByScopedUserKey = nextContactCardOriginalNames
        canonicalFriendUIDsByIdentity = nextCanonicalFriendUIDsByIdentity
        canonicalFriendUIDIdentityScope = scope
        contactStore.markFriendRelationsLoaded()
        print("[JHT Perf] contacts_apply_store_updated count=\(contacts.count)")
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        print("[JHT Perf] contacts_apply_done count=\(contacts.count) total_ms=\(totalMs)")
        scheduleContactsPostApplyReconciliation(reason: "contacts_sync")
        commitAuthoritativeProfileContactProjection(scope: scope, reason: "friends_read")
    }

    private func scheduleContactsPostApplyReconciliation(reason: String) {
        let scope = remoteDataScopeKey(for: apiContext)
        contactsPostApplyReconciliationGeneration &+= 1
        let generation = contactsPostApplyReconciliationGeneration
        contactsPostApplyReconciliationTask?.cancel()
        contactsPostApplyReconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.contactsPostApplyReconciliationGeneration == generation,
                  self.isCurrentRemoteScope(scope),
                  self.contactStore.friendRelationsLoaded() else {
                return
            }
            let start = CFAbsoluteTimeGetCurrent()
            // JHT_MOD_BEGIN CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改开始：联系人后处理分段让出主线程，避免三段重计算连续压帧
            var phaseStart = CFAbsoluteTimeGetCurrent()
            self.refreshDirectConversationDisplayNames()
            self.logContactsPostApplyReconciliationPhase("refresh_direct_conversation_display_names", startedAt: phaseStart, reason: reason)
            guard await self.pauseContactsPostApplyReconciliationSlice(generation: generation, scope: scope) else { return }
            phaseStart = CFAbsoluteTimeGetCurrent()
            self.pruneNonFriendDirectConversations()
            self.logContactsPostApplyReconciliationPhase("prune_non_friend_direct_conversations", startedAt: phaseStart, reason: reason)
            guard await self.pauseContactsPostApplyReconciliationSlice(generation: generation, scope: scope) else { return }
            phaseStart = CFAbsoluteTimeGetCurrent()
            self.reapplyAllAvatarRealtimeProjections()
            self.logContactsPostApplyReconciliationPhase("reapply_avatar_realtime_projections", startedAt: phaseStart, reason: reason)
            // JHT_MOD_END CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改结束
            let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            print("[JHT Perf] contacts_post_apply_reconcile_done reason=\(reason) contacts=\(self.contacts.count) conversations=\(self.conversations.count) total_ms=\(totalMs)")
            if self.contactsPostApplyReconciliationGeneration == generation {
                self.contactsPostApplyReconciliationTask = nil
            }
        }
    }

    // JHT_MOD_BEGIN CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改开始：联系人后处理异步分片工具
    private func pauseContactsPostApplyReconciliationSlice(generation: UInt64, scope: String) async -> Bool {
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 16_000_000)
        } catch {
            return false
        }
        return !Task.isCancelled
            && contactsPostApplyReconciliationGeneration == generation
            && isCurrentRemoteScope(scope)
            && contactStore.friendRelationsLoaded()
    }

    private func logContactsPostApplyReconciliationPhase(_ phase: String, startedAt: CFAbsoluteTime, reason: String) {
        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        print("[JHT Perf] contacts_post_apply_reconcile_phase phase=\(phase) reason=\(reason) elapsed_ms=\(elapsedMs)")
        #endif
    }
    // JHT_MOD_END CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改结束

    func refreshDirectConversationDisplayNames() {
        let lookup = makeConversationUserLookup()
        conversationStore.refreshDirectConversationProfiles(
            channelIDForConversation: { [self] conversation in
                remoteChannelID(for: conversation, lookup: lookup)
            },
            titleForChannel: { [self] channelID in
                titleForRemoteConversation(channelID: channelID, kind: .direct, lookup: lookup)
            },
            participantsForChannel: { [self] channelID in
                participantsForRemoteConversation(channelID: channelID, kind: .direct, lookup: lookup)
            }
        )
    }

    func applyBlacklist(
        _ relations: [RemoteBlacklistRelation],
        readStamp: ProfileContactReadStamp?
    ) {
        let contactByID = contacts.reduce(into: [String: IMUser]()) { result, user in
            let key = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = user
        }
        let existingByID = blacklist.reduce(into: [String: BlacklistItem]()) { result, item in
            let key = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = item
        }
        var seenBlockedUIDs: Set<String> = []
        var droppedDuplicateCount = 0
        var nextBlacklist: [BlacklistItem] = relations.compactMap { relation -> BlacklistItem? in
            let blockedUID = relation.blockedUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !blockedUID.isEmpty else { return nil }
            guard seenBlockedUIDs.insert(blockedUID).inserted else {
                droppedDuplicateCount += 1
                return nil
            }
            let fallbackName = blockedUID.isEmpty ? "未知用户" : blockedUID
            let name = preferredDisplayName(
                candidates: [
                    contactByID[blockedUID]?.name,
                    existingByID[blockedUID]?.name,
                    directConversationSnapshotDisplayName(forBlockedUID: blockedUID)
                ],
                identifiers: [blockedUID],
                fallback: fallbackName
            )
            return BlacklistItem(
                id: blockedUID,
                name: name,
                reason: relation.reason.isEmpty ? "已拉黑" : relation.reason
            )
        }
        let identifiers = Set(nextBlacklist.map { $0.id }).union(blacklist.map { $0.id })
        for identifier in identifiers where profileContactRevisionFence.wasMutated(
            profileContactKey("blacklist", identifier: identifier),
            after: readStamp
        ) {
            nextBlacklist.removeAll { $0.id == identifier }
            if let current = blacklist.first(where: { $0.id == identifier }) {
                nextBlacklist.append(current)
            }
        }
        blacklist = nextBlacklist
        if droppedDuplicateCount > 0 {
            print("[JHT Perf] blacklist_sync_dedupe dropped=\(droppedDuplicateCount) input=\(relations.count)")
        }
        let scope = remoteDataScopeKey(for: apiContext)
        commitAuthoritativeProfileContactProjection(scope: scope, reason: "blacklist_read")
    }

    func userSearchResult(_ remote: RemoteUserSearchItem) -> UserSearchResult {
        let friendAction = remote.friendAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canApplyFriend = remote.canApplyFriend && friendAction != "none"
        return UserSearchResult(
            imUID: remote.imUID,
            userID: remote.userID,
            nickname: preferredDisplayName(
                candidates: [remote.remark, remote.displayName, remote.rawNickname, remote.nickname, remote.userID, remote.imUID],
                identifiers: [remote.imUID, remote.userID],
                fallback: remote.userID.isEmpty ? remote.imUID : remote.userID
            ),
            phone: remote.visiblePhone,
            avatarURL: resolveTenantAssetURL(remote.avatar),
            status: remote.status,
            presenceStatus: presenceStatusText(
                rawStatus: remote.presenceStatus,
                online: remote.onlineKnown ? remote.online : nil
            ),
            relationStatus: remote.relationStatus,
            canApplyFriend: canApplyFriend,
            reason: remote.reason,
            friendAction: remote.friendAction,
            friendFlow: remote.friendFlow,
            requiresTenantReview: remote.requiresTenantReview,
            requiresTargetApproval: remote.requiresTargetApproval
        )
    }

    func userSearchBlockedMessage(_ result: UserSearchResult) -> String {
        if result.isCancelledUser {
            return "该用户已注销，无法添加好友"
        }
        let reason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch result.relationStatus {
        case "friend":
            return "你们已经是好友"
        case "pending_out":
            return FriendAddPresentation.sentMessage
        case "pending_in":
            return "对方已申请添加你，请到新朋友处理"
        case "blocked":
            return "当前用户不可添加"
        case "self":
            return "不能添加自己为好友"
        default:
            if reason == "user_disabled"
                || reason == "target_user_disabled"
                || reason == "account_disabled" {
                return "该用户已停用，无法添加"
            }
            if reason.contains("blacklist") || reason.contains("blocked") {
                return "当前用户不可添加"
            }
            if reason.contains("cross_tenant") || reason.contains("target_type") || reason.contains("not_allowed") {
                return "当前账号暂不支持添加好友"
            }
            return "当前关系状态不可申请好友"
        }
    }

    nonisolated static func friendRequestProjection(
        _ item: RemoteFriendApplication,
        currentID: String
    ) -> FriendRequest? {
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let applicantID = item.applicantUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = item.targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverDirection = item.direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCurrentID = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedDirection: String
        if !normalizedCurrentID.isEmpty, applicantID == normalizedCurrentID {
            derivedDirection = "outgoing"
        } else if !normalizedCurrentID.isEmpty, targetID == normalizedCurrentID {
            derivedDirection = "incoming"
        } else {
            derivedDirection = ""
        }
        // A valid viewer-specific server direction is authoritative.  Identity
        // derivation is retained only for legacy payloads that omitted it.
        let direction = ["incoming", "outgoing"].contains(serverDirection)
            ? serverDirection
            : derivedDirection
        guard direction == "incoming" || direction == "outgoing" else { return nil }
        let isOutgoing = direction == "outgoing"
        let isIncoming = direction == "incoming"
        let suppressed = Self.isSuppressedFriendApplication(status: status, outcome: item.outcome)
        if suppressed && isIncoming {
            return nil
        }
        let reviewStatus = item.tenantReviewStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let legacyCanRespond = isIncoming
            && item.requiresTargetApproval != false
            && status == "pending"
            && (reviewStatus.isEmpty || reviewStatus == "not_required" || reviewStatus == "approved")
        // `actionable_by_current_user` is computed for this exact viewer and is
        // therefore stronger than generic flow hints such as
        // `requires_target_approval`.  Do not hide valid accept/reject controls
        // when those compatibility fields disagree.
        let canRespond = !suppressed
            && isIncoming
            && status == "pending"
            && (item.actionableByCurrentUser ?? legacyCanRespond)
        let displayName = isOutgoing
            ? (item.targetName.isEmpty ? targetID : item.targetName)
            : (item.applicantName.isEmpty ? applicantID : item.applicantName)
        let peerID = isOutgoing ? targetID : applicantID
        let avatar = isOutgoing ? item.targetAvatar : item.applicantAvatar
        let source: String
        if isOutgoing {
            source = "我发出的申请"
        } else {
            switch item.source {
            case "direct_chat_not_friends": source = "来自私聊"
            case "profile": source = "来自个人资料"
            case "search_user": source = "来自用户搜索"
            default: source = item.source.isEmpty ? (item.sourceGroupName ?? "好友申请") : item.source
            }
        }
        let message: String
        if status == "accepted" {
            message = "申请已通过"
        } else if status == "rejected" {
            message = "申请已拒绝"
        } else if status == "cancelled" || status == "canceled" || item.outcome.lowercased() == "application_cancelled" {
            message = "申请已取消"
        } else if suppressed {
            message = FriendAddPresentation.suppressedMessage
        } else if status == "expired" || item.outcome.lowercased() == "application_expired" {
            message = "申请已过期"
        } else if isOutgoing {
            message = reviewStatus == "pending" ? "等待企业审核" : "等待对方通过"
        } else if !canRespond {
            message = "当前暂不可处理"
        } else {
            message = item.message ?? "申请添加你为好友"
        }
        return FriendRequest(
            id: item.id,
            name: displayName,
            userID: peerID,
            avatarURL: avatar,
            source: source,
            message: message,
            status: status,
            direction: direction,
            tenantReviewStatus: reviewStatus,
            peerReviewStatus: item.peerReviewStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            canRespond: canRespond,
            outcome: item.outcome,
            relationStatus: item.relationStatus,
            friendAction: item.friendAction,
            friendFlow: item.friendFlow,
            directlyEstablished: item.directlyEstablished,
            requiresTenantReview: item.requiresTenantReview,
            requiresTargetApproval: item.requiresTargetApproval,
            resolutionMode: item.resolutionMode,
            accepted: status == "accepted" || item.relationStatus.lowercased() == "friend"
        )
    }

    func applyFriendApplications(_ applications: [RemoteFriendApplication]) {
        let currentID = (apiContext.imUID ?? currentUser.id).trimmingCharacters(in: .whitespacesAndNewlines)
        friendRequests = applications.compactMap {
            Self.friendRequestProjection($0, currentID: currentID)
        }
    }

    func refreshFriendApplicationsAndRelations() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        await refreshFriendApplicationsAndRelations(context: context, scope: scope)
    }

    func refreshFriendApplicationsAndRelations(context: IMAPIContext, scope: String) async {
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        profileContactRevisionFence.rebind(scopeHash: scope)
        if let requests = try? await api.listFriendApplications(context: context) {
            guard isCurrentRemoteScope(scope) else { return }
            applyFriendApplications(requests)
        }
        let blacklistReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        if let blocked = try? await api.listBlacklist(context: context) {
            guard isCurrentRemoteScope(scope) else { return }
            applyBlacklist(blocked, readStamp: blacklistReadStamp)
        }
        let friendsReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        if let relations = try? await api.listFriends(context: context) {
            guard isCurrentRemoteScope(scope) else { return }
            applyFriendRelations(relations, readStamp: friendsReadStamp)
        }
    }

    func applyDevices(_ remoteDevices: [RemoteUserDevice]) {
        guard !remoteDevices.isEmpty else { return }
        deviceSessions = remoteDevices.map { device in
            DeviceSession(
                id: device.deviceID,
                name: device.deviceType.isEmpty ? device.deviceID : device.deviceType,
                platform: device.appID,
                lastSeen: displayTime(device.lastSeenAt),
                status: device.banned ? "已封禁" : device.status,
                isBound: true,
                isBlocked: device.banned
            )
        }
    }

    func refreshLoginLogs() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession, isCurrentRemoteScope(scope), !isLoginLogsLoading else { return }
        isLoginLogsLoading = true
        defer { isLoginLogsLoading = false }
        do {
            let remoteLogs = try await api.listMyLoginLogs(context: context)
            guard isCurrentRemoteScope(scope) else { return }
            loginLogs = remoteLogs.map { remote in
                LoginLog(
                    id: remote.id,
                    device: Self.loginLogDeviceLabel(remote.deviceType),
                    location: "当前账号",
                    time: displayTime(remote.createdAt),
                    result: Self.loginLogResultLabel(remote.result)
                )
            }
            loginLogsLoadFailed = false
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            loginLogsLoadFailed = true
            logSyncEndpointFailure("/api/tenant/me/login-logs", error: error)
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "登录日志同步失败", silent: true)
            }
        }
    }

    private static func loginLogDeviceLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios": return "iOS"
        case "android": return "Android"
        case "web": return "Web"
        case "desktop": return "桌面端"
        default: return "未知设备"
        }
    }

    private static func loginLogResultLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "success": return "成功"
        case "blocked": return "已拦截"
        case "locked": return "已锁定"
        case "limited": return "已限制"
        case "warning": return "风险提示"
        default: return "失败"
        }
    }

    func applyInbox(_ remoteInbox: [RemoteInboxEntry]) {
        let previousKnownIDs = contactStore.knownInboxIDs()
        let sortedInbox = remoteInbox.filter(shouldKeepFriendInboxEntry).sorted { lhs, rhs in
            let lhsDate = parseRemoteDate(lhs.createdAt) ?? Date.distantPast
            let rhsDate = parseRemoteDate(rhs.createdAt) ?? Date.distantPast
            return lhsDate > rhsDate
        }
        let nextItems = sortedInbox.map(inboxItem)
        inboxItems = nextItems
        contactStore.replaceKnownInboxIDs(Set(nextItems.map(\.id)))
        syncSystemConversationFromInbox(nextItems)

        let newUnreadAnnouncements = nextItems.filter { item in
            item.isAnnouncement && !item.isRead && !previousKnownIDs.contains(item.id)
        }
        guard isAuthenticated, !previousKnownIDs.isEmpty, let firstAnnouncement = newUnreadAnnouncements.first else { return }
        SystemNotificationSound.playMessage()
        toast = newUnreadAnnouncements.count > 1
            ? "收到 \(newUnreadAnnouncements.count) 条新公告"
            : "收到新公告：\(firstAnnouncement.title)"
    }

    static func mergedInboxEntries(_ primary: [RemoteInboxEntry], _ announcements: [RemoteInboxEntry]) -> [RemoteInboxEntry] {
        guard !announcements.isEmpty else { return primary }
        var ids: [String: Int] = [:]
        var merged = primary
        for index in merged.indices {
            let id = merged[index].id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty {
                ids[id] = index
            }
        }
        for item in announcements {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = ids[id] {
                merged[index] = item
            } else {
                ids[id] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    func mergeInboxNotifications(_ remoteInbox: [RemoteInboxEntry]) {
        guard !remoteInbox.isEmpty else { return }
        let mappedNotifications = remoteInbox
            .filter(shouldKeepFriendInboxEntry)
            .sorted {
                let lhsDate = parseRemoteDate($0.createdAt) ?? Date.distantPast
                let rhsDate = parseRemoteDate($1.createdAt) ?? Date.distantPast
                return lhsDate > rhsDate
            }
            .map(inboxItem)
            .filter { !$0.id.isEmpty }
        let notificationIDs = Set(mappedNotifications.map(\.id))
        let preservedItems = inboxItems.filter { !notificationIDs.contains($0.id) }
        inboxItems = mappedNotifications + preservedItems
        contactStore.mergeKnownInboxIDs(Set(inboxItems.map(\.id)))
        syncSystemConversationFromInbox(inboxItems)
    }

    private func shouldKeepFriendInboxEntry(_ item: RemoteInboxEntry) -> Bool {
        let event = payloadString(
            item.payload,
            ["event", "event_type", "notification_type", "notice_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isFriendRelationRealtimeEvent(event: event, kind: kind) else {
            return true
        }
        let status = payloadString(item.payload, ["status", "application_status"])
        let outcome = payloadString(item.payload, ["outcome"])
        return !Self.isSuppressedFriendApplication(status: status, outcome: outcome)
    }

    private func inboxItem(from item: RemoteInboxEntry) -> InboxItem {
        let category = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "system" : item.kind
        let isAnnouncement = InboxItem(id: item.id, title: item.title, subtitle: item.summary, time: "", category: category, isRead: false, accentHex: 0).isAnnouncement
        let approval = groupInviteApproval(from: item.payload, kind: item.kind, fallbackTitle: item.title)
        let isRead = item.readAt != nil || (!isAnnouncement && contactStore.isSystemInboxReadLocally(id: item.id))
        return InboxItem(
            id: item.id,
            title: item.title,
            subtitle: item.summary,
            time: displayTime(item.createdAt),
            category: category,
            isRead: isRead,
            accentHex: approval != nil ? 0x7C6BFF : (isAnnouncement ? 0x5D6BFF : 0x18B6D7),
            avatarURL: resolveTenantAssetURL(item.senderAvatarURL),
            groupInviteApproval: approval,
            sortTimestamp: parseRemoteDate(item.createdAt)?.timeIntervalSince1970 ?? 0
        )
    }

    func syncSystemConversationFromInbox(_ items: [InboxItem]) {
        let systemItems = items.filter { !$0.isAnnouncement }
        let unread = systemItems.filter { !$0.isRead }.count
        let messagePairs: [(item: InboxItem, message: ChatMessage)] = systemItems
            .reversed()
            .enumerated()
            .map { offset, item in
                var message = systemInboxMessage(from: item)
                message.channelSeq = Int64(offset + 1)
                return (item, message)
            }
        let messages = messagePairs.map { $0.message }
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：系统会话同步避免生成序号临时数组
        let lastMsgSeq = ConversationSequenceInspector.maximumChannelSeq(in: messages) ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        let firstUnread = messagePairs.first { !$0.item.isRead }
        conversationStore.replaceSystemConversation { previousSystem in
            guard let latest = systemItems.first else {
                return nil
            }
            let latestItemTimestamp = latest.sortTimestamp
            if let previousSystem,
               shouldPreserveNewerSystemConversationSnapshot(
                   previousSortTimestamp: previousSystem.sortTimestamp,
                   latestInboxSortTimestamp: latestItemTimestamp
               ) {
                return previousSystem
            }
            let lastMessage = systemConversationPreview(from: latest)
            let previousReadSeq = min(previousSystem?.lastReadSeq ?? 0, lastMsgSeq)
            let firstUnreadSeq = firstUnread?.message.channelSeq ?? 0
            let firstUnreadMessageID = firstUnread?.message.id ?? ""
            let lastReadSeq = unread == 0
                ? lastMsgSeq
                : min(max(previousReadSeq, max(firstUnreadSeq - 1, 0)), lastMsgSeq)
            return Conversation(
                id: "system_notification",
                title: "系统通知",
                subtitle: "系统",
                kind: .system,
                lastMessage: lastMessage,
                time: latest.time,
                unread: unread,
                isPinned: previousSystem?.isPinned ?? false,
                isMuted: previousSystem?.isMuted ?? false,
                memberCount: 1,
                accentHex: 0x18B6D7,
                participants: [],
                messages: messages,
                avatarURL: systemNoticeAvatarURL,
                hasUnreadReaction: false,
                unreadReactionCount: 0,
                lastMsgSeq: lastMsgSeq,
                lastReadSeq: lastReadSeq,
                firstUnreadSeq: firstUnreadSeq,
                firstUnreadMessageID: firstUnreadMessageID,
                unreadAnchorSeq: firstUnreadSeq,
                unreadAnchorState: unread > 0 ? "unread" : "none",
                sortTimestamp: latestItemTimestamp
            )
        }
    }

    private func systemConversationPreview(from item: InboxItem) -> String {
        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subtitle.isEmpty { return subtitle }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "系统通知" : title
    }

    private func systemInboxMessage(from item: InboxItem) -> ChatMessage {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if title.isEmpty {
            text = subtitle.isEmpty ? "系统通知" : subtitle
        } else if subtitle.isEmpty {
            text = title
        } else {
            text = "\(title)\n\(subtitle)"
        }
        return ChatMessage(
            id: "inbox_\(item.id)",
            senderId: "system",
            senderName: "系统",
            text: text,
            time: item.time,
            isOutgoing: false,
            status: item.isRead ? .read : .sent,
            kind: .system,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil,
            groupInviteApproval: item.groupInviteApproval
        )
    }

    func attachmentResourceComponents(
        for message: ChatMessage
    ) -> (fileID: String, attachmentID: String, mediaID: String) {
        let encoded = message.attachmentFileID ?? ""
        if encoded.hasPrefix("attachment_id:") {
            return ("", String(encoded.dropFirst("attachment_id:".count)), "")
        }
        if encoded.hasPrefix("media_id:") {
            return ("", "", String(encoded.dropFirst("media_id:".count)))
        }
        return (encoded, "", "")
    }

    func tenantFileID(for message: ChatMessage) -> String {
        attachmentResourceComponents(for: message).fileID
    }

    // Remote message payload, sticker, mention, and attachment parsing helpers are split to Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift.

}
