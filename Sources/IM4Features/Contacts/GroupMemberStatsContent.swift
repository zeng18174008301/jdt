// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupMemberStatsContent: View {
    let memberCount: Int?
    let ownerName: String
    let adminCount: Int?

    public init(memberCount: Int?, ownerName: String, adminCount: Int?) {
        self.memberCount = memberCount
        self.ownerName = ownerName
        self.adminCount = adminCount
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let memberCount { // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
                GroupMemberStat(value: String(memberCount), label: "成员")
            }
            GroupMemberStat(value: ownerName, label: "群主")
            // WDT_APP_CONTRACT_20261021_05: hide all aggregate statistics together.
            if let adminCount, adminCount >= 0 {
                GroupMemberStat(value: String(adminCount), label: "管理员")
            }
        }
        .im4PlainCard(radius: 22)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
