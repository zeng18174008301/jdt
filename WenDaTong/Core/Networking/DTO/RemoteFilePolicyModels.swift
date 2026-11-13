import Foundation
import IM4Data

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteSplashConfiguration = IM4Data.RemoteSplashConfiguration

extension RemoteSplashConfiguration {
    var disabledReason: String {
        if !licenseEnabled { return "license_disabled" }
        let serverReason = serverDisabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverReason.isEmpty { return serverReason }
        guard let configEnabled else { return "splash_config_missing" }
        if !configEnabled { return "splash_config_disabled" }
        if !splashEnabled { return "splash_disabled" }
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missing_version" }
        if imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missing_image_url" }
        return ""
    }

    func makeSnapshot(tenantID: String, resolvedImageURL: String, fetchedAt: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
        tenantID: tenantID,
        licenseEnabled: licenseEnabled,
        splashEnabled: splashEnabled,
            assetID: assetID,
            imageURL: resolvedImageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? imageURL : resolvedImageURL,
            version: version,
            cacheKeyOverride: cacheKey,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: fetchedAt.timeIntervalSince1970,
            disabledReason: disabledReason,
            prefetchStatus: disabledReason.isEmpty ? .pending : .skipped,
            lastPrefetchAt: nil,
            lastPrefetchError: ""
        )
    }

    static let empty = RemoteSplashConfiguration(
        licenseEnabled: false,
        configEnabled: nil,
        splashEnabled: false,
        assetID: "",
        imageURL: "",
        version: "",
        cacheKey: "",
        cacheStrategy: "",
        width: nil,
        height: nil,
        mimeType: "",
        sizeBytes: nil,
        etag: "",
        sha256: "",
        minIntervalSec: nil,
        dailyCap: nil,
        minShowMS: nil,
        maxShowMS: nil,
        actionURL: "",
        serverDisabledReason: ""
    )
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

struct RemoteFileUploadConfig: Decodable {
    let messageActionsPolicy: MessageActionsPolicy
    let maxBytes: Int64
    let maxMB: Int
    let source: String
    let messageRecallMaxMinutes: Int
    let voiceCallEnabled: Bool
    let videoCallEnabled: Bool
    let voiceCallLicenseKnown: Bool
    let videoCallLicenseKnown: Bool
    let readReceiptsEnabled: Bool
    let groupAdminDeleteMessageEnabled: Bool
    let splashConfiguration: RemoteSplashConfiguration

    enum CodingKeys: String, CodingKey {
        case fileUploadMaxBytes = "file_upload_max_bytes"
        case maxFileSizeBytes = "max_file_size_bytes"
        case maxBytes = "max_bytes"
        case maxMB = "max_mb"
        case source
        case messageRecallMaxMinutes = "message_recall_max_minutes"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case readReceiptsEnabled = "read_receipts_enabled"
        case groupAdminDeleteMessageEnabled = "group_admin_delete_message_enabled"
        case features
        case splash
        case splashEnabled = "splash_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case splashConfigEnabled = "splash_config_enabled"
        case splashAssetID = "splash_asset_id"
        case splashImageURL = "splash_image_url"
        case splashVersion = "splash_version"
        case splashWidth = "splash_width"
        case splashHeight = "splash_height"
        case splashMimeType = "splash_mime_type"
        case splashSizeBytes = "splash_size_bytes"
        case splashETag = "splash_etag"
        case splashSHA256 = "splash_sha256"
        case splashCacheKey = "splash_cache_key"
        case splashCacheStrategy = "splash_cache_strategy"
        case splashDisabledReason = "splash_disabled_reason"
        case splashMinIntervalSec = "splash_min_interval_sec"
        case splashDailyCap = "splash_daily_cap"
        case splashMinShowMS = "splash_min_show_ms"
        case splashMaxShowMS = "splash_max_show_ms"
        case splashActionURL = "splash_action_url"
    }

