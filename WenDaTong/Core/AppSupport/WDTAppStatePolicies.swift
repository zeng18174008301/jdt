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

enum GIFAttachmentUploadPolicy {
    static let maximumBytes: Int64 = 10 * 1024 * 1024
    static let invalidMessage = "GIF 图片格式无效，请重新选择"
    enum ValidationError: Error { case invalid, tooLarge }

    static func isDeclaredGIF(name: String, mimeType: String) -> Bool {
        mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image/gif"
            || (name as NSString).pathExtension.lowercased() == "gif"
    }

    // Unknown legacy/cross-client MIME can nominate a GIF, but is not proof of
    // its format. Playback must still validate GIF bytes in the actual decoder.
    // An explicit non-GIF MIME must never be overridden by a misleading name.
    static func isGIFCandidate(mimeType: String, name: String, fileExtension: String) -> Bool {
        let mime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime == "image/gif" { return true }
        guard mime.isEmpty || mime == "application/octet-stream" else { return false }
        return fileExtension.lowercased() == "gif" || (name as NSString).pathExtension.lowercased() == "gif"
    }

    static func allowsUpload(sizeBytes: Int64, config: FileUploadConfig) -> Bool {
        sizeBytes > 0 && sizeBytes <= min(maximumBytes, max(0, config.maxBytes))
    }

    static func overLimitMessage(config: FileUploadConfig) -> String {
        config.maxBytes < maximumBytes ? config.overLimitMessage : "GIF 图片不能超过 10 MB"
    }

    // Inspection never rewrites upload bytes. Native-rejected files may be read
    // into a bounded buffer for Wuffs structural inspection, not pixel decoding.
    static func isGIF(data: Data?, fileURL: URL?, name: String, mimeType: String, maximumAllowedBytes: Int64 = maximumBytes) throws -> Bool {
        let header: Data
        if let fileURL {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 6) ?? Data()
        } else {
            header = Data(data?.prefix(6) ?? Data())
        }
        let hasGIFHeader = header == Data("GIF87a".utf8) || header == Data("GIF89a".utf8)
        guard hasGIFHeader || isDeclaredGIF(name: name, mimeType: mimeType) else { return false }
        guard hasGIFHeader else { throw ValidationError.invalid }
        let actualBytes = fileURL.flatMap { PendingAttachmentFileStore.fileSize(at: $0) } ?? data.map { Int64($0.count) } ?? 0
        guard actualBytes > 0 else { throw ValidationError.invalid }
        guard actualBytes <= min(maximumBytes, max(0, maximumAllowedBytes)) else { throw ValidationError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        if let fileURL {
            source = CGImageSourceCreateWithURL(fileURL as CFURL, options)
        } else if let data {
            source = CGImageSourceCreateWithData(data as CFData, options)
        } else {
            source = nil
        }
        if let source,
              CGImageSourceGetType(source).map({ $0 as String }) == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 {
            return true
        }
        do {
            let bytes: Data
            if let fileURL {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                bytes = try handle.read(upToCount: Int(min(maximumBytes, max(0, maximumAllowedBytes))) + 1) ?? Data()
            } else {
                bytes = data ?? Data()
            }
            guard Int64(bytes.count) <= min(maximumBytes, max(0, maximumAllowedBytes)) else { throw ValidationError.tooLarge }
            _ = try StickerGIFFallbackDecoder.metadata(data: bytes)
        } catch StickerGIFResourceError.tooLarge {
            throw ValidationError.tooLarge
        } catch ValidationError.tooLarge {
            throw ValidationError.tooLarge
        } catch {
            throw ValidationError.invalid
        }
        return true
    }
}

enum RTCCapabilityMedia {
    case voice
    case video
    case generic
}

func rtcCapabilityFailureMessage(code: String, media: RTCCapabilityMedia) -> String? {
    let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
    let mediaName: String
    switch media {
    case .voice:
        mediaName = "语音通话"
    case .video:
        mediaName = "视频通话"
    case .generic:
        mediaName = "通话"
    }
    switch normalized {
    case "rtc_license_capabilities_unavailable":
        return "暂时无法确认\(mediaName)权限，请稍后重试"
    case "voice_call_not_enabled":
        return "该企业未开通语音通话"
    case "video_call_not_enabled":
        return "该企业未开通视频通话"
    case "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing":
        return "\(mediaName)媒体服务配置缺失，请联系管理员"
    default:
        return nil
    }
}

// Shared by login and registration so both UI paths enforce the same policy.
func isValidAuthAccountUsername(_ value: String) -> Bool {
    let normalized = AuthInputFilter.accountUsername.apply(to: value.trimmingCharacters(in: .whitespacesAndNewlines))
    return normalized == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && (5...10).contains(normalized.count)
}

