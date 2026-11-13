import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

@MainActor
protocol IOSNotificationCenterManaging: AnyObject {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: IOSNotificationCenterManaging {}

enum IOSNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var permitsRemoteNotificationRegistration: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}

enum IOSNotificationAuthorizationAction: Equatable, Sendable {
    case requestAuthorization
    case registerRemoteNotifications
    case none
}

enum IOSNotificationAuthorizationPolicy {
    static func action(
        status: IOSNotificationAuthorizationStatus,
        didRequestThisProcess: Bool
    ) -> IOSNotificationAuthorizationAction {
        switch status {
        case .notDetermined:
            return didRequestThisProcess ? .none : .requestAuthorization
        case .authorized, .provisional, .ephemeral:
            return .registerRemoteNotifications
        case .denied, .unknown:
            return .none
        }
    }
}

@MainActor
protocol IOSNotificationAuthorizationManaging: AnyObject {
    func authorizationStatus() async -> IOSNotificationAuthorizationStatus
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
}

@MainActor
final class IOSSystemNotificationAuthorizationManager: IOSNotificationAuthorizationManaging {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> IOSNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class IOSNotificationPermissionCoordinator {
    static let shared = IOSNotificationPermissionCoordinator()

    private let manager: IOSNotificationAuthorizationManaging
    private var didRequestAuthorizationThisProcess = false
    private var isResolving = false
    private(set) var latestStatus: IOSNotificationAuthorizationStatus = .unknown

    init(manager: IOSNotificationAuthorizationManaging = IOSSystemNotificationAuthorizationManager()) {
        self.manager = manager
    }

    func currentStatus() async -> IOSNotificationAuthorizationStatus {
        let status = await manager.authorizationStatus()
        latestStatus = status
        return status
    }

    @discardableResult
    func sceneDidBecomeActive() async -> IOSNotificationAuthorizationStatus {
        await resolvePermissionIfNeeded()
    }

    @discardableResult
    func requestFromUserGestureIfNeeded() async -> IOSNotificationAuthorizationStatus {
        await resolvePermissionIfNeeded()
    }

    private func resolvePermissionIfNeeded() async -> IOSNotificationAuthorizationStatus {
        guard !isResolving else { return latestStatus }
        isResolving = true
        defer { isResolving = false }

        var status = await manager.authorizationStatus()
        latestStatus = status
        switch IOSNotificationAuthorizationPolicy.action(
            status: status,
            didRequestThisProcess: didRequestAuthorizationThisProcess
        ) {
        case .requestAuthorization:
            didRequestAuthorizationThisProcess = true
            _ = await manager.requestAuthorization()
            status = await manager.authorizationStatus()
            latestStatus = status
            if status.permitsRemoteNotificationRegistration {
                manager.registerForRemoteNotifications()
            }
        case .registerRemoteNotifications:
            manager.registerForRemoteNotifications()
        case .none:
            break
        }
        return status
    }
}
