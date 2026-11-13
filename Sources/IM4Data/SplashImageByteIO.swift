// WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111_BEGIN
import Foundation
import CryptoKit

public enum SplashImageValidationFailure: String, Equatable, Sendable {
    case emptyData = "empty_data"
    case fileTooLarge = "file_too_large"
    case unsupportedFormat = "unsupported_format"
    case mimeTypeMismatch = "mime_type_mismatch"
    case sizeMismatch = "size_mismatch"
    case checksumMismatch = "checksum_mismatch"
    case decodeFailed = "decode_failed"
    case dimensionsOutOfRange = "dimensions_out_of_range"
    case dimensionsMismatch = "dimensions_mismatch"
}

public enum SplashImageByteValidation {
    case valid(mimeType: String, sha256Hex: String)
    case invalid(SplashImageValidationFailure)
}

public enum SplashImageByteValidator {
    public static let maxSizeBytes = 5 * 1_024 * 1_024
    public static let maxWidth = 4_096
    public static let maxHeight = 8_192
    public static let maxPixelCount: Int64 = 12_000_000

    public static func validate(
        data: Data,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String
    ) -> SplashImageByteValidation {
        guard !data.isEmpty else {
            return .invalid(.emptyData)
        }
        guard data.count <= maxSizeBytes else {
            return .invalid(.fileTooLarge)
        }
        guard let detectedMimeType = detectedMimeType(data) else {
            return .invalid(.unsupportedFormat)
        }

        let normalizedExpectedMimeType = normalizedMimeType(expectedMimeType)
        if !expectedMimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !normalizedExpectedMimeType.isEmpty,
                  normalizedExpectedMimeType == detectedMimeType else {
                return .invalid(.mimeTypeMismatch)
            }
        }

        if let expectedSizeBytes {
            guard expectedSizeBytes > 0,
                  Int64(data.count) == expectedSizeBytes else {
                return .invalid(.sizeMismatch)
            }
        }

        let digest = SHA256.hash(data: data)
        let digestData = Data(digest)
        let sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        if !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !matchesExpectedSHA256(
               expectedSHA256,
               digestHex: sha256Hex,
               digestData: digestData
           ) {
            return .invalid(.checksumMismatch)
        }

        return .valid(mimeType: detectedMimeType, sha256Hex: sha256Hex)
    }

    public static func dimensionsFailure(
        width: Int,
        height: Int,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) -> SplashImageValidationFailure? {
        guard width > 0,
              height > 0,
              width <= maxWidth,
              height <= maxHeight,
              Int64(width) * Int64(height) <= maxPixelCount else {
            return .dimensionsOutOfRange
        }
        if let expectedWidth {
            guard expectedWidth > 0, width == expectedWidth else {
                return .dimensionsMismatch
            }
        }
        if let expectedHeight {
            guard expectedHeight > 0, height == expectedHeight else {
                return .dimensionsMismatch
            }
        }
        return nil
    }

    private static func detectedMimeType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 12,
           bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]),
           bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        return nil
    }

    private static func normalizedMimeType(_ rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image/jpeg", "image/jpg":
            return "image/jpeg"
        case "image/png":
            return "image/png"
        case "image/webp":
            return "image/webp"
        default:
            return ""
        }
    }

    private static func matchesExpectedSHA256(
        _ rawValue: String,
        digestHex: String,
        digestData: Data
    ) -> Bool {
        var expected = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if expected.lowercased().hasPrefix("sha256:") {
            expected.removeFirst("sha256:".count)
            expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if expected.count == 64,
           expected.unicodeScalars.allSatisfy({ scalar in
               CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
           }) {
            return expected.lowercased() == digestHex
        }

        let expectedBase64 = expected
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedBase64 = expectedBase64 + String(
            repeating: "=",
            count: (4 - expectedBase64.count % 4) % 4
        )
        guard let decoded = Data(base64Encoded: paddedBase64) else {
            return false
        }
        return decoded == digestData
    }
}

public enum SplashImageByteStore {
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BlueStoneIMSplashImages", isDirectory: true)
    }

    public static func read(from url: URL, mapped: Bool = false) throws -> Data {
        try Data(contentsOf: url, options: mapped ? [.mappedIfSafe] : [])
    }

    public static func fetch(from url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    public static func write(_ data: Data, to url: URL, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public static func discardInvalidFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
// WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111_END
