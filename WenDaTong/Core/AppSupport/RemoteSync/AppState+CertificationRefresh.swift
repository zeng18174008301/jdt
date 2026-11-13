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

// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
@MainActor
final class CertificationPresentationStore {
    private(set) var scopeRevision = 0
    private let revisionChanges = CurrentValueSubject<Int, Never>(0)

    var contentRevision: Int { revisionChanges.value }
    var changes: AnyPublisher<Int, Never> { revisionChanges.eraseToAnyPublisher() }

    func advance(scopeChanged: Bool = false) {
        if scopeChanged { scopeRevision &+= 1 }
        revisionChanges.send(contentRevision &+ 1)
    }
}
// WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

extension AppState {
    func certificationPresentation(
        forExactUID rawUID: String
    ) -> CertificationPresentation? {
        guard isAuthenticated,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ),
              certificationIdentityRoot.scope == activeScope else {
            return nil
        }
        return certificationIdentityRoot.presentation(forExactUID: rawUID)
    }

    func ensureCertificationPresentations(
        forExactUIDs rawUIDs: some Sequence<String>
    ) {
        guard isAuthenticated,
              apiContext.hasIMSession,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ) else {
            #if DEBUG
            NSLog("[JHT Certification] stage=scope_unavailable authenticated=%d im_session=%d", isAuthenticated ? 1 : 0, apiContext.hasIMSession ? 1 : 0)
            #endif
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return
        }
        if certificationIdentityRoot.scope != activeScope {
            _ = certificationIdentityRoot.bind(activeScope)
            certificationProfileRequestFence.bind(activeScope)
            certificationPresentationStore.advance(scopeChanged: true) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        } else if certificationProfileRequestFence.scope != activeScope {
            certificationProfileRequestFence.bind(activeScope)
        }
        let uids = CertificationProfileUIDBatch.normalizedAll(rawUIDs)
        let unresolvedUIDs = uids.filter { uid in
            guard let state = certificationIdentityRoot.state(forExactUID: uid) else {
                return true
            }
            return state.needsRefetch
        }
        let queueableUIDs = certificationProfileRequestFence.queueableUIDs(
            from: unresolvedUIDs
        )
        #if DEBUG
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：节流重复 ensure 日志，避免性能分析日志刷屏
        CertificationEnsureLogThrottle.shared.log(
            requested: uids.count,
            unresolved: unresolvedUIDs.count,
            queueable: queueableUIDs.count
        )
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
        #endif
        guard !queueableUIDs.isEmpty else { return }
        pendingCertificationProfileUIDs.formUnion(queueableUIDs)
        scheduleCertificationProfileRefreshIfNeeded()
    }

    func certificationPresentationRootScope(
        for context: IMAPIContext
    ) -> CertificationPresentationRootScope? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty
            ? context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            : storedSessionID
        let scope = CertificationPresentationRootScope(
            tenantID: tenantID,
            viewerID: viewerID,
            appID: appID,
            sessionID: sessionID,
            sessionGeneration: certificationSessionGeneration,
            realtimeGeneration: certificationRealtimeGeneration
        )
        return scope.isValid ? scope : nil
    }

    private func certificationContextBindingKey(
        for context: IMAPIContext
    ) -> String? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty
            ? context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            : storedSessionID
        guard !tenantID.isEmpty,
              !viewerID.isEmpty,
              !appID.isEmpty,
              !sessionID.isEmpty else {
            return nil
        }
        return [tenantID, viewerID, appID, sessionID]
            .joined(separator: "\u{1f}")
    }

    func reconcileCertificationIdentityScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        guard certificationContextBindingKey(for: previousContext)
                != certificationContextBindingKey(for: nextContext) else {
            return
        }
        certificationSessionGeneration &+= 1
        purgeCertificationIdentityRoot(rebindCurrentScope: true)
    }

    func purgeCertificationIdentityRoot(
        rebindCurrentScope: Bool
    ) {
        let hadState = certificationIdentityRoot.scope != nil
            || !certificationIdentityRoot.subjectStates.isEmpty
            || certificationProfileRequestFence.scope != nil
            || !certificationProfileRequestFence.phases.isEmpty
            || !pendingCertificationProfileUIDs.isEmpty
            || certificationProfileRefreshTask != nil
        certificationProfileRequestSequence &+= 1
        certificationProfileRefreshTask?.cancel()
        certificationProfileRefreshTask = nil
        pendingCertificationProfileUIDs.removeAll(keepingCapacity: false)
        certificationIdentityRoot.purge()
        certificationProfileRequestFence.bind(nil)
        if rebindCurrentScope,
           let scope = certificationPresentationRootScope(for: apiContext) {
            _ = certificationIdentityRoot.bind(scope)
            certificationProfileRequestFence.bind(scope)
        }
        if hadState || certificationIdentityRoot.scope != nil {
            certificationPresentationStore.advance(scopeChanged: true) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }
    }

    private func scheduleCertificationProfileRefreshIfNeeded() {
        guard certificationProfileRefreshTask == nil,
              !pendingCertificationProfileUIDs.isEmpty else {
            return
        }
        let now = Date()
        let queueable = Set(certificationProfileRequestFence.queueableUIDs(
            from: pendingCertificationProfileUIDs
        ))
        pendingCertificationProfileUIDs.formIntersection(queueable)
        guard !pendingCertificationProfileUIDs.isEmpty,
              let nextRetryAt = certificationProfileRequestFence.nextRetryDate(
                for: pendingCertificationProfileUIDs,
                now: now
              ) else {
            return
        }
        let delay = max(0.05, nextRetryAt.timeIntervalSince(now))
        let delayNanoseconds = UInt64(min(delay, 8) * 1_000_000_000)
        certificationProfileRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.flushCertificationProfileRefresh()
        }
    }

    private func flushCertificationProfileRefresh() async {
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
        var cleanupSequence = certificationProfileRequestSequence
        defer {
            if certificationProfileRequestSequence == cleanupSequence {
                certificationProfileRefreshTask = nil
                if !pendingCertificationProfileUIDs.isEmpty {
                    scheduleCertificationProfileRefreshIfNeeded()
                }
            }
        }
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
        guard isAuthenticated,
              apiContext.hasIMSession,
              let requestScope = certificationPresentationRootScope(
                for: apiContext
              ),
              certificationIdentityRoot.scope == requestScope else {
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return
        }
        guard let request = certificationProfileRequestFence.begin(
            exactUIDs: pendingCertificationProfileUIDs.sorted(),
            now: Date()
        ) else { return }
        let batch = request.exactUIDs
        let requestWave = request.wave
        pendingCertificationProfileUIDs.subtract(batch)
        certificationProfileRequestSequence &+= 1
        let requestSequence = certificationProfileRequestSequence
        cleanupSequence = requestSequence // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
        let context = apiContext
        let tenantID = requestScope.tenantID
        let requestAuthority = context.authSessionFence // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
        let avatarCommitEpochAtRequest = avatarLocalCommitAuthorityFence.epoch

        #if DEBUG
        NSLog("[JHT Certification] stage=request_started requested=%d", batch.count)
        #endif
        do {
            let avatarRequestStartedAt = DispatchTime.now().uptimeNanoseconds
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
            let response = try await CertificationProfileRequestBroker.shared.response(
                scope: requestScope,
                exactUIDs: batch,
                requestAuthority: requestAuthority
            ) { requestedUIDs in
                try await self.fetchUserProfiles(context: context, exactUIDs: requestedUIDs)
            }
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
            guard !Task.isCancelled,
                  certificationProfileRequestSequence == requestSequence,
                  certificationPresentationRootScope(for: apiContext)
                    == requestScope,
                  certificationIdentityRoot.scope == requestScope else {
                #if DEBUG
                NSLog("[JHT Certification] stage=response_discarded")
                #endif
                return
            }
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
            guard apiContext.isSameAuthAuthority(as: requestAuthority) else {
                throw CancellationError()
            }
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
            let requestedUIDs = Set(batch)
            let responseUIDs = Set(
                response.items.map(\.imUID) + response.missingUIDs
            )
            #if DEBUG
            NSLog("[JHT Certification] stage=response_received requested=%d items=%d missing=%d coverage_valid=%d", batch.count, response.items.count, response.missingUIDs.count, (!response.hasMalformedCoverage && responseUIDs == requestedUIDs) ? 1 : 0)
            #endif
            guard !response.hasMalformedCoverage,
                  responseUIDs == requestedUIDs else {
                _ = certificationIdentityRoot.markMalformedForRefetch(
                    exactUIDs: batch
                )
                pendingCertificationProfileUIDs.formUnion(
                    certificationProfileRequestFence.markFailed(
                        exactUIDs: batch,
                        wave: requestWave,
                        kind: .transient,
                        now: Date()
                    )
                )
                return
            }

            var authoritativeAvatarSummaries: [UserSummaryV2]? = []
            if authoritativeAvatarSummaries != nil {
                for item in response.items {
                    guard case .authoritative(let summary) = item.userSummaryProjection else {
                        authoritativeAvatarSummaries = nil
                        break
                    }
                    authoritativeAvatarSummaries?.append(summary)
                }
                if authoritativeAvatarSummaries?.count != response.items.count {
                    authoritativeAvatarSummaries = nil
                }
            }

            var changed = false
            var resolvedUIDs: Set<String> = []
            var negativeUIDs = Set(response.missingUIDs)
            var malformedUIDs: Set<String> = []
            for item in response.items {
                switch item.userSummaryProjection {
                case .authoritative(let summary):
                    resolvedUIDs.insert(item.imUID)
                    let outcome = certificationIdentityRoot.apply(
                        summary: summary,
                        subjectTenantID: tenantID,
                        responseScope: requestScope,
                        fresh: true
                    )
                    changed = changed
                        || certificationPresentationOutcomeChangesUI(outcome)
                case .authoritativeOmission:
                    negativeUIDs.insert(item.imUID)
                    let outcome = certificationIdentityRoot
                        .applyAuthoritativeMissing(
                            exactUID: item.imUID,
                            responseScope: requestScope,
                            fresh: true
                        )
                    changed = changed
                        || certificationPresentationOutcomeChangesUI(outcome)
                case .malformed:
                    malformedUIDs.insert(item.imUID)
                    _ = certificationIdentityRoot.markMalformedForRefetch(
                        exactUIDs: [item.imUID]
                    )
                    continue
                }
            }
            for uid in response.missingUIDs {
                let outcome = certificationIdentityRoot
                    .applyAuthoritativeMissing(
                        exactUID: uid,
                        responseScope: requestScope,
                        fresh: true
                    )
                changed = changed
                    || certificationPresentationOutcomeChangesUI(outcome)
            }
            #if DEBUG
            let visibleCount = batch.filter { certificationIdentityRoot.presentation(forExactUID: $0) != nil }.count
            let refetchCount = batch.filter { certificationIdentityRoot.state(forExactUID: $0)?.needsRefetch == true }.count
            NSLog("[JHT Certification] stage=projection resolved=%d negative=%d malformed=%d visible=%d needs_refetch=%d", resolvedUIDs.count, negativeUIDs.count, malformedUIDs.count, visibleCount, refetchCount)
            #endif
            if changed {
                certificationPresentationStore.advance() // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }
            certificationProfileRequestFence.markResolved(
                exactUIDs: resolvedUIDs,
                wave: requestWave
            )
            certificationProfileRequestFence.markNegative(
                exactUIDs: negativeUIDs,
                wave: requestWave
            )
            if !malformedUIDs.isEmpty {
                pendingCertificationProfileUIDs.formUnion(
                    certificationProfileRequestFence.markFailed(
                        exactUIDs: malformedUIDs,
                        wave: requestWave,
                        kind: .transient,
                        now: Date()
                    )
                )
            }
            if let authoritativeAvatarSummaries,
               avatarLocalCommitAuthorityFence.epoch == avatarCommitEpochAtRequest,
               AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: avatarRequestStartedAt,
                completedAt: DispatchTime.now().uptimeNanoseconds
               ),
               AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs,
                allItemsAuthoritative: authoritativeAvatarSummaries.count == response.items.count
               ) {
                let outcomes = avatarRealtimeProjection.applyAuthorityBatch(
                    summaries: authoritativeAvatarSummaries,
                    subjectTenantID: tenantID
                )
                handleAvatarRealtimeOutcomes(outcomes)
            }
        } catch {
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
            guard !Task.isCancelled, isAuthenticated,
                  certificationProfileRequestSequence == requestSequence,
                  certificationPresentationRootScope(for: apiContext) == requestScope else {
                return
            }
            let isCurrentFailure = !(error is CancellationError)
                && apiContext.isSameAuthAuthority(as: requestAuthority)
            let failureKind = isCurrentFailure ? Self.certificationProfileFetchFailureKind(error) : .transient
            #if DEBUG
            NSLog("[JHT Certification] stage=request_failed retryable=%d", failureKind == .transient ? 1 : 0)
            #endif
            if isCurrentFailure {
                _ = certificationIdentityRoot.markMalformedForRefetch(exactUIDs: batch)
            }
            pendingCertificationProfileUIDs.formUnion(
                certificationProfileRequestFence.markFailed(
                    exactUIDs: batch,
                    wave: requestWave,
                    kind: failureKind,
                    now: Date()
                )
            )
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
        }
    }

    nonisolated static func certificationProfileFetchFailureKind(
        _ error: Error
    ) -> CertificationProfileFetchFailureKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return .terminal
            default:
                return .transient
            }
        }
        guard let apiError = error as? IMAPIError else { return .transient }
        switch apiError {
        case .rateLimited, .server, .emptyResponse:
            return .transient
        case .httpStatus(let status, _):
            if status == 408 || status == 429 || (500...599).contains(status) {
                return .transient
            }
            return .terminal
        case .missingContext, .badURL, .unauthorized, .forbidden,
             .forcedAuthRequired, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity:
            return .terminal
        }
    }

    func certificationPresentationOutcomeChangesUI(
        _ outcome: CertificationPresentationFenceOutcome
    ) -> Bool {
        switch outcome {
        case .applied, .cleared, .purged:
            return true
        case .invalidated, .purgedForRefetch,
             .idempotent, .ignoredStale, .ignoredForeign:
            return false
        }
    }

}

// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
// appStateEnvironment composition moved to App/FeatureRoutingComposition.swift.
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END
