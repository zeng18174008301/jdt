import SwiftUI

@MainActor
public final class ChatScreenPresentationState: ObservableObject {
    @Published public private(set) var isComposerEditing = false
    @Published public var showBatchForwardTargets = false
    @Published public var showGroupAnnouncement = true
    @Published public var showGroupAnnouncementDetail = false
    @Published public var openedGroupAnnouncementID: String?
    @Published public var showPinnedMessages = false
    @Published public var pinnedCarouselIndex = 0
    @Published public var scrollTargetID: String?
    @Published public var focusedTimelineMessageID: String?
    @Published public var focusedTimelineMessageGeneration = 0
    @Published public var pendingUnreadCount = 0
    @Published public var previousMessageCount = 0
    @Published public var didInitialScroll = false
    @Published public var didAutoScrollToUnreadAnchor = false
    @Published public var unreadDividerVisible = false
    @Published public var didInitialLatestWindowCatchupScroll = false
    @Published public var didScheduleInitialProvisionalBottom = false
    @Published public var didResolveReadStatusAnchorAfterSideData = false
    @Published public var showSearch = false
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113: search draft and results belong to the search page.
    @Published public var oldestHistoryLoadAnchorID: String?
    @Published public var oldestHistoryLoadAnchorMinY: CGFloat?
    @Published public var newestHistoryLoadAnchorSeq: Int64 = 0
    @Published public var didTriggerOlderHistoryLoadForScrollIntent = false
    @Published public var isApplyingInitialScroll = false
    @Published public var isUserBrowsingHistory = false
    @Published public var isAtBottom = false
    @Published public var pendingOwnSendScrollBaselineCount: Int?
    @Published public var didScrollTowardUnreadMessages = false
    @Published public var lastScrollVisibility = ChatScrollVisibility.initial
    @Published public var underfilledOlderAutofillAttempts = 0
    private var composerEditingEventRevision: UInt64 = 0

    // UIKit can end editing while SwiftUI replaces a conversation's input view.
    // Publish only this layout flag after that update; a newer focus event wins.
    public func receiveComposerEditingEvent(_ isEditing: Bool) {
        composerEditingEventRevision &+= 1
        let revision = composerEditingEventRevision
        Task { @MainActor [weak self] in
            guard let self, self.composerEditingEventRevision == revision,
                  self.isComposerEditing != isEditing else { return }
            self.isComposerEditing = isEditing
        }
    }

    public init() {}
}
