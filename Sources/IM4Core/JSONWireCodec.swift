import Foundation

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN
public protocol WireCodec: Sendable {
    func encodeJSONObject(_ object: Any) throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

public typealias WireCoding = WireCodec

public struct JSONWireCodec: WireCodec {
    public init() {}
    public func encodeJSONObject(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw WireCodecError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(type, from: data)
    }
}

public enum WireCodecError: Error, Equatable, CustomNSError {
    // Preserve the pre-module Foundation error identity; no payload or secret is added.
    public static let errorDomain = "BlueStoneIM.WireCodecError"
    public var errorCode: Int {
        switch self {
        case .invalidJSONObject: return 0
        case .encryptionProfileMissing: return 1
        case .invalidEncryptedEnvelope: return 2
        }
    }

    case invalidJSONObject
    case encryptionProfileMissing
    case invalidEncryptedEnvelope
}
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END
