// WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
import Foundation

// WDT_IOS1_SAFE_NUMERIC_20261023_BEGIN
extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: value.rounded(.towardZero))
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(exactly: value.rounded(.towardZero))
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite else { return nil }
            return parsed
        }
        return nil
    }

    // WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y", "enabled"].contains(normalized) { return true }
            if ["false", "0", "no", "n", "disabled"].contains(normalized) { return false }
        }
        return nil
    }
    // WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END
    // WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
    func decodeStrictBoolIfPresent(forKey key: Key) -> Bool? {
        guard contains(key) else { return nil }
        return try? decode(Bool.self, forKey: key)
    }
    // WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END

}
// WDT_IOS1_SAFE_NUMERIC_20261023_END
// WDT_IOS1_DATA_NETWORK_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            guard value.isFinite else { return nil }
            return Int64(exactly: value).map(String.init) ?? String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
func decodeFlexibleBoolIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, keys: [K]) -> Bool? {
    for key in keys {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y", "verified", "approved", "passed", "success", "已认证", "已验证"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "n", "unverified", "unbound", "未认证", "未验证", "未绑定"].contains(normalized) {
                return false
            }
        }
    }
    return nil
}

func decodeFlexibleBool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, keys: [K]) -> Bool {
    if let value = decodeFlexibleBoolIfPresent(container, keys: keys) {
        return value
    }
    return false
}
// WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END
