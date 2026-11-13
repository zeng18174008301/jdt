import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeMessageMapper {
    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:128; pure value snapshot counterpart.
    func stickerSnapshot(from message: RemoteMessage) -> StickerMessageSnapshot? {
        guard isStickerPayload(message.payload, contentType: message.contentType) else { return nil }
        var variants = stickerVariantSnapshots(from: message.payload)
        let thumbnailFileID = attachmentPayloadString(message.payload, ["thumbnail_file_id", "thumb_file_id", "preview_file_id"])
        let fileID = attachmentPayloadString(
            message.payload,
            ["file_id", "original_file_id", "source_file_id", "animation_file_id", "asset_file_id"],
            fallback: variants.first(where: { !$0.fileID.isEmpty })?.fileID ?? thumbnailFileID
        )
        let stickerID = attachmentPayloadString(message.payload, ["sticker_id", "id"])
        guard !stickerID.isEmpty || !fileID.isEmpty else { return nil }
        let mimeType = attachmentPayloadString(message.payload, ["mime_type"], fallback: "image/gif")
        let thumbnailURL = attachmentPayloadString(message.payload, ["thumbnail_url", "thumb_url", "thumbnail_endpoint", "preview_thumbnail_url", "thumbnail_preview_url", "preview_url"])
        if variants.isEmpty, !fileID.isEmpty {
            variants = [
                StickerMessageVariantSnapshot(
                    kind: "original",
                    fileID: fileID,
                    mimeType: mimeType,
                    thumbnailURL: thumbnailURL,
                    cacheKey: attachmentPayloadString(message.payload, ["cache_key", "cacheKey", "version"])
                )
            ]
        }
        return StickerMessageSnapshot(
            stickerID: stickerID,
            packID: attachmentPayloadString(message.payload, ["pack_id"]),
            fileID: fileID,
            mimeType: mimeType,
            width: attachmentPayloadInt64(message.payload, ["width"]).map(Int.init),
            height: attachmentPayloadInt64(message.payload, ["height"]).map(Int.init),
            durationMS: attachmentPayloadInt64(message.payload, ["duration_ms"]).map(Int.init),
            frameCount: attachmentPayloadInt64(message.payload, ["frame_count"]).map(Int.init),
            thumbnailURL: thumbnailURL,
            variants: variants,
            fallbackText: stickerFallbackText(from: message.payload)
        )
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift:167; pure value snapshot counterpart.
    func stickerVariantSnapshots(from payload: [String: JSONValue]) -> [StickerMessageVariantSnapshot] {
        guard case .array(let values)? = payload["variants"] else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value else { return nil }
            let fileID = payloadString(object, ["file_id", "original_file_id", "source_file_id", "animation_file_id", "asset_file_id"])
            let kind = payloadString(object, ["kind", "variant"])
            let mimeType = payloadString(object, ["mime_type"])
            guard !fileID.isEmpty || !kind.isEmpty || !mimeType.isEmpty else { return nil }
            return StickerMessageVariantSnapshot(
                kind: kind,
                fileID: fileID,
                mimeType: mimeType,
                assetURL: payloadString(object, ["url", "asset_url", "file_url", "animation_url", "source_url", "original_url", "download_url", "download_public"]),
                sizeBytes: payloadInt64(object, ["size_bytes", "size"]),
                width: payloadInt64(object, ["width"]).map(Int.init),
                height: payloadInt64(object, ["height"]).map(Int.init),
                durationMS: payloadInt64(object, ["duration_ms"]).map(Int.init),
                frameCount: payloadInt64(object, ["frame_count"]).map(Int.init),
                thumbnailURL: payloadString(object, ["thumbnail_url", "thumb_url", "thumbnail_endpoint", "preview_thumbnail_url", "thumbnail_preview_url", "preview_url"]),
                cacheKey: payloadString(object, ["cache_key", "cacheKey", "version"])
            )
        }
    }

    // Source Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift:357; pure value snapshot counterpart.
    func remoteClientMessageIdentifiers(_ remote: RemoteMessage) -> [String] {
        var identifiers: [String] = []
        if let clientMsgNo = remote.clientMsgNo?.trimmingCharacters(in: .whitespacesAndNewlines), !clientMsgNo.isEmpty {
            identifiers.append(clientMsgNo)
        }
        for key in ["client_msg_no", "client_msg_id", "client_message_id", "client_id", "local_id", "localId"] {
            let value = payloadString(remote.payload, [key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                identifiers.append(value)
            }
        }
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
