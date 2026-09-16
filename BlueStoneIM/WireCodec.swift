import Foundation
import CryptoKit

protocol WireCodec: Sendable {
    func encodeJSONObject(_ object: Any) throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

typealias WireCoding = WireCodec

struct JSONWireCodec: WireCodec {
    func encodeJSONObject(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw WireCodecError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(type, from: data)
    }
}

struct WireBrandProfile: Sendable, Equatable {
    let identifier: String
    let fieldMapping: WireFieldMappingProfile
    let encryptionKeyID: String?
    let encryptionProfile: WireEncryptionProfile?

    init(
        identifier: String,
        fieldMapping: WireFieldMappingProfile = .canonical,
        encryptionKeyID: String? = nil,
        encryptionProfile: WireEncryptionProfile? = nil
    ) {
        self.identifier = identifier
        self.fieldMapping = fieldMapping
        self.encryptionKeyID = encryptionProfile?.keyID ?? encryptionKeyID
        self.encryptionProfile = encryptionProfile
    }

    static let canonical = WireBrandProfile(identifier: "canonical")
}

struct WireEncryptionProfile: Sendable, Equatable {
    let keyID: String
    let sharedSecret: Data
    let algorithm: String

    init(
        keyID: String,
        sharedSecret: Data,
        algorithm: String = "aes-gcm-256"
    ) {
        self.keyID = keyID
        self.sharedSecret = sharedSecret
        self.algorithm = algorithm
    }
}

struct WireFieldMappingProfile: Sendable, Equatable {
    let name: String
    let outboundFields: [String: String]
    let inboundFields: [String: String]

    init(
        name: String,
        outboundFields: [String: String] = [:],
        inboundFields: [String: String]? = nil
    ) {
        self.name = name
        self.outboundFields = outboundFields
        if let inboundFields {
            self.inboundFields = inboundFields
        } else {
            var reversed: [String: String] = [:]
            for (canonical, branded) in outboundFields {
                reversed[branded] = canonical
            }
            self.inboundFields = reversed
        }
    }

    static let canonical = WireFieldMappingProfile(name: "canonical")
}

struct EncryptedEnvelopeWireCodec: WireCodec {
    private struct Envelope: Codable {
        let alg: String
        let kid: String
        let body: String
    }

    let brandProfile: WireBrandProfile
    private let payloadCodec: any WireCodec
    private let jsonCodec = JSONWireCodec()

    init(
        brandProfile: WireBrandProfile,
        payloadCodec: (any WireCodec)? = nil
    ) {
        self.brandProfile = brandProfile
        self.payloadCodec = payloadCodec ?? FieldMappingWireCodec(brandProfile: brandProfile)
    }

    func encodeJSONObject(_ object: Any) throws -> Data {
        guard let encryptionProfile = brandProfile.encryptionProfile else {
            throw WireCodecError.encryptionProfileMissing
        }
        let payloadData = try payloadCodec.encodeJSONObject(object)
        let sealed = try AES.GCM.seal(payloadData, using: SymmetricKey(data: encryptionProfile.sharedSecret))
        guard let combined = sealed.combined else {
            throw WireCodecError.invalidEncryptedEnvelope
        }
        return try jsonCodec.encodeJSONObject([
            "alg": encryptionProfile.algorithm,
            "kid": encryptionProfile.keyID,
            "body": combined.base64EncodedString()
        ])
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let encryptionProfile = brandProfile.encryptionProfile else {
            throw WireCodecError.encryptionProfileMissing
        }
        let envelope = try jsonCodec.decode(Envelope.self, from: data)
        guard envelope.alg == encryptionProfile.algorithm,
              envelope.kid == encryptionProfile.keyID,
              let combined = Data(base64Encoded: envelope.body) else {
            throw WireCodecError.invalidEncryptedEnvelope
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw WireCodecError.invalidEncryptedEnvelope
        }
        let payloadData: Data
        do {
            payloadData = try AES.GCM.open(sealed, using: SymmetricKey(data: encryptionProfile.sharedSecret))
        } catch {
            throw WireCodecError.invalidEncryptedEnvelope
        }
        return try payloadCodec.decode(type, from: payloadData)
    }
}

struct FieldMappingWireCodec: WireCodec {
    let brandProfile: WireBrandProfile
    private let jsonCodec = JSONWireCodec()

    init(brandProfile: WireBrandProfile) {
        self.brandProfile = brandProfile
    }

    func encodeJSONObject(_ object: Any) throws -> Data {
        let mapped = Self.mapJSONObject(object, fields: brandProfile.fieldMapping.outboundFields)
        return try jsonCodec.encodeJSONObject(mapped)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !brandProfile.fieldMapping.inboundFields.isEmpty else {
            return try jsonCodec.decode(type, from: data)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let mapped = Self.mapJSONObject(object, fields: brandProfile.fieldMapping.inboundFields)
        guard JSONSerialization.isValidJSONObject(mapped) else {
            throw WireCodecError.invalidJSONObject
        }
        let canonicalData = try JSONSerialization.data(withJSONObject: mapped)
        return try jsonCodec.decode(type, from: canonicalData)
    }

    private static func mapJSONObject(_ object: Any, fields: [String: String]) -> Any {
        if fields.isEmpty {
            return object
        }
        if let dictionary = object as? [String: Any] {
            var mapped: [String: Any] = [:]
            for (key, value) in dictionary {
                let mappedKey = fields[key] ?? key
                mapped[mappedKey] = mapJSONObject(value, fields: fields)
            }
            return mapped
        }
        if let array = object as? [Any] {
            return array.map { mapJSONObject($0, fields: fields) }
        }
        return object
    }
}

enum WireCodecError: Error, Equatable {
    case invalidJSONObject
    case encryptionProfileMissing
    case invalidEncryptedEnvelope
}
