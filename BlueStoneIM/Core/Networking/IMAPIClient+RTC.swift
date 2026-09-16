import Foundation

@MainActor
extension IMAPIClient {
    func rtcPolicyEndpoint(_ context: IMAPIContext) throws -> URL {
        let base = tenantBase(for: context)
        guard let plan = runtimeRoutePlan(base: base, path: "/api/rtc/provider") else { return base }
        guard let endpoint = plan.primary.compactMap({ URL(string: $0) }).first else {
            throw CancellationError()
        }
        return endpoint
    }

    func rtcPolicyScope(_ context: IMAPIContext, endpoint: URL) -> [String] {
        [endpoint.absoluteString, context.tenantID ?? "", context.appID,
         context.imUID ?? "", context.deviceID, context.sessionEpoch, String(context.credentialRevision),
         String(tenantRouteTransientGeneration)]
    }

    func validateRTCPolicyScope(_ scope: [String], context: IMAPIContext) throws {
        try Task.checkCancellation()
        guard scope == rtcPolicyScope(context, endpoint: try rtcPolicyEndpoint(context)) else {
            throw CancellationError()
        }
    }

    func rtcPolicyObservation(context: IMAPIContext) async throws -> RTCPolicyObservation {
        let endpoint = try rtcPolicyEndpoint(context)
        let scope = rtcPolicyScope(context, endpoint: endpoint)
        if let cached = rtcPolicyAdvertisement, cached.scope == scope, cached.expiresAt > Date() {
            try Task.checkCancellation()
            return cached
        }
        _ = try await rtcProvider(context: context)
        guard let observation = rtcPolicyAdvertisement,
              observation.scope == rtcPolicyScope(context, endpoint: try rtcPolicyEndpoint(context)),
              observation.expiresAt > Date() else { throw CancellationError() }
        return observation
    }

    func negotiatedRTCCapabilities(
        _ capabilities: RTCDeviceCapabilities, observation: RTCPolicyObservation
    ) -> [String: Any] {
        var body = capabilities.requestBody
        if observation.requiresV1 { body["ice_transport_policy_version"] = 1 }
        return body
    }

