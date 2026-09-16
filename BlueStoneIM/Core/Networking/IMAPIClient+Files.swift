import Foundation

@MainActor
extension IMAPIClient {
    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REQUEST_HELPER - 修改开始：公共媒体文件接口使用匿名 REST 请求，保留本地 IM 上下文用于租户路由
    private func publicMediaRequest<T: Decodable>(
        context: IMAPIContext,
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> T {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: path,
            method: method,
            bearer: nil,
            body: body,
            cachePolicy: cachePolicy,
            bearerPurpose: .publicMedia
        )
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REQUEST_HELPER - 修改结束

    func presignAvatarUpload(context: IMAPIContext, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/avatar/presign-upload",
            method: "POST",
            bearer: context.imToken,
            body: [
                "file_name": fileName,
                "mime_type": mimeType,
                "size_bytes": sizeBytes,
                "width": width,
                "height": height,
                "app_id": context.appID
            ],
			preserveHTTPStatusErrors: true
        )
    }

    func uploadAvatarBinary(upload: RemoteSignedUpload, data: Data, mimeType: String) async throws {
        try await uploadBinary(upload: upload, data: data, mimeType: mimeType, failureMessage: "头像图片上传失败")
    }

    func uploadGroupAvatarBinary(upload: RemoteSignedUpload, data: Data, mimeType: String) async throws {
        try await uploadBinary(upload: upload, data: data, mimeType: mimeType, failureMessage: "群头像图片上传失败")
    }

