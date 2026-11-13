import SwiftUI
import UIKit
import QuickLook
import AVFoundation

enum SystemPreviewLoader {
    static func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        try await SystemPreviewDownloadStore.shared.download(remoteURL, suggestedName: suggestedName, cacheIdentity: cacheIdentity)
    }

    static func discardTransient(_ url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
            .standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func purgeAllTransientFiles() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}

protocol SystemPreviewDownloading: Sendable {
    func download(from remoteURL: URL) async throws -> URL
}

struct SystemPreviewDownloadHTTPStatusError: MediaHTTPStatusProvidingError, Equatable {
    let statusCode: Int
    let requestURL: URL?
}

struct URLSessionSystemPreviewDownloader: SystemPreviewDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from remoteURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw SystemPreviewDownloadHTTPStatusError(
                statusCode: httpResponse.statusCode,
                requestURL: remoteURL
            )
        }
        return temporaryURL
    }
}

actor SystemPreviewDownloadStore {
    static let shared = SystemPreviewDownloadStore()

    private let downloader: any SystemPreviewDownloading
    private var inFlightDownloads: [String: Task<URL, Error>] = [:]

    init(downloader: any SystemPreviewDownloading = URLSessionSystemPreviewDownloader()) {
        self.downloader = downloader
    }

    func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        if remoteURL.isFileURL {
            return remoteURL
        }

        let stableIdentity = cacheIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stableIdentity.isEmpty else {
            return try await downloadToTransientPreview(remoteURL, suggestedName: suggestedName)
        }

        let cacheKey = Self.cacheKey(remoteURL: remoteURL, suggestedName: suggestedName, cacheIdentity: stableIdentity)

        if let task = inFlightDownloads[cacheKey] {
            let sharedURL = try await task.value
            return try Self.materializeConsumerCopy(from: sharedURL)
        }

        let downloader = self.downloader
        let task = Task<URL, Error> {
            let temporaryURL = try await downloader.download(from: remoteURL)
            let destination = Self.destinationURL(remoteURL: remoteURL, suggestedName: suggestedName, cacheIdentity: stableIdentity)
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            return destination
        }

        inFlightDownloads[cacheKey] = task
        do {
            let localURL = try await task.value
            inFlightDownloads[cacheKey] = nil
            return try Self.materializeConsumerCopy(from: localURL)
        } catch {
            inFlightDownloads[cacheKey] = nil
            throw error
        }
    }

    private func downloadToTransientPreview(_ remoteURL: URL, suggestedName: String) async throws -> URL {
        let temporaryURL = try await downloader.download(from: remoteURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let directory = root.appendingPathComponent("transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            Self.sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension),
            isDirectory: false
        )
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func destinationURL(remoteURL: URL, suggestedName: String, cacheIdentity: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let directory = root
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent(stableHash(cacheIdentity), isDirectory: true)
        let fileName = sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func materializeConsumerCopy(from sharedURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
            .appendingPathComponent("consumer-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        let destination = directory.appendingPathComponent(sharedURL.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: sharedURL, to: destination)
        return destination
    }

    private static func cacheKey(remoteURL: URL, suggestedName: String, cacheIdentity: String) -> String {
        "\(cacheIdentity)|\(sanitizedFileName(suggestedName, fallbackExtension: remoteURL.pathExtension))"
    }

    private static func stableHash(_ value: String) -> String {
        MediaResourceIdentity.stableHash(value)
    }

    private static func sanitizedFileName(_ rawValue: String, fallbackExtension: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "preview-file" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.contains(".") || fallbackExtension.isEmpty {
            return sanitized.isEmpty ? "preview-file" : sanitized
        }
        return "\(sanitized).\(fallbackExtension)"
    }
}
