import IM4Domain
import IM4Data // WDT_IOS1_HTTP_ROUTE_V5_20261113
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
struct IMOutgoingConfirmationRoute {
    let endpoint: URL
    let cursorAuthority: String
    let permit: LocalMessageConfirmationPermit
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

@MainActor
extension IMAPIClient {
    func syncConversations(context: IMAPIContext, version: Int64) async throws -> RemoteConversationSyncData {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let body: [String: Any] = try baseIMBody(context).merging(["version": version, "limit": 50]) { _, new in new }
        return try await request(base: imBase(for: context), path: "/api/im/conversations/sync", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func conversationPage(context: IMAPIContext, cursor: String) async throws -> RemoteConversationPage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["limit"] = 100
        if !cursor.isEmpty { body["cursor"] = cursor }
        return try await request(
            base: imBase(for: context), path: "/api/im/conversations/page", method: "POST",
            bearer: context.imToken, body: body, propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .singleSend,
            requestAuthority: requestAuthority
        )
    }

    func syncMessages(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, beforeSeq: Int64?, limit: Int = 50) async throws -> RemoteMessageSyncResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let body = try messageSyncBody(context: context, channelID: channelID, channelType: channelType,
                                       afterSeq: afterSeq, beforeSeq: beforeSeq, limit: limit)
        return try await request(base: imBase(for: context), path: "/api/im/sync", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private func messageSyncBody(context: IMAPIContext, channelID: String, channelType: String,
                                 afterSeq: Int64, beforeSeq: Int64?, limit: Int) throws -> [String: Any] {
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType
        body["after_seq"] = afterSeq
        if let beforeSeq, beforeSeq > 0 {
            body["before_seq"] = beforeSeq
        }
        body["limit"] = limit
        return body
    }

    func outgoingConfirmationRoute(context: IMAPIContext) -> IMOutgoingConfirmationRoute? {
        let permit = runtimeRouteStore.currentOutgoingConfirmationPermit()
        let usesV5 = runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue)
        guard routeV5StartupContext?.authSessionFence == context.authSessionFence,
              routeV5StartupContext?.imToken == context.imToken,
              !isTenantRuntimeRevoked(appID: context.appID, tenantID: context.tenantID) else { return nil }
        let base = imBase(for: context)
        guard let plan = runtimeRoutePlan(base: base, path: "/api/im/sync") else {
            return .init(endpoint: base, cursorAuthority: base.absoluteString, permit: permit)
        }
        let snapshot = plan.snapshot
        guard snapshot.appID == context.appID, snapshot.tenantID == context.tenantID else { return nil }
        var origin = plan.primary.compactMap(URL.init(string:)).first ?? base
        if usesV5, let route = snapshot.services[plan.service.rawValue] {
            let authorized = (route.preferred + route.backups).compactMap(URL.init(string:))
            if authorized.contains(where: {
                Self.sameOrigin($0, base) && ($0.path == base.path || ["", "/"].contains(base.path))
            }) {
                let scope = IMRouteV5Scope(appID: snapshot.appID,
                    environment: snapshot.environment ?? Self.configuredAppBootstrapEnvironment(),
                    tenantID: snapshot.tenantID, service: plan.service.rawValue)
                origin = httpRoutesV5.selected(in: scope, authorized: authorized) ?? base
            } else {
                origin = base
            }
        }
        return .init(endpoint: origin, cursorAuthority: snapshot.configHash + "|" + origin.absoluteString,
                     permit: permit)
    }

    func syncOutgoingConfirmationPage(context: IMAPIContext, channelID: String, channelType: String,
                                      beforeSeq: Int64, route: IMOutgoingConfirmationRoute) async throws -> RemoteMessageSyncResult {
        let body = try messageSyncBody(context: context, channelID: channelID, channelType: channelType,
                                       afterSeq: 0, beforeSeq: beforeSeq, limit: 50)
        let checkAuthority: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try route.permit.withCurrent {}
        }
        try checkAuthority()
        return try await IMRouteV5OpeningRead.$isActive.withValue(true) {
            try await requestOnce(base: route.endpoint, path: "/api/im/sync", method: "POST",
                                  bearer: context.imToken, body: body, requiredHTTPStatus: 200,
                                  propagateTaskCancellation: true, expectedResponseOrigin: route.endpoint,
                                  validateRTCRequest: checkAuthority, requestAuthority: context.authSessionFence,
                                  forcedAuthAuthorityBase: imBase(for: context))
        }
    }