    enum FeatureCodingKeys: String, CodingKey {
        case messageRecallMaxMinutes = "message_recall_max_minutes"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case readReceiptsEnabled = "read_receipts_enabled"
        case groupAdminDeleteMessageEnabled = "group_admin_delete_message_enabled"
        case splashEnabled = "splash_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case splashConfigEnabled = "splash_config_enabled"
    }

    enum SplashCodingKeys: String, CodingKey {
        case enabled
        case splashEnabled = "splash_enabled"
        case licenseEnabled = "license_enabled"
        case splashLicenseEnabled = "splash_license_enabled"
        case configEnabled = "config_enabled"
        case splashConfigEnabled = "splash_config_enabled"
        case assetID = "asset_id"
        case splashAssetID = "splash_asset_id"
        case imageURL = "image_url"
        case splashImageURL = "splash_image_url"
        case version
        case splashVersion = "splash_version"
        case width
        case splashWidth = "splash_width"
        case height
        case splashHeight = "splash_height"
        case mimeType = "mime_type"
        case splashMimeType = "splash_mime_type"
        case sizeBytes = "size_bytes"
        case splashSizeBytes = "splash_size_bytes"
        case etag
        case splashETag = "splash_etag"
        case sha256
        case splashSHA256 = "splash_sha256"
        case cacheKey = "cache_key"
        case splashCacheKey = "splash_cache_key"
        case cacheStrategy = "cache_strategy"
        case splashCacheStrategy = "splash_cache_strategy"
        case disabledReason = "disabled_reason"
        case splashDisabledReason = "splash_disabled_reason"
        case minIntervalSec = "min_interval_sec"
        case splashMinIntervalSec = "splash_min_interval_sec"
        case dailyCap = "daily_cap"
        case splashDailyCap = "splash_daily_cap"
        case minShowMS = "min_show_ms"
        case splashMinShowMS = "splash_min_show_ms"
        case maxShowMS = "max_show_ms"
        case splashMaxShowMS = "splash_max_show_ms"
        case actionURL = "action_url"
        case splashActionURL = "splash_action_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageActionsPolicy = try MessageActionsPolicy(from: decoder)
        let features = try? c.nestedContainer(keyedBy: FeatureCodingKeys.self, forKey: .features)
        let splash = try? c.nestedContainer(keyedBy: SplashCodingKeys.self, forKey: .splash)

        func splashString(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> String {
            if let value = c.decodeLossyStringIfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return "" }
            for key in nestedKeys {
                if let value = splash.decodeLossyStringIfPresent(forKey: key) {
                    return value
                }
            }
            return ""
        }

