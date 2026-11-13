import Foundation
import IM4Data

enum LegalDocumentType: String, CaseIterable, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var fixedWebURL: URL {
        switch self {
        case .terms:
            return URL(string: "https://wdatong.cn/ios_yonghu.html")!
        case .privacy:
            return URL(string: "https://wdatong.cn/ios_yinsi.html")!
        }
    }

    var title: String {
        switch self {
        case .terms:
            return "用户协议"
        case .privacy:
            return "隐私政策"
        }
    }

    var symbol: String {
        switch self {
        case .terms:
            return "doc.text.fill"
        case .privacy:
            return "hand.raised.fill"
        }
    }

    func matches(_ rawValue: String) -> Bool {
        let normalized = Self.normalized(rawValue)
        switch self {
        case .terms:
            return ["terms", "user_terms", "user_agreement", "agreement", "service_terms"].contains(normalized)
        case .privacy:
            return ["privacy", "privacy_policy", "policy"].contains(normalized)
        }
    }

    static func normalized(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteLegalDocManifest = IM4Data.RemoteLegalDocManifest

extension RemoteLegalDocManifest: @retroactive Decodable {
    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case manifestRevision = "manifest_revision"
        case manifestRevisionCamel = "manifestRevision"
        case manifestHash = "manifest_hash"
        case manifestHashCamel = "manifestHash"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case docs
    }

    public init(from decoder: Decoder) throws {
        let appID: String
        let manifestRevision: Int64
        let manifestHash: String
        let updatedAt: String
        let docs: [RemoteLegalDoc]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        manifestRevision = c.decodeLossyInt64IfPresent(forKey: .manifestRevision)
            ?? c.decodeLossyInt64IfPresent(forKey: .manifestRevisionCamel)
            ?? 0
        manifestHash = try c.decodeIfPresent(String.self, forKey: .manifestHash)
            ?? c.decodeIfPresent(String.self, forKey: .manifestHashCamel)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
            ?? ""
        docs = try c.decodeIfPresent([RemoteLegalDoc].self, forKey: .docs) ?? []
        self.init(
            appID: appID,
            manifestRevision: manifestRevision,
            manifestHash: manifestHash,
            updatedAt: updatedAt,
            docs: docs
        )
    }

    func document(type: LegalDocumentType) -> RemoteLegalDoc? {
        docs.first { type.matches($0.docType) }
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteLegalDoc = IM4Data.RemoteLegalDoc

extension RemoteLegalDoc: @retroactive Decodable {
    enum CodingKeys: String, CodingKey {
        case docType = "doc_type"
        case docTypeCamel = "docType"
        case version
        case title
        case downloadURL = "download_url"
        case downloadURLCamel = "downloadUrl"
        case downloadURLUpperCamel = "downloadURL"
        case downloadExpiresAt = "download_expires_at"
        case downloadExpiresAtCamel = "downloadExpiresAt"
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case sizeBytes = "size_bytes"
        case sizeBytesCamel = "sizeBytes"
        case checksum
    }

    public init(from decoder: Decoder) throws {
        let docType: String
        let version: Int64
        let title: String
        let downloadURL: String
        let downloadExpiresAt: String
        let mimeType: String
        let sizeBytes: Int64
        let checksum: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDocType = try c.decodeIfPresent(String.self, forKey: .docType)
            ?? c.decodeIfPresent(String.self, forKey: .docTypeCamel)
            ?? ""
        docType = decodedDocType
        version = c.decodeLossyInt64IfPresent(forKey: .version) ?? 0
        let defaultTitle = LegalDocumentType.allCases.first { $0.matches(decodedDocType) }?.title ?? "协议内容"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaultTitle
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURLUpperCamel)
            ?? ""
        downloadExpiresAt = try c.decodeIfPresent(String.self, forKey: .downloadExpiresAt)
            ?? c.decodeIfPresent(String.self, forKey: .downloadExpiresAtCamel)
            ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            ?? c.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
            ?? ""
        sizeBytes = c.decodeLossyInt64IfPresent(forKey: .sizeBytes)
            ?? c.decodeLossyInt64IfPresent(forKey: .sizeBytesCamel)
            ?? 0
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? ""
        self.init(
            docType: docType,
            version: version,
            title: title,
            downloadURL: downloadURL,
            downloadExpiresAt: downloadExpiresAt,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            checksum: checksum
        )
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：协议正文由客户端受控 HTTP 拉取后内嵌展示
// WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
struct LegalDocumentLoadFailure: Error, Equatable {
    let message: String
}
// WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END

struct LegalDocumentContent: Equatable {
    let type: LegalDocumentType
    let title: String
    let html: String
    let sourceURL: URL
    let baseURL: URL
    let manifest: RemoteLegalDocManifest

    var displayHTML: String {
        let policy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        """
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else { return policy }
        if let headRange = trimmedHTML.range(of: "<head", options: [.caseInsensitive]),
           let headEnd = trimmedHTML[headRange.lowerBound...].range(of: ">") {
            var value = trimmedHTML
            value.insert(contentsOf: "\n\(policy)\n", at: headEnd.upperBound)
            return value
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(policy)
        </head>
        <body>
        \(trimmedHTML)
        </body>
        </html>
        """
    }
}
// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
