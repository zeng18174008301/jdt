import Foundation
import CryptoKit
import ImageIO

@MainActor
extension IMAPIClient {
    func presignAvatarUpload(context: IMAPIContext, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
			preserveHTTPStatusErrors: true,
            requestAuthority: requestAuthority
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
        progress: (@Sendable (Double) -> Void)? = nil,
        signedVideoBase: URL? = nil
    ) async throws {
        // JHT_MOD_BEGIN ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改开始：上传文件大小校验离开 MainActor，避免大文件发送时阻塞 UI
        try await Self.validateBinaryUploadFile(fileURL: fileURL, expectedSizeBytes: sizeBytes)
        // JHT_MOD_END ATTACHMENT_BINARY_UPLOAD_NON_MAIN_PERF_20260912 - 修改结束
        let uploadURLString = resolveAssetURL(upload.url, base: signedVideoBase ?? tenantBase(for: IMAPIContext.load()))
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
                progress: progress,
                rejectsRedirects: signedVideoBase != nil
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
            if signedVideoBase != nil, statusCode == 409, failure.serverCode == "filealreadyexists",
               upload.headers.contains(where: {
                   $0.key.caseInsensitiveCompare("x-oss-forbid-overwrite") == .orderedSame
                       && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
               }) {
                // This only authorizes checking the existing object, not sending a message.
                return
            }
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
        progress: (@Sendable (Double) -> Void)?,
        rejectsRedirects: Bool
    ) async throws -> HTTPTransportResult {
        let progressDelegate = (progress != nil || rejectsRedirects)
            ? UploadProgressDelegate(progress: progress ?? { _ in }, rejectsRedirects: rejectsRedirects)
            : nil
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
}
