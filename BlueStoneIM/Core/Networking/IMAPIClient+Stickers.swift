import Foundation

@MainActor
extension IMAPIClient {
    func listUserStickers(context: IMAPIContext, status: String? = nil, since: String? = nil, limit: Int? = nil) async throws -> [RemoteUserSticker] {
        try requireIM(context)
        var queryItems: [String] = []
        if let status = status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            queryItems.append("status=\(status.urlQueryEncoded)")
        }
        if let since = since?.trimmingCharacters(in: .whitespacesAndNewlines), !since.isEmpty {
            queryItems.append("since=\(since.urlQueryEncoded)")
        }
        if let limit {
            queryItems.append("limit=\(min(max(limit, 1), 200))")
        }
        let suffix = queryItems.isEmpty ? "" : "?\(queryItems.joined(separator: "&"))"
        let data: RemoteList<RemoteUserSticker> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/user-stickers\(suffix)",
            bearer: context.imToken
        )
        return data.items
    }

    func getUserSticker(context: IMAPIContext, id: String) async throws -> RemoteUserSticker {
        try requireIM(context)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/user-stickers/\(normalizedID.urlPathEncoded)",
            bearer: context.imToken
        )
    }

    func deleteUserSticker(context: IMAPIContext, id: String) async throws -> RemoteUserSticker {
        try requireIM(context)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/user-stickers/\(normalizedID.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken
        )
    }

    func orderUserStickers(context: IMAPIContext, ids: [String]) async throws -> [RemoteUserSticker] {
        try requireIM(context)
        let normalizedIDs = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let data: RemoteList<RemoteUserSticker> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/user-stickers/order",
            method: "PATCH",
            bearer: context.imToken,
            body: ["ids": normalizedIDs]
        )
        return data.items
    }

    func commitUserSticker(context: IMAPIContext, fileID: String, name: String? = nil, packID: String? = nil) async throws -> RemoteUserStickerCommitResult {
        try requireIM(context)
        let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["file_id": normalizedFileID]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body["name"] = name
        }
        if let packID = packID?.trimmingCharacters(in: .whitespacesAndNewlines), !packID.isEmpty {
            body["pack_id"] = packID
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/user-stickers/commit",
            method: "POST",
            bearer: context.imToken,
            body: body
        )
    }

    func listStickerPacks(context: IMAPIContext) async throws -> [RemoteStickerPack] {
        try requireIM(context)
        let data: RemoteList<RemoteStickerPack> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/sticker-packs",
            bearer: context.imToken
        )
        return data.items
    }

    func listStickerPackStickers(context: IMAPIContext, packID: String) async throws -> [RemoteSticker] {
        try requireIM(context)
        let data: RemoteList<RemoteSticker> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/sticker-packs/\(packID.urlPathEncoded)/stickers",
            bearer: context.imToken
        )
        return data.items
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
