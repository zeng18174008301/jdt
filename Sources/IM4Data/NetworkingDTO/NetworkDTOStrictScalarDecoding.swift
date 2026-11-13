import Foundation

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
extension KeyedDecodingContainer {
    func decodeStrictIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key) else { return nil }
        return try? decode(Int.self, forKey: key)
    }

    func decodeStrictInt64IfPresent(forKey key: Key) -> Int64? {
        guard contains(key) else { return nil }
        return try? decode(Int64.self, forKey: key)
    }

    func containsInvalidStrictValue<T: Decodable>(_ type: T.Type, forKey key: Key) -> Bool {
        guard contains(key) else { return false }
        return (try? decode(T.self, forKey: key)) == nil
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
