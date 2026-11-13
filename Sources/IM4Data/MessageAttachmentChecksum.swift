// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

internal enum MessageAttachmentChecksum {
    static func normalizedSHA256(_ rawValue: String) -> String {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return ""
        }
        return rawValue
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
