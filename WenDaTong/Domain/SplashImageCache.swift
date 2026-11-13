import Foundation
import IM4Data
import UIKit

typealias SplashImageValidationFailure = IM4Data.SplashImageValidationFailure // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111

struct SplashPreparedImage: @unchecked Sendable {
    let fileURL: URL
    let image: UIImage
    let mimeType: String
    let sizeBytes: Int64
    let width: Int
    let height: Int
    let sha256Hex: String
}

enum SplashImageValidationResult {
    case valid(SplashPreparedImage)
    case invalid(SplashImageValidationFailure)
}

enum SplashImageValidator {
    static let maxSizeBytes = SplashImageByteValidator.maxSizeBytes
    static let maxWidth = SplashImageByteValidator.maxWidth
    static let maxHeight = SplashImageByteValidator.maxHeight
    static let maxPixelCount = SplashImageByteValidator.maxPixelCount

    static func validate(
        data: Data,
        fileURL: URL,
        expectedSHA256: String = "",
        expectedSizeBytes: Int64? = nil,
        expectedMimeType: String = "",
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) -> SplashImageValidationResult {
        let detectedMimeType: String
        let sha256Hex: String
        switch SplashImageByteValidator.validate(data: data, expectedSHA256: expectedSHA256,
                                                 expectedSizeBytes: expectedSizeBytes, expectedMimeType: expectedMimeType) {
        case .valid(let mimeType, let digest):
            detectedMimeType = mimeType
            sha256Hex = digest
        case .invalid(let failure):
            return .invalid(failure)
        }
        guard let sourceImage = UIImage(data: data),
              let sourceCGImage = sourceImage.cgImage else {
            return .invalid(.decodeFailed)
        }
        let width = sourceCGImage.width
        let height = sourceCGImage.height
        if let failure = SplashImageByteValidator.dimensionsFailure(
            width: width, height: height, expectedWidth: expectedWidth, expectedHeight: expectedHeight
        ) {
            return .invalid(failure)
        }
        guard let decodedImage = decodedImage(from: sourceImage, cgImage: sourceCGImage) else {
            return .invalid(.decodeFailed)
        }

        return .valid(SplashPreparedImage(
            fileURL: fileURL,
            image: decodedImage,
            mimeType: detectedMimeType,
            sizeBytes: Int64(data.count),
            width: width,
            height: height,
            sha256Hex: sha256Hex
        ))
    }

    private static func decodedImage(from image: UIImage, cgImage: CGImage) -> UIImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let decodedCGImage = context.makeImage() else {
            return nil
        }
        return UIImage(
            cgImage: decodedCGImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}

struct SplashImagePreparationResult: @unchecked Sendable {
    let status: SplashImagePrefetchStatus
    let preparedImage: SplashPreparedImage?
    let validationFailure: SplashImageValidationFailure?
}

struct SplashImageDiskCache: Sendable {
    static let shared = SplashImageDiskCache()
    let directory: URL

    init(directory: URL = SplashImageDiskCache.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        SplashImageByteStore.defaultDirectory
    }

    static func cacheKey(assetID: String, version: String, imageURL: String) -> String? {
        let trimmedAssetID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return nil }
        if !trimmedAssetID.isEmpty {
            return "splash-asset-\(stableHashHex("\(trimmedAssetID)|\(trimmedVersion)"))"
        }
        guard !trimmedURL.isEmpty else { return nil }
        return "splash-url-\(stableHashHex("\(trimmedURL)|\(trimmedVersion)"))"
    }

    static func cacheKey(explicitKey: String) -> String? {
        let trimmedKey = explicitKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return "splash-explicit-\(stableHashHex(trimmedKey))"
    }

    static func cacheKey(
        scope: SplashTenantScope,
        assetID: String,
        version: String,
        imageURL: String
    ) -> String? {
        guard scope.isValid,
              let unscopedKey = cacheKey(assetID: assetID, version: version, imageURL: imageURL) else {
            return nil
        }
        return "splash-scoped-\(stableHashHex("\(scope.storageKey)|\(unscopedKey)"))"
    }

