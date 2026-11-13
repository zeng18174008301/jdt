import CryptoKit
import Foundation

enum MediaPipelineCore {
    static func identity(
        kind: MediaResourceKind,
        scope: String = "",
        fileID: String = "",
        attachmentID: String = "",
        mediaID: String = "",
        cacheKey: String = "",
        version: String = "",
        checksumSHA256: String = "",
        createdAt: String = "",
        variant: MediaCacheVariant? = nil,
        mimeType: String = "",
        sizeBytes: Int64? = nil
    ) -> MediaResourceIdentity {
        MediaResourceIdentity(
            resourceKind: kind,
            scope: scope,
            fileID: fileID,
            attachmentID: attachmentID,
            mediaID: mediaID,
            cacheKey: cacheKey,
            version: version,
            checksumSHA256: checksumSHA256,
            createdAt: createdAt,
            variant: variant,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
    }

    static func shouldRefreshSignature(expiresAt: Date?, now: Date = Date(), policy: MediaCachePolicy) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= policy.signatureRefreshLeadTime
    }

    static func cacheFileURL(
        for identity: MediaResourceIdentity,
        in rootDirectory: URL,
        preferredExtension: String = ""
    ) -> URL {
        identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
    }
}

// Server video posters have their own content identity, independent of playback URLs.
struct IOSServerVideoPosterStatus: Codable, Sendable {
    enum State: String, Codable, Sendable { case none, pending, ready, failed, skipped }
    let fileID: String
    let checksum: String
    let sourceChecksum: String
    let state: State
    let posterID: String?
    let posterChecksum: String?
    let version: String?
    let mime: String?
    let size: Int64?
    let width: Int?
    let height: Int?
    enum CodingKeys: String, CodingKey {
        case fileID = "file_id", checksum = "checksum_sha256", sourceChecksum = "poster_source_checksum"
        case state = "thumbnail_status", posterID = "poster_file_id", posterChecksum = "poster_checksum"
        case version = "thumbnail_version", mime = "poster_mime_type", size = "poster_size_bytes"
        case width = "poster_width", height = "poster_height"
    }
    func validate(parentID: String, expectedChecksum: String) throws {
        let sha = checksum.lowercased()
        guard fileID == parentID, !parentID.isEmpty, parentID.count <= 256,
              parentID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              MediaFileIntegrityAuthority.normalizedSHA256(sha) == sha, !sha.isEmpty,
              sourceChecksum.lowercased() == sha,
              expectedChecksum.isEmpty || expectedChecksum.lowercased() == sha else {
            throw IOSServerVideoPosterError.invalidBinding
        }
        guard state == .ready else { return }
        guard let posterID, !posterID.isEmpty, posterID != parentID, posterID.count <= 256,
              !posterID.contains(where: { $0.isWhitespace || "/\\?#%".contains($0) }),
              let posterChecksum, !posterChecksum.isEmpty,
              MediaFileIntegrityAuthority.normalizedSHA256(posterChecksum.lowercased()) == posterChecksum.lowercased(),
              version?.lowercased() == posterChecksum.lowercased(), mime?.lowercased() == "image/jpeg",
              let size, (1...1_048_576).contains(size),
              let width, let height, (1...640).contains(width), (1...640).contains(height) else {
            throw IOSServerVideoPosterError.invalidBinding
        }
    }
    func metadata(scope: String) -> MediaResourceMetadata {
        let resource = ["server-video-poster", fileID, checksum.lowercased(), posterID ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return MediaResourceMetadata(scope: scope, fileID: resource, version: version?.lowercased() ?? "",
            mimeType: "image/jpeg", sizeBytes: size, fileExtension: "jpg",
            thumbnailVersion: version?.lowercased() ?? "", thumbnailMimeType: "image/jpeg", thumbnailExtension: "jpg")
    }
}

enum IOSServerVideoPosterError: Error { case invalidBinding, invalidBytes, http(Int, String?, Int?) }

// A validated receipt locates the existing indexed thumbnail without making a status request.
// The media index still owns file integrity, message authority and offline expiry.
actor IOSServerVideoPosterReceiptStore {
    static let shared = IOSServerVideoPosterReceiptStore()
    private struct Receipt: Codable {
        let status: IOSServerVideoPosterStatus
        let sourceVersion: String
    }
    private func location(root: URL, parentID: String) -> URL {
        let name = SHA256.hash(data: Data(parentID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("poster-receipts", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func load(root: URL, parentID: String, checksum: String, sourceVersion: String) -> IOSServerVideoPosterStatus? {
        let url = location(root: root, parentID: parentID)
        guard let data = try? Data(contentsOf: url), data.count <= 16_384,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.status.state == .ready,
              receipt.sourceVersion.isEmpty || sourceVersion.isEmpty || receipt.sourceVersion == sourceVersion,
              (try? receipt.status.validate(parentID: parentID, expectedChecksum: checksum)) != nil else { return nil }
        return receipt.status
    }
    func save(_ status: IOSServerVideoPosterStatus, root: URL, sourceVersion: String) {
        guard status.state == .ready, (try? status.validate(parentID: status.fileID, expectedChecksum: status.checksum)) != nil else { return }
        let url = location(root: root, parentID: status.fileID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Receipt(status: status, sourceVersion: sourceVersion)).write(to: url, options: .atomic)
        } catch {
            // A missing receipt only causes a future status refresh; it must not hide a committed cover.
        }
    }
}

enum IOSVideoPosterPresentation: Equatable {
    case ready(URL), pending, missing, failed, limited, unavailable
}

actor IOSServerVideoPosterBudget {
    static let shared = IOSServerVideoPosterBudget()
    private var attempts: [String: [TimeInterval]] = [:]
    private var cooldowns: [String: TimeInterval] = [:]
    func reserve(_ key: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        attempts = attempts.mapValues { $0.filter { now - $0 < 60 } }.filter { !$0.value.isEmpty }
        cooldowns = cooldowns.filter { $0.value > now }
        guard cooldowns[key] == nil, attempts[key, default: []].count < 5 else { return false }
        attempts[key, default: []].append(now)
        return true
    }
    func deferRetry(_ key: String, seconds: Int) {
        cooldowns[key] = ProcessInfo.processInfo.systemUptime + Double(max(1, seconds))
    }
}
