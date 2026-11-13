import Foundation

// WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_BEGIN
extension AppState {
    // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: keep platform session refresh independent from tenant IM refresh.
    func refreshPlatformAuthSessionIfNeeded(
        reason: String, silent: Bool, context: IMAPIContext? = nil, force: Bool = false
    ) async -> Bool {
        await refreshPlatformAuthSessionAuthorityIfNeeded(reason: reason, silent: silent,
            context: context, force: force) != nil
    }

    func refreshPlatformAuthSessionAuthorityIfNeeded(
        reason: String, silent: Bool, context explicitContext: IMAPIContext? = nil, force: Bool = false
    ) async -> IMAuthSessionFence? {
        let context = explicitContext ?? apiContext
        let ownerFence = context.authSessionFence
        guard apiContext.isSameAuthAuthority(as: ownerFence) else { return nil }
        guard let platformSession = context.platformAuthSession,
              platformSession.isUsable,
              context.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        if !force {
            guard let refreshDelay = IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                accessExpiresAt: platformSession.accessExpiresAt,
                now: Date().timeIntervalSince1970
            ) else {
                return ownerFence
            }
            guard refreshDelay <= 0 else { return ownerFence }
        }
        if platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken) {
            return ownerFence
        }
        guard let refreshContext = platformRefreshContext(from: context) else { return nil }
        let refreshFence = refreshContext.authSessionFence
        if platformAuthSessionDidAdvance(since: platformSession, platformToken: context.platformToken) {
            return ownerFence
        }
        if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
            let result = await existing.value
            return platformRefreshContinuationAuthority(result, from: context)
        }
        guard let taskToken = remoteSyncEngine.claimAuthSessionRefreshTask(for: refreshFence) else {
            if let existing = remoteSyncEngine.currentAuthSessionRefreshTask(for: refreshFence) {
                let result = await existing.value
                return platformRefreshContinuationAuthority(result, from: context)
            }
            return nil
        }
        let task = Task<Bool, Never> { [weak self, refreshContext, refreshFence, ownerFence, platformSession, reason] in
            guard let self else { return false }
            var requestContext = refreshContext
            if let pending = self.apiContext.pendingRefreshRequestID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pending.isEmpty {
                requestContext.pendingRefreshRequestID = pending
            } else {
                var stagedContext = self.apiContext
                stagedContext.pendingRefreshRequestID = UUID().uuidString.lowercased()
                guard stagedContext.save(sessionStore: self.protectedSessionStore).isCommitted,
                      self.currentPlatformRefreshFence() == refreshFence,
                      self.apiContext.isSameAuthAuthority(as: ownerFence) else {
                    return false
                }
                self.apiContext = stagedContext
                requestContext.pendingRefreshRequestID = stagedContext.pendingRefreshRequestID
            }
            do {
                guard self.currentPlatformRefreshFence() == refreshFence,
                      self.apiContext.isSameAuthAuthority(as: ownerFence) else { return false }
                let refreshed = try await self.api.refreshCurrentSession(context: requestContext, requestAuthority: ownerFence)
                guard self.applyPlatformAuthSessionRefreshResult(
                    refreshed,
                    expectedFence: refreshFence,
                    expectedOwnerFence: ownerFence,
                    previousPlatformSession: platformSession
                ) else { return false }
                if !silent {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("登录状态已恢复")
                }
                print("[JHT Auth] platform_session_refresh_success reason=\(reason) token_type=\(refreshed.authSession.normalizedTokenType)")
                return true
            } catch {
                guard self.currentPlatformRefreshFence() == refreshFence,
                      self.apiContext.isSameAuthAuthority(as: ownerFence) else { return false }
                let failure = self.safeAuthRefreshFailureLogClassification(error)
                print("[JHT Auth] platform_session_refresh_failure reason=\(reason) status=\(failure.status) code=\(failure.code)")
                return false
            }
        }
        remoteSyncEngine.attachAuthSessionRefreshTask(taskToken, task: task)
        let result = await task.value
        remoteSyncEngine.finishAuthSessionRefreshTask(taskToken)
        return platformRefreshContinuationAuthority(result, from: context)
    }

    /// A successful matching shared task may install exactly one platform credential revision.
    /// Rebase only those platform fields for the full original fence comparison, never globally.
    private func platformRefreshContinuationAuthority(_ succeeded: Bool, from original: IMAPIContext) -> IMAuthSessionFence? {
        guard succeeded else { return nil }
        let owner = original.authSessionFence
        if apiContext.isSameAuthAuthority(as: owner) { return owner }
        guard let previous = original.platformAuthSession,
              apiContext.credentialRevision == owner.credentialRevision &+ 1,
              apiContext.platformAuthSession?.sessionID == original.platformAuthSession?.sessionID,
              platformAuthSessionDidAdvance(since: previous, platformToken: original.platformToken) else { return nil }
        var rebased = apiContext
        rebased.credentialRevision = owner.credentialRevision
        rebased.platformAuthSession = original.platformAuthSession
        guard rebased.authSessionFence == owner else { return nil }
        return apiContext.authSessionFence
    }

    private func platformRefreshContext(from context: IMAPIContext) -> IMAPIContext? {
        guard context.platformAuthSession?.isUsable == true else { return nil }
        var platformContext = context
        platformContext.tenantAuthSession = nil
        platformContext.accessExpiresAt = context.platformAuthSession?.accessExpiresAt ?? 0
        return platformContext
    }

    private func currentPlatformRefreshFence() -> IMAuthSessionFence? {
        platformRefreshContext(from: apiContext)?.authSessionFence
    }

    private func platformAuthSessionDidAdvance(
        since previous: IMStoredAuthSession,
        platformToken previousToken: String?
    ) -> Bool {
        guard let current = apiContext.platformAuthSession,
              current.isUsable,
              current.normalizedTokenType == "platform" else {
            return false
        }
        if current.sessionID != previous.sessionID { return true }
        if current.authVersion > previous.authVersion { return true }
        if current.sessionGeneration > previous.sessionGeneration { return true }
        if current.accessExpiresAt > previous.accessExpiresAt { return true }
        let oldToken = previousToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newToken = apiContext.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !newToken.isEmpty && !oldToken.isEmpty && newToken != oldToken
    }

    private func applyPlatformAuthSessionRefreshResult(
        _ result: RemoteAuthSessionRefreshResult,
        expectedFence: IMAuthSessionFence,
        expectedOwnerFence: IMAuthSessionFence,
        previousPlatformSession: IMStoredAuthSession
    ) -> Bool {
        guard result.authSession.isUsable else { return false }
        let normalizedType = result.authSession.normalizedTokenType
        guard normalizedType.isEmpty || normalizedType == "platform" else { return false }
        guard currentPlatformRefreshFence() == expectedFence,
              apiContext.isSameAuthAuthority(as: expectedOwnerFence),
              let currentPlatformSession = apiContext.platformAuthSession,
              currentPlatformSession.sessionID == previousPlatformSession.sessionID else {
            return false
        }
        if result.authVersion > 0,
           currentPlatformSession.authVersion > 0,
           result.authVersion < currentPlatformSession.authVersion {
            return false
        }
        if result.sessionGeneration > 0,
           currentPlatformSession.sessionGeneration > 0,
           result.sessionGeneration < currentPlatformSession.sessionGeneration {
            return false
        }
        var candidate = apiContext
        let previousAccessExpiresAt = candidate.accessExpiresAt
        let tenantAccessExpiresAt = candidate.tenantAuthSession?.accessExpiresAt ?? 0
        let refreshedPlatformToken = result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? result.platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.imToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refreshedPlatformToken.isEmpty {
            candidate.platformToken = refreshedPlatformToken
        }
        if !result.authSession.appID.isEmpty {
            candidate.appID = IMAPIContext.normalizedIOSAppID(result.authSession.appID)
        }
        if !result.authSession.deviceID.isEmpty {
            candidate.deviceID = result.authSession.deviceID
        }
        candidate.persistAuthSession(
            result.authSession,
            fallbackTokenType: "platform",
            fallbackTenantID: nil,
            fallbackAccessExpiresAt: result.expiresAt
        )
        if candidate.hasIMSession {
            candidate.accessExpiresAt = tenantAccessExpiresAt > 0 ? tenantAccessExpiresAt : previousAccessExpiresAt
        } else if result.expiresAt > 0 {
            candidate.accessExpiresAt = result.expiresAt
        }
        candidate.pendingRefreshRequestID = nil
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted,
              currentPlatformRefreshFence() == expectedFence,
              apiContext.isSameAuthAuthority(as: expectedOwnerFence) else {
            return false
        }
        apiContext = candidate
        if !result.workspaces.isEmpty {
            applyWorkspaces(result.workspaces)
        }
        return true
    }
    // WDT_IOS_TOKEN_VALIDITY_20260924_END
}
// WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_END
