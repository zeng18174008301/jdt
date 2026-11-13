import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

extension AppState {
    var currentAppID: String {
        IMAPIContext.normalizedIOSAppID(apiContext.appID)
    }

    var avatarImageRouteContext: AvatarImageRouteContext? {
        guard let client = api as? IMAPIClient,
              let route = client.runtimeTenantBinaryRouteContext(context: apiContext),
              let routeSnapshotHash = client.tenantRouteSnapshot?.configHash else {
            return nil
        }
        let capturedContext = apiContext
        let authorityID = "\(route.appID)|\(route.tenantID)"
        let routeBases = route.activeBases + route.standbyBases
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak client] in
            guard let self, let client,
                  self.apiContext.appID == route.appID,
                  self.apiContext.tenantID == route.tenantID,
                  let current = client.tenantRouteSnapshot,
                  current.appID == route.appID,
                  current.tenantID == route.tenantID,
                  current.revision == route.revision,
                  current.configHash == routeSnapshotHash,
                  !client.isTenantRuntimeRevoked(appID: route.appID, tenantID: route.tenantID) else {
                return false
            }
            return true
        }
        return AvatarImageRouteContext(
            authorityID: authorityID,
            revision: route.revision,
            routeBases: routeBases,
            fetcher: { [weak client] relativePath in
                guard let client, isCurrent() else { throw CancellationError() }
                let result = try await client.fetchRuntimeTenantBinary(
                    relativePath,
                    context: capturedContext
                )
                guard isCurrent() else { throw CancellationError() }
                return result.data
            },
            authorityCheck: isCurrent
        )
    }

    func groupAvatarCacheKey(
        groupID: String,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) -> String {
        guard let request = TenantRelativeImageURLResolver.request(
            avatarURL,
            routeContext: avatarImageRouteContext
        ), case let .tenantRelative(path) = request else {
            return ""
        }
        let memberID = (apiContext.imUID ?? currentUser.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupAvatarCacheIdentity.cacheKey(
            groupID: groupID,
            memberID: memberID,
            stableAssetIdentity: path,
            version: avatarVersion,
            updatedAt: avatarUpdatedAt
        )
    }

    func groupAvatarCacheKey(for conversation: ConversationMessageSnapshot) -> String {
        let channelID = remoteChannelID(for: conversation)
        return groupAvatarCacheKey(
            groupID: channelID.isEmpty ? conversation.id : channelID,
            avatarURL: conversation.avatarURL,
            avatarVersion: conversation.avatarVersion,
            avatarUpdatedAt: conversation.avatarUpdatedAt
        )
    }

    func enterpriseLogoCacheKey(for enterprise: Enterprise) -> String {
        enterprise.logoImageCacheKey(scope: enterpriseLogoScopeKey(for: enterprise))
    }

    func workspaceSelectionLogoPrefetchSignature(for enterprises: [Enterprise]) -> String {
        enterprises
            .prefix(8)
            .map { enterprise in
                [
                    enterprise.id,
                    enterprise.logoURL,
                    enterprise.logoStatus,
                    enterprise.logoVersion,
                    enterprise.logoUpdatedAt,
                    enterprise.logoCacheKey,
                    enterprise.logoMime,
                    enterprise.logoWidth.map(String.init) ?? "",
                    enterprise.logoHeight.map(String.init) ?? "",
                    enterpriseLogoScopeKey(for: enterprise)
                ]
                .joined(separator: "#")
            }
            .joined(separator: "|")
    }

    func prefetchWorkspaceSelectionLogos(_ enterprises: [Enterprise]) async {
        let candidates = enterprises.prefix(8).compactMap { enterprise -> (url: String, cacheKey: String)? in
            let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enterprise.isLogoRenderable,
                  !raw.hasPrefix("data:image"),
                  let url = URL(string: raw),
                  url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return (url.absoluteString, enterpriseLogoCacheKey(for: enterprise))
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            _ = await AvatarImageCache.shared.remoteImage(
                for: candidate.url,
                routeContext: avatarImageRouteContext,
                cacheKey: candidate.cacheKey
            )
        }
    }

    private func enterpriseLogoScopeKey(for enterprise: Enterprise) -> String {
        [
            apiContext.accountID ?? "",
            enterprise.id,
            apiContext.imUID ?? "",
            apiContext.appID,
            apiContext.deviceID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