        func splashBool(_ topKey: CodingKeys, featureKey: FeatureCodingKeys?, nestedKeys: [SplashCodingKeys]) -> Bool? {
            if let value = c.decodeLossyBoolIfPresent(forKey: topKey) {
                return value
            }
            if let featureKey, let value = features?.decodeLossyBoolIfPresent(forKey: featureKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyBoolIfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        func splashInt(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> Int? {
            if let value = c.decodeLossyIntIfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyIntIfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        func splashInt64(_ topKey: CodingKeys, nestedKeys: [SplashCodingKeys]) -> Int64? {
            if let value = c.decodeLossyInt64IfPresent(forKey: topKey) {
                return value
            }
            guard let splash else { return nil }
            for key in nestedKeys {
                if let value = splash.decodeLossyInt64IfPresent(forKey: key) {
                    return value
                }
            }
            return nil
        }

        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .fileUploadMaxBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .maxFileSizeBytes)
            ?? c.decodeIfPresent(Int64.self, forKey: .maxBytes)
            ?? FileUploadConfig.defaultValue.maxBytes
        maxMB = try c.decodeIfPresent(Int.self, forKey: .maxMB)
            ?? max(1, Int((maxBytes + 1024 * 1024 - 1) / (1024 * 1024)))
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? FileUploadConfig.defaultValue.source
        messageRecallMaxMinutes = c.decodeLossyIntIfPresent(forKey: .messageRecallMaxMinutes)
            ?? features?.decodeLossyIntIfPresent(forKey: .messageRecallMaxMinutes)
            ?? FileUploadConfig.defaultValue.messageRecallMaxMinutes
        let voiceLicense = c.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
        let videoLicense = c.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
        voiceCallEnabled = voiceLicense ?? false
        videoCallEnabled = videoLicense ?? false
        voiceCallLicenseKnown = voiceLicense != nil
        videoCallLicenseKnown = videoLicense != nil
        readReceiptsEnabled = c.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .readReceiptsEnabled)
            ?? FileUploadConfig.defaultValue.readReceiptsEnabled
        groupAdminDeleteMessageEnabled = c.decodeLossyBoolIfPresent(forKey: .groupAdminDeleteMessageEnabled)
            ?? features?.decodeLossyBoolIfPresent(forKey: .groupAdminDeleteMessageEnabled)
            ?? FileUploadConfig.defaultValue.groupAdminDeleteMessageEnabled
        splashConfiguration = RemoteSplashConfiguration(
            licenseEnabled: splashBool(
                .splashLicenseEnabled,
                featureKey: .splashLicenseEnabled,
                nestedKeys: [.splashLicenseEnabled, .licenseEnabled]
            ) ?? false,
            configEnabled: splashBool(
                .splashConfigEnabled,
                featureKey: .splashConfigEnabled,
                nestedKeys: [.splashConfigEnabled, .configEnabled]
            ),
            splashEnabled: splashBool(
                .splashEnabled,
                featureKey: .splashEnabled,
                nestedKeys: [.splashEnabled, .enabled]
            ) ?? false,
            assetID: splashString(.splashAssetID, nestedKeys: [.splashAssetID, .assetID]),
            imageURL: splashString(.splashImageURL, nestedKeys: [.splashImageURL, .imageURL]),
            version: splashString(.splashVersion, nestedKeys: [.splashVersion, .version]),
            cacheKey: splashString(.splashCacheKey, nestedKeys: [.splashCacheKey, .cacheKey]),
            cacheStrategy: splashString(.splashCacheStrategy, nestedKeys: [.splashCacheStrategy, .cacheStrategy]),
            width: splashInt(.splashWidth, nestedKeys: [.splashWidth, .width]),
            height: splashInt(.splashHeight, nestedKeys: [.splashHeight, .height]),
            mimeType: splashString(.splashMimeType, nestedKeys: [.splashMimeType, .mimeType]),
            sizeBytes: splashInt64(.splashSizeBytes, nestedKeys: [.splashSizeBytes, .sizeBytes]),
            etag: splashString(.splashETag, nestedKeys: [.splashETag, .etag]),
            sha256: splashString(.splashSHA256, nestedKeys: [.splashSHA256, .sha256]),
            minIntervalSec: splashInt(.splashMinIntervalSec, nestedKeys: [.splashMinIntervalSec, .minIntervalSec]),
            dailyCap: splashInt(.splashDailyCap, nestedKeys: [.splashDailyCap, .dailyCap]),
            minShowMS: splashInt(.splashMinShowMS, nestedKeys: [.splashMinShowMS, .minShowMS]),
            maxShowMS: splashInt(.splashMaxShowMS, nestedKeys: [.splashMaxShowMS, .maxShowMS]),
            actionURL: splashString(.splashActionURL, nestedKeys: [.splashActionURL, .actionURL]),
            serverDisabledReason: splashString(.splashDisabledReason, nestedKeys: [.splashDisabledReason, .disabledReason])
        )
    }

    var model: FileUploadConfig {
        FileUploadConfig(
            maxBytes: maxBytes,
            maxMB: maxMB,
            source: source,
            messageRecallMaxMinutes: messageRecallMaxMinutes,
            voiceCallEnabled: voiceCallEnabled,
            videoCallEnabled: videoCallEnabled,
            readReceiptsEnabled: readReceiptsEnabled,
            groupAdminDeleteMessageEnabled: groupAdminDeleteMessageEnabled,
            voiceCallLicenseKnown: voiceCallLicenseKnown,
            videoCallLicenseKnown: videoCallLicenseKnown
        )
    }
}
