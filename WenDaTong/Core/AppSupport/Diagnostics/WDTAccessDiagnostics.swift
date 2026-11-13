import Foundation
import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct AccessDiagnosticsPolicy: Equatable {
    let appID: String
    let overlayConfiguration: AccessDiagnosticsOverlayConfiguration
    let copyEnabled: Bool

    static let disabled = AccessDiagnosticsPolicy(
        appID: "",
        overlayConfiguration: .unavailable,
        copyEnabled: false
    )

    init(
        appID: String = IMAPIContext.canonicalIOSAppID,
        overlayConfiguration: AccessDiagnosticsOverlayConfiguration? = nil,
        overlayEnabled: Bool? = nil,
        copyEnabled: Bool
    ) {
        self.appID = appID
        self.overlayConfiguration = overlayConfiguration
            ?? AccessDiagnosticsOverlayConfiguration(
                configuredValue: overlayEnabled,
                fieldWasPresent: overlayEnabled != nil
            )
        self.copyEnabled = copyEnabled
    }

    var allowsOverlay: Bool {
        overlayConfiguration.isEnabled
            && !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
enum AccessDiagnosticsAuthorization: Equatable {
    case unavailable
    case disabled
    case enabled(appID: String)

    func allows(_ appID: String?) -> Bool {
        guard case .enabled(let authorizedAppID) = self else { return false }
        let normalizedAuthorizedAppID = Self.normalizedRequiredAppID(authorizedAppID)
        let normalizedAppID = Self.normalizedRequiredAppID(appID ?? "")
        return !normalizedAuthorizedAppID.isEmpty && normalizedAuthorizedAppID == normalizedAppID
    }

    fileprivate static func normalizedRequiredAppID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return IMAPIContext.normalizedIOSAppID(trimmed, allowCustomAppID: true)
    }
}

enum AccessDiagnosticsAuthPhase: String, Equatable, Hashable {
    case loggedOut
    case authenticated
}

struct AccessDiagnosticsActivationScope: Equatable, Hashable {
    let appID: String
    let accountID: String?
    let tenantID: String?
    let authPhase: AccessDiagnosticsAuthPhase
    let sessionGeneration: Int64
    let deviceID: String?
    let sessionEpoch: String?

    init(
        appID: String,
        accountID: String? = nil,
        tenantID: String? = nil,
        authPhase: AccessDiagnosticsAuthPhase,
        sessionGeneration: Int64 = 0,
        deviceID: String? = nil,
        sessionEpoch: String? = nil
    ) {
        let trimmedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = trimmedAppID.isEmpty
            ? ""
            : IMAPIContext.normalizedIOSAppID(trimmedAppID, allowCustomAppID: true)
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTenantID = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = authPhase == .authenticated && normalizedAccountID?.isEmpty == false
            ? normalizedAccountID
            : nil
        self.tenantID = authPhase == .authenticated && normalizedTenantID?.isEmpty == false
            ? normalizedTenantID
            : nil
        self.authPhase = authPhase
        self.sessionGeneration = authPhase == .authenticated ? max(0, sessionGeneration) : 0
        // The session generation alone does not change on every device or epoch transition.
        self.deviceID = authPhase == .authenticated ? deviceID : nil
        self.sessionEpoch = authPhase == .authenticated ? sessionEpoch : nil
    }

    var isValid: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (authPhase == .loggedOut || (accountID?.isEmpty == false && tenantID?.isEmpty == false))
    }
}

enum AccessDiagnosticsActivationEntry: Equatable {
    case loggedOutLoginLogo
    case loggedInAboutLogo
}

enum AccessDiagnosticsVisibilityTransition: Equatable {
    case unchanged
    case opened
    case closed
}

private struct AccessDiagnosticsTapSequence {
    var entry: AccessDiagnosticsActivationEntry?
    var scope: AccessDiagnosticsActivationScope?
    var timestamps: [UInt64] = []

    mutating func reset() {
        entry = nil
        scope = nil
        timestamps.removeAll(keepingCapacity: true)
    }
}
// JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

@MainActor
final class AccessDiagnostics: ObservableObject {
    static let shared = AccessDiagnostics()
    static var isOverlayCompiled: Bool {
        true
    }

