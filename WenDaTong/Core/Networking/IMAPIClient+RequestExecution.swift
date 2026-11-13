// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
import Foundation
import IM4Core
import CryptoKit
import Dispatch

@MainActor
extension IMAPIClient {
    func request<T: Decodable>(
        base: URL,
        path: String,
        method: String = "GET",
        bearer: String? = nil,
        body: [String: Any]? = nil,
        additionalHeaders: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        preserveHTTPStatusErrors: Bool = false,
		requiredHTTPStatus: Int? = nil,
        preserveRTCSignalErrorDetails: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        bearerPurpose: IMAPIBearerPurpose = .session,
		classifyUncertainMessageSendOutcome: Bool = false,
		classifyUncertainRegistrationOutcome: Bool = false,
		propagateTaskCancellation: Bool = false,
		runtimeRouteReplayPolicy: RuntimeRouteReplayPolicy = .singleSend,
		expectedResponseOrigin: URL? = nil,
        preservePercentEncodedPath: Bool = false,
        requiredRTCEndpoint: URL? = nil,
        coalescingScope: String? = nil,
        validateRTCRequest: (@MainActor () throws -> Void)? = nil,
        requestAuthority: IMAuthSessionFence? = nil,
        contactOwner: ContactHTTPRequestOwner? = nil // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
    ) async throws -> T {
        let messageRouteV5 = method == "POST" && path == "/api/im/messages"
            ? runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue) : nil // WDT_IOS1_HTTP_ROUTE_V5_20261113
        try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        if let diagnostic = SyncFailureDiagnostic.friendAcceptance, diagnostic.matches(method: method, path: path) {
            diagnostic.record(.routing)
        }
        if path.hasPrefix("/api/tenant/") || path.hasPrefix("/api/im/") {
            let scope = revokedTenantRuntimeScope ?? tenantRouteSnapshot.flatMap { snapshot in
                snapshot.tenantID.map { (appID: snapshot.appID, tenantID: $0) }
            }
            if let scope, isTenantRuntimeRevoked(appID: scope.appID, tenantID: scope.tenantID) {
                throw IMAPIError.businessForbidden(code: "tenant_service_stopped", message: "企业服务已停用", error: nil)
            }
        }
        if let requiredRTCEndpoint {
            try Task.checkCancellation()
            let route = runtimeRoutePlan(base: base, path: path)
            let actual = route?.primary.compactMap { URL(string: $0) }.first ?? (route == nil ? base : nil)
            guard path.hasPrefix("/api/rtc/"), actual == requiredRTCEndpoint,
                  runtimeRouteReplayPolicy == .currentEndpointOnly else { throw CancellationError() }
        }
		guard let plan = runtimeRoutePlan(base: base, path: path) else {
			return try await requestOnce(
				base: base, path: path, method: method, bearer: bearer, body: body,
				additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
				preserveHTTPStatusErrors: preserveHTTPStatusErrors,
				requiredHTTPStatus: requiredHTTPStatus,
				preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
				timeoutInterval: timeoutInterval, bearerPurpose: bearerPurpose,
				classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
				classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
				propagateTaskCancellation: propagateTaskCancellation,
				expectedResponseOrigin: expectedResponseOrigin,
                preservePercentEncodedPath: preservePercentEncodedPath,
                coalescingScope: coalescingScope,
                validateRTCRequest: validateRTCRequest,
                requestAuthority: requestAuthority, contactOwner: contactOwner,
                messageRouteV5: messageRouteV5 // WDT_IOS1_HTTP_ROUTE_V5_20261113
			)
		}
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if expectedResponseOrigin == nil, requiredRTCEndpoint == nil,
           runtimeRouteReplayPolicy != .currentEndpointOnly, !path.hasPrefix("/api/rtc/"),
           (messageRouteV5 ?? runtimeRouteStore.routeV5Enabled(plan.service.rawValue)) {
            return try await requestUsingHTTPRouteV5(
                base: base, snapshot: plan.snapshot, service: plan.service, path: path,
                method: method, bearer: bearer, body: body, requestAuthority: requestAuthority,
                contactOwner: contactOwner
            ) { endpoint, checkAuthority in
                try await self.requestOnce(
                    base: endpoint, path: path, method: method, bearer: bearer, body: body,
                    additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
                    preserveHTTPStatusErrors: preserveHTTPStatusErrors, requiredHTTPStatus: requiredHTTPStatus,
                    preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
                    timeoutInterval: timeoutInterval, bearerPurpose: bearerPurpose,
                    classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome
                        || (plan.service == .imAPI && method == "POST" && path == "/api/im/messages"),
                    classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
                    propagateTaskCancellation: true, expectedResponseOrigin: endpoint,
                    preservePercentEncodedPath: preservePercentEncodedPath, coalescingScope: coalescingScope,
                    validateRTCRequest: checkAuthority, requestAuthority: requestAuthority, contactOwner: contactOwner,
                    forcedAuthAuthorityBase: base, messageRouteV5: messageRouteV5
                )
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
		let preferredBudgetMS = plan.snapshot.policy.preferredFailureBudgetMS
		let configuredTimeout = timeoutInterval ?? Self.timeoutInterval(for: path, method: method)
		let primaryAttemptStartedMS = runtimeMonotonicNowMS()
		let primaryDeadlineMS = primaryAttemptStartedMS > UInt64.max - preferredBudgetMS
			? UInt64.max
			: primaryAttemptStartedMS + preferredBudgetMS
		let beganDuringColdLaunch = runtimeColdLaunchLifecycle.isTracking
		let canReplayAcrossEndpoints = Self.canReplayAcrossRuntimeRouteEndpoints(
			method: method,
			policy: runtimeRouteReplayPolicy
		)
		let listRoute = TypedListResponseRoute.matching(method: method, path: path, response: T.self) // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111 · WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
		var lastQualifiedError: Error?
		var attemptedEndpoint = false
		for endpoint in plan.primary {
			guard let candidate = URL(string: endpoint) else { continue }
			if attemptedEndpoint, !canReplayAcrossEndpoints { break }
			let nowMS = runtimeMonotonicNowMS()
			guard nowMS < primaryDeadlineMS else { break }
			let remainingSeconds = TimeInterval(primaryDeadlineMS - nowMS) / 1_000
			// A registration POST cannot be replayed on a backup. Preserve its
			// existing request timeout instead of shortening it to a route probe budget.
			let isRegistrationPost = classifyUncertainRegistrationOutcome && method.uppercased() == "POST"
			let attemptTimeout = isRegistrationPost ? configuredTimeout : min(configuredTimeout, remainingSeconds)
			guard attemptTimeout > 0 else { break }
			attemptedEndpoint = true
			do {
                    if let requiredRTCEndpoint, candidate != requiredRTCEndpoint {
                        throw CancellationError()
                    }
				let value: T = try await requestOnce(
					base: candidate, path: path, method: method, bearer: bearer, body: body,
					additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
					preserveHTTPStatusErrors: preserveHTTPStatusErrors,
					requiredHTTPStatus: requiredHTTPStatus,
					preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
					timeoutInterval: attemptTimeout, bearerPurpose: bearerPurpose,
					classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
					classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
					propagateTaskCancellation: propagateTaskCancellation,
                    expectedResponseOrigin: requiredRTCEndpoint ?? expectedResponseOrigin,
                    preservePercentEncodedPath: preservePercentEncodedPath,
                    coalescingScope: coalescingScope,
                    validateRTCRequest: validateRTCRequest,
                requestAuthority: requestAuthority, contactOwner: contactOwner,
                messageRouteV5: messageRouteV5 // WDT_IOS1_HTTP_ROUTE_V5_20261113
				)
				try listRoute.checkRoutingOwnership() // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
				try contactOwner?.check() // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
				guard listRoute.permitsRouteEffects, contactOwner?.ownsAuthority() != false else { return value } // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
				recordRuntimeColdLaunchSuccessIfNeeded(
					beganDuringColdLaunch: beganDuringColdLaunch,
					plan: plan
				)
				if contactOwner == nil, requiredRTCEndpoint == nil, plan.recovery, method.uppercased() == "GET", body == nil,
				   let preferredEndpoint = plan.backups.first, let preferredBase = URL(string: preferredEndpoint) {
					schedulePreferredHTTPProbe(
						T.self,
						base: preferredBase,
						path: path,
						bearer: bearer,
						additionalHeaders: additionalHeaders,
						preserveHTTPStatusErrors: preserveHTTPStatusErrors,
						preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
						timeoutInterval: attemptTimeout,
						bearerPurpose: bearerPurpose,
						plan: plan,
                        preservePercentEncodedPath: preservePercentEncodedPath,
                        requestAuthority: requestAuthority
					)
				}
				recordAccessDiagnosticsRouteHit(
					service: plan.service,
					endpoint: candidate,
					tier: plan.recovery ? .backup : .preferred
				)
				return value
			} catch {
				guard contactOwner?.ownsAuthority() != false else { throw error } // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
				try listRoute.checkRoutingOwnership(requiresCurrentAuthority: true, after: error) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111 · WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
				let failure = Self.runtimeRouteFailure(for: error)
				guard failure.decision == .qualifiedNetwork else {
					recordRuntimeColdLaunchUnqualifiedIfNeeded(
						beganDuringColdLaunch: beganDuringColdLaunch,
						plan: plan,
						cancelled: failure == .cancelled
					)
					throw error
				}
				lastQualifiedError = error
			}
		}
		if lastQualifiedError != nil, canReplayAcrossEndpoints {
			let nowMS = runtimeMonotonicNowMS()
			let remainingMS = nowMS < primaryDeadlineMS ? primaryDeadlineMS - nowMS : 0
			if remainingMS > 0 {
				do {
					try await runtimeSleep(remainingMS)
				} catch {
					try listRoute.checkRoutingOwnership(requiresCurrentAuthority: true, after: error) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111 · WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
					recordRuntimeColdLaunchUnqualifiedIfNeeded(
						beganDuringColdLaunch: beganDuringColdLaunch,
						plan: plan,
						cancelled: true
					)
					throw error
				}
			}
		}
		try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
		try listRoute.checkRoutingOwnership(requiresCurrentAuthority: lastQualifiedError != nil) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
		if lastQualifiedError != nil {
			recordRuntimeColdLaunchPreferredFailureIfNeeded(
				beganDuringColdLaunch: beganDuringColdLaunch, plan: plan, attemptStartedAtMS: primaryAttemptStartedMS
			)
		}
		if attemptedEndpoint, !canReplayAcrossEndpoints, let lastQualifiedError {
			throw lastQualifiedError
		}
		for endpoint in plan.backups {
			guard let candidate = URL(string: endpoint) else { continue }
			if attemptedEndpoint, !canReplayAcrossEndpoints { break }
			attemptedEndpoint = true
			do {
                    if let requiredRTCEndpoint, candidate != requiredRTCEndpoint {
                        throw CancellationError()
                    }
				let value: T = try await requestOnce(
					base: candidate, path: path, method: method, bearer: bearer, body: body,
					additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
					preserveHTTPStatusErrors: preserveHTTPStatusErrors,
					requiredHTTPStatus: requiredHTTPStatus,
					preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
					timeoutInterval: timeoutInterval, bearerPurpose: bearerPurpose,
					classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
					classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
					propagateTaskCancellation: propagateTaskCancellation,
					expectedResponseOrigin: expectedResponseOrigin,
                    preservePercentEncodedPath: preservePercentEncodedPath,
                    coalescingScope: coalescingScope,
                    validateRTCRequest: validateRTCRequest,
                requestAuthority: requestAuthority, contactOwner: contactOwner,
                messageRouteV5: messageRouteV5 // WDT_IOS1_HTTP_ROUTE_V5_20261113
				)
				try listRoute.checkRoutingOwnership() // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
				try contactOwner?.check() // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
				guard listRoute.permitsRouteEffects, contactOwner?.ownsAuthority() != false else { return value } // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
				recordAccessDiagnosticsRouteHit(
					service: plan.service,
					endpoint: candidate,
					tier: plan.recovery ? .preferred : .backup
				)
				return value
			} catch {
				guard contactOwner?.ownsAuthority() != false else { throw error } // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
				try listRoute.checkRoutingOwnership(requiresCurrentAuthority: true, after: error) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111 · WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
				let failure = Self.runtimeRouteFailure(for: error)
				guard failure.decision == .qualifiedNetwork else { throw error }
				lastQualifiedError = error
			}
		}
		throw lastQualifiedError ?? IMAPIError.server("服务路由暂不可用")
	}

    func requestOnce<T: Decodable>(
        base: URL,
        path: String,
        method: String = "GET",
        bearer: String? = nil,
        body: [String: Any]? = nil,
        additionalHeaders: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        preserveHTTPStatusErrors: Bool = false,
		requiredHTTPStatus: Int? = nil,
        preserveRTCSignalErrorDetails: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        bearerPurpose: IMAPIBearerPurpose = .session,
		classifyUncertainMessageSendOutcome: Bool = false,
		classifyUncertainRegistrationOutcome: Bool = false,
		propagateTaskCancellation: Bool = false,
		expectedResponseOrigin: URL? = nil,
        preservePercentEncodedPath: Bool = false,
        coalescingScope: String? = nil,
        validateRTCRequest: (@MainActor () throws -> Void)? = nil,
        requestAuthority: IMAuthSessionFence? = nil,
        contactOwner: ContactHTTPRequestOwner? = nil, // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        forcedAuthAuthorityBase: URL? = nil,
        messageRouteV5: Bool? = nil // WDT_IOS1_HTTP_ROUTE_V5_20261113
    ) async throws -> T {
        try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
        let listRoute = TypedListResponseRoute.matching(method: method, path: path, response: T.self) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
        try listRoute.checkAttempt(requiresCurrentAuthority: true) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111 · WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
        SyncFailureDiagnostic.httpObservation?.beginUploadStep()
        let acceptanceDiagnostic = SyncFailureDiagnostic.friendAcceptance.flatMap {
            $0.matches(method: method, path: path) ? $0 : nil
        }
        acceptanceDiagnostic?.record(.preparing, endpoint: base)
        guard let url = Self.resolvedURL(
            base: base,
            path: path,
            preservePercentEncodedPath: preservePercentEncodedPath
        ) else {
            throw IMAPIError.badURL(path)
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if forcedAuthAuthorityBase != nil || HTTPRouteTiming.current != nil,
           let expectedResponseOrigin, !Self.sameOrigin(url, expectedResponseOrigin) {
            throw IMAPIError.businessForbidden(code: "route_host_mismatch", message: "服务入口不匹配", error: nil)
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        if let forcedAuthRequestGate {
            // WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112: bind the exact request owner, including nil for ordinary callers.
            try await ContactHTTPRequestOwner.$current.withValue(contactOwner) {
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                try await HTTPRouteTiming.$current.withValue(nil) {
                    try await forcedAuthRequestGate(IMAPIRequestDescriptor(
                        base: forcedAuthAuthorityBase ?? base, path: path, method: method,
                        hasBearerToken: bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ))
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
            }
        }
        try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        try validateRTCRequest?()
        try listRoute.checkAttempt(requiresCurrentAuthority: true) // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111 · WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111 · WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = cachePolicy
        request.timeoutInterval = timeoutInterval ?? Self.timeoutInterval(for: path, method: method)
        request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (field, rawValue) in additionalHeaders
            where field.caseInsensitiveCompare("Idempotency-Key") == .orderedSame {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: "Idempotency-Key")
            }
        }
        if bearerPurpose == .publicMedia, VideoAttachmentHTTPObservation.current != nil,
           method == "POST", path.hasPrefix("/api/tenant/files/"), path.hasSuffix("/uploaded"),
           additionalHeaders["Prefer"] == "respond-async" {
            request.setValue("respond-async", forHTTPHeaderField: "Prefer")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try wireCodec.encodeJSONObject(body)
            } catch {
                SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .requestEncoding))
                throw error
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        let isMessageWrite = method == "POST" && path == "/api/im/messages"
        let durableSend = isMessageWrite ? IMDurableOutgoingSend.current : nil
        let selectedV5 = messageRouteV5 ?? (isMessageWrite && runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue))
        let protectedWrite = isMessageWrite && (durableSend?.didReserve == true || selectedV5)
        if let durableSend {
            guard body?["client_msg_no"] as? String == durableSend.clientMessageID else {
                throw LocalMessageDatabaseError.identityConflict
            }
            try durableSend.checkScope(requestAuthority)
            let admission = try await durableSend.prepare(selectedV5: selectedV5, protect: protectedWrite)
            switch admission {
            case .confirmationRequired: throw MessageSendOutcomeUncertainError(requiresReadback: true)
            case .deferred: throw CancellationError()
            case .send(let knownUnsent):
                do {
                    try Task.checkCancellation()
                    try durableSend.checkScope(requestAuthority)
                    try validateRTCRequest?()
                } catch {
                    if protectedWrite {
                        await durableSend.releaseUnsent()
                    } else if knownUnsent {
                        try? await durableSend.deferKnownUnsent()
                    }
                    throw error
                }
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        let rawResult: RawHTTPResult
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Separate shared transport bytes across exact caller fences, including same-token new epochs.
        let authorityCoalescingScope = Self.requestAuthorityCoalescingScope(requestAuthority, coalescingScope: coalescingScope)
        let dedupeKey = Self.idempotentGETRequestKey(base: base, path: path, method: method, bearer: bearer, body: body, coalescingScope: authorityCoalescingScope)
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
#if DEBUG
        // Only the existing registration submission and typed confirmation
        // entrypoints opt in. Observe before uncertain-outcome conversion loses
        // the HTTP distinction; do not open the suppressed generic HTTP logs.
        let observesRegistration = classifyUncertainRegistrationOutcome || T.self == RemoteRegistrationConfirmation.self
        var registrationDiagnostic: RegistrationDiagnosticState? = observesRegistration
            ? (classifyUncertainRegistrationOutcome ? .submitContractFailed : .statusContractFailed)
            : nil
        defer {
            if let registrationDiagnostic {
                recordRegistrationDiagnostic(
                    registrationDiagnostic,
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - requestStartedAt
                )
            }
        }
#endif
        logHTTPRequestStart(method: method, url: url, bodyData: request.httpBody, dedupeKey: dedupeKey)
        acceptanceDiagnostic?.record(.transportStarted, endpoint: base)
        let callerTrace = SDKHTTPTrace.current // WDT_IOS1_SDK_GET_V3_20261111: this logical caller, not shared creator.
        do {
            rawResult = try await rawHTTPResult(
                for: request,
                dedupeKey: dedupeKey,
				propagateTaskCancellation: propagateTaskCancellation || durableSend != nil,
				expectedResponseOrigin: expectedResponseOrigin, contactOwner: contactOwner // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
            )
            callerTrace?.linkToPhysicalSource(rawResult.producerSourceCorrelation) // WDT_IOS1_SDK_GET_V3_20261111: one causal edge after original await.
        } catch {
            try listRoute.checkAttempt() // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111 · WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
#if DEBUG
            if observesRegistration {
                registrationDiagnostic = .transportFailure(isSubmission: classifyUncertainRegistrationOutcome, error: error)
            }
#endif
            logRequestFailure(method: method, url: url, statusCode: nil, errorCode: "transport", requestID: nil, error: error)
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(error: error))
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            if protectedWrite {
                let failure = Self.runtimeRouteFailure(for: error)
                if failure == .tlsCertificate || failure == .dns || (error as? URLError)?.code == .cannotConnectToHost {
                    await durableSend?.releaseUnsent()
                    throw error
                }
                throw MessageSendOutcomeUncertainError(requiresReadback: true)
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
            if classifyUncertainMessageSendOutcome { throw MessageSendOutcomeUncertainError() }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw error
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        do {
            try contactOwner?.check()
            try validateRTCRequest?()
            try listRoute.checkAttempt()
        } catch {
            if protectedWrite {
                throw MessageSendOutcomeUncertainError(requiresReadback: true, statusCode: rawResult.statusCode)
            }
            throw error
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - requestStartedAt) * 1000)
        guard rawResult.isHTTPResponse, let statusCode = rawResult.statusCode else {
            logRequestFailure(method: method, url: url, statusCode: nil, errorCode: "invalid_response", requestID: nil, error: nil)
            if classifyUncertainMessageSendOutcome || protectedWrite {
                throw MessageSendOutcomeUncertainError(requiresReadback: protectedWrite)
            }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.emptyResponse
        }
        SyncFailureDiagnostic.httpObservation?.recordPrimaryResponse(
            path: path, status: statusCode,
            fingerprint: rawResult.requestID.map {
                "hash:" + SHA256.hash(data: Data($0.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            },
            resolvedPath: url.path
        )
#if DEBUG
        if observesRegistration {
            registrationDiagnostic = .httpResponse(isSubmission: classifyUncertainRegistrationOutcome, statusCode: statusCode)
        }
#endif
		if let expectedResponseOrigin {
			guard let responseURL = rawResult.responseURL,
			      Self.sameOrigin(responseURL, expectedResponseOrigin) else {
                if protectedWrite {
                    throw MessageSendOutcomeUncertainError(requiresReadback: true, statusCode: statusCode)
                }
				throw IMAPIError.businessForbidden(
					code: "bootstrap_host_mismatch",
					message: "应用启动响应来源不匹配",
					error: nil
				)
			}
		}
        let data = rawResult.data
        if bearerPurpose == .publicMedia, let videoUpload = VideoAttachmentHTTPObservation.current {
            videoUpload.status = statusCode
            videoUpload.retryAfter = max(0, rawResult.retryAfterSeconds ?? 0)
        }
        // Capture the actual envelope code and trace before the existing error
        // branches normalize them to .server(String) and a generic UI toast.
        acceptanceDiagnostic?.record(.response, endpoint: base, status: statusCode,
                                     responseData: data, requestID: rawResult.requestID)
        logHTTPResponse(method: method, url: url, statusCode: statusCode, requestID: rawResult.requestID, data: data, elapsedMS: elapsedMS)
		if let requiredHTTPStatus, statusCode != requiredHTTPStatus {
			logRequestFailure(
				method: method,
				url: url,
				statusCode: statusCode,
				errorCode: "http_\(statusCode)",
				requestID: rawResult.requestID,
				error: nil
			)
			throw IMAPIError.httpStatus(
				statusCode,
				message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
			)
		}
        let decodeStart = CFAbsoluteTimeGetCurrent()
        // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN: move only chat response parsing off the UI actor.
        let decoded: DecodedAPIResponse<T>
        // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
        if method == "POST", path == "/api/im/conversations/page", T.self == RemoteConversationPage.self {
            let page = await decodeConversationPageResponseOffMain(from: data, observation: callerTrace?.decode)
            // The exact metatype guard keeps the new cross-task value page-only.
            // Generic response handling resumes on its original MainActor here.
            decoded = DecodedAPIResponse(errorEnvelope: page.errorEnvelope,
                loginSecurityEnvelope: page.loginSecurityEnvelope, envelope: page.envelope as? APIEnvelope<T>)
        // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_BEGIN
        } else if method == "POST", path == "/api/im/conversations/sync", T.self == RemoteConversationSyncData.self {
            let sync = await decodeConversationSyncResponseOffMain(from: data, observation: callerTrace?.decode)
            try Task.checkCancellation()
            let envelope = sync.envelope.map { APIEnvelope<T>(ok: $0.ok, data: $0.data as? T, error: $0.error) }
            decoded = DecodedAPIResponse(errorEnvelope: sync.errorEnvelope,
                loginSecurityEnvelope: sync.loginSecurityEnvelope, envelope: envelope)
        // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_END
        } else if Self.shouldDecodeChatResponseOffMain(path: path) {
            decoded = await decodeAPIResponseOffMain(from: data, observation: callerTrace?.decode)
        // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
        } else if listRoute != .other { // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
            let list = await decodeTypedListTransferOffMain(from: data, route: listRoute, observation: callerTrace?.decode)
            decoded = try list.classificationResponse(status: statusCode) // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END
        // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
        } else {
            decoded = decodeAPIResponse(from: data, observation: callerTrace?.decode)
        }
        // WDT_CHAT_RESOURCE_PERF_20261023_END
        try contactOwner?.check() // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
        let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
        if decodeMs > 80, SyncFailureDiagnostic.friendAcceptance == nil {
            print("[JHT Perf] api_decode_ms=\(decodeMs) method=\(method) path=\(Self.redactedPathForLog(path)) bytes=\(data.count)")
        }
        let errorEnvelope = decoded.errorEnvelope
        let loginSecurityEnvelope = decoded.loginSecurityEnvelope
        let envelope = decoded.envelope
        let errorBody = errorEnvelope?.resolvedError ?? envelope?.error ?? loginSecurityEnvelope?.resolvedError
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if let timing = HTTPRouteTiming.current, envelope?.ok == false || errorBody != nil {
            timing.failed(IMAPIError.server("服务返回明确业务错误"))
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        let requestID = rawResult.requestID
        let errorCode = Self.effectiveErrorCode(for: errorBody) ?? ""
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if protectedWrite, !(200..<300).contains(statusCode) {
            if [400, 401, 403, 404, 405, 409, 410, 413, 415, 422, 429].contains(statusCode) {
                // The message handler rejected the request before persisting a new message.
                await durableSend?.releaseUnsent()
            } else {
                throw MessageSendOutcomeUncertainError(requiresReadback: true, statusCode: statusCode,
                    businessCode: errorCode.isEmpty ? nil : errorCode)
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册 503 中明确的回执/状态错误保留 code，交给 AppState 继续原确认流程并展示文案
        if classifyUncertainRegistrationOutcome,
           statusCode == 503,
           ["registration_request_already_submitted", "registration_status_unavailable"]
            .contains(errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "正在确认注册结果，请勿重复提交。"),
                error: errorBody
            )
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        if classifyUncertainRegistrationOutcome, (500..<600).contains(statusCode) {
            throw RegistrationOutcomeUncertainError()
        }
        if !preserveHTTPStatusErrors,
           [502, 503, 504].contains(statusCode),
           errorCode.isEmpty {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .http, httpStatus: statusCode))
            throw IMAPIError.httpStatus(
                statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }
        if statusCode == 422 && errorCode == "captcha_device_proof_required" {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "设备验证已失效，请重试"),
                error: errorBody
            )
        }
        if errorCode == "security_blocked" {
            let info = SecurityBlockedInfo(error: errorBody)
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.securityBlocked(info)
        }
        if let quotaCode = IMAPIClient.licenseQuotaErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: quotaCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: quotaCode,
                message: IMAPIClient.licenseQuotaUserMessage(for: quotaCode),
                error: errorBody
            )
        }
        if Self.isLoginRequestPath(path),
           let loginCode = Self.loginFailureCode(errorCode, statusCode: statusCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: loginCode, requestID: requestID, error: nil)
            throw IMAPIError.loginSecurity(
                code: loginCode,
                message: Self.userMessage(for: errorBody, fallback: "登录失败"),
                info: loginSecurityEnvelope?.data
            )
        }
        // JHT_MOD_BEGIN LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改开始：登录 503 auth_dependency_unavailable 保留业务码，避免被普通 503 吞掉后误回退
        if Self.isLoginRequestPath(path),
           statusCode == 503,
           errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auth_dependency_unavailable" {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: "auth_dependency_unavailable",
                message: Self.userMessage(for: errorBody, fallback: "登录服务暂不可用，请稍后重试"),
                error: errorBody
            )
        }
        // JHT_MOD_END LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改结束
        if statusCode == 401, bearerPurpose == .rtc {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode.isEmpty ? "rtc_unauthorized" : errorCode, requestID: requestID, error: nil)
            throw RTCCredentialError.unauthorized(Self.userMessage(for: errorBody, fallback: "RTC 凭证已失效"))
        }
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_AUTH_ERRORS - 修改开始：媒体公共接口的 401/403/423 不触发会话刷新、设备吊销或登录安全分支
        if bearerPurpose == .publicMedia,
           statusCode == 401 || statusCode == 403 || statusCode == 423 {
            let publicMediaCode = Self.effectiveErrorCode(for: errorBody) ?? "http_\(statusCode)"
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: publicMediaCode,
                requestID: requestID,
                error: nil
            )
            throw IMAPIError.httpStatus(
                statusCode,
                message: Self.userMessage(
                    for: errorBody,
                    fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
                )
            )
        }
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_AUTH_ERRORS - 修改结束
        if bearerPurpose == .session,
           (statusCode == 401 || statusCode == 403),
           DeviceRevocationDetector.matches(error: errorBody) {
            let deviceCode = Self.effectiveErrorCode(for: errorBody) ?? "device_revoked"
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: deviceCode, requestID: requestID, error: nil)
            if Self.isPushDeviceRegistrationRequestPath(path, method: method) {
                throw IMAPIError.businessForbidden(
                    code: deviceCode,
                    message: Self.userMessage(for: errorBody, fallback: "推送设备注册失败"),
                    error: errorBody
                )
            }
            // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN
            guard requestAuthority != nil, !IMRouteV5OpeningRead.isActive else { // WDT_IOS1_HTTP_ROUTE_V5_20261113
                throw IMAnonymousDeviceRejectionError(statusCode: statusCode, code: deviceCode,
                    userMessage: DeviceRevocationDetector.logoutMessage)
            }
            // WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END
            // WDT_IOS1_REFRESH_DEVICE_ERROR_AUTHORITY_OWNER_20261111_BEGIN — This refresh already has a captured authority owner; do not post an unscoped event first.
            if method == "POST", path == "/api/tenant/auth/session/refresh" {
                throw IMSessionRefreshRejectionError(statusCode: statusCode, code: deviceCode,
                    userMessage: Self.userMessage(for: errorBody, fallback: DeviceRevocationDetector.logoutMessage))
            }
            // WDT_IOS1_REFRESH_DEVICE_ERROR_AUTHORITY_OWNER_20261111_END
            // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — No caller fence means no authority to clear any live session.
            if let requestAuthority {
                try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
                NotificationCenter.default.post(name: .imCurrentDeviceRevoked, object: requestAuthority)
            }
            // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
            throw IMAPIError.unauthorized(DeviceRevocationDetector.logoutMessage)
        }
        if statusCode == 401, Self.isSessionRefreshRequestPath(path), !errorCode.isEmpty {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMSessionRefreshRejectionError(
                statusCode: statusCode,
                code: errorCode,
                userMessage: Self.userMessage(for: errorBody, fallback: "登录已失效")
            )
        }
        if statusCode == 401 {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "unauthorized", requestID: requestID, error: nil)
            throw IMAPIError.unauthorized(Self.userMessage(for: errorBody, fallback: "登录已失效"))
        }
        if statusCode == 423 {
            let lockedCode = Self.effectiveErrorCode(for: errorBody) ?? "account_locked"
            let lockedMessage = Self.userMessage(for: errorBody, fallback: "账号已锁定，请联系商户后台管理员解锁")
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: lockedCode, requestID: requestID, error: nil)
            throw IMAPIError.loginSecurity(
                code: lockedCode,
                message: lockedMessage,
                info: loginSecurityEnvelope?.data
            )
        }
        if let capabilityCode = Self.licenseCapabilityErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: capabilityCode, requestID: requestID, error: nil)
            throw IMAPIError.conflict(
                code: capabilityCode,
                message: Self.userMessage(for: errorBody, fallback: "企业能力不可用")
            )
        }
        if Self.isAccessDiscoveryRequestPath(path),
           Self.isTerminalAccessDiscoveryErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "实时连接入口暂不可用"),
                error: errorBody
            )
        }
        if statusCode == 403 {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "forbidden", requestID: requestID, error: nil)
            if let errorBody,
               Self.isFriendshipRequiredError(errorBody) {
                throw IMAPIError.businessForbidden(
                    code: Self.effectiveErrorCode(for: errorBody) ?? "not_friends",
                    message: Self.userMessage(for: errorBody, fallback: "需先添加好友后才能发起私聊"),
                    error: errorBody
                )
            }
            if let errorBody {
                throw IMAPIError.businessForbidden(
                    code: Self.effectiveErrorCode(for: errorBody) ?? "forbidden",
                    message: Self.userMessage(for: errorBody, fallback: "无权限"),
                    error: errorBody
                )
            }
            throw IMAPIError.forbidden(Self.userMessage(for: errorBody, fallback: "无权限"))
        }
        if method == "POST", path == "/api/im/conversations/page",
           statusCode == 400 || statusCode == 410 || (500...599).contains(statusCode) {
            throw ConversationPageFailure(
                statusCode: statusCode,
                code: errorCode == "conversation_page_cursor_expired" ? errorCode : "conversation_page_unavailable"
            )
        }
        if preserveRTCSignalErrorDetails,
           (statusCode == 404 || statusCode == 409 || statusCode == 422 ||
            (statusCode == 400 && errorCode == "bad_json" && method == "POST" &&
             path.hasPrefix("/api/rtc/rooms/") && path.hasSuffix("/quality-samples") &&
             path.split(separator: "/").count == 5)) {
            let code = errorCode.isEmpty ? "http_\(statusCode)" : errorCode
            let message = Self.userMessage(
                for: errorBody,
                fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: code,
                requestID: requestID,
                error: nil
            )
            throw RTCVideoSignalHTTPError(statusCode: statusCode, code: code, message: message)
        }
        if statusCode == 409 {
            let conflictCode = Self.effectiveErrorCode(for: errorBody) ?? "conflict"
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: conflictCode, requestID: requestID, error: nil)
            if bearerPurpose == .publicMedia, VideoAttachmentHTTPObservation.current != nil, method == "POST",
               path.hasPrefix("/api/tenant/files/"), path.hasSuffix("/uploaded"),
               path.split(separator: "/").count == 5,
               errorBody?.code == "object_not_found" {
                throw VideoAttachmentObjectMissing(retryAfterSeconds: max(
                    0, errorBody?.retryAfterSeconds ?? 0, rawResult.retryAfterSeconds ?? 0
                ))
            }
            throw IMAPIError.conflict(
                code: conflictCode,
                message: Self.userMessage(for: errorBody, fallback: "操作冲突")
            )
        }
        if statusCode == 429 {
            let retryAfterHeader = rawResult.retryAfterSeconds
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "rate_limited", requestID: requestID, error: nil)
            throw IMAPIError.rateLimited(
                code: Self.effectiveErrorCode(for: errorBody) ?? "rate_limited",
                message: Self.userMessage(for: errorBody, fallback: "操作过于频繁，请稍后再试"),
                retryAfterSeconds: errorBody?.retryAfterSeconds ?? retryAfterHeader,
                lockedUntil: errorBody?.lockedUntil
            )
        }
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        if !(200..<300).contains(statusCode), url.path.hasSuffix("/api/tenant/search") {
            let code = errorCode.isEmpty ? "http_\(statusCode)" : errorCode
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: code, requestID: requestID, error: nil)
            throw TenantSearchHTTPFailure(status: statusCode, code: code)
        }
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        if classifyUncertainRegistrationOutcome,
           (400..<500).contains(statusCode),
           !errorCode.isEmpty {
            let message = Self.userMessage(
                for: errorBody,
                fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: errorCode,
                requestID: requestID,
                error: nil
            )
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: message,
                error: errorBody
            )
        }
        if preserveHTTPStatusErrors, !(200..<300).contains(statusCode) {
            if classifyUncertainRegistrationOutcome,
               (errorBody == nil || errorCode.isEmpty) {
                throw RegistrationOutcomeUncertainError()
            }
            let message = Self.userMessage(for: errorBody, fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode))
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "http_\(statusCode)", requestID: requestID, error: nil)
            throw IMAPIError.httpStatus(statusCode, message: message)
        }
        guard let envelope else {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: "decode_envelope_failed", requestID: requestID, error: nil)
            if !errorCode.isEmpty {
                SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(
                    code: (200..<300).contains(statusCode) ? .decode : .http,
                    httpStatus: statusCode, serverCode: errorCode
                ))
            }
            if classifyUncertainMessageSendOutcome || protectedWrite, (200..<300).contains(statusCode) {
                throw MessageSendOutcomeUncertainError(requiresReadback: protectedWrite, statusCode: statusCode)
            }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.server(HTTPURLResponse.localizedString(forStatusCode: statusCode))
        }
        if !(200..<300).contains(statusCode) || envelope.ok == false {
            if protectedWrite, (200..<300).contains(statusCode) {
                throw MessageSendOutcomeUncertainError(requiresReadback: true, statusCode: statusCode,
                    businessCode: errorCode.isEmpty ? nil : errorCode)
            } // WDT_IOS1_HTTP_ROUTE_V5_20261113
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: envelope.error) ?? "api_error", requestID: requestID, error: nil)
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.server(Self.userMessage(for: envelope.error, fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)))
        }
        if let data = envelope.data {
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            if protectedWrite, let sent = data as? RemoteSendResponse,
               !AuthoritativeMessageSendPolicy.accepts(remoteMessageID: sent.message.messageID) || sent.message.channelSeq <= 0 {
                throw MessageSendOutcomeUncertainError(requiresReadback: true, statusCode: statusCode)
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
#if DEBUG
            if observesRegistration {
                registrationDiagnostic = .httpResponse(
                    isSubmission: classifyUncertainRegistrationOutcome,
                    statusCode: statusCode,
                    acceptedPayload: envelope.ok == true,
                    confirmationStatus: (data as? RemoteRegistrationConfirmation)?.status
                )
            }
#endif
            return data
        }
        if T.self == EmptyPayload.self, let empty = EmptyPayload() as? T {
            return empty
        }
        // Access discovery can return its config or signed envelope at the
        // JSON root. The caller still verifies signed payloads before use.
        if Self.isAccessDiscoveryRequestPath(url.path),
           envelope.ok == nil, errorBody == nil {
            if (T.self == RemoteAccessDiscoveryResponse.self || T.self == SignedAccessDiscoveryEnvelope.self),
               let discovery = try? wireCodec.decode(T.self, from: data) {
                return discovery
            }
            if T.self == RemoteAccessDiscoveryResponse.self,
               (try? wireCodec.decode(SignedAccessDiscoveryEnvelope.self, from: data)) != nil {
                throw AccessDiscoveryTrustError.configurationBlocked
            }
        }
        logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: "empty_data", requestID: requestID, error: nil)
        if classifyUncertainMessageSendOutcome || protectedWrite, (200..<300).contains(statusCode) {
            throw MessageSendOutcomeUncertainError(requiresReadback: protectedWrite, statusCode: statusCode)
        }
        if classifyUncertainRegistrationOutcome {
            throw RegistrationOutcomeUncertainError()
        }
        throw IMAPIError.emptyResponse
    }
}

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END
