import IM4Features
import SwiftUI
import UIKit

struct EnterpriseHeaderCard<Trailing: View>: View {
    let enterprise: Enterprise
    var isSwitchingEnabled = true
    var action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        EnterpriseHeaderCardContent(name: enterprise.name, displayCode: enterprise.displayCode,
            disabledDescription: enterprise.isWorkspaceEnterable ? "" : enterprise.workspaceDisabledDescription,
            isSwitchingEnabled: isSwitchingEnabled, action: action, logo: {
                EnterpriseLogoView(enterprise: enterprise, size: 58, cornerRadius: 20,
                    cacheKey: enterprise.logoImageCacheKey(scope: "enterprise-header"))
            }, trailing: trailing)
    }
}

struct EnterpriseCard: View {
    let enterprise: Enterprise
    var isSwitchingEnabled = true
    var action: () -> Void

    var body: some View {
        EnterpriseHeaderCard(enterprise: enterprise, isSwitchingEnabled: isSwitchingEnabled, action: action) {
            EmptyView()
        }
    }
}

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
typealias AnnouncementBanner = IM4Features.ConversationAnnouncementBannerContent
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
