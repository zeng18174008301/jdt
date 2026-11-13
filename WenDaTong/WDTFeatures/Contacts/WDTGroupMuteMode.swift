// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import IM4Domain // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import IM4Stores
import Foundation

enum GroupNotificationMuteProjection {
    static func isMuted(group: GroupInfo, conversation _: ConversationMessageSnapshot?) -> Bool {
        group.muted
    }
}

enum GroupMuteListAccessMode: Equatable {
    case manage
    case permissionReadOnly

    init(canManage: Bool) {
        self = canManage ? .manage : .permissionReadOnly
    }

    var loadsRemoteList: Bool {
        self == .manage
    }
}


// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
typealias GroupMuteLifecycle = IM4Domain.GroupMuteLifecycle
typealias GroupMuteModeValidationError = IM4Domain.GroupMuteModeValidationError
typealias GroupMuteModeIntent = IM4Domain.GroupMuteModeIntent
typealias GroupMuteModeProjection = IM4Domain.GroupMuteModeProjection
typealias GroupMuteModeTransition = IM4Domain.GroupMuteModeTransition
typealias PersistedGroupMuteModeProjection = IM4Domain.PersistedGroupMuteModeProjection
typealias GroupMuteModeState = IM4Domain.GroupMuteModeState
typealias GroupModerationStore = IM4Stores.GroupModerationStore
// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
