import Foundation
import UIKit

enum SplashImagePrefetchStatus: String, Codable, Hashable, Sendable {
    case pending
    case cached
    case downloaded
    case failed
    case skipped
}

struct SplashTenantScope: Hashable, Sendable {
    let appID: String
    let accountID: String
    let tenantID: String
    let tenantOrigin: String

    init(appID: String, accountID: String, tenantID: String, tenantOrigin: String) {
        self.appID = Self.normalize(appID)
        self.accountID = Self.normalize(accountID)
        self.tenantID = Self.normalize(tenantID)
        self.tenantOrigin = Self.normalizedTenantAPIOrigin(tenantOrigin)
    }

    var isValid: Bool {
        !appID.isEmpty && !accountID.isEmpty && !tenantID.isEmpty && !tenantOrigin.isEmpty
    }

    var storageKey: String {
        [appID, accountID, tenantID, tenantOrigin]
            .map(Self.storageComponent)
            .joined(separator: ".")
    }

    static func normalizedTenantAPIOrigin(_ rawValue: String) -> String {
        let trimmed = normalize(rawValue)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            return ""
        }

        let host = rawHost.lowercased()
        let renderedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        var path = components.percentEncodedPath
        if path.isEmpty || path == "/" {
            path = ""
        } else {
            if !path.hasPrefix("/") {
                path = "/" + path
            }
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
        }
        return "\(scheme)://\(renderedHost):\(port)\(path)"
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storageComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct SplashConfigSnapshot: Codable, Hashable, Sendable {
    static let defaultMinIntervalSec = 14_400
    static let defaultDailyCap = 3
    static let defaultMinShowMS = 1_200
    static let defaultMaxShowMS = 3_000

    let tenantID: String
    let licenseEnabled: Bool
    let splashEnabled: Bool
    let assetID: String
    let imageURL: String
    let version: String
    let cacheKeyOverride: String?
    let width: Int?
    let height: Int?
    let mimeType: String
    let sizeBytes: Int64?
    let etag: String
    let sha256: String
    let minIntervalSec: Int?
    let dailyCap: Int?
    let minShowMS: Int?
    let maxShowMS: Int?
    let actionURL: String
    let fetchedAt: TimeInterval
    let disabledReason: String
    let prefetchStatus: SplashImagePrefetchStatus
    let lastPrefetchAt: TimeInterval?
    let lastPrefetchError: String

    var cacheKey: String? {
        if let cacheKeyOverride = cacheKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cacheKeyOverride.isEmpty {
            return SplashImageDiskCache.cacheKey(explicitKey: cacheKeyOverride)
        }
        return SplashImageDiskCache.cacheKey(assetID: assetID, version: version, imageURL: imageURL)
    }

    func cacheKey(scope: SplashTenantScope) -> String? {
        guard scope.isValid, scope.tenantID == tenantID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if let cacheKeyOverride = cacheKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cacheKeyOverride.isEmpty {
            return SplashImageDiskCache.cacheKey(scope: scope, explicitKey: cacheKeyOverride)
        }
        return SplashImageDiskCache.cacheKey(
            scope: scope,
            assetID: assetID,
            version: version,
            imageURL: imageURL
        )
    }

    var normalizedVersion: String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedMinIntervalSec: Int {
        max(0, minIntervalSec ?? Self.defaultMinIntervalSec)
    }

    var resolvedDailyCap: Int {
        max(0, dailyCap ?? Self.defaultDailyCap)
    }

    var resolvedMinShowMS: Int {
        max(0, minShowMS ?? Self.defaultMinShowMS)
    }

    var resolvedMaxShowMS: Int {
        max(500, max(resolvedMinShowMS, maxShowMS ?? Self.defaultMaxShowMS))
    }

    var isConfigDisplayable: Bool {
        licenseEnabled
            && splashEnabled
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && disabledReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isDisplayable(now: Date = Date(), cache: SplashImageDiskCache = .shared) -> Bool {
        guard isConfigDisplayable,
              let cacheKey else {
            return false
        }
        return cache.containsImage(for: cacheKey)
    }

    func isDisplayable(
        scope: SplashTenantScope,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared
    ) -> Bool {
        guard isConfigDisplayable,
              let cacheKey = cacheKey(scope: scope) else {
            return false
        }
        return cache.containsImage(for: cacheKey)
    }

    func withPrefetch(status: SplashImagePrefetchStatus, error: String = "", at date: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: licenseEnabled,
            splashEnabled: splashEnabled,
            assetID: assetID,
            imageURL: imageURL,
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: fetchedAt,
            disabledReason: disabledReason,
            prefetchStatus: status,
            lastPrefetchAt: date.timeIntervalSince1970,
            lastPrefetchError: error
        )
    }

    func disabled(reason: String, at date: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: false,
            splashEnabled: false,
            assetID: assetID,
            imageURL: imageURL,
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: date.timeIntervalSince1970,
            disabledReason: reason,
            prefetchStatus: .skipped,
            lastPrefetchAt: lastPrefetchAt,
            lastPrefetchError: lastPrefetchError
        )
    }
}

