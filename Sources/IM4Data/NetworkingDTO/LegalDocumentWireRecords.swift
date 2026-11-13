import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteLegalDocManifest: Equatable, Sendable {
    public let appID: String

    public let manifestRevision: Int64

    public let manifestHash: String

    public let updatedAt: String

    public let docs: [RemoteLegalDoc]

    public init(
        appID: String,
        manifestRevision: Int64 = 0,
        manifestHash: String = "",
        updatedAt: String = "",
        docs: [RemoteLegalDoc]
    ) {
        self.appID = appID
        self.manifestRevision = manifestRevision
        self.manifestHash = manifestHash
        self.updatedAt = updatedAt
        self.docs = docs
    }
}

public struct RemoteLegalDoc: Equatable, Sendable {
    public let docType: String

    public let version: Int64

    public let title: String

    public let downloadURL: String

    public let downloadExpiresAt: String

    public let mimeType: String

    public let sizeBytes: Int64

    public let checksum: String

    public init(
        docType: String,
        version: Int64 = 0,
        title: String,
        downloadURL: String,
        downloadExpiresAt: String = "",
        mimeType: String = "text/html",
        sizeBytes: Int64 = 0,
        checksum: String = ""
    ) {
        self.docType = docType
        self.version = version
        self.title = title
        self.downloadURL = downloadURL
        self.downloadExpiresAt = downloadExpiresAt
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksum = checksum
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