    @Published private(set) var snapshot: AccessDiagnosticsSnapshot
    @Published private(set) var isVisible: Bool
    @Published private(set) var isCopyEnabled: Bool
    private var lastAppliedPolicy: AccessDiagnosticsPolicy = .disabled
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private static let manualTapThreshold = 5
    private static let manualTapWindowNanoseconds: UInt64 = 3_000_000_000
    private var authorization: AccessDiagnosticsAuthorization = .unavailable
    private var currentScope: AccessDiagnosticsActivationScope?
    private(set) var connectionScopeEpoch: UInt64 = 0
    private var lastConnectionResult: RealtimeConnectionDiagnostic?
    private var turnHosts: [String] = []
    private var turnCallID: String?
    private var turnLookupTask: Task<Void, Never>?
    private var turnTimeoutTask: Task<Void, Never>?
    private var manuallyActivatedScope: AccessDiagnosticsActivationScope?
    private var tapSequence = AccessDiagnosticsTapSequence()
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    init(snapshot: AccessDiagnosticsSnapshot = .initial) {
        self.snapshot = snapshot
        self.isVisible = false
        self.isCopyEnabled = false
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func updateScope(_ scope: AccessDiagnosticsActivationScope?) {
        let nextScope = scope?.isValid == true ? scope : nil
        guard nextScope != currentScope else { return }
        currentScope = nextScope
        turnHosts = []
        turnCallID = nil
        connectionScopeEpoch &+= 1
        lastConnectionResult = nil
        manuallyActivatedScope = nil
        resetTapSequence()
        clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
        recomputeVisibility()
    }

    func applyPolicy(_ policy: AccessDiagnosticsPolicy) {
        lastAppliedPolicy = policy
        let normalizedAppID = AccessDiagnosticsAuthorization.normalizedRequiredAppID(policy.appID)
        if Self.isOverlayCompiled, policy.overlayConfiguration.isEnabled, !normalizedAppID.isEmpty {
            authorization = .enabled(appID: normalizedAppID)
        } else {
            authorization = policy.overlayConfiguration == .disabled ? .disabled : .unavailable
        }
        if !authorization.allows(currentScope?.appID) {
            turnHosts = []
            turnCallID = nil
            manuallyActivatedScope = nil
            resetTapSequence()
            clearSnapshot(overlayStatus: policy.overlayConfiguration.displayText)
        } else {
            snapshot.currentPolicyOverlayStatus = policy.overlayConfiguration.displayText
        }
        recomputeVisibility()
    }

    func bindConnectionDiagnostics(to client: RealtimeClient) {
        client.diagnosticScopeProvider = { [weak self] in self?.connectionScopeEpoch }
        client.onDiagnostic = { [weak self] event, scopeEpoch in
            self?.recordConnection(event, scopeEpoch: scopeEpoch)
        }
    }

    /// The local epoch is memory-only and never enters the diagnostic record or log.
    func recordConnection(_ event: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        guard event.currentAtReceipt,
              let scopeEpoch, scopeEpoch == connectionScopeEpoch else { return }
        if let previous = lastConnectionResult {
            guard event.generation >= previous.generation else { return }
            // Keep one record: the first failure in this generation, otherwise the latest result.
            // A new generation or scope replaces it; old late callbacks never overwrite it.
            if event.generation == previous.generation, previous.isFailure { return }
        }
        lastConnectionResult = event
        if isVisible { snapshot.connectionResult = event }
    }

    func record(_ event: AccessDiagnosticsEvent) {
        guard isVisible else { return }
        snapshot = AccessDiagnosticsReducer.reduce(snapshot, event: event)
    }

    // Only sanitized hosts are retained; ICE credentials and URLs never enter the snapshot.
    func recordTurnServers(urls: [String], callID: String? = nil) {
        guard let scope = currentScope, authorization.allows(scope.appID) else { return }
        let hosts = AccessDiagnosticsTurnAddresses.hosts(from: urls)
        guard hosts != turnHosts || callID != turnCallID else { return }
        turnHosts = hosts
        turnCallID = callID
        refreshTurnAddresses()
    }

    func clearTurnServers(callID: String?) {
        guard callID == turnCallID else { return }
        turnHosts = []
        turnCallID = nil
        refreshTurnAddresses()
    }

    private func refreshTurnAddresses() {
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        snapshot.turnAddresses.begin(hosts: isVisible ? turnHosts : [])
        guard isVisible, !turnHosts.isEmpty else { return }
        let hosts = turnHosts
        let generation = snapshot.turnAddresses.generation
        turnLookupTask = Task { [weak self] in
            for host in hosts {
                guard !Task.isCancelled else { return }
                let ips = await AccessDiagnosticsTurnAddresses.resolve(host)
                guard !Task.isCancelled, let self, self.isVisible else { return }
                self.snapshot.turnAddresses.apply(ips, host: host, generation: generation)
            }
        }
        turnTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.isVisible, self.snapshot.turnAddresses.generation == generation else { return }
            self.turnLookupTask?.cancel()
            for host in hosts { self.snapshot.turnAddresses.apply([], host: host, generation: generation) }
        }
    }