    func uploadBinary(upload: RemoteSignedUpload, data: Data, mimeType: String, failureMessage: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let uploadURLString = resolveAssetURL(upload.url, base: tenantBase(for: IMAPIContext.load()))
        guard let url = URL(string: uploadURLString), url.scheme != nil, !uploadURLString.isEmpty else {
            throw IMAPIError.badURL(upload.url)
        }
        let method = upload.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PUT" : upload.method
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (key, value) in upload.headers where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let result: HTTPTransportResult
        let httpTransport = self.httpTransport
        do {
            // JHT_MOD_BEGIN ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改开始：二进制上传请求体离开 MainActor 执行，主线程只保留状态更新
            result = try await Self.performBinaryUpload(
                httpTransport: httpTransport,
                request: request,
                data: data,
                progress: progress
            )
            // JHT_MOD_END ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改结束
        } catch {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(error: error))
            logUploadFailure(method: method, url: url, statusCode: nil, dataLength: data.count, responseBody: "", error: error)
            if isDevelopmentObjectTunnelURL(url) {
                throw IMAPIError.server("\(failureMessage)：本地对象上传地址不可用，请确认 tenant-api 已启动；真机联调需把 TENANT_BASE_URL 和 App tenantBase 配成 Mac 局域网地址")
            }
            throw error
        }
        guard result.isHTTPResponse, let statusCode = result.statusCode else {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .invalidResponse))
            logUploadFailure(method: method, url: url, statusCode: nil, dataLength: data.count, responseBody: "", error: nil)
            throw IMAPIError.server(failureMessage)
        }
        guard (200..<300).contains(statusCode) else {
            let failure = binaryUploadFailure(from: result)
            let responseBody = failure.detail
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(failure)
            logUploadFailure(method: method, url: url, statusCode: statusCode, dataLength: data.count, responseBody: responseBody, error: nil)
            let detail = uploadFailureDetail(statusCode: statusCode, responseData: result.data, responseBody: responseBody, url: url)
            throw IMAPIError.server(detail.isEmpty ? failureMessage : "\(failureMessage)：\(detail)")
        }
    }

    func uploadBinary(
        upload: RemoteSignedUpload,
        fileURL: URL,
        mimeType: String,
        sizeBytes: Int64,
        failureMessage: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // JHT_MOD_BEGIN ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改开始：上传文件大小校验离开 MainActor，避免大文件发送时阻塞 UI
        try await Self.validateBinaryUploadFile(fileURL: fileURL, expectedSizeBytes: sizeBytes)
        // JHT_MOD_END ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改结束
        let uploadURLString = resolveAssetURL(upload.url, base: tenantBase(for: IMAPIContext.load()))
        guard let url = URL(string: uploadURLString), url.scheme != nil, !uploadURLString.isEmpty else {
            throw IMAPIError.badURL(upload.url)
        }
        let method = upload.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PUT" : upload.method
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60 * 60
        // The signer owns Content-Type; local MIME is only a fallback.
        request.setValue(mimeType.isEmpty ? "application/octet-stream" : mimeType, forHTTPHeaderField: "Content-Type")
        for (key, value) in upload.headers where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        let result: HTTPTransportResult
        let httpTransport = self.httpTransport
        let logLength = Int(clamping: sizeBytes)
        do {
            // JHT_MOD_BEGIN ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改开始：文件上传请求体离开 MainActor 执行，主线程只保留状态更新
            result = try await Self.performBinaryUpload(
                httpTransport: httpTransport,
                request: request,
                fileURL: fileURL,
                progress: progress
            )
            // JHT_MOD_END ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改结束
        } catch {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(error: error))
            logUploadFailure(method: method, url: url, statusCode: nil, dataLength: logLength, responseBody: "", error: error)
            if isDevelopmentObjectTunnelURL(url) {
                throw IMAPIError.server("\(failureMessage)：本地对象上传地址不可用，请确认 tenant-api 已启动；真机联调需把 TENANT_BASE_URL 和 App tenantBase 配成 Mac 局域网地址")
            }
            throw error
        }
        guard result.isHTTPResponse, let statusCode = result.statusCode else {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .invalidResponse))
            logUploadFailure(method: method, url: url, statusCode: nil, dataLength: logLength, responseBody: "", error: nil)
            throw IMAPIError.server(failureMessage)
        }
        guard (200..<300).contains(statusCode) else {
            let failure = binaryUploadFailure(from: result)
            let responseBody = failure.detail
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(failure)
            logUploadFailure(method: method, url: url, statusCode: statusCode, dataLength: logLength, responseBody: responseBody, error: nil)
            let detail = uploadFailureDetail(statusCode: statusCode, responseData: result.data, responseBody: responseBody, url: url)
            throw IMAPIError.server(detail.isEmpty ? failureMessage : "\(failureMessage)：\(detail)")
        }
    }

    // JHT_MOD_BEGIN ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改开始：二进制上传和本地文件校验使用非 MainActor helper，避免 URLSession 上传等待占用 UI actor
    private nonisolated static func validateBinaryUploadFile(fileURL: URL, expectedSizeBytes: Int64) async throws {
        let currentSize = try PendingAttachmentFileStore.regularFileSize(at: fileURL)
        guard currentSize == expectedSizeBytes,
              expectedSizeBytes >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func performBinaryUpload(
        httpTransport: HTTPTransport,
        request: URLRequest,
        data: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPTransportResult {
        let progressDelegate = progress.map { UploadProgressDelegate(progress: $0) }
        return try await httpTransport.upload(for: request, from: data, delegate: progressDelegate)
    }

    private nonisolated static func performBinaryUpload(
        httpTransport: HTTPTransport,
        request: URLRequest,
        fileURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPTransportResult {
        let progressDelegate = progress.map { UploadProgressDelegate(progress: $0) }
        return try await httpTransport.upload(for: request, fromFile: fileURL, delegate: progressDelegate)
    }
    // JHT_MOD_END ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改结束

    func binaryUploadFailure(from result: HTTPTransportResult) -> AttachmentUploadFailure {
        var code = Self.effectiveErrorCode(for: uploadAPIError(from: result.data))
        if code == nil {
            // Read only the bounded OSS Code element, never persist the XML error body.
            let text = String(decoding: result.data.prefix(16_384), as: UTF8.self)
            if let range = text.range(of: #"<Code>[A-Za-z]{1,64}</Code>"#, options: .regularExpression) {
                code = String(text[range].dropFirst(6).dropLast(7))
            }
        }
        return AttachmentUploadFailure(
            code: .http, httpStatus: result.statusCode, serverCode: code,
            storageRequestID: result.value(forHTTPHeaderField: "x-oss-request-id")
        )
    }

    func uploadFailureDetail(statusCode: Int, responseData: Data, responseBody: String, url: URL) -> String {
        if let apiError = uploadAPIError(from: responseData) {
            return Self.userMessage(for: apiError, fallback: "HTTP \(statusCode)")
        }
        if isDevelopmentObjectTunnelURL(url) {
            return "本地对象上传地址不可用（HTTP \(statusCode)）"
        }
        let trimmedBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty {
            return "HTTP \(statusCode)"
        }
        return "HTTP \(statusCode) \(trimmedBody)"
    }

    func isDevelopmentObjectTunnelURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let query = url.query?.lowercased() ?? ""
        return host == "oss.local.dev"
            || query.contains("development_signature=1")
            || query.contains("dev_object_signature=1")
            || url.path.contains("/api/tenant/dev-objects/")
    }

    static func responsePreview(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let raw = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 240 else { return singleLine }
        return "\(singleLine.prefix(240))..."
    }

    func uploadAPIError(from data: Data) -> APIEnvelopeError? {
        guard !data.isEmpty else { return nil }
        if let errorEnvelope = try? decoder.decode(APIErrorEnvelope.self, from: data),
           let error = errorEnvelope.resolvedError {
            return error
        }
        if let envelope = try? decoder.decode(APIEnvelope<EmptyPayload>.self, from: data),
           let error = envelope.error {
            return error
        }
        return nil
    }

    func logUploadFailure(method: String, url: URL, statusCode: Int?, dataLength: Int, responseBody: String, error: Error?) {
        let status = statusCode.map(String.init) ?? "none"
        let body = redactedUploadResponseBody(responseBody)
        let errorText = error.map { " error=\(Self.redactedSensitiveLogText($0.localizedDescription))" } ?? ""
        print(Self.apiLogDivider(icon: "❌", title: "UPLOAD FAILED"))
        print("[JHT API] ❌ upload_failed method=\(method) url=\(redactedUploadURL(url)) status=\(status) bytes=\(dataLength) body=\(body) tenantBase=\(Self.redactedURLString(tenantBase, redactAllQueryValues: true))\(errorText)")
    }

    func redactedUploadResponseBody(_ responseBody: String) -> String {
        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        let lowered = trimmed.lowercased()
        let sensitiveMarkers = [
            "sqlstate",
            "bucket",
            "object key",
            "object_key",
            "secret_ref",
            "secret ref",
            "access_key",
            "access key",
            "signer",
            "internal server error"
        ]
        if sensitiveMarkers.contains(where: { lowered.contains($0) }) {
            return "<redacted-storage-error>"
        }
        return Self.redactedSensitiveLogText(trimmed)
    }

    func redactedUploadURL(_ url: URL) -> String {
        // Object keys and signed query parameters are not diagnostic metadata.
        var origin = URLComponents()
        origin.scheme = url.scheme
        origin.host = url.host
        origin.port = url.port
        return origin.string ?? "<upload-origin>"
    }

    private static let sensitiveLogQueryNames: Set<String> = [
        "token",
        "access_token",
        "refresh_token",
        "im_token",
        "platform_token",
        "api_token",
        "authorization",
        "cookie",
        "set_cookie",
        "idempotency_key",
        "signature",
        "x-oss-signature",
        "credential",
        "expires",
        "captcha",
        "captcha_code",
        "device_proof",
        "slide_token",
        "pass_token",
        "password",
        "secret",
        "registration_session_secret",
        "dsn",
        "private_key",
        "public_key_b64",
        "phone",
        "id_card_no",
        "im_uid",
        "imuid",
        "friend_uid",
        "frienduid",
        "user_id",
        "userid",
        "display_name",
        "displayname",
        "raw_nickname",
        "rawnickname",
        "nickname",
        "remark",
        "friend_remark",
        "friendremark",
        "content",
        "message",
        "text",
        "caption"
    ]

    static func redactedURLString(_ url: URL, redactAllQueryValues: Bool) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<redacted-url>"
        }
        components.user = nil
        components.password = nil
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map { item in
                let normalizedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let shouldRedact = redactAllQueryValues || sensitiveLogQueryNames.contains(normalizedName)
                let value: String?
                if shouldRedact {
                    value = "redacted"
                } else {
                    value = item.value.map(Self.redactedSensitiveLogText)
                }
                return URLQueryItem(name: item.name, value: value)
            }
        }
        components.percentEncodedPath = redactedAPIPathForLog(components.percentEncodedPath)
        return components.string ?? "<redacted-url>"
    }

    nonisolated static func redactedSensitiveLogText(_ raw: String) -> String {
        var value = raw
        let jsonPatterns = [
            #"(?i)("(?:password|token|access_token|accessToken|refresh_token|refreshToken|im_token|imToken|platform_token|platformToken|api_token|apiToken|authorization|cookie|set_cookie|setCookie|idempotency_key|idempotencyKey|signature|credential|secret|registration_session_secret|dsn|private_key|privateKey|public_key_b64|publicKeyB64|captcha_code|captchaCode|device_proof|deviceProof|slide_token|slideToken|pass_token|passToken|phone|id_card_no|idCardNo|im_uid|imUID|imUid|friend_uid|friendUID|friendUid|user_id|userID|userId|display_name|displayName|raw_nickname|rawNickname|nickname|remark|friend_remark|friendRemark|content|message|text|caption)"\s*:\s*")[^"]*(")"#
        ]
        for pattern in jsonPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1redacted$2",
                options: .regularExpression
            )
        }
        let queryPatterns = [
            #"(?i)(token|access_token|refresh_token|im_token|platform_token|api_token|authorization|cookie|set_cookie|idempotency_key|signature|x-oss-signature|credential|expires|captcha|captcha_code|device_proof|slide_token|pass_token|password|secret|dsn|private_key|public_key_b64|phone|id_card_no|im_uid|imUID|imUid|friend_uid|friendUID|friendUid|user_id|userID|userId|display_name|displayName|raw_nickname|rawNickname|nickname|remark|friend_remark|friendRemark|content|message|text|caption)=([^\s&]+)"#
        ]
        for pattern in queryPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1=redacted",
                options: .regularExpression
            )
        }
        return value
    }

    nonisolated static func redactedAPIPathForLog(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5,
              parts[1] == "api",
              parts[2] == "tenant",
              parts[3] == "friends",
              parts[4] != "applications" else {
            return path
        }
        var redacted = parts
        redacted[4] = "hash-\(diagnosticFingerprint(parts[4]).replacingOccurrences(of: "hash:", with: ""))"
        return redacted.joined(separator: "/")
    }

    nonisolated static func diagnosticFingerprint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "hash:\(String(hash, radix: 16).suffix(8))"
    }

