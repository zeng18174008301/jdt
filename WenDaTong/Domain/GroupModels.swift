// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

enum GroupDescriptionInputError: Error, Equatable {
    case tooLong

    var userMessage: String {
        switch self {
        case .tooLong:
            return "群描述不能超过 500 个字符"
        }
    }
}

enum GroupDescriptionInputPolicy {
    static let maximumUnicodeScalars = 500

    static func normalizedUnicodeScalarCount(_ value: String) -> Int {
        value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    static func normalize(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUnicodeScalarCount(value) <= maximumUnicodeScalars else {
            throw GroupDescriptionInputError.tooLong
        }
        return normalized
    }
}


// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
