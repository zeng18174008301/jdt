import IM4Domain
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import CryptoKit
import ImageIO

struct VideoAttachmentObjectMissing: Error {
    let retryAfterSeconds: Int
}

@MainActor
final class VideoAttachmentHTTPObservation {
    @TaskLocal static var current: VideoAttachmentHTTPObservation?
    var status: Int?
    var retryAfter = 0
}

private struct VideoAttachmentVerification: Decodable {
    let fileID: String
    let appID: String
    let channelID: String
    let channelType: String
    let clientMessageID: String
    let verified: Bool
    let completionState: String
    let checksum: String
    let retryAfter: Int?
    let verificationError: String?
    let file: RemoteAvatarFile

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id", appID = "app_id", channelID = "channel_id", channelType = "channel_type"
        case clientMessageID = "client_msg_no", verified, completionState = "completion_state"
        case checksum = "checksum_sha256", retryAfter = "retry_after_seconds"
        case verificationError = "verification_error_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try c.decode(String.self, forKey: .fileID)
        appID = try c.decode(String.self, forKey: .appID)
        channelID = try c.decode(String.self, forKey: .channelID)
        channelType = try c.decode(String.self, forKey: .channelType)
        clientMessageID = try c.decode(String.self, forKey: .clientMessageID)
        verified = try c.decode(Bool.self, forKey: .verified)
        completionState = try c.decode(String.self, forKey: .completionState)
        checksum = try c.decode(String.self, forKey: .checksum)
        retryAfter = try c.decodeIfPresent(Int.self, forKey: .retryAfter)
        verificationError = try c.decodeIfPresent(String.self, forKey: .verificationError)
        file = try RemoteAvatarFile(from: decoder)
    }
}

