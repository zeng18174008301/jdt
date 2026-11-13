// WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111_BEGIN
import Foundation
import ImageIO

public enum MediaDownloadByteTransfer {
    public static func fetch(_ request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public static func install(_ data: Data, at destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("media-download-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}

public struct RemoteImageTransportResult: Sendable {
    public let data: Data
    public let statusCode: Int?

    public init(data: Data, statusCode: Int?) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol RemoteImageTransporting: Sendable {
    func data(from url: URL) async throws -> RemoteImageTransportResult
}

public struct URLSessionRemoteImageTransport: RemoteImageTransporting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> RemoteImageTransportResult {
        // WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
        // Download compressed bytes to a temporary file instead of buffering an unbounded response in RAM.
        let (fileURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return RemoteImageTransportResult(
            data: try RemoteImageFile.previewData(fromFileURL: fileURL),
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
        // WDT_IOS1_IMAGE_BUDGET_20261023_END
    }
}

public enum RemoteImageDataURLDecoder {
    public static func data(from value: String) -> Data? {
        guard value.prefix(5).lowercased() == "data:",
              let separator = value.firstIndex(of: ",") else { return nil }
        let metadata = value[value.index(value.startIndex, offsetBy: 5)..<separator]
        let payload = value[value.index(after: separator)...]
        let limit = RemoteImageFile.maximumEncodedByteCount
        if metadata.lowercased().split(separator: ";").contains("base64") {
            guard payload.utf8.count <= ((limit + 2) / 3) * 4,
                  let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
                  data.count <= limit else { return nil }
            return data
        }
        guard payload.utf8.count <= limit * 3,
              let decoded = String(payload).removingPercentEncoding,
              decoded.utf8.count <= limit else { return nil }
        return Data(decoded.utf8)
    }
}

public enum RemoteImageFile {
    public static let maximumEncodedByteCount = 32 * 1024 * 1024

    public nonisolated static func previewData(fromFileURL url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= maximumEncodedByteCount else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumEncodedByteCount else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    public nonisolated static func pixelSize(fromFileURL url: URL) -> CGSize? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = CGFloat(rawWidth.doubleValue)
        let height = CGFloat(rawHeight.doubleValue)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
// WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111_END
