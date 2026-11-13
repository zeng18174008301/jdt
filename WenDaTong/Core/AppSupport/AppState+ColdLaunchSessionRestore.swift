import Foundation

extension AppState {
    // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_BEGIN
    func makeColdLaunchSessionRestoreTask(restoringContext: IMAPIContext, restoringScope: String) -> Task<Void, Never> {
        Task {
            guard !Task.isCancelled, isCurrentColdLaunchRestore(restoringContext, scope: restoringScope) else { return }
            if await applyCachedRemoteSnapshotIfAvailable(context: restoringContext) {
                guard !Task.isCancelled, isCurrentColdLaunchRestore(restoringContext, scope: restoringScope) else { return }
                bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已加载本地会话，正在更新")
            }
            guard !Task.isCancelled, isCurrentColdLaunchRestore(restoringContext, scope: restoringScope) else { return }
            startInboxRefreshLoop()
            startRTCCallRefreshLoop()
            _ = await refreshStoredAuthSessionIfNeeded(
                reason: "cold_launch",
                silent: true,
                context: restoringContext,
                scope: restoringScope
            )
            let refreshedContext = apiContext
            guard !Task.isCancelled, !isApplicationBackgroundedForRTC,
                  refreshedContext.hasIMSession,
                  isCurrentColdLaunchRestore(restoringContext, scope: restoringScope) else { return }
            pendingColdLaunchRealtimeAdmission = (restoringScope, refreshedContext.authSessionFence)
            resumePendingColdLaunchRealtimeAdmission()
            let synced = await refreshRemoteSnapshot(silent: false, force: true)
            guard !Task.isCancelled, isCurrentColdLaunchRestore(restoringContext, scope: restoringScope) else { return }
            await completeColdLaunchSessionRestore(
                restoringContext: restoringContext,
                synced: synced
            )
        }
    }

    private func isCurrentColdLaunchRestore(_ context: IMAPIContext, scope: String) -> Bool {
        isAuthenticated && isCurrentRemoteScope(scope)
            && (apiContext.isSameAuthAuthority(as: context.authSessionFence)
                || apiContext.credentialsAdvanced(since: context.authSessionFence))
    }

    func resumePendingColdLaunchRealtimeAdmission() {
        guard let pending = pendingColdLaunchRealtimeAdmission else { return }
        guard coldLaunchSessionRestoreTask?.isCancelled != true,
              isAuthenticated, isCurrentRemoteScope(pending.scope),
              apiContext.isSameAuthAuthority(as: pending.authority)
                || apiContext.credentialsAdvanced(since: pending.authority) else {
            pendingColdLaunchRealtimeAdmission = nil
            return
        }
        guard iosRiskTelemetrySceneIsActive, !isApplicationBackgroundedForRTC else { return }
        pendingColdLaunchRealtimeAdmission = nil
        startRealtimeConnection(context: apiContext)
    }

    func retireColdLaunchSessionRestoreAdmission() {
        pendingColdLaunchRealtimeAdmission = nil
        coldLaunchSessionRestoreTask?.cancel()
    }
    // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_END

    func completeColdLaunchSessionRestore(
        restoringContext: IMAPIContext,
        synced: Bool
    ) async {
        let restoringScope = remoteDataScopeKey(for: restoringContext)
        guard isCurrentRemoteScope(restoringScope) else { return }
        guard isAuthenticated else {
            bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            return
        }
        if hasLoadedRemoteSnapshot {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(synced ? "已恢复登录状态" : "登录状态已恢复，部分数据同步失败")
            bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            await evaluateForcedAppPolicyAuthIfNeeded(
                forceRefreshVerification: true,
                reason: "restore_session"
            )
        } else {
            bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已保留，数据同步失败，请稍后重试")
            scheduleColdLaunchSessionRecovery(restoringContext: restoringContext)
        }
    }

    private func scheduleColdLaunchSessionRecovery(restoringContext: IMAPIContext) {
        guard coldLaunchSessionRecoveryTask == nil else { return }
        let restoringScope = remoteDataScopeKey(for: restoringContext)
        coldLaunchSessionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.coldLaunchSessionRecoveryTask = nil }
            let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000]
            for delay in retryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard self.isAuthenticated,
                      self.isCurrentRemoteScope(restoringScope) else { return }
                if await self.refreshRemoteSnapshot(silent: true, force: true) {
                    guard self.isAuthenticated,
                          self.isCurrentRemoteScope(restoringScope) else { return }
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("已恢复登录状态")
                    return
                }
            }
        }
    }

    func restoreCurrentUserFromSession() {
        guard let imUID = apiContext.imUID, !imUID.isEmpty else { return }
        if let cachedIdentity = IMCurrentUserIdentityCache.load(context: apiContext, defaults: currentUserIdentityDefaults) { // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
            hydrateCurrentProfileAuthority(from: cachedIdentity.authorityCheckpoint)
            setCurrentUser(cachedIdentity.makeUser(
                fallbackEnterprise: currentEnterprise.name,
                fallbackSeed: stableSeed(imUID)
            )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            return
        }
        setCurrentUser(IMUser(
            id: imUID,
            userID: imUID,
            username: "USERNAME_PLACEHOLDER",
            name: imUID,
            title: "",
            department: "",
            phone: "",
            email: apiContext.accountID ?? "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(imUID),
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    }

    func persistCurrentUserIdentityIfPossible() {
        IMCurrentUserIdentityCache.save(
            currentUser,
            context: apiContext,
            profileAuthorityCheckpoint: currentProfileAuthorityCheckpoint(),
            defaults: currentUserIdentityDefaults // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
        )
    }

}