@MainActor
extension IMAPIClient {
    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REQUEST_HELPER - 修改开始：公共媒体文件接口使用匿名 REST 请求，保留本地 IM 上下文用于租户路由
    private func publicMediaRequest<T: Decodable>(
        context: IMAPIContext,
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        additionalHeaders: [String: String] = [:],
        requiredHTTPStatus: Int? = nil,
        propagateTaskCancellation: Bool = false,
        coalescingScope: String? = nil
    ) async throws -> T {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: path,
            method: method,
            bearer: nil,
            body: body,
            additionalHeaders: additionalHeaders,
            cachePolicy: cachePolicy,
            requiredHTTPStatus: requiredHTTPStatus,
            bearerPurpose: .publicMedia,
            propagateTaskCancellation: propagateTaskCancellation,
            coalescingScope: coalescingScope,
            requestAuthority: requestAuthority
        )
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REQUEST_HELPER - 修改结束
    func commitAvatar(context: IMAPIContext, fileID: String) async throws -> RemoteAvatarCommitData {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/avatar",
            method: "PATCH",
            bearer: context.imToken,
			body: ["file_id": fileID],
			preserveHTTPStatusErrors: true,
            requestAuthority: requestAuthority
        )
    }

    func presignFileUpload(context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, clientMessageID: String, purpose: String, fileName: String, mimeType: String, sizeBytes: Int) async throws -> RemoteAvatarUploadData {
        try await presignFileUpload(
            context: context, conversation: conversation, channelID: channelID, clientMessageID: clientMessageID,
            purpose: purpose, fileName: fileName, mimeType: mimeType, sizeBytes: sizeBytes, routing: nil
        )
    }

    enum VideoUploadTransport: String {
        case auto, standard
    }

    func presignVideoAttachmentUpload(
        context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, clientMessageID: String,
        fileName: String, mimeType: String, sizeBytes: Int, checksum: String,
        transport: VideoUploadTransport, expectedFileID: String
    ) async throws -> RemoteAvatarUploadData {
        guard !MediaFileIntegrityAuthority.normalizedSHA256(checksum).isEmpty,
              transport != .standard || !expectedFileID.isEmpty else {
            throw IMAPIError.server("video_upload_identity_unavailable")
        }
        let response = try await presignFileUpload(
            context: context, conversation: conversation, channelID: channelID, clientMessageID: clientMessageID,
            purpose: "message_attachment", fileName: fileName, mimeType: mimeType, sizeBytes: sizeBytes,
            routing: (checksum, transport, expectedFileID)
        )
        guard !response.file.id.isEmpty, response.file.id == response.file.id.trimmingCharacters(in: .whitespacesAndNewlines),
              expectedFileID.isEmpty || response.file.id == expectedFileID,
              response.file.sizeBytes == 0 || response.file.sizeBytes == sizeBytes,
              response.file.mimeType.isEmpty || response.file.mimeType.caseInsensitiveCompare(mimeType) == .orderedSame,
              response.file.checksum.isEmpty || response.file.checksum.lowercased() == checksum else {
            throw IMAPIError.server("video_upload_identity_mismatch")
        }
        return response
    }

    private func presignFileUpload(
        context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, clientMessageID: String,
        purpose: String, fileName: String, mimeType: String, sizeBytes: Int,
        routing: (checksum: String, transport: VideoUploadTransport, expectedFileID: String)?
    ) async throws -> RemoteAvatarUploadData {
        try requireIM(context)
        let normalizedChannelType = channelType(conversation.kind)
        let normalizedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientMessageID = clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata: [String: Any] = [:]
        if !normalizedPurpose.isEmpty {
            metadata["purpose"] = normalizedPurpose
        }
        if !normalizedClientMessageID.isEmpty {
            metadata["message_id"] = normalizedClientMessageID
        }
        if normalizedPurpose == "message_attachment", conversation.kind == .group {
            metadata["group_id"] = channelID
        }
        var body: [String: Any] = [
            "app_id": context.appID,
            "channel_id": channelID,
            "channel_type": normalizedChannelType,
            "file_name": fileName,
            "mime_type": mimeType.isEmpty ? "application/octet-stream" : mimeType,
            "size_bytes": sizeBytes
        ]
        if !normalizedPurpose.isEmpty {
            body["purpose"] = normalizedPurpose
        }
        if !normalizedClientMessageID.isEmpty {
            body["client_msg_no"] = normalizedClientMessageID
        }
        if !metadata.isEmpty {
            body["metadata"] = metadata
        }
        if let routing {
            body["checksum"] = routing.checksum
            body["upload_transport"] = routing.transport.rawValue
            if !routing.expectedFileID.isEmpty {
                body["expected_file_id"] = routing.expectedFileID
            }
            if conversation.kind == .group {
                body["group_id"] = channelID
            }
        }
        return try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/presign-upload",
            method: "POST",
            body: body,
            propagateTaskCancellation: routing != nil
        )
    }

    func presignVoiceMessageUpload(
        context: IMAPIContext,
        conversation: ConversationMessageSnapshot,
        channelID: String,
        clientMessageID: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        durationMS: Int,
        waveform: [Int]
    ) async throws -> RemoteAvatarUploadData {
        try requireIM(context)
        return try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/presign-upload",
            method: "POST",
            body: voiceMessageUploadBody(
                context: context,
                conversation: conversation,
                channelID: channelID,
                clientMessageID: clientMessageID,
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                durationMS: durationMS,
                waveform: waveform
            )
        )
    }

    func fileUploadConfig(context: IMAPIContext) async throws -> RemoteFileUploadConfig {
        try await publicMediaRequest(context: context, path: "/api/tenant/files/config")
    }

    func uploadFileBinary(upload: RemoteSignedUpload, data: Data, mimeType: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await uploadBinary(upload: upload, data: data, mimeType: mimeType, failureMessage: "文件上传失败", progress: progress)
    }

    func uploadFileBinary(upload: RemoteSignedUpload, fileURL: URL, mimeType: String, sizeBytes: Int64, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await uploadBinary(
            upload: upload,
            fileURL: fileURL,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            failureMessage: "文件上传失败",
            progress: progress
        )
    }

    func uploadVideoAttachmentBinary(
        context: IMAPIContext, upload: RemoteSignedUpload, fileURL: URL, mimeType: String, sizeBytes: Int64,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try await uploadBinary(
            upload: upload, fileURL: fileURL, mimeType: mimeType, sizeBytes: sizeBytes, failureMessage: "视频上传失败",
            progress: progress, signedVideoBase: tenantBase(for: context)
        )
    }

    func markFileUploaded(context: IMAPIContext, fileID: String) async throws -> RemoteAvatarFile {
        let data: RemoteUploadedFileResponse = try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/uploaded",
            method: "POST",
            body: [:]
        )
        return data.file
    }

    func markMessageFileUploaded(
        context: IMAPIContext,
        fileID: String,
        conversation: ConversationMessageSnapshot,
        channelID: String,
        clientMessageID: String
    ) async throws -> RemoteAvatarFile {
        try requireIM(context)
        let data: RemoteUploadedFileResponse = try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/uploaded",
            method: "POST",
            body: messageAttachmentCompletionBody(conversation: conversation, channelID: channelID, clientMessageID: clientMessageID)
        )
        return data.file
    }

    private func messageAttachmentCompletionBody(
        conversation: ConversationMessageSnapshot, channelID: String, clientMessageID: String
    ) -> [String: Any] {
        var body: [String: Any] = [
            "purpose": "message_attachment",
            "channel_id": channelID,
            "channel_type": channelType(conversation.kind),
            "client_msg_no": clientMessageID,
            "metadata": [
                "purpose": "message_attachment",
                "message_id": clientMessageID
            ]
        ]
        if conversation.kind == .group {
            body["group_id"] = channelID
        }
        return body
    }

    func confirmRoutedVideoAttachmentUpload(
        context: IMAPIContext, conversation: ConversationMessageSnapshot, channelID: String, clientMessageID: String,
        fileID: String, sizeBytes: Int64, mimeType: String, checksum: String, preparedFile: RemoteAvatarFile?,
        verificationSelected: Bool = false,
        onVerificationSelected: @MainActor () async throws -> Void = {}
    ) async throws -> RemoteAvatarFile {
        let path = "/api/tenant/files/\(fileID.urlPathEncoded)"
        let invalidResponse = IMAPIError.server("video_upload_verification_invalid")
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        var supportsVerification = verificationSelected
        var nextPoll = 2
        func wait(_ seconds: Int) async throws {
            guard ProcessInfo.processInfo.systemUptime + Double(seconds) < deadline else {
                throw IMAPIError.server("video_upload_verification_timeout")
            }
            if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let status: VideoAttachmentVerification
            let response = VideoAttachmentHTTPObservation()
            do {
                status = try await VideoAttachmentHTTPObservation.$current.withValue(response) {
                    try await publicMediaRequest(
                        context: context, path: path + "/upload-status", cachePolicy: .reloadIgnoringLocalCacheData,
                        requiredHTTPStatus: 200, propagateTaskCancellation: true
                    )
                }
            } catch IMAPIError.httpStatus(let code, _) where !supportsVerification && (code == 404 || code == 405) {
                try await wait(response.retryAfter)
                let legacyResponse = VideoAttachmentHTTPObservation()
                let file: RemoteAvatarFile = try await VideoAttachmentHTTPObservation.$current.withValue(legacyResponse) {
                    let result: RemoteUploadedFileResponse = try await publicMediaRequest(
                        context: context, path: path + "/uploaded", method: "POST",
                        body: messageAttachmentCompletionBody(conversation: conversation, channelID: channelID, clientMessageID: clientMessageID),
                        propagateTaskCancellation: true
                    )
                    return result.file
                }
                guard legacyResponse.status == 200, file.id == fileID,
                      file.status == "uploaded", file.uploadStatus == "uploaded",
                      file.sizeBytes == 0 || Int64(file.sizeBytes) == sizeBytes,
                      file.mimeType.isEmpty || file.mimeType.caseInsensitiveCompare(mimeType) == .orderedSame,
                      file.checksum.isEmpty || file.checksum.lowercased() == checksum else {
                    throw invalidResponse
                }
                return file
            }
            let file = status.file
            guard status.fileID == fileID, file.id == fileID, status.appID == context.appID,
                  status.channelID == channelID, status.channelType == channelType(conversation.kind),
                  status.clientMessageID == clientMessageID, Int64(file.sizeBytes) == sizeBytes,
                  file.mimeType.caseInsensitiveCompare(mimeType) == .orderedSame,
                  file.uploadStatus == file.status, (status.retryAfter ?? 0) >= 0 else {
                throw invalidResponse
            }
            if !supportsVerification {
                try await onVerificationSelected()
                supportsVerification = true
            }
            if status.verified {
                guard status.completionState == "uploaded", file.status == "uploaded",
                      status.checksum.lowercased() == checksum, file.checksum.lowercased() == checksum,
                      (status.verificationError ?? "").isEmpty else {
                    throw invalidResponse
                }
                return preparedFile.map { file.merged(with: $0) } ?? file
            }
            guard status.checksum.isEmpty, (status.verificationError ?? "").isEmpty else {
                throw invalidResponse
            }
            switch (status.completionState, file.status) {
            case ("prepared", "prepared"), ("verification_required", "uploaded"):
                try await wait(max(response.retryAfter, status.retryAfter ?? 0))
                let completionResponse = VideoAttachmentHTTPObservation()
                let accepted: RemoteUploadedFileResponse = try await VideoAttachmentHTTPObservation.$current.withValue(completionResponse) {
                    try await publicMediaRequest(
                        context: context, path: path + "/uploaded", method: "POST",
                        body: messageAttachmentCompletionBody(conversation: conversation, channelID: channelID, clientMessageID: clientMessageID),
                        additionalHeaders: ["Prefer": "respond-async"], propagateTaskCancellation: true
                    )
                }
                guard completionResponse.status == 200 || completionResponse.status == 202,
                      accepted.file.id == fileID else { throw invalidResponse }
                // Even a successful completion POST isn't proof of verification.
                try await wait(max(nextPoll, completionResponse.retryAfter))
            case ("verifying", "prepared"), ("verifying", "uploaded"):
                try await wait(max(status.retryAfter ?? 0, nextPoll, response.retryAfter))
            default:
                throw invalidResponse
            }
            nextPoll = min(10, nextPoll * 2)
        }
        throw IMAPIError.server("video_upload_verification_timeout")
    }

    func markVoiceMessageUploaded(
        context: IMAPIContext,
        fileID: String,
        conversation: ConversationMessageSnapshot,
        channelID: String,
        clientMessageID: String
    ) async throws -> RemoteAvatarFile {
        try requireIM(context)
        let normalizedChannelType = channelType(conversation.kind)
        var body: [String: Any] = [
            "purpose": "message_attachment",
            "channel_id": channelID,
            "channel_type": normalizedChannelType,
            "client_msg_no": clientMessageID,
            "metadata": [
                "purpose": "message_attachment",
                "message_id": clientMessageID
            ]
        ]
        if conversation.kind == .group {
            body["group_id"] = channelID
        }
        let data: RemoteUploadedFileResponse = try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/uploaded",
            method: "POST",
            body: body
        )
        return data.file
    }

    func voiceMessageUploadBody(
        context: IMAPIContext,
        conversation: ConversationMessageSnapshot,
        channelID: String,
        clientMessageID: String,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        durationMS: Int,
        waveform: [Int]
    ) -> [String: Any] {
        let normalizedDurationMS = VoiceMessagePayload.normalizedDurationMS(durationMS)
        let durationSeconds = VoiceMessagePayload.durationSeconds(from: normalizedDurationMS)
        let normalizedWaveform = VoiceMessagePayload.normalizedWaveform(waveform)
        let normalizedChannelType = channelType(conversation.kind)
        var body: [String: Any] = [
            "app_id": context.appID,
            "purpose": "message_attachment",
            "channel_id": channelID,
            "channel_type": normalizedChannelType,
            "client_msg_no": clientMessageID,
            "file_name": fileName,
            "mime_type": mimeType,
            "size_bytes": sizeBytes,
            "media_category": "voice",
            "kind": "voice",
            "fallback_text": VoiceMessagePayload.fallbackText,
            "duration_ms": normalizedDurationMS,
            "duration_seconds": durationSeconds,
            "waveform": normalizedWaveform,
            "metadata": ["purpose": "message_attachment"]
        ]
        if conversation.kind == .group {
            body["group_id"] = channelID
        }
        return body
    }

    func listGroupFiles(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupFile] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteGroupFile> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/files", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func listTenantFiles(context: IMAPIContext, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0) async throws -> [RemoteGroupFile] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var queryItems = [
            "limit=\(min(max(limit, 1), 100))",
            "offset=\(max(offset, 0))"
        ]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append("q=\(trimmedQuery.urlQueryEncoded)")
        }
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCategory.isEmpty {
            queryItems.append("category=\(trimmedCategory.urlQueryEncoded)")
        }
        let data: RemoteList<RemoteGroupFile> = try await request(base: tenantBase(for: context), path: "/api/tenant/files?\(queryItems.joined(separator: "&"))", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func listFavoriteAssets(context: IMAPIContext, category: String = "all", limit: Int = 30, cursor: String = "") async throws -> RemoteFavoriteAssetsResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "limit": min(max(limit, 1), 100),
            "category": trimmedCategory.isEmpty ? "all" : trimmedCategory
        ]
        let trimmedCursor = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCursor.isEmpty {
            body["cursor"] = trimmedCursor
        } else {
            body["cursor"] = ""
        }
        return try await request(
            base: imBase(for: context),
            path: "/api/im/favorites/list",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func getTenantFile(context: IMAPIContext, fileID: String) async throws -> RemoteUserFileDetail {
        try await getTenantFile(context: context, fileID: fileID, coalescingScope: nil)
    }

    func getTenantFile(context: IMAPIContext, fileID: String, coalescingScope: String?) async throws -> RemoteUserFileDetail {
        try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)",
            cachePolicy: .reloadIgnoringLocalCacheData,
            coalescingScope: coalescingScope
        )
    }

    func serverVideoPosterStatus(context: IMAPIContext, fileID: String, timeout: TimeInterval = 15) async throws -> IOSServerVideoPosterStatus {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        return try await request(base: tenantBase(for: context), path: "/api/tenant/files/\(fileID.urlPathEncoded)/poster-status",
            additionalHeaders: ["Cache-Control": "no-cache"], cachePolicy: .reloadIgnoringLocalCacheData,
            preserveHTTPStatusErrors: true, timeoutInterval: timeout, bearerPurpose: .publicMedia,
            propagateTaskCancellation: true, runtimeRouteReplayPolicy: .singleSend,
                requestAuthority: requestAuthority)
    }

    func serverVideoPosterBytes(context: IMAPIContext, status: IOSServerVideoPosterStatus, timeout: TimeInterval = 15) async throws -> Data {
        let base = tenantBase(for: context)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        components.path = "/api/tenant/files/\(status.fileID)/poster"
        components.queryItems = [URLQueryItem(name: "v", value: status.version)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let response = try await httpTransport.data(for: request, rejectingCrossOriginRedirectsFrom: url)
        if let final = response.responseURL,
           final.scheme != url.scheme || final.host != url.host || final.port != url.port { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw IOSServerVideoPosterError.http(response.statusCode ?? 0, error?["code"] as? String,
                response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() == "image/jpeg" else {
            throw IOSServerVideoPosterError.invalidBytes
        }
        try await Task.detached(priority: .utility) { try Self.validateVideoPosterBytes(response.data, status: status) }.value
        return response.data
    }

    func presignTenantFileDownloadURL(context: IMAPIContext, fileID: String) async throws -> String {
        let result: RemoteAttachmentDownloadAddress = try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/presign-download",
            method: "POST",
            body: [:]
        )
        guard let url = result.value else { throw IMAPIError.server("文件下载地址暂不可用") }
        return url
    }

    func presignTenantFileDownload(context: IMAPIContext, fileID: String) async throws -> RemoteUserFileDetail {
        try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/presign-download",
            method: "POST",
            body: [:]
        )
    }

    func forwardTenantFile(context: IMAPIContext, fileID: String, targetChannelID: String, targetChannelType: String, clientMessageID: String) async throws -> RemoteMessage {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let response: RemoteTenantFileForwardResponse = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/files/\(fileID.urlPathEncoded)/forward",
            method: "POST",
            bearer: context.imToken,
            body: [
                "app_id": IMAPIContext.normalizedIOSAppID(context.appID),
                "device_id": context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                "target_channel_id": targetChannelID.trimmingCharacters(in: .whitespacesAndNewlines),
                "target_channel_type": targetChannelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                "client_msg_id": clientMessageID
            ],
            requestAuthority: requestAuthority
        )
        return response.message
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

// The presign response may contain only a URL, without the file-detail object.
struct RemoteAttachmentDownloadAddress: Decodable {
    let value: String?

    private enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url", signedURL = "signed_url"
        case downloadPublic = "download_public", download, url, previewURL = "preview_url"
    }
    private struct NestedDownload: Decodable { let url: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try [
            c.decodeIfPresent(String.self, forKey: .downloadURL),
            c.decodeIfPresent(String.self, forKey: .signedURL),
            c.decodeIfPresent(NestedDownload.self, forKey: .download)?.url,
            c.decodeIfPresent(String.self, forKey: .url),
            c.decodeIfPresent(String.self, forKey: .downloadPublic),
            c.decodeIfPresent(String.self, forKey: .previewURL)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

extension IMAPIClient {
    nonisolated static func validateVideoPosterBytes(_ bytes: Data, status: IOSServerVideoPosterStatus) throws {
        guard bytes.count <= 1_048_576, Int64(bytes.count) == status.size,
              bytes.starts(with: [0xff, 0xd8, 0xff]),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == status.posterChecksum?.lowercased(),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == status.width,
              properties[kCGImagePropertyPixelHeight] as? Int == status.height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw IOSServerVideoPosterError.invalidBytes }
    }
}

// Existing API doubles keep their two-argument behavior. The production
// IMAPIClient implements the scoped requirement and namespaces its GET flight.
extension IMAPIProtocol {
    func getTenantFile(context: IMAPIContext, fileID: String, coalescingScope: String?) async throws -> RemoteUserFileDetail {
        try await getTenantFile(context: context, fileID: fileID)
    }
}
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
