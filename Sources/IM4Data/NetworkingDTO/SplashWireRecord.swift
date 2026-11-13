import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteSplashConfiguration: Equatable, Sendable {
    public let licenseEnabled: Bool
    public let configEnabled: Bool?
    public let splashEnabled: Bool
    public let assetID: String
    public let imageURL: String
    public let version: String
    public let cacheKey: String
    public let cacheStrategy: String
    public let width: Int?
    public let height: Int?
    public let mimeType: String
    public let sizeBytes: Int64?
    public let etag: String
    public let sha256: String
    public let minIntervalSec: Int?
    public let dailyCap: Int?
    public let minShowMS: Int?
    public let maxShowMS: Int?
    public let actionURL: String
    public let serverDisabledReason: String

    public init(
        licenseEnabled: Bool,
        configEnabled: Bool?,
        splashEnabled: Bool,
        assetID: String,
        imageURL: String,
        version: String,
        cacheKey: String,
        cacheStrategy: String,
        width: Int?,
        height: Int?,
        mimeType: String,
        sizeBytes: Int64?,
        etag: String,
        sha256: String,
        minIntervalSec: Int?,
        dailyCap: Int?,
        minShowMS: Int?,
        maxShowMS: Int?,
        actionURL: String,
        serverDisabledReason: String
    ) {
        self.licenseEnabled = licenseEnabled
        self.configEnabled = configEnabled
        self.splashEnabled = splashEnabled
        self.assetID = assetID
        self.imageURL = imageURL
        self.version = version
        self.cacheKey = cacheKey
        self.cacheStrategy = cacheStrategy
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.etag = etag
        self.sha256 = sha256
        self.minIntervalSec = minIntervalSec
        self.dailyCap = dailyCap
        self.minShowMS = minShowMS
        self.maxShowMS = maxShowMS
        self.actionURL = actionURL
        self.serverDisabledReason = serverDisabledReason
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
