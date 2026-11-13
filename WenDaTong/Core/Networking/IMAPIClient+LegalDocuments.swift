import Foundation

@MainActor
extension IMAPIClient {
    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：用户协议/隐私协议固定到实际 API Origin
    private struct LegalDocManifestAuthority {
        let manifest: RemoteLegalDocManifest
        let base: URL
        let bodyPaths: [String]
    }

    func publicLegalDocs(appID: String) async throws -> RemoteLegalDocManifest {
        Self.fixedLegalDocumentManifest(appID: appID)
    }

    func legalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent {
        return try await fixedLegalDocumentContent(type: type, appID: appID)
    }

    private func fixedLegalDocumentContent(type: LegalDocumentType, appID: String) async throws -> LegalDocumentContent {
        let documentURL = type.fixedWebURL
        let baseURL = try Self.legalDocumentFixedBaseURL(for: documentURL)
        let html = try await legalDocumentHTML(from: documentURL, expectedOrigin: baseURL)
        return LegalDocumentContent(
            type: type,
            title: type.title,
            html: html,
            sourceURL: documentURL,
            baseURL: baseURL,
            manifest: Self.fixedLegalDocumentManifest(appID: appID)
        )
    }

    private nonisolated static func fixedLegalDocumentManifest(appID: String) -> RemoteLegalDocManifest {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        return RemoteLegalDocManifest(
            appID: normalizedAppID,
            manifestRevision: 0,
            manifestHash: "fixed-wdatong-legal-docs",
            docs: LegalDocumentType.allCases.map { type in
                RemoteLegalDoc(
                    docType: type.rawValue,
                    title: type.title,
                    downloadURL: type.fixedWebURL.absoluteString
                )
            }
        )
    }

    private nonisolated static func legalDocumentFixedBaseURL(for url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw IMAPIError.badURL("legal_doc_fixed_url_invalid")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else {
            throw IMAPIError.badURL("legal_doc_fixed_url_invalid")
        }
        return baseURL
    }

    private func remoteLegalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent {
        let authority = try await legalDocsManifestAuthority(appID: appID, context: context)
        guard let document = authority.manifest.document(type: type) else {
            throw IMAPIError.businessForbidden(
                code: "legal_doc_manifest_not_found",
                message: "\(type.title)暂未配置",
                error: nil
            )
        }
        let documentURL = try Self.resolvedLegalDocBodyURL(
            document.downloadURL,
            base: authority.base,
            expectedPaths: authority.bodyPaths
        )
        let html = try await legalDocumentHTML(from: documentURL, expectedOrigin: authority.base)
        return LegalDocumentContent(
            type: type,
            title: document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? type.title : document.title,
            html: html,
            sourceURL: documentURL,
            baseURL: authority.base,
            manifest: authority.manifest
        )
    }

    func resolveLegalDocAssetURL(_ rawValue: String, appID: String) async throws -> String {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try Self.resolvedLegalDocAssetURL(rawValue, base: base).absoluteString
    }

    private func legalDocsManifestAuthority(appID: String, context: IMAPIContext?) async throws -> LegalDocManifestAuthority {
        let tenantID = context?.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let context, !tenantID.isEmpty {
            return try await tenantLegalDocsManifestAuthority(appID: appID, context: context)
        }
        if let knownTenantAuthority = try await knownTenantLegalDocsManifestAuthority(appID: appID) {
            return knownTenantAuthority
        }
        return try await platformLegalDocsManifestAuthority(appID: appID)
    }

