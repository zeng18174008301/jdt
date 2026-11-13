// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain

public struct ContactDirectoryRowInput: Identifiable, Equatable {
    public let id: String
    let userRevision: UInt64
    public let displayName: String
    public let userNumber: String?
    public let departmentSummary: String?
    public let certification: ConversationCertificationInput?
    public let accessibilityLabel: String
    public let avatarIsCancelled: Bool
    public let avatarSeed: UInt
    public init(id: String, userRevision: UInt64, displayName: String, userNumber: String?, departmentSummary: String?,
                certification: ConversationCertificationInput?, accessibilityLabel: String, avatarIsCancelled: Bool, avatarSeed: UInt) {
        self.id = id
        self.userRevision = userRevision
        self.displayName = displayName
        self.userNumber = userNumber
        self.departmentSummary = departmentSummary
        self.certification = certification; self.accessibilityLabel = accessibilityLabel; self.avatarIsCancelled = avatarIsCancelled
        self.avatarSeed = avatarSeed
    }
}
public struct ContactDirectoryGroupInput: Identifiable, Equatable {
    public let letter: String
    public let rows: [ContactDirectoryRowInput]
    public var id: String { letter }
    public init(letter: String, rows: [ContactDirectoryRowInput]) { self.letter = letter; self.rows = rows }
}
public enum ContactDirectoryStatus: Equatable { case loading, empty, failed(String) }
public struct ContactDirectoryHeaderRevision: Equatable {
    public let showsTabs: Bool
    public let requests: Int
    public let groups: Int
    public let blacklist: Int
    public let status: ContactDirectoryStatus?
    public init(showsTabs: Bool, requests: Int, groups: Int, blacklist: Int, status: ContactDirectoryStatus?) {
        self.showsTabs = showsTabs; self.requests = requests; self.groups = groups; self.blacklist = blacklist; self.status = status
    }
}
/// Specific image SDK adapter; authorization and cache/request policy remain in the App implementation.
@MainActor public struct ContactDirectoryAvatarRendering {
    let cached: (Int) -> UIImage?
    let loadImage: (Int) async -> UIImage?
    let authorized: () -> Bool
    public init(cachedImage: @escaping (Int) -> UIImage?, load: @escaping (Int) async -> UIImage?, isAuthorized: @escaping () -> Bool) {
        cached = cachedImage; loadImage = load; authorized = isAuthorized
    }
    func cachedImage(maxPixelSize: Int) -> UIImage? { cached(maxPixelSize) }
    func load(maxPixelSize: Int) async -> UIImage? { await loadImage(maxPixelSize) }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