    static func cacheKey(scope: SplashTenantScope, explicitKey: String) -> String? {
        guard scope.isValid,
              let unscopedKey = cacheKey(explicitKey: explicitKey) else {
            return nil
        }
        return "splash-scoped-\(stableHashHex("\(scope.storageKey)|\(unscopedKey)"))"
    }

    func fileURL(for cacheKey: String) -> URL {
        directory.appendingPathComponent(cacheKey, isDirectory: false)
    }

    func containsImage(for cacheKey: String) -> Bool {
        let url = fileURL(for: cacheKey)
        guard let data = try? SplashImageByteStore.read(from: url), !data.isEmpty else { return false }
        if case .valid = SplashImageValidator.validate(data: data, fileURL: url) {
            return true
        }
        return false
    }

    func storeImageData(_ data: Data, cacheKey: String) -> Bool {
        let url = fileURL(for: cacheKey)
        guard case .valid = SplashImageValidator.validate(data: data, fileURL: url) else {
            return false
        }
        do {
            try SplashImageByteStore.write(data, to: url, in: directory)
            return true
        } catch {
            return false
        }
    }

    func prepareImage(
        from urlString: String,
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashImagePreparationResult {
        if let cachedImage = await validatedCachedImage(
            cacheKey: cacheKey,
            expectedSHA256: expectedSHA256,
            expectedSizeBytes: expectedSizeBytes,
            expectedMimeType: expectedMimeType,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        ) {
            return SplashImagePreparationResult(
                status: .cached,
                preparedImage: cachedImage,
                validationFailure: nil
            )
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              !cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SplashImagePreparationResult(
                status: .failed,
                preparedImage: nil,
                validationFailure: .emptyData
            )
        }
        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try SplashImageByteStore.read(from: url, mapped: true)
                }.value
            } else {
                let result = try await SplashImageByteStore.fetch(from: url)
                if let http = result.1 as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    return SplashImagePreparationResult(
                        status: .failed,
                        preparedImage: nil,
                        validationFailure: nil
                    )
                }
                data = result.0
            }
            return await validateAndStore(
                data,
                cacheKey: cacheKey,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        } catch {
            return SplashImagePreparationResult(
                status: .failed,
                preparedImage: nil,
                validationFailure: nil
            )
        }
    }

    func prefetchImage(from urlString: String, cacheKey: String) async -> SplashImagePrefetchStatus {
        await prepareImage(
            from: urlString,
            cacheKey: cacheKey,
            expectedSHA256: "",
            expectedSizeBytes: nil,
            expectedMimeType: "",
            expectedWidth: nil,
            expectedHeight: nil
        ).status
    }

    private func validatedCachedImage(
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashPreparedImage? {
        let fileURL = fileURL(for: cacheKey)
        return await Task.detached(priority: .utility) {
            guard let data = try? SplashImageByteStore.read(from: fileURL, mapped: true) else {
                return nil
            }
            switch SplashImageValidator.validate(
                data: data,
                fileURL: fileURL,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            ) {
            case .valid(let preparedImage):
                return preparedImage
            case .invalid:
                SplashImageByteStore.discardInvalidFile(at: fileURL)
                return nil
            }
        }.value
    }

    private func validateAndStore(
        _ data: Data,
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashImagePreparationResult {
        let directory = directory
        let fileURL = fileURL(for: cacheKey)
        return await Task.detached(priority: .utility) {
            let validation = SplashImageValidator.validate(
                data: data,
                fileURL: fileURL,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
            switch validation {
            case .valid(let preparedImage):
                do {
                    try SplashImageByteStore.write(data, to: fileURL, in: directory)
                    return SplashImagePreparationResult(
                        status: .downloaded,
                        preparedImage: preparedImage,
                        validationFailure: nil
                    )
                } catch {
                    return SplashImagePreparationResult(
                        status: .failed,
                        preparedImage: nil,
                        validationFailure: nil
                    )
                }
            case .invalid(let failure):
                SplashImageByteStore.discardInvalidFile(at: fileURL)
                return SplashImagePreparationResult(
                    status: .failed,
                    preparedImage: nil,
                    validationFailure: failure
                )
            }
        }.value
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