    private func platformLegalDocsManifestAuthority(appID: String) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        do {
            return try await platformLegalDocsManifestAuthority(
                appID: normalizedAppID,
                base: base,
                manifestPath: Self.platformLegalDocsManifestPath(appID: normalizedAppID),
                bodyPaths: [Self.platformLegalDocsManifestEndpointPath]
            )
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            if let fallback = try await bootstrapLegalDocsManifestAuthority(
                appID: normalizedAppID,
                base: base
            ) {
                return fallback
            }
            throw error
        }
    }

    private func platformLegalDocsManifestAuthority(
        appID: String,
        base: URL,
        manifestPath: String,
        bodyPaths: [String]
    ) async throws -> LegalDocManifestAuthority {
        let manifest: RemoteLegalDocManifest = try await request(
            base: base,
            path: manifestPath,
            cachePolicy: .reloadIgnoringLocalCacheData,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: base, requestAuthority: nil
        )
        try validateLegalDocManifest(manifest, appID: appID)
        return LegalDocManifestAuthority(
            manifest: manifest,
            base: base,
            bodyPaths: Self.uniqueLegalDocBodyPaths(bodyPaths)
        )
    }

    private func bootstrapLegalDocsManifestAuthority(
        appID: String,
        base: URL
    ) async throws -> LegalDocManifestAuthority? {
        guard let legal = bootstrapMemory?.legal,
              Self.hasBootstrapLegalDocsManifestCandidate(legal) else {
            return nil
        }
        let manifestPath = Self.legalDocsManifestPath(from: legal, appID: appID)
        guard let requestPath = Self.legalDocsManifestRequestPath(manifestPath, base: base),
              requestPath != Self.platformLegalDocsManifestPath(appID: appID) else {
            return nil
        }
        let bodyPaths = Self.uniqueLegalDocBodyPaths([
            Self.platformLegalDocsManifestEndpointPath,
            Self.legalDocsManifestEndpointPath(from: requestPath)
        ].compactMap { $0 })
        return try await platformLegalDocsManifestAuthority(
            appID: appID,
            base: base,
            manifestPath: requestPath,
            bodyPaths: bodyPaths
        )
    }

    private func tenantLegalDocsManifestAuthority(appID: String, context: IMAPIContext) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = tenantBase(for: context)
        return try await tenantLegalDocsManifestAuthority(appID: normalizedAppID, base: base)
    }

    private func knownTenantLegalDocsManifestAuthority(appID: String) async throws -> LegalDocManifestAuthority? {
        guard let base = knownTenantLegalDocsBase() else { return nil }
        do {
            return try await tenantLegalDocsManifestAuthority(appID: appID, base: base)
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            return nil
        }
    }

    private func knownTenantLegalDocsBase() -> URL? {
        if let snapshot = tenantRouteSnapshot,
           let raw = runtimeRouteSelector.endpoints(snapshot, service: .tenantAPI).first,
           let routed = Self.normalizedTenantAPIBaseURL(raw) {
            return routed
        }
        guard !Self.isReleasePlaceholderTenantBase(tenantBase) else {
            return nil
        }
        return tenantBase
    }

    private func tenantLegalDocsManifestAuthority(appID: String, base: URL) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let manifest: RemoteLegalDocManifest = try await request(
            base: base,
            path: Self.tenantLegalDocsManifestPath(appID: normalizedAppID),
            cachePolicy: .reloadIgnoringLocalCacheData,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: base, requestAuthority: nil
        )
        try validateLegalDocManifest(manifest, appID: normalizedAppID)
        return LegalDocManifestAuthority(
            manifest: manifest,
            base: base,
            bodyPaths: [Self.tenantLegalDocsManifestEndpointPath]
        )
    }

    private func validateLegalDocManifest(_ manifest: RemoteLegalDocManifest, appID: String) throws {
        guard Self.matchesFixedAppID(manifest.appID, expected: appID) else {
            throw IMAPIError.businessForbidden(
                code: "app_context_mismatch",
                message: "应用协议配置不匹配，请联系管理员",
                error: nil
            )
        }
    }

    private func legalDocumentHTML(from url: URL, expectedOrigin: URL) async throws -> String {
        guard Self.isAllowedLegalDocAssetURL(url, base: expectedOrigin) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeoutInterval(for: url.path, method: "GET")
        request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let result = try await rawHTTPResult(
            for: request,
            dedupeKey: nil,
            propagateTaskCancellation: true,
            expectedResponseOrigin: expectedOrigin
        )
        guard result.isHTTPResponse, let statusCode = result.statusCode else {
            throw IMAPIError.emptyResponse
        }
        guard statusCode == 200 else {
            throw IMAPIError.httpStatus(
                statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }
        guard let responseURL = result.responseURL,
              Self.isAllowedLegalDocAssetURL(responseURL, base: expectedOrigin) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        guard !result.data.isEmpty else {
            throw IMAPIError.emptyResponse
        }
        return String(data: result.data, encoding: .utf8) ?? String(decoding: result.data, as: UTF8.self)
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
}