    func rtcProvider(context: IMAPIContext) async throws -> RemoteRTCProvider {
        try requireIM(context)
        let endpoint = try rtcPolicyEndpoint(context)
        let scope = rtcPolicyScope(context, endpoint: endpoint)
        rtcPolicyAdvertisement = nil
        let provider: RemoteRTCProvider = try await request(
            base: endpoint,
            path: "/api/rtc/provider",
            bearer: context.imToken,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: endpoint,
            requiredRTCEndpoint: endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(scope, context: context) }
        )
        try Task.checkCancellation()
        guard scope == rtcPolicyScope(context, endpoint: try rtcPolicyEndpoint(context)) else {
            throw CancellationError()
        }
        rtcPolicyAdvertisement = RTCPolicyObservation(scope: scope, endpoint: endpoint,
            requiresV1: provider.iceTransportPolicyVersion == 1, expiresAt: Date().addingTimeInterval(30))
        return provider
    }

    func listRTCCalls(context: IMAPIContext) async throws -> [RemoteRTCCall] {
        try requireIM(context)
        let data: RemoteRTCCallsData = try await request(base: tenantBase(for: context), path: "/api/rtc/calls", bearer: context.imToken)
        return data.calls
    }

    func createRTCCall(context: IMAPIContext, calleeUID: String, callType: String, channelID: String? = nil) async throws -> RemoteRTCCallResponse {
        try requireIM(context)
        let observation = try await rtcPolicyObservation(context: context)
        let normalizedCallType = callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var body: [String: Any] = [
            "callee_uid": calleeUID,
            "target_uid": calleeUID,
            "channel_type": "direct",
            "call_type": normalizedCallType.isEmpty ? callType : normalizedCallType
        ]
        if normalizedCallType == "audio" {
            let capabilities = RTCDeviceCapabilities(audio: true, video: false, cameraAvailable: false)
            body["device_capabilities"] = negotiatedRTCCapabilities(capabilities, observation: observation)
            body["idempotency_key"] = Self.rtcMutationIdempotencyKey("audio-create")
        }
        if let channelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channelID.isEmpty {
            body["channel_id"] = channelID
        }
        var response: RemoteRTCCallResponse = try await request(
            base: observation.endpoint,
            path: "/api/rtc/calls",
            method: "POST",
            bearer: context.imToken,
            body: body,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
        response.requiresAcceptedDeviceBeforeJoin = observation.requiresV1
        return response
    }

    func acceptRTCCall(context: IMAPIContext, callID: String) async throws -> RemoteRTCCallResponse {
        try requireIM(context)
        let observation = try await rtcPolicyObservation(context: context)
        let capabilities = RTCDeviceCapabilities(audio: true, video: false, cameraAvailable: false)
        return try await request(
            base: observation.endpoint,
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/accept",
            method: "POST",
            bearer: context.imToken,
            body: [
                "accept_mode": "audio",
                "device_capabilities": negotiatedRTCCapabilities(capabilities, observation: observation),
                "idempotency_key": Self.rtcMutationIdempotencyKey("audio-accept")
            ],
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
    }

    func rejectRTCCall(context: IMAPIContext, callID: String) async throws {
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        try await rejectRTCCall(
            context: context,
            callID: callID,
            idempotencyKey: Self.rtcMutationIdempotencyKey("reject")
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func rejectRTCCall(context: IMAPIContext, callID: String, idempotencyKey: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/reject",
            method: "POST",
            bearer: context.imToken,
            body: ["idempotency_key": idempotencyKey]
        )
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func cancelRTCCall(context: IMAPIContext, callID: String, reason: String) async throws {
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        try await cancelRTCCall(
            context: context,
            callID: callID,
            reason: reason,
            idempotencyKey: Self.rtcMutationIdempotencyKey("cancel")
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func cancelRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/cancel",
            method: "POST",
            bearer: context.imToken,
            body: [
                "idempotency_key": idempotencyKey,
                "reason": reason
            ]
        )
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func hangupRTCCall(context: IMAPIContext, callID: String, reason: String) async throws {
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        try await hangupRTCCall(
            context: context,
            callID: callID,
            reason: reason,
            idempotencyKey: Self.rtcMutationIdempotencyKey("hangup")
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func hangupRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/hangup",
            method: "POST",
            bearer: context.imToken,
            body: [
                "idempotency_key": idempotencyKey,
                "reason": reason
            ]
        )
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func timeoutRTCCall(context: IMAPIContext, callID: String, reason: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/timeout",
            method: "POST",
            bearer: context.imToken,
            body: [
                "idempotency_key": Self.rtcMutationIdempotencyKey("timeout"),
                "reason": reason
            ]
        )
    }

    func joinRTCRoom(context: IMAPIContext, roomID: String, rtcToken: String) async throws -> RemoteRTCRoomJoinData {
        try requireIM(context)
        guard !roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("语音房间信息不完整")
        }
        let observation = try await rtcPolicyObservation(context: context)
        let joined: RemoteRTCRoomJoinData = try await request(
            base: observation.endpoint,
            path: "/api/rtc/rooms/\(roomID.urlPathEncoded)/join",
            method: "POST",
            bearer: rtcToken,
            body: ["rtc_token": rtcToken],
            bearerPurpose: .rtc,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
        _ = try RTCIcePolicy.resolve(joined.media.icePolicy, requiresV1: observation.requiresV1, servers: joined.media.iceServers)
        return joined
    }

    func updateRTCMediaState(
        context: IMAPIContext,
        callID: String,
        mediaState: String,
        expectedStateVersion: Int64? = nil,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteRTCCall {
        try requireIM(context)
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMediaState = mediaState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCallID.isEmpty, !normalizedMediaState.isEmpty else {
            throw IMAPIError.server("视频通话状态信息不完整")
        }
        var body: [String: Any] = [
            "idempotency_key": idempotencyKey,
            "media_state": normalizedMediaState
        ]
        if let expectedStateVersion, expectedStateVersion > 0 {
            body["expected_state_version"] = expectedStateVersion
        }
        let response: RemoteRTCCallResponse = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(normalizedCallID.urlPathEncoded)/media-state",
            method: "POST",
            bearer: context.imToken,
            body: body,
            preserveRTCSignalErrorDetails: true
        )
        return response.call
    }

    func listRTCRoomParticipants(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String
    ) async throws -> [RemoteRTCRoomParticipant] {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("语音房间信息不完整")
        }
        guard let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty else {
            throw IMAPIError.missingContext("tenant_id")
        }
        let data: RemoteList<RemoteRTCRoomParticipant> = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/participants?tenant_id=\(tenantID.urlQueryEncoded)",
            bearer: normalizedToken,
            bearerPurpose: .rtc
        )
        return data.items
    }

    func postRTCSignal(context: IMAPIContext, roomID: String, rtcToken: String, envelope: RemoteRTCSignalEnvelope) async throws {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("语音房间信息不完整")
        }
        let signalKind = envelope.kind.rawValue
        let body: [String: Any] = [
            "to_uid": envelope.toUID,
            "to_device": envelope.toDevice,
            "kind": signalKind,
            "data": envelope.data.mapValues(\.anyValue)
        ]
        let path = "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/signal"
        let signalBase = tenantBase(for: context)
        guard let url = URL(string: path, relativeTo: signalBase)?.absoluteURL else {
            throw IMAPIError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutInterval(for: path, method: "POST")
        request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try wireCodec.encodeJSONObject(body)

        let rawResult: RawHTTPResult
        do {
            rawResult = try await rawHTTPResult(for: request, dedupeKey: nil)
        } catch {
            Self.rtcSignalDebug(
                "post_signal_failed status=none code=transport room=\(Self.rtcShortDebugID(normalizedRoomID)) kind=\(signalKind) toUID=\(!envelope.toUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDevice=\(!envelope.toDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDeviceHash=\(Self.rtcDeviceDebugHash(envelope.toDevice)) error=\(Self.redactedSensitiveLogText(error.localizedDescription))"
            )
            throw error
        }
        guard rawResult.isHTTPResponse, let statusCode = rawResult.statusCode else {
            Self.rtcSignalDebug(
                "post_signal_failed status=none code=invalid_response room=\(Self.rtcShortDebugID(normalizedRoomID)) kind=\(signalKind) toUID=\(!envelope.toUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDevice=\(!envelope.toDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDeviceHash=\(Self.rtcDeviceDebugHash(envelope.toDevice))"
            )
            throw IMAPIError.emptyResponse
        }
        let decoded: DecodedAPIResponse<EmptyPayload> = decodeAPIResponse(from: rawResult.data)
        let errorBody = decoded.errorEnvelope?.resolvedError ?? decoded.envelope?.error ?? decoded.loginSecurityEnvelope?.resolvedError
        let errorCode = Self.effectiveErrorCode(for: errorBody) ?? ""
        let requestIDText = rawResult.requestID?.isEmpty == false ? rawResult.requestID! : "none"
        if (200..<300).contains(statusCode), decoded.envelope?.ok != false {
            Self.rtcSignalDebug(
                "post_signal_ok status=\(statusCode) room=\(Self.rtcShortDebugID(normalizedRoomID)) kind=\(signalKind) toUID=\(!envelope.toUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDevice=\(!envelope.toDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDeviceHash=\(Self.rtcDeviceDebugHash(envelope.toDevice)) request_id=\(requestIDText)"
            )
            return
        }

        let logCode = errorCode.isEmpty ? "http_\(statusCode)" : errorCode
        let message = Self.userMessage(for: errorBody, fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode))
        Self.rtcSignalDebug(
            "post_signal_failed status=\(statusCode) code=\(logCode) message=\(Self.redactedSensitiveLogText(message)) room=\(Self.rtcShortDebugID(normalizedRoomID)) kind=\(signalKind) toUID=\(!envelope.toUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDevice=\(!envelope.toDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) toDeviceHash=\(Self.rtcDeviceDebugHash(envelope.toDevice)) request_id=\(requestIDText)"
        )
        if statusCode == 401 {
            throw RTCCredentialError.unauthorized(Self.userMessage(for: errorBody, fallback: "RTC 凭证已失效"))
        }
        if statusCode == 403 {
            throw IMAPIError.businessForbidden(code: logCode, message: message, error: errorBody)
        }
        if statusCode == 409 {
            throw IMAPIError.conflict(code: logCode, message: message)
        }
        if statusCode == 429 {
            throw IMAPIError.rateLimited(
                code: logCode,
                message: message,
                retryAfterSeconds: errorBody?.retryAfterSeconds ?? rawResult.retryAfterSeconds,
                lockedUntil: errorBody?.lockedUntil
            )
        }
        throw IMAPIError.server(message)
    }

    func pollRTCSignals(context: IMAPIContext, roomID: String, rtcToken: String, deviceID: String) async throws -> [RemoteRTCSignalItem] {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("语音房间信息不完整")
        }
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalizedDeviceID.isEmpty ? "" : "?device_id=\(normalizedDeviceID.urlQueryEncoded)"
        let data: RemoteRTCSignalItemsData = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/signal\(query)",
            bearer: normalizedToken,
            bearerPurpose: .rtc
        )
        return data.items
    }

    func updateRTCDeviceCapabilities(context: IMAPIContext, capabilities: RTCDeviceCapabilities) async throws {
        try requireIM(context)
        let observation = try await rtcPolicyObservation(context: context)
        let _: EmptyPayload = try await request(
            base: observation.endpoint,
            path: "/api/rtc/device-capabilities",
            method: "PUT",
            bearer: context.imToken,
            body: ["device_capabilities": negotiatedRTCCapabilities(capabilities, observation: observation)],
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
    }

    func createRTCVideoCall(
        context: IMAPIContext,
        calleeUID: String,
        channelID: String?,
        capabilities: RTCDeviceCapabilities
    ) async throws -> RemoteRTCCallResponse {
        try requireIM(context)
        let observation = try await rtcPolicyObservation(context: context)
        var body: [String: Any] = [
            "target_uid": calleeUID,
            "call_type": "video",
            "channel_type": "direct",
            "device_capabilities": negotiatedRTCCapabilities(capabilities, observation: observation),
            "idempotency_key": Self.rtcMutationIdempotencyKey("video-create")
        ]
        if let channelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines), !channelID.isEmpty {
            body["channel_id"] = channelID
        }
        var response: RemoteRTCCallResponse = try await request(
            base: observation.endpoint,
            path: "/api/rtc/calls",
            method: "POST",
            bearer: context.imToken,
            body: body,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
        response.requiresAcceptedDeviceBeforeJoin = observation.requiresV1
        return response
    }

    func acceptRTCCall(
        context: IMAPIContext,
        callID: String,
        mode: String,
        capabilities: RTCDeviceCapabilities
    ) async throws -> RemoteRTCCallResponse {
        try requireIM(context)
        let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMode == "audio" || normalizedMode == "video" else {
            throw IMAPIError.server("接听方式无效")
        }
        let observation = try await rtcPolicyObservation(context: context)
        return try await request(
            base: observation.endpoint,
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/accept",
            method: "POST",
            bearer: context.imToken,
            body: [
                "accept_mode": normalizedMode,
                "device_capabilities": negotiatedRTCCapabilities(capabilities, observation: observation),
                "idempotency_key": Self.rtcMutationIdempotencyKey("video-accept")
            ],
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: observation.endpoint,
            requiredRTCEndpoint: observation.endpoint,
            validateRTCRequest: { try self.validateRTCPolicyScope(observation.scope, context: context) }
        )
    }

    func downgradeRTCCall(context: IMAPIContext, callID: String, reason: String) async throws -> RemoteRTCCallResponse {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/\(callID.urlPathEncoded)/downgrade",
            method: "POST",
            bearer: context.imToken,
            body: [
                "idempotency_key": Self.rtcMutationIdempotencyKey("video-downgrade"),
                "media_mode": "audio",
                "reason": reason
            ]
        )
    }

    static func rtcMutationIdempotencyKey(_ action: String) -> String {
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return "ios-\(normalizedAction.isEmpty ? "rtc" : normalizedAction)-\(UUID().uuidString.lowercased())"
    }

    func postRTCSignalV2(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        envelope: RemoteRTCSignalEnvelope
    ) async throws -> RemoteRTCSignalPostResult {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("视频房间信息不完整")
        }
        let body: [String: Any] = [
            "protocol_version": envelope.protocolVersion,
            "message_id": envelope.messageID,
            "seq": envelope.seq,
            "negotiation_id": envelope.negotiationID,
            "call_id": envelope.callID,
            "to_uid": envelope.toUID,
            "to_device": envelope.toDevice,
            "kind": envelope.kind.rawValue,
            "data": envelope.data.mapValues(\.anyValue),
            "sent_at": envelope.sentAt
        ]
        return try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/signals",
            method: "POST",
            bearer: normalizedToken,
            body: body,
            preserveRTCSignalErrorDetails: true,
            bearerPurpose: .rtc
        )
    }

    func pollRTCSignalsV2(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        cursor: String,
        limit: Int,
        waitMS: Int
    ) async throws -> RemoteRTCSignalItemsData {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("视频房间信息不完整")
        }
        let normalizedWaitMS = RTCVideoSignalLongPollPolicy.normalizedWaitMS(waitMS)
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "wait_ms", value: String(normalizedWaitMS))
        ]
        return try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/signals?\(query.percentEncodedQuery ?? "")",
            bearer: normalizedToken,
            timeoutInterval: RTCVideoSignalLongPollPolicy.requestTimeout(waitMS: normalizedWaitMS),
            bearerPurpose: .rtc
        )
    }

    func ackRTCSignals(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        cursor: String
    ) async throws {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCursor = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty, !normalizedCursor.isEmpty else {
            throw IMAPIError.server("视频信令游标不完整")
        }
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/signals/ack",
            method: "POST",
            bearer: normalizedToken,
            body: ["cursor": normalizedCursor],
            bearerPurpose: .rtc
        )
    }

    func refreshRTCIceCredentials(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String
    ) async throws -> RemoteRTCIceCredentials {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty, !normalizedToken.isEmpty else {
            throw IMAPIError.server("视频房间信息不完整")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/ice-credentials",
            method: "POST",
            bearer: normalizedToken,
            body: [:],
            cachePolicy: .reloadIgnoringLocalCacheData,
            preserveRTCSignalErrorDetails: true,
            timeoutInterval: 3,
            bearerPurpose: .rtc
        )
    }

    func postRTCQualitySamples(
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        samples: [RTCQualitySample]
    ) async throws -> RemoteRTCQualityBatchResult {
        try requireIM(context)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoomID.isEmpty,
              !normalizedToken.isEmpty,
              RTCQualityTokenScope.hasWriteScope(normalizedToken),
              !samples.isEmpty,
              samples.count <= 30 else {
            throw IMAPIError.server("RTC 质量样本不满足上报条件")
        }
        let body: [String: Any] = [
            "schema_version": RTCQualitySample.schemaVersion,
            "samples": samples.map(\.requestBody)
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body),
              encoded.count <= 64 * 1_024 else {
            throw IMAPIError.server("RTC 质量样本批次过大")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/rooms/\(normalizedRoomID.urlPathEncoded)/quality-samples",
            method: "POST",
            bearer: normalizedToken,
            body: body,
            preserveRTCSignalErrorDetails: true,
            timeoutInterval: 1.5,
            bearerPurpose: .rtc
        )
    }

    func listRTCCallEvents(context: IMAPIContext) async throws -> [RemoteRTCCallEvent] {
        try requireIM(context)
        let data: RemoteRTCCallEventsData = try await request(base: tenantBase(for: context), path: "/api/rtc/calls/events", bearer: context.imToken)
        return data.events
    }

    func ackRTCCallEventNotifications(context: IMAPIContext, notificationIDs: [String]) async throws {
        let ids = Array(Set(notificationIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).prefix(64)
        guard !ids.isEmpty else { return }
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/rtc/calls/events/ack",
            method: "POST",
            bearer: context.imToken,
            body: ["notification_ids": Array(ids)]
        )
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