struct SplashRefreshCandidate: Equatable, Sendable {
    let generation: Int
    let scope: SplashTenantScope
    let version: String
    let cacheKey: String

    init?(
        generation: Int,
        scope: SplashTenantScope,
        snapshot: SplashConfigSnapshot
    ) {
        guard generation > 0,
              scope.isValid,
              snapshot.isConfigDisplayable,
              !snapshot.normalizedVersion.isEmpty,
              let cacheKey = snapshot.cacheKey(scope: scope) else {
            return nil
        }
        self.generation = generation
        self.scope = scope
        version = snapshot.normalizedVersion
        self.cacheKey = cacheKey
    }

    func matches(
        currentGeneration: Int,
        currentScope: SplashTenantScope?,
        snapshot: SplashConfigSnapshot?
    ) -> Bool {
        guard generation == currentGeneration,
              scope == currentScope,
              let snapshot,
              snapshot.normalizedVersion == version,
              snapshot.cacheKey(scope: scope) == cacheKey else {
            return false
        }
        return true
    }
}

struct SplashDisplayState: Codable, Hashable, Sendable {
    var lastShownAt: TimeInterval?
    var lastShownVersion: String
    var shownVersions: [String]
    var todayCount: Int
    var todayDate: String
    var lastBackgroundedAt: TimeInterval?

    static let empty = SplashDisplayState(
        lastShownAt: nil,
        lastShownVersion: "",
        shownVersions: [],
        todayCount: 0,
        todayDate: "",
        lastBackgroundedAt: nil
    )

    func normalizedForDay(_ date: Date) -> SplashDisplayState {
        let today = Self.dayKey(for: date)
        guard todayDate != today else { return self }
        var next = self
        next.todayDate = today
        next.todayCount = 0
        return next
    }

    func canPresent(
        snapshot: SplashConfigSnapshot,
        at date: Date = Date(),
        isColdStartLike: Bool,
        alreadyShownInThisLaunch: Bool
    ) -> Bool {
        guard isColdStartLike,
              !alreadyShownInThisLaunch,
              snapshot.isConfigDisplayable else {
            return false
        }
        let version = snapshot.normalizedVersion
        guard !version.isEmpty else { return false }
        return true
    }

    func recordingShown(snapshot: SplashConfigSnapshot, at date: Date = Date()) -> SplashDisplayState {
        var next = normalizedForDay(date)
        let version = snapshot.normalizedVersion
        next.lastShownAt = date.timeIntervalSince1970
        next.lastShownVersion = version
        if !version.isEmpty, !next.shownVersions.contains(version) {
            next.shownVersions.append(version)
            if next.shownVersions.count > 40 {
                next.shownVersions.removeFirst(next.shownVersions.count - 40)
            }
        }
        next.todayCount += 1
        return next
    }