#if DEBUG
    nonisolated static func debugDiagnosticFingerprint(_ raw: String) -> String {
        diagnosticFingerprint(raw)
    }
#endif

    func commitAvatar(context: IMAPIContext, fileID: String) async throws -> RemoteAvatarCommitData {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/me/avatar",
            method: "PATCH",
            bearer: context.imToken,
			body: ["file_id": fileID],
			preserveHTTPStatusErrors: true
        )
    }

    func presignFileUpload(context: IMAPIContext, conversation: Conversation, channelID: String, clientMessageID: String, purpose: String, fileName: String, mimeType: String, sizeBytes: Int) async throws -> RemoteAvatarUploadData {
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
        return try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/presign-upload",
            method: "POST",
            body: body
        )
    }

    func presignVoiceMessageUpload(
        context: IMAPIContext,
        conversation: Conversation,
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
        conversation: Conversation,
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

    func markVoiceMessageUploaded(
        context: IMAPIContext,
        fileID: String,
        conversation: Conversation,
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
        conversation: Conversation,
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
        try requireIM(context)
        let data: RemoteList<RemoteGroupFile> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/files", bearer: context.imToken)
        return data.items
    }

    func listTenantFiles(context: IMAPIContext, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0) async throws -> [RemoteGroupFile] {
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
        let data: RemoteList<RemoteGroupFile> = try await request(base: tenantBase(for: context), path: "/api/tenant/files?\(queryItems.joined(separator: "&"))", bearer: context.imToken)
        return data.items
    }

    func listFavoriteAssets(context: IMAPIContext, category: String = "all", limit: Int = 30, cursor: String = "") async throws -> RemoteFavoriteAssetsResponse {
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
            body: body
        )
    }

    func getTenantFile(context: IMAPIContext, fileID: String) async throws -> RemoteUserFileDetail {
        try await publicMediaRequest(
            context: context,
            path: "/api/tenant/files/\(fileID.urlPathEncoded)",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
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
            ]
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