    func scheduleOpeningConversationRouteRead(context: IMAPIContext, channelID: String,
                                              channelType: String, afterSeq: Int64) {
        guard !channelID.isEmpty, runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue),
              let snapshot = tenantRouteSnapshot, snapshot.appID == context.appID,
              let tenantID = snapshot.tenantID, tenantID == context.tenantID,
              let route = snapshot.services[IMRuntimeRouteService.imAPI.rawValue],
              httpRoutesV5.session?.authSessionFence == context.authSessionFence else { return }
        let base = imBase(for: context)
        let authorized = (route.preferred + route.backups).compactMap(URL.init(string:))
        guard authorized.contains(where: { Self.sameOrigin($0, base) && ($0.path == base.path || ["", "/"].contains(base.path)) }),
              authorized.contains(where: { !Self.sameOrigin($0, base) }) else { return }
        let scope = IMRouteV5Scope(appID: snapshot.appID,
            environment: snapshot.environment ?? Self.configuredAppBootstrapEnvironment(),
            tenantID: tenantID, service: IMRuntimeRouteService.imAPI.rawValue)
        httpRoutesV5.scheduleOpeningRead(scope: scope) { [weak self] in
            guard let self, self.runtimeRouteStore.routeV5Enabled(scope.service),
                  self.tenantRouteSnapshot == snapshot,
                  self.httpRoutesV5.session?.authSessionFence == context.authSessionFence else { return }
            await IMRouteV5OpeningRead.$isActive.withValue(true) {
                _ = try? await self.syncMessages(context: context, channelID: channelID,
                                                 channelType: channelType, afterSeq: afterSeq, limit: 1)
            }
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    func syncMessageReceipts(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, receiptType: String, limit: Int = 100) async throws -> RemoteMessageReceiptSyncResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType
        body["after_seq"] = afterSeq
        body["receipt_type"] = receiptType
        body["limit"] = limit
        return try await request(base: imBase(for: context), path: "/api/im/message-receipts/sync", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func syncMessageExtras(context: IMAPIContext, channelID: String, channelType: String, afterVersion: Int64 = 0, limit: Int = 100) async throws -> [RemoteMessageExtra] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType
        body["after_version"] = afterVersion
        body["limit"] = limit
        let data: RemoteList<RemoteMessageExtra> = try await request(base: imBase(for: context), path: "/api/im/message-extras/sync", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        return data.items
    }

    func groupPinnedMessages(context: IMAPIContext, groupID: String, limit: Int = 50) async throws -> [RemoteMessage] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var queryItems = try baseIMBody(context)
        queryItems["limit"] = limit
        let query = "?" + queryItems
            .map { "\($0.key.urlQueryEncoded)=\(String(describing: $0.value).urlQueryEncoded)" }
            .sorted()
            .joined(separator: "&")
        let data: RemotePinnedMessagesResponse = try await request(base: imBase(for: context), path: "/api/im/groups/\(groupID.urlPathEncoded)/pinned-messages\(query)", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func searchMessages(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, query: String, limit: Int = 50) async throws -> [RemoteMessageSearchResult] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["query"] = query
        body["limit"] = limit
        body["offset"] = 0
        let data: RemoteMessageSearchResponse = try await request(base: imBase(for: context), path: "/api/im/messages/search", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        return data.items
    }

    func updateConversationSettings(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["stick"] = conversation.isPinned
        body["mute"] = conversation.isMuted
        body["draft"] = ""
        let _: RemoteConversationSettingsResponse = try await request(base: imBase(for: context), path: "/api/im/conversations/settings", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    @discardableResult
    func readAck(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, throughSeq: Int64) async throws -> RemoteReadAckResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        if throughSeq > 0 {
            body["channel_seq"] = throughSeq
        } else if conversation.kind == .system {
            body["channel_seq"] = 0
        } else {
            return .empty
        }
        return try await request(base: imBase(for: context), path: "/api/im/read-ack", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func deliveryAck(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, channelSeq: Int64) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        guard channelSeq > 0 else { return }
        var body = try baseIMBody(context)
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["channel_seq"] = channelSeq
        let _: RemoteReadAckResponse = try await request(
            base: imBase(for: context),
            path: "/api/im/delivery-ack",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func messageReadReceipts(context: IMAPIContext, messageID: String) async throws -> RemoteMessageReadReceiptResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let query = "?tenant_id=\((context.tenantID ?? "").urlPathEncoded)&im_uid=\((context.imUID ?? "").urlPathEncoded)&device_id=\(context.deviceID.urlPathEncoded)&limit=100"
        return try await request(base: imBase(for: context), path: "/api/im/messages/\(messageID.urlPathEncoded)/read-receipts\(query)", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func appendReplyPayload(_ replyContext: MessageReplyContext?, to payload: inout [String: Any]) {
        guard let replyContext else { return }
        let messageID = replyContext.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = replyContext.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderName = replyContext.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderID = replyContext.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        var replyObject: [String: Any] = [
            "summary": summary.isEmpty ? (replyContext.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary,
            "preview": summary.isEmpty ? (replyContext.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary,
            "text": summary.isEmpty ? (replyContext.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary,
            "quote_text": summary.isEmpty ? (replyContext.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary,
            "quoted_text": summary.isEmpty ? (replyContext.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary,
            "content_type": replyContext.contentType,
            "type": replyContext.contentType,
            "sender_name": senderName,
            "sender_display_name": senderName,
            "display_name": senderName,
            "from_name": senderName,
            "sender_uid": senderID,
            "sender_id": senderID,
            "from_uid": senderID,
            "from_user_id": senderID,
            "unavailable": replyContext.isUnavailable
        ]
        if !messageID.isEmpty {
            replyObject["message_id"] = messageID
            replyObject["id"] = messageID
            payload["reply_to_message_id"] = messageID
        }
        if replyContext.channelSeq > 0 {
            replyObject["channel_seq"] = replyContext.channelSeq
        }
        if !replyContext.thumbnailURL.isEmpty {
            replyObject["thumbnail_url"] = replyContext.thumbnailURL
            replyObject["thumb_url"] = replyContext.thumbnailURL
        }
        payload["reply_to"] = replyObject
        payload["replyTo"] = replyObject
        payload["reply_message"] = replyObject
        payload["quoted_message"] = replyObject
    }

    func sendText(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, text: String, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String, mentionAll: Bool = false, mentionedUsers: [MentionIdentity] = []) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var payload: [String: Any] = ["text": text]
        if let quote, !quote.isEmpty {
            payload["quote"] = quote
        }
        appendReplyPayload(replyContext, to: &payload)
        var mentionPayloads = mentionedUsers.map { mention in
            [
                "type": "user",
                "im_uid": mention.imUID,
                "user_id": mention.userID,
                "username": mention.username,
                "display_text": mention.mentionToken,
                "notify": true
            ] as [String: Any]
        }
        if mentionAll {
            payload["mention_all"] = true
            mentionPayloads.insert([
                "type": "all",
                "target": "all",
                "display_text": "@所有人",
                "notify": true
            ], at: 0)
        }
        if !mentionPayloads.isEmpty {
            payload["mentions"] = mentionPayloads
        }
        let mentionUIDs = mentionedUsers.map(\.imUID).filter { !$0.isEmpty }
        if !mentionUIDs.isEmpty {
            payload["mention_uids"] = mentionUIDs
        }
        var body = try baseIMBody(context)
        body["from_uid"] = context.imUID
        body["app_id"] = context.appID
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["client_msg_no"] = clientMessageID
        body["content_type"] = "text"
        body["payload"] = payload
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        do {
            let data: RemoteSendResponse = try await request(
                base: imBase(for: context),
                path: "/api/im/messages",
                method: "POST",
                bearer: context.imToken,
                body: body,
                bearerPurpose: .messageSend,
                classifyUncertainMessageSendOutcome: true,
                requestAuthority: requestAuthority
            )
            guard AuthoritativeMessageSendPolicy.accepts(remoteMessageID: data.message.messageID) else {
                throw MessageSendOutcomeUncertainError()
            }
            return data.message
        } catch let uncertain as MessageSendOutcomeUncertainError
            where uncertain.requiresReadback || runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue) {
            if IMDurableOutgoingSend.current == nil, let confirmed = try? await reconcileUncertainTextSend(
                context: context, channelID: channelID, channelType: channelType(conversation.kind),
                clientMessageID: clientMessageID
            ) {
                return confirmed
            }
            throw uncertain
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    }

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private func reconcileUncertainTextSend(
        context: IMAPIContext, channelID: String, channelType: String, clientMessageID: String
    ) async throws -> RemoteMessage? {
        let authority = context.authSessionFence
        try Task.checkCancellation()
        guard httpRoutesV5.session?.authSessionFence == authority, let sender = context.imUID else {
            throw CancellationError()
        }
        let page = try? await syncMessages(context: context, channelID: channelID, channelType: channelType,
                                          afterSeq: 0, beforeSeq: Int64.max, limit: 10)
        try Task.checkCancellation()
        guard httpRoutesV5.session?.authSessionFence == authority else { throw CancellationError() }
        return page?.items.first {
            $0.clientMsgNo == clientMessageID && $0.fromUID == sender && $0.channelID == channelID
                && $0.channelType == channelType && $0.channelSeq > 0
                && AuthoritativeMessageSendPolicy.accepts(remoteMessageID: $0.messageID)
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    func appendUploadedFilePayload(_ file: RemoteAvatarFile, to payload: inout [String: Any]) {
        let stringFields: [(String, String)] = [
            ("file_name", file.fileName),
            ("mime_type", file.mimeType),
            ("status", file.status),
            ("attachment_status", file.status),
            ("upload_status", file.uploadStatus),
            ("preview_url", file.previewURL),
            ("download_url", file.downloadURL),
            ("download_endpoint", file.downloadEndpoint),
            ("detail_endpoint", file.detailEndpoint),
            ("cache_key", file.cacheKey),
            ("version", file.version),
            ("checksum", file.checksum),
            ("media_category", file.mediaCategory),
            ("extension", file.fileExtension),
            ("thumbnail_url", file.thumbnailURL),
            ("poster_url", file.posterURL),
            ("cover_url", file.coverURL),
            ("preview_kind", file.previewKind),
            ("content_disposition", file.contentDisposition)
        ]
        for (key, value) in stringFields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload[key] = trimmed
            }
        }
        if file.previewAvailable {
            payload["preview_available"] = true
        }
        if file.downloadAvailable {
            payload["download_available"] = true
        }
        if let width = file.width, width > 0 {
            payload["width"] = width
        }
        if let height = file.height, height > 0 {
            payload["height"] = height
        }
        if let durationSeconds = file.durationSeconds, durationSeconds > 0 {
            payload["duration_seconds"] = durationSeconds
        }
    }

    func sendAttachment(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, kind: MessageKind, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let mediaCategory = IMAPIClient.inferredMediaCategory(kind: kind, fileName: name, mimeType: mimeType)
        let fileExtension = (name as NSString).pathExtension.lowercased()
        var payload: [String: Any] = [
            "file_name": name,
            "mime_type": mimeType.isEmpty ? (kind == .image ? "image/jpeg" : "application/octet-stream") : mimeType,
            "media_category": mediaCategory,
            "kind": mediaCategory,
            "preview_kind": IMAPIClient.previewKind(forMediaCategory: mediaCategory),
            "attachment_status": "uploaded",
            "upload_status": "uploaded"
        ]
        if !fileExtension.isEmpty {
            payload["extension"] = fileExtension
        }
        if !file.id.isEmpty {
            payload["file_id"] = file.id
            payload["attachment_id"] = file.id
            payload["media_id"] = file.id
        }
        let effectiveSizeBytes = Int64(file.sizeBytes > 0 ? file.sizeBytes : Int(sizeBytes ?? 0))
        if effectiveSizeBytes > 0 {
            payload["size_bytes"] = effectiveSizeBytes
        }
        appendUploadedFilePayload(file, to: &payload)
        if payload["download_endpoint"] == nil, !file.id.isEmpty {
            payload["download_endpoint"] = "/api/tenant/files/\(file.id)/presign-download"
        }
        if payload["detail_endpoint"] == nil, !file.id.isEmpty {
            payload["detail_endpoint"] = "/api/tenant/files/\(file.id)"
        }
        if let quote, !quote.isEmpty {
            payload["quote"] = quote
        }
        appendReplyPayload(replyContext, to: &payload)
        var body = try baseIMBody(context)
        body["from_uid"] = context.imUID
        body["app_id"] = context.appID
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["client_msg_no"] = clientMessageID
        body["client_msg_id"] = clientMessageID
        body["local_id"] = clientMessageID
        body["content_type"] = kind == .image ? "image" : "file"
        body["payload"] = payload
        let data: RemoteSendResponse = try await request(base: imBase(for: context), path: "/api/im/messages", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        return data.message
    }

    func sendVoice(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, durationMS: Int, waveform: [Int], quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "voice-\(clientMessageID).m4a" : name
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "audio/mp4" : mimeType
        let fileExtension = (normalizedName as NSString).pathExtension.lowercased()
        let effectiveSizeBytes = Int64(file.sizeBytes > 0 ? file.sizeBytes : Int(sizeBytes ?? 0))
        let normalizedDurationMS = VoiceMessagePayload.normalizedDurationMS(durationMS)
        let durationSeconds = VoiceMessagePayload.durationSeconds(from: normalizedDurationMS)
        var payload: [String: Any] = [:]
        appendUploadedFilePayload(file, to: &payload)
        payload["file_name"] = normalizedName
        payload["mime_type"] = normalizedMimeType
        payload["media_category"] = "voice"
        payload["kind"] = "voice"
        payload["preview_kind"] = "voice"
        payload["text"] = VoiceMessagePayload.fallbackText
        payload["fallback_text"] = VoiceMessagePayload.fallbackText
        payload["attachment_status"] = "uploaded"
        payload["upload_status"] = "uploaded"
        payload["duration_ms"] = normalizedDurationMS
        payload["duration_seconds"] = durationSeconds
        payload["waveform"] = VoiceMessagePayload.normalizedWaveform(waveform)
        if !fileExtension.isEmpty {
            payload["extension"] = fileExtension
        }
        if !file.id.isEmpty {
            payload["file_id"] = file.id
            payload["attachment_id"] = file.id
            payload["media_id"] = file.id
        }
        if effectiveSizeBytes > 0 {
            payload["size_bytes"] = effectiveSizeBytes
        }
        if payload["download_endpoint"] == nil, !file.id.isEmpty {
            payload["download_endpoint"] = "/api/tenant/files/\(file.id)/presign-download"
        }
        if payload["detail_endpoint"] == nil, !file.id.isEmpty {
            payload["detail_endpoint"] = "/api/tenant/files/\(file.id)"
        }
        if let quote, !quote.isEmpty {
            payload["quote"] = quote
        }
        appendReplyPayload(replyContext, to: &payload)
        var body = try baseIMBody(context)
        body["from_uid"] = context.imUID
        body["app_id"] = context.appID
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["client_msg_no"] = clientMessageID
        body["client_msg_id"] = clientMessageID
        body["local_id"] = clientMessageID
        body["content_type"] = "voice"
        body["payload"] = payload
        let data: RemoteSendResponse = try await request(base: imBase(for: context), path: "/api/im/messages", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        return data.message
    }

    func sendSticker(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, sticker: StickerMessageSnapshot, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var payload = sticker.messageSendDictionary
        if let quote, !quote.isEmpty {
            payload["quote"] = quote
        }
        appendReplyPayload(replyContext, to: &payload)
        var body = try baseIMBody(context)
        body["from_uid"] = context.imUID
        body["app_id"] = context.appID
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["client_msg_no"] = clientMessageID
        body["client_msg_id"] = clientMessageID
        body["local_id"] = clientMessageID
        body["content_type"] = "sticker"
        body["payload"] = payload
        let data: RemoteSendResponse = try await request(base: imBase(for: context), path: "/api/im/messages", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        return data.message
    }

    func sendContactCard(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, contactID: String, contactName: String, contactAvatar: String?, quote: String?, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let normalizedContactID = contactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContactID.isEmpty else {
            throw IMAPIError.forbidden("该联系人缺少用户ID，暂不能发送名片")
        }
        let normalizedContactName = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedContactName.isEmpty ? normalizedContactID : normalizedContactName
        var payload: [String: Any] = [
            "contact_uid": normalizedContactID,
            "im_uid": normalizedContactID,
            "user_id": normalizedContactID,
            "contact_user_id": normalizedContactID,
            "target_uid": normalizedContactID,
            "contact_name": displayName,
            "text": "个人名片：\(displayName)"
        ]
        if let contactAvatar = contactAvatar?.trimmingCharacters(in: .whitespacesAndNewlines), !contactAvatar.isEmpty {
            payload["contact_avatar"] = contactAvatar
        }
        if let quote, !quote.isEmpty {
            payload["quote"] = quote
        }
        var body = try baseIMBody(context)
        body["from_uid"] = context.imUID
        body["app_id"] = context.appID
        body["channel_id"] = channelID
        body["channel_type"] = channelType(conversation.kind)
        body["client_msg_no"] = clientMessageID
        body["content_type"] = "contact_card"
        body["payload"] = payload
        let data: RemoteSendResponse = try await request(
            base: imBase(for: context),
            path: "/api/im/messages",
            method: "POST",
            bearer: context.imToken,
            body: body,
            bearerPurpose: .messageSend,
            classifyUncertainMessageSendOutcome: true,
            requestAuthority: requestAuthority
        )
        guard !data.message.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageSendOutcomeUncertainError()
        }
        return data.message
    }

	func editMessage(context: IMAPIContext, messageID: String, text: String, clientEditID: String, expectedEditRevision: Int64) async throws -> RemoteExtraResponse {
	    // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
	    let requestAuthority = context.authSessionFence
	    // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try actionBody(context)
        body["content_type"] = "text"
        body["payload"] = ["text": text]
		body["client_edit_id"] = clientEditID
		body["expected_edit_revision"] = expectedEditRevision
		return try await request(
			base: imBase(for: context),
			path: "/api/im/messages/\(messageID.urlPathEncoded)/edit",
			method: "POST",
			bearer: context.imToken,
			body: body,
			additionalHeaders: ["Idempotency-Key": clientEditID],
			preserveHTTPStatusErrors: true,
			runtimeRouteReplayPolicy: .singleSend,
		    requestAuthority: requestAuthority
		)
    }

    func recallMessage(context: IMAPIContext, messageID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: RemoteExtraResponse = try await request(base: imBase(for: context), path: "/api/im/messages/\(messageID.urlPathEncoded)/recall", method: "POST", bearer: context.imToken, body: try actionBody(context), requestAuthority: requestAuthority)
    }

    func deleteMessage(context: IMAPIContext, messageID: String) async throws -> RemoteExtraResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        return try await request(
            base: imBase(for: context),
            path: "/api/im/messages/\(messageID.urlPathEncoded)/delete",
            method: "POST",
            bearer: context.imToken,
            body: try baseIMBody(context),
            runtimeRouteReplayPolicy: .singleSend,
            requestAuthority: requestAuthority
        )
    }

    func adminDeleteGroupMessage(context: IMAPIContext, groupID: String, messageID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: imBase(for: context),
            path: "/api/im/groups/\(groupID.urlPathEncoded)/messages/\(messageID.urlPathEncoded)/admin-delete",
            method: "POST",
            bearer: context.imToken,
            body: try actionBody(context),
            requestAuthority: requestAuthority
        )
    }

    func reactMessage(context: IMAPIContext, messageID: String, emoji: String, action: String) async throws -> RemoteExtraResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try actionBody(context)
        body["emoji"] = emoji
        body["action"] = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "remove" ? "remove" : "add"
        return try await request(base: imBase(for: context), path: "/api/im/messages/\(messageID.urlPathEncoded)/reaction", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func pinMessage(context: IMAPIContext, messageID: String, pinned: Bool) async throws -> RemoteExtraResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try actionBody(context)
        body["pinned"] = pinned
        return try await request(base: imBase(for: context), path: "/api/im/messages/\(messageID.urlPathEncoded)/pin", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func favoriteMessage(context: IMAPIContext, messageID: String, favorited: Bool) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try actionBody(context)
        body["favorited"] = favorited
        let _: RemoteExtraResponse = try await request(base: imBase(for: context), path: "/api/im/messages/\(messageID.urlPathEncoded)/favorite", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func forwardMessage(context: IMAPIContext, messageID: String, targetChannelID: String, targetChannelType: String, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body = try baseIMBody(context)
        body["target_channel_id"] = targetChannelID
        body["target_channel_type"] = targetChannelType
        body["client_msg_id"] = clientMessageID
        body["channel_id"] = targetChannelID
        body["channel_type"] = targetChannelType
        body["client_msg_no"] = clientMessageID
        let data: RemoteForwardMessageResponse = try await request(
            base: imBase(for: context),
            path: "/api/im/messages/\(messageID.urlPathEncoded)/forward",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
        return data.message
    }

    func forwardBatch(
        context: IMAPIContext,
        command: BatchForwardSubmitCommand
    ) async throws -> BatchForwardCommittedResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let requestBody = command.request
        let body: [String: Any] = [
            "client_batch_id": requestBody.clientBatchID,
            "source_channel_id": requestBody.sourceChannelID,
            "source_channel_type": requestBody.sourceChannelType,
            "source_message_ids": requestBody.sourceMessageIDs,
            "targets": requestBody.targets.map {
                [
                    "channel_id": $0.channelID,
                    "channel_type": $0.channelType
                ]
            },
            "mode": requestBody.mode.rawValue
        ]
        return try await request(
            base: imBase(for: context),
            path: "/api/im/messages/forward-batch",
            method: "POST",
            bearer: context.imToken,
            body: body,
            additionalHeaders: command.headers,
            propagateTaskCancellation: true,
            requestAuthority: requestAuthority
        )
    }

    func lookupMessageReport(context: IMAPIContext, messageID: String) async throws -> RemoteMessageReportLookupResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else {
            throw IMAPIError.missingContext("message_id")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/message-reports/lookup?message_id=\(normalizedMessageID.urlQueryEncoded)",
            bearer: context.imToken,
            requestAuthority: requestAuthority
        )
    }

    func reportMessage(context: IMAPIContext, messageID: String, channelID: String, channelType: String, reason: String, description: String) async throws -> RemoteMessageReport {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let body: [String: Any] = [
            "message_id": messageID.trimmingCharacters(in: .whitespacesAndNewlines),
            "channel_id": channelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "channel_type": channelType.trimmingCharacters(in: .whitespacesAndNewlines),
            "reason": reason.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": description.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return try await request(base: tenantBase(for: context), path: "/api/tenant/message-reports", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
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
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