    func recordingBackgrounded(at date: Date = Date()) -> SplashDisplayState {
        var next = normalizedForDay(date)
        next.lastBackgroundedAt = date.timeIntervalSince1970
        return next
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

enum SplashOverlayEvaluationResult: Equatable, Sendable {
    case shown
    case notReadyNoSnapshot
    case notReadyNoCache
    case imageDecodeFailed
    case launchSplashActive
    case notColdStartLike
    case notAuthenticated
    case noSession
    case noTenant
    case overlayAlreadyActive
    case blockedByPolicy(String)

    var reason: String {
        switch self {
        case .shown:
            return "shown"
        case .notReadyNoSnapshot:
            return "not_ready_no_snapshot"
        case .notReadyNoCache:
            return "not_ready_no_cache"
        case .imageDecodeFailed:
            return "image_decode_failed"
        case .launchSplashActive:
            return "launch_splash_active"
        case .notColdStartLike:
            return "not_cold_start_like"
        case .notAuthenticated:
            return "not_authenticated"
        case .noSession:
            return "no_session"
        case .noTenant:
            return "no_tenant"
        case .overlayAlreadyActive:
            return "overlay_already_active"
        case .blockedByPolicy(let reason):
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "blocked_by_policy" : "blocked_by_policy_\(normalized)"
        }
    }

    var keepsInitialEvaluationPending: Bool {
        switch self {
        case .notReadyNoSnapshot, .notReadyNoCache, .imageDecodeFailed, .launchSplashActive, .notAuthenticated, .noSession, .noTenant:
            return true
        case .shown, .notColdStartLike, .overlayAlreadyActive, .blockedByPolicy:
            return false
        }
    }
}

struct SplashOverlayPresentation: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let tenantID: String
    let version: String
    let imageFileURL: URL
    let image: UIImage
    let minShowMS: Int
    let maxShowMS: Int
    let startedAt: TimeInterval

    init(snapshot: SplashConfigSnapshot, preparedImage: SplashPreparedImage, startedAt: Date = Date()) {
        tenantID = snapshot.tenantID
        version = snapshot.normalizedVersion
        imageFileURL = preparedImage.fileURL
        image = preparedImage.image
        minShowMS = snapshot.resolvedMinShowMS
        maxShowMS = snapshot.resolvedMaxShowMS
        self.startedAt = startedAt.timeIntervalSince1970
        id = "\(snapshot.tenantID)|\(snapshot.normalizedVersion)|\(Int(startedAt.timeIntervalSince1970 * 1000))"
    }

    func canSkip(at date: Date = Date()) -> Bool {
        canSkipSplash(startedAt: startedAt, minShowMS: minShowMS, now: date)
    }

    static func == (lhs: SplashOverlayPresentation, rhs: SplashOverlayPresentation) -> Bool {
        lhs.id == rhs.id
            && lhs.tenantID == rhs.tenantID
            && lhs.version == rhs.version
            && lhs.imageFileURL == rhs.imageFileURL
            && lhs.minShowMS == rhs.minShowMS
            && lhs.maxShowMS == rhs.maxShowMS
            && lhs.startedAt == rhs.startedAt
    }
}

func canPresentColdLaunchSplash(
    hasMainShellBecomeInteractive: Bool
) -> Bool {
    !hasMainShellBecomeInteractive
}

func canSkipSplash(
    startedAt: TimeInterval,
    minShowMS: Int,
    now: Date = Date()
) -> Bool {
    let elapsedMS = max(0, Int((now.timeIntervalSince1970 - startedAt) * 1_000))
    return elapsedMS >= max(0, minShowMS)
}

struct SplashImageCoverLayout: Equatable, Sendable {
    let renderedSize: CGSize

    static func layout(imageSize: CGSize, containerSize: CGSize) -> SplashImageCoverLayout {
        let containerWidth = max(containerSize.width, 0)
        let containerHeight = max(containerSize.height, 0)
        guard containerWidth > 0, containerHeight > 0 else {
            return SplashImageCoverLayout(renderedSize: .zero)
        }

        let imageWidth = max(imageSize.width, 1)
        let imageHeight = max(imageSize.height, 1)
        let scale = max(containerWidth / imageWidth, containerHeight / imageHeight)
        return SplashImageCoverLayout(renderedSize: CGSize(
            width: imageWidth * scale,
            height: imageHeight * scale
        ))
    }
}
