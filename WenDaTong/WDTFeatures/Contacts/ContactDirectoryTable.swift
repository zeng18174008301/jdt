// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Features

extension ContactDirectoryRowPresentation {
    func featureInput(userRevision: UInt64 = 0) -> ContactDirectoryRowInput {
        ContactDirectoryRowInput(id: id, userRevision: userRevision, displayName: displayName, userNumber: userNumber, departmentSummary: departmentSummary,
            certification: certification.map { ConversationCertificationInput(visibleLabel: $0.visibleLabel,
                accessibilityLabel: $0.accessibilityLabel, styleToken: $0.styleToken, revision: $0.revision, generation: $0.generation) },
            accessibilityLabel: accessibilityLabel,
            avatarIsCancelled: user.isCancelledUser || isCancelledUserAvatarURL(user.displayAvatarURL), avatarSeed: user.avatarSeed)
    }
}
struct ContactDirectoryTableProjection {
    let groups: [ContactDirectoryGroup]
    let inputs: [ContactDirectoryGroupInput]
    let rowsByID: [String: ContactDirectoryRowPresentation]

    private let revisionsByID: [String: UInt64]
    private let lastRevision: UInt64

    init(groups: [ContactDirectoryGroup], previous: ContactDirectoryTableProjection? = nil) {
        self.groups = groups
        var revision = previous?.lastRevision ?? 0
        var revisions: [String: UInt64] = [:]
        var rows: [String: ContactDirectoryRowPresentation] = [:]
        inputs = groups.map { group in
            ContactDirectoryGroupInput(letter: group.letter, rows: group.rows.map { row in
                if let existing = revisions[row.id] {
                    return row.featureInput(userRevision: existing)
                }
                rows[row.id] = row
                let rowRevision: UInt64
                if previous?.rowsByID[row.id]?.user == row.user, let unchanged = previous?.revisionsByID[row.id] {
                    rowRevision = unchanged
                } else {
                    revision &+= 1
                    rowRevision = revision
                }
                revisions[row.id] = rowRevision
                return row.featureInput(userRevision: rowRevision)
            })
        }
        rowsByID = rows
        revisionsByID = revisions
        lastRevision = revision
    }
}

struct ContactDirectoryTable<Header: View>: View {
    typealias Status = ContactDirectoryStatus
    typealias HeaderRevision = ContactDirectoryHeaderRevision
    let projection: ContactDirectoryTableProjection
    let groupsRevision: String
    let headerRevision: HeaderRevision
    let state: AppState
    let avatarImageRouteContext: AvatarImageRouteContext?
    let header: Header
    let onSelect: (IMUser) -> Void
    let onScrollChange: (Bool) -> Void
    var body: some View {
        ContactDirectoryTableContent(groups: projection.inputs, groupsRevision: groupsRevision, headerRevision: headerRevision,
            ownerIdentity: ObjectIdentifier(state), avatarRouteIdentity: avatarImageRouteContext?.requestIdentity,
            header: header.appStateEnvironment(state).environment(\.avatarImageRouteContext, avatarImageRouteContext),
            avatarRenderer: { id in
                guard let row = projection.rowsByID[id] else { return nil }
                return ContactDirectoryAvatar(user: row.user, routeContext: avatarImageRouteContext)?.featureRenderer
            },
            richRow: { input in
                if let row = projection.rowsByID[input.id] {
                    ContactDirectoryRow(row: row).appStateEnvironment(state).environment(\.avatarImageRouteContext, avatarImageRouteContext)
                }
            }, onSelect: { id in
                if let user = projection.rowsByID[id]?.user { onSelect(user) }
            }, onScrollChange: onScrollChange)
    }
}

private struct ContactDirectoryAvatar: Sendable {
    let url: String
    let request: AvatarRemoteImageRequest
    let cacheKey: String
    let storageKey: String
    let routeContext: AvatarImageRouteContext?

    init?(user: IMUser, routeContext: AvatarImageRouteContext?) {
        let url = user.displayAvatarURL
        guard !isCancelledUserAvatarURL(url),
              let request = TenantRelativeImageURLResolver.request(url, routeContext: routeContext) else { return nil }
        let cacheKey = AvatarImageCache.cacheKey(url: request.stableIdentity, version: user.avatarVersion,
                                                 updatedAt: user.avatarUpdatedAt)
        guard let storageKey = request.storageCacheKey(cacheKey, routeContext: routeContext) else { return nil }
        self.url = url
        self.request = request
        self.cacheKey = cacheKey
        self.storageKey = storageKey
        self.routeContext = routeContext
    }

    @MainActor
    var featureRenderer: ContactDirectoryAvatarRendering {
        ContactDirectoryAvatarRendering(cachedImage: { cachedImage(maxPixelSize: $0) },
            load: { await load(maxPixelSize: $0) }, isAuthorized: { request.isAuthorized(routeContext: routeContext) })
    }

    @MainActor
    func cachedImage(maxPixelSize: Int) -> UIImage? {
        guard let image = AvatarImageCache.shared.peekImage(for: storageKey, maxPixelSize: maxPixelSize),
              request.isAuthorized(routeContext: routeContext) else { return nil }
        return image
    }

    @MainActor
    func load(maxPixelSize: Int) async -> UIImage? {
        await AvatarImageCache.shared.remoteImage(for: url, routeContext: routeContext,
                                                  cacheKey: cacheKey, maxPixelSize: maxPixelSize)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
