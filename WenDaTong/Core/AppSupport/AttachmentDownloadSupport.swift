import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

extension URL {
    var usableLocalFileURL: URL? {
        guard isFileURL,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return self
    }
}


enum AttachmentDownloadCachePolicy {
    static func legacyRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("BlueStoneIMAttachmentDownloads", isDirectory: true)
    }

    static func destinationURL(remoteURL: URL?, suggestedName: String, cacheKey: String, fallbackExtension: String) throws -> URL {
        let root = try legacyRootURL()
        let remoteKey = remoteURL?.absoluteString ?? UUID().uuidString
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remoteKey : cacheKey
        let directory = root.appendingPathComponent(stableHash(stableKey), isDirectory: true)
        let resolvedFallbackExtension = fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (remoteURL?.pathExtension ?? "")
            : fallbackExtension
        return directory.appendingPathComponent(sanitizedFileName(suggestedName, fallbackExtension: resolvedFallbackExtension), isDirectory: false)
    }

    static func canReuseCachedDownload(at url: URL, expectedSizeBytes: Int64?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { return false }
        if let expectedSizeBytes, expectedSizeBytes > 0 {
            return fileSize == expectedSizeBytes
        }
        return true
    }

    static func stagingURL(suggestedName: String, fallbackExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMAttachmentDownloadStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory.appendingPathComponent(
            sanitizedFileName(suggestedName, fallbackExtension: fallbackExtension),
            isDirectory: false
        )
    }

    static func purgeTransientStaging() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMAttachmentDownloadStaging", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    static func legacyCandidateURLs(fileManager: FileManager = .default) -> [URL] {
        guard let root = try? legacyRootURL(fileManager: fileManager),
              fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard result.count < 10_000,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(url)
        }
        return result
    }

    static func purgeLegacyDownloads(fileManager: FileManager = .default) {
        guard let root = try? legacyRootURL(fileManager: fileManager),
              fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func sanitizedFileName(_ rawValue: String, fallbackExtension: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment-file" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.contains(".") || fallbackExtension.isEmpty {
            return sanitized.isEmpty ? "attachment-file" : sanitized
        }
        return "\(sanitized).\(fallbackExtension)"
    }
}

typealias AttachmentDownloadSessionFactory = @Sendable (_ delegate: any URLSessionDownloadDelegate) -> URLSession

struct AttachmentDownloadHTTPStatusError: MediaHTTPStatusProvidingError, Equatable {
    let statusCode: Int
    let requestURL: URL?
}

// JHT_MOD_BEGIN ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改开始：附件下载执行从 AppState/MainActor 抽到 support executor
enum AttachmentDownloadExecutor {
    static func temporaryFile(
        remoteURL: URL,
        suggestedName: String,
        cacheKey: String,
        fallbackExtension: String,
        expectedSizeBytes: Int64?,
        sessionFactory: @escaping AttachmentDownloadSessionFactory,
        byteProgress: @escaping @Sendable (AttachmentDownloadSnapshot) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = AttachmentDownloadProgressDelegate(
            suggestedName: suggestedName,
            cacheKey: cacheKey,
            fallbackExtension: fallbackExtension,
            expectedSizeBytes: expectedSizeBytes,
            sessionFactory: sessionFactory,
            byteProgress: byteProgress,
            progress: progress
        )
        return try await downloader.start(remoteURL: remoteURL)
    }
}
// JHT_MOD_END ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改结束

final class AttachmentDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let suggestedName: String
    private let cacheKey: String
    private let fallbackExtension: String
    private let expectedSizeBytes: Int64?
    private let progress: @Sendable (Double) -> Void
    private let byteProgress: @Sendable (AttachmentDownloadSnapshot) -> Void
    private let sessionFactory: AttachmentDownloadSessionFactory
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var didFinish = false
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_STATE - 修改开始：下载回调进度节流状态，减少图片下载时主线程进度任务堆积
    private var lastByteProgressEmissionAt: TimeInterval?
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_STATE - 修改结束：下载回调进度节流状态，减少图片下载时主线程进度任务堆积

    init(
        suggestedName: String,
        cacheKey: String,
        fallbackExtension: String,
        expectedSizeBytes: Int64?,
        sessionFactory: @escaping AttachmentDownloadSessionFactory = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        },
        byteProgress: @escaping @Sendable (AttachmentDownloadSnapshot) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.suggestedName = suggestedName
        self.cacheKey = cacheKey
        self.fallbackExtension = fallbackExtension
        self.expectedSizeBytes = expectedSizeBytes
        self.sessionFactory = sessionFactory
        self.progress = progress
        self.byteProgress = byteProgress
    }

    func start(remoteURL: URL) async throws -> URL {
        if remoteURL.isFileURL {
            progress(1)
            return remoteURL
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = sessionFactory(self)
                let task = session.downloadTask(with: remoteURL)
                self.session = session
                self.task = task
                lock.unlock()
                progress(0)
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        session?.invalidateAndCancel()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // WDT_APP_CONTRACT_20261021_10: unknown length emits bytes, never a fabricated percentage.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSizeBytes
        let snapshot = AttachmentDownloadSnapshot(receivedBytes: totalBytesWritten, totalBytes: total)
        let fraction = total.flatMap { $0 > 0 ? Double(totalBytesWritten) / Double($0) : nil }
        guard shouldEmitByteProgress() else { return }
        byteProgress(snapshot)
        if let fraction { progress(max(0, min(fraction, 1))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let httpResponse = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw AttachmentDownloadHTTPStatusError(
                    statusCode: httpResponse.statusCode,
                    requestURL: downloadTask.originalRequest?.url
                )
            }
            let destination = try AttachmentDownloadCachePolicy.stagingURL(
                suggestedName: suggestedName,
                fallbackExtension: fallbackExtension
            )
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: location, to: destination)
            guard AttachmentDownloadCachePolicy.canReuseCachedDownload(at: destination, expectedSizeBytes: expectedSizeBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            progress(1)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    private func shouldEmitByteProgress() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        // Byte updates reach the main actor. A fast transfer must still honor
        // the interval, even when each callback advances several percent.
        if let lastByteProgressEmissionAt, now - lastByteProgressEmissionAt < 0.12 { return false }
        lastByteProgressEmissionAt = now
        return true
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

}
