import IM4Features
import SwiftUI
import UIKit

struct UserAvatarPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext
    let user: IMUser
    let displayName: String
    let source: String
    @State private var loadPhase: UserAvatarPreviewLoadPhase = .loading
    @State private var retryGeneration = 0

    var body: some View {
        UserAvatarPreviewContent(displayName: displayName, loadPhase: loadPhase,
            onRetry: { retryGeneration += 1 }, onDismiss: { dismiss() })
            .task(id: loadIdentity) {
                await loadAvatar()
            }
    }

    private var loadIdentity: String {
        "\(user.id)|\(source)|\(user.avatarVersion)|\(user.avatarUpdatedAt)|retry=\(retryGeneration)"
    }

    @MainActor
    private func loadAvatar() async {
        loadPhase = .loading
        let image = await AvatarImageCache.shared.remoteImage(
            for: source,
            routeContext: avatarImageRouteContext,
            cacheKey: user.avatarCacheKey,
            maxPixelSize: nil,
            retryPolicy: .none
        )
        guard !Task.isCancelled else { return }
        loadPhase = image.map(UserAvatarPreviewLoadPhase.loaded) ?? .failed
    }
}