enum AuthoritativeMessageSendPolicy {
    static func accepts(remoteMessageID: String) -> Bool {
        !remoteMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum FriendRemarkValidationError: LocalizedError, Equatable {
    case tooLong(max: Int)

    var errorDescription: String? {
        switch self {
        case .tooLong(let max):
            return "好友备注最多 \(max) 个字符"
        }
    }
}

enum FriendRemarkInputPolicy {
    static let maxUnicodeCodePoints = 128

    static func normalize(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.unicodeScalars.count <= maxUnicodeCodePoints else {
            throw FriendRemarkValidationError.tooLong(max: maxUnicodeCodePoints)
        }
        return normalized
    }

    static func unicodeCodePointCount(_ raw: String) -> Int {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    static func validationMessage(for raw: String) -> String? {
        do {
            _ = try normalize(raw)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "好友备注最多 \(maxUnicodeCodePoints) 个字符"
        }
    }
}

struct FriendRemarkSaveFailure: Equatable {
    enum Kind: Equatable {
        case validation
        case identity
        case unauthorized
        case forbidden
        case relationChanged
        case readbackPending
        case network
        case server
        case unexpected
    }

    let kind: Kind
    let message: String
}

enum FriendRemarkSaveResult: Equatable {
    case success
    case failure(FriendRemarkSaveFailure)
}

// WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112: FriendIdentityKey is defined by ContactStore.

struct AppCacheCleanupResult: Equatable, Sendable {
    let bytesRemoved: Int64
    let failures: [String]
}

enum AuthenticatedTenantContextBindingValidation: Equatable {
    case verified
    case incomplete
    case mismatch
}

enum AppCacheCleaner {
    private static let cacheDirectoryNames = [
        "BlueStoneIMAttachmentDownloads",
        "BlueStoneIMAttachmentThumbnails",
        "BlueStoneIMMediaPipeline",
        "BlueStoneIMSplashImages",
        "BlueStoneIMRemoteSnapshots"
    ]
    private static let temporaryDirectoryNames = [
        "BlueStoneIMFilePreviews",
        "BlueStoneIMPendingAttachments",
        "BlueStoneIMAttachmentDownloadStaging"
    ]

    static func clear(
        cacheBase: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        temporaryBase: URL = FileManager.default.temporaryDirectory
    ) async -> AppCacheCleanupResult {
        let roots = cacheDirectoryNames.compactMap { cacheBase?.appendingPathComponent($0, isDirectory: true) }
            + temporaryDirectoryNames.map { temporaryBase.appendingPathComponent($0, isDirectory: true) }
        return await Task.detached {
            let fileManager = FileManager()
            var removedBytes: Int64 = 0
            var failures: [String] = []
            for root in roots {
                guard fileManager.fileExists(atPath: root.path) else { continue }
                let size: Int64
                do {
                    size = try allocatedSize(of: root, fileManager: fileManager)
                } catch {
                    size = 0
                    failures.append("\(root.lastPathComponent)（大小统计）")
                }
                do {
                    try fileManager.removeItem(at: root)
                    removedBytes += size
                } catch {
                    failures.append(root.lastPathComponent)
                }
            }
            return AppCacheCleanupResult(bytesRemoved: removedBytes, failures: failures)
        }.value
    }

    private static func allocatedSize(of root: URL, fileManager: FileManager) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

struct BiometricProtectionSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var unlockChats: Bool
    var previewFiles: Bool

    static let disabled = BiometricProtectionSettings(
        enabled: false,
        unlockChats: true,
        previewFiles: true
    )
}

struct BiometricProtectionSettingsDraft: Equatable {
    var enabled: Bool
    var unlockChats: Bool
    var previewFiles: Bool
    private(set) var isUpdating = false

    init(settings: BiometricProtectionSettings) {
        enabled = settings.enabled
        unlockChats = settings.unlockChats
        previewFiles = settings.previewFiles
    }

    var settings: BiometricProtectionSettings {
        BiometricProtectionSettings(
            enabled: enabled,
            unlockChats: unlockChats,
            previewFiles: previewFiles
        )
    }

    func hasChanges(comparedTo persisted: BiometricProtectionSettings) -> Bool {
        settings != persisted
    }

    mutating func beginEnabledChange(to requestedEnabled: Bool) -> BiometricProtectionSettings? {
        guard !isUpdating, requestedEnabled != enabled else { return nil }
        isUpdating = true
        var requested = settings
        requested.enabled = requestedEnabled
        return requested
    }

    mutating func beginSave(comparedTo persisted: BiometricProtectionSettings) -> BiometricProtectionSettings? {
        guard !isUpdating, hasChanges(comparedTo: persisted) else { return nil }
        isUpdating = true
        return settings
    }

    mutating func finish(with authoritative: BiometricProtectionSettings) {
        enabled = authoritative.enabled
        unlockChats = authoritative.unlockChats
        previewFiles = authoritative.previewFiles
        isUpdating = false
    }

    mutating func synchronize(with authoritative: BiometricProtectionSettings) {
        guard !isUpdating else { return }
        finish(with: authoritative)
    }
}

enum BiometricProtectedSurface: Hashable, Sendable {
    case chat
    case filePreview

    var reason: String {
        switch self {
        case .chat: return "验证身份后查看会话"
        case .filePreview: return "验证身份后预览企业文件"
        }
    }
}

@MainActor
protocol LocalBiometricAuthenticating: Sendable {
    func authenticate(reason: String) async throws
}

@MainActor
final class SystemLocalBiometricAuthenticator: LocalBiometricAuthenticating, @unchecked Sendable {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        guard try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) else {
            throw LAError(.authenticationFailed)
        }
    }
}

enum BiometricProtectionStore {
    private static let keyPrefix = "wenxintong.ios.biometric-protection.v1"

    static func scopeKey(context: IMAPIContext) -> String {
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
        let account = [context.accountID, context.imUID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "prelogin"
        return "\(keyPrefix).\(appID).\(account.isEmpty ? "prelogin" : account)"
    }

    static func load(context: IMAPIContext, defaults: UserDefaults = .standard) -> BiometricProtectionSettings {
        guard let data = defaults.data(forKey: scopeKey(context: context)),
              let value = try? JSONDecoder().decode(BiometricProtectionSettings.self, from: data) else {
            return .disabled
        }
        return value
    }

    static func save(_ settings: BiometricProtectionSettings, context: IMAPIContext, defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: scopeKey(context: context))
    }
}