    func disablePreservingAllowedPolicy(reason: String = "接入诊断暂不可用") {
        resetTapSequence()
        guard Self.isOverlayCompiled,
              lastAppliedPolicy.allowsOverlay,
              let scope = currentScope,
              authorization.allows(scope.appID) else {
            forceDisable()
            return
        }
        isCopyEnabled = false
        // A transient auth failure is not a policy revocation. Keep the
        // same-AppId authorization even before the user opens the overlay,
        // otherwise the next five taps can never pass the activation guard.
        guard isVisible, manuallyActivatedScope == scope else {
            manuallyActivatedScope = nil
            clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
            recomputeVisibility()
            return
        }
        snapshot = AccessDiagnosticsReducer.reduce(snapshot, event: .failed(reason: reason))
        snapshot.currentPolicyOverlayStatus = lastAppliedPolicy.overlayConfiguration.displayText
    }

    func forceDisable() {
        turnHosts = []
        turnCallID = nil
        lastConnectionResult = nil
        lastAppliedPolicy = .disabled
        authorization = .unavailable
        manuallyActivatedScope = nil
        resetTapSequence()
        clearSnapshot()
        recomputeVisibility()
    }

    func reset(to snapshot: AccessDiagnosticsSnapshot = .initial) {
        turnHosts = []
        turnCallID = nil
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        self.snapshot = snapshot
        lastConnectionResult = snapshot.connectionResult
    }

    @discardableResult
    func registerLogoTap(
        entry: AccessDiagnosticsActivationEntry,
        scope: AccessDiagnosticsActivationScope,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AccessDiagnosticsVisibilityTransition {
        guard scope.isValid,
              currentEntryIsAllowed(entry, scope: scope),
              authorization.allows(scope.appID),
              currentScope == scope else {
            resetTapSequence()
            return .unchanged
        }

        if tapSequence.entry != entry || tapSequence.scope != scope {
            resetTapSequence()
            tapSequence.entry = entry
            tapSequence.scope = scope
        }

        tapSequence.timestamps.removeAll { timestamp in
            nowNanoseconds < timestamp || nowNanoseconds - timestamp > Self.manualTapWindowNanoseconds
        }
        tapSequence.timestamps.append(nowNanoseconds)

        guard tapSequence.timestamps.count >= Self.manualTapThreshold,
              let firstTap = tapSequence.timestamps.suffix(Self.manualTapThreshold).first,
              nowNanoseconds >= firstTap,
              nowNanoseconds - firstTap <= Self.manualTapWindowNanoseconds else {
            return .unchanged
        }

        resetTapSequence()
        return toggleManualActivation(for: scope)
    }

    func resetLogoTapSequence(entry: AccessDiagnosticsActivationEntry? = nil) {
        guard entry == nil || tapSequence.entry == entry else { return }
        resetTapSequence()
    }

    private func toggleManualActivation(for scope: AccessDiagnosticsActivationScope) -> AccessDiagnosticsVisibilityTransition {
        if isVisible, manuallyActivatedScope == scope {
            manuallyActivatedScope = nil
            clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
            recomputeVisibility()
            return .closed
        }
        manuallyActivatedScope = scope
        clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
        recomputeVisibility()
        return isVisible ? .opened : .unchanged
    }

    private func currentEntryIsAllowed(
        _ entry: AccessDiagnosticsActivationEntry,
        scope: AccessDiagnosticsActivationScope
    ) -> Bool {
        switch (entry, scope.authPhase) {
        case (.loggedOutLoginLogo, .loggedOut),
             (.loggedInAboutLogo, .authenticated):
            return true
        default:
            return false
        }
    }

    private func resetTapSequence() {
        tapSequence.reset()
    }

    private func clearSnapshot(overlayStatus: String? = nil) {
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        snapshot = .initial
        if let overlayStatus {
            snapshot.currentPolicyOverlayStatus = overlayStatus
        }
    }

    private func recomputeVisibility() {
        let shouldShow = Self.isOverlayCompiled
            && currentScope.map { authorization.allows($0.appID) && manuallyActivatedScope == $0 } == true
        let wasVisible = isVisible
        isVisible = shouldShow
        if shouldShow && !wasVisible { refreshTurnAddresses() }
        if shouldShow { snapshot.connectionResult = lastConnectionResult }
        isCopyEnabled = false
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
}
