@testable import IM4Features
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import WenDaTong

extension IdentityPresentationTests {
    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testCertificationPillObservesOnlyInjectedScopeAndSkipsPrefetchedRows() {
        let changes = PassthroughSubject<Int, Never>()
        var scopeRevision = 0
        var queriedUIDs: [String] = []
        var requestedUIDs: [String] = []
        let source = CertificationPillSource(
            changes: changes.eraseToAnyPublisher(),
            scopeRevision: { scopeRevision },
            presentation: { uid in
                queriedUIDs.append(uid)
                return nil
            },
            ensure: { requestedUIDs.append($0) }
        )

        let hosted = hostForSimulatorUI(
            VStack {
                CertificationPillView(exactUID: " live ")
                CertificationPillView(exactUID: "prefetched", usesProvidedPresentationOnly: true)
            }
            .environment(\.certificationPillSource, source),
            size: CGSize(width: 320, height: 140)
        )
        defer { hosted.window.isHidden = true }
        XCTAssertEqual(requestedUIDs, ["live"])
        XCTAssertEqual(Set(queriedUIDs), ["live"])

        queriedUIDs.removeAll()
        changes.send(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(Set(queriedUIDs), ["live"])
        XCTAssertEqual(requestedUIDs, ["live"])

        scopeRevision += 1
        changes.send(2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(requestedUIDs, ["live", "live"])
        XCTAssertEqual(Set(queriedUIDs), ["live"])
    }
    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_END

    // WDT_CHAT_READ_TRIGGER_20261021_BEGIN
    func testChatBottomTargetIncludesTrailingPaddingForStrictReadVisibility() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let chat = try sourceText(relativePath: "../WenDaTong/App/ChatTimelineAssembly.swift")
        let viewState = try sourceText(relativePath: "../WenDaTong/ChatViews.swift")
        let scrollStart = try XCTUnwrap(chat.range(of: "private func messageScrollView(")?.lowerBound)
        let scrollEnd = try XCTUnwrap(chat[scrollStart...].range(of: "private var messageHistoryStatusOverlay:")?.lowerBound)
        let scroll = String(chat[scrollStart..<scrollEnd]) + (try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewTimeline.swift"))
        XCTAssertFalse(scroll.contains(".padding(.bottom, 12)"))
        XCTAssertTrue(scroll.contains("contentMaxY: frame.maxY"))

        let anchorSource = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatTimelineLayout.swift")
        let anchorStart = try XCTUnwrap(anchorSource.range(of: "struct ChatTimelineBottomAnchor")?.lowerBound)
        let anchorEnd = try XCTUnwrap(anchorSource[anchorStart...].range(of: "struct ChatTranscriptList")?.lowerBound)
        let anchor = anchorSource[anchorStart..<anchorEnd]
        let height = try XCTUnwrap(anchor.range(of: ".frame(height: height)"))
        let padding = try XCTUnwrap(anchor.range(of: ".padding(.bottom, 12)"))
        let identity = try XCTUnwrap(anchor.range(of: ".id(anchorID)"))
        XCTAssertLessThan(height.lowerBound, padding.lowerBound)
        XCTAssertLessThan(padding.lowerBound, identity.lowerBound)
        XCTAssertTrue(viewState.contains("let messageListBottomAnchorHeight: CGFloat = 24") && chat.contains("ChatTimelineBottomAnchor(height: messageListBottomAnchorHeight, anchorID: bottomAnchorID)"))
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    func testChatDepartureReleasesReadRequestFlagsWithoutClearingUnread() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let chat = try sourceText(relativePath: "../WenDaTong/App/ChatTranscriptLayoutAssembly.swift")
        let start = try XCTUnwrap(chat.range(of: "// JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_DISAPPEAR")?.lowerBound)
        let end = try XCTUnwrap(chat[start...].range(of: ".sheet(isPresented: $presentation.showGroupAnnouncementDetail)")?.lowerBound)
        let departure = chat[start..<end]
        let epoch = try XCTUnwrap(departure.range(of: "readVisibilityEpoch &+= 1"))
        let reset = try XCTUnwrap(departure.range(of: "isClearingUnreadReminder = false"))
        XCTAssertLessThan(epoch.lowerBound, reset.lowerBound)
        XCTAssertTrue(departure.contains("lastVisibleReadAckToken = \"\""))
        XCTAssertTrue(departure.contains("scrollMetricsMeasurements.removeAll()"))
        XCTAssertFalse(departure.contains("markConversationRead("))
        XCTAssertFalse(departure.contains("clearUnreadReminderLocally("))
        XCTAssertFalse(departure.contains("clearConversationUnreadLocally("))
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }
    // WDT_CHAT_READ_TRIGGER_20261021_END

    func testChatTranscriptOwnsKeyboardDismissalWithoutWrappingComposerControls() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let chat = try sourceText(relativePath: "../WenDaTong/App/ChatTimelineAssembly.swift")
        let timeline = String(try sourceSection(chat, startingAt: "func messageTimeline(")) + (try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewTimeline.swift"))
        XCTAssertTrue(timeline.contains("simultaneousGesture(messageTranscriptTapGesture)"))
        XCTAssertTrue(timeline.contains("chatScrollDismissesKeyboardOnDrag()"))
        XCTAssertTrue(timeline.contains("dismissChatKeyboardFromTranscript(trigger: .tap)"))
        let longPress = try sourceSection(sourceText(relativePath: "../WenDaTong/App/ChatMessageInteractionAssembly.swift"), startingAt: "func observeSecondaryMessageEntry<Content: View>")
        XCTAssertTrue(timeline.contains("observeSecondaryMessageEntry(row.message)") && timeline.contains("actions.longPress()") && longPress.contains("guard entry.isCurrent(identity: screenActions.authority.chatBubbleSessionIdentity()) else { return }") && longPress.contains("dismissChatKeyboardFromTranscript(trigger: .longPress)"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let composer = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposer.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerTextEntry.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerAssembly.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerSections.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerSections.swift")
        let composerActions = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerActions.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerActionAssembly.swift")
        XCTAssertFalse(composer.contains("messageTranscriptTapGesture") || composerActions.contains("messageTranscriptTapGesture"))
        XCTAssertFalse(composer.contains("messageTranscriptDragGesture") || composerActions.contains("messageTranscriptDragGesture"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    // WDT_CHAT_KEYBOARD_INSET_20261021_BEGIN
    func testChatKeyboardDismissalRestoresLayoutAndUsesImmediateScrollDismissal() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let chat = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewTimeline.swift")
        let scrollDismissal = try sourceSection(chat, startingAt: "func chatScrollDismissesKeyboardOnDrag()")
        XCTAssertTrue(scrollDismissal.contains("scrollDismissesKeyboard(.immediately)"))
        let transcript = try sourceText(relativePath: "../WenDaTong/App/ChatTimelineAssembly.swift")
        let drag = try sourceSection(transcript, startingAt: "private var messageTranscriptDragGesture")
        XCTAssertTrue(drag.contains("dismissChatKeyboardFromTranscript(trigger: .verticalScroll)"))
        XCTAssertFalse(drag.contains("#unavailable(iOS 16.0)"))
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_BEGIN
        let inputViews = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerInputViews.swift")
        let beginEditing = try sourceSection(inputViews, startingAt: "func textViewDidBeginEditing(_ textView: UITextView)")
        XCTAssertTrue(beginEditing.contains("parent.onEditingChanged(true)"))
        let endEditingTail = try sourceSection(inputViews, startingAt: "func textViewDidEndEditing(_ textView: UITextView)")
        let endEditingEnd = try XCTUnwrap(endEditingTail.range(of: "\n        }")?.upperBound)
        let endEditing = endEditingTail[..<endEditingEnd]
        XCTAssertTrue(endEditing.contains("parent.onEditingChanged(false)"))
        XCTAssertFalse(endEditing.contains("parent.text ="))
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_END
        let layout = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewLayout.swift") + sourceText(relativePath: "../WenDaTong/App/ChatTranscriptLayoutAssembly.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerComposition.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatScreenLayout.swift")
        let shell = try sourceSection(layout, startingAt: "struct ChatScreenLayout")
        XCTAssertTrue(shell.contains(".ignoresSafeArea(.keyboard, edges: chatIgnoredKeyboardEdges("))
        XCTAssertTrue(shell.contains("searchIsFocused: isHistorySearchFocused"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let composer = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposer.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerTextEntry.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerAssembly.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerSections.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerSections.swift")
        let inputActions = try sourceText(relativePath: "../WenDaTong/App/ChatComposerInputActions.swift")
        XCTAssertTrue(inputActions.contains("onEditingChanged: onEditingChanged") && composer.contains("onEditingChanged: actions.onEditingChanged"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_BEGIN
        let inputBox = try sourceSection(inputViews, startingAt: "struct ComposerInputBox: View")
        XCTAssertTrue(inputBox.contains("onEditingChanged: onEditingChanged"))
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }
    // WDT_CHAT_KEYBOARD_INSET_20261021_END

    @MainActor
    func testImmediateMuteListProjectionMergesSelectedIdentityAndReasonIntoSparseResponse() throws {
        let remote = try JSONDecoder().decode(
            RemoteGroupMuteListItem.self,
            from: Data(#"{"group_id":"group-1"}"#.utf8)
        )
        let selected = IMUser(
            id: "im-uid-1",
            userID: "user-1",
            username: "member001",
            name: "已选择成员",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 7,
            badges: []
        )
        let state = AppState(apiContextOverride: IMAPIContext(
            platformToken: nil,
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "operator-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        ))

        let item = state.groupMuteListItem(
            from: remote,
            fallbackGroupID: "group-1",
            fallbackTarget: selected,
            fallbackTargetUID: selected.id,
            fallbackReason: "违反群规"
        )

        XCTAssertEqual(item.targetUID, "im-uid-1")
        XCTAssertEqual(item.targetUserID, "user-1")
        XCTAssertEqual(item.targetUsername, "member001")
        XCTAssertEqual(item.targetNickname, "已选择成员")
        XCTAssertEqual(item.reason, "违反群规")
        XCTAssertEqual(item.targetDisplayName, "已选择成员")
        XCTAssertEqual(item.targetDisplayID, "user-1")
    }

    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
    func testMessageBubbleGroupSenderMetadataUsesOneHorizontalRow() throws {
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        let source = try sourceText(relativePath: "../Sources/IM4Features/Chat/MessageBubble.swift")
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        let rendererStart = try XCTUnwrap(
            source.range(of: "private func senderNameWithRole(")?.lowerBound
        )
        let rendererTail = source[rendererStart...]
        let rendererEnd = try XCTUnwrap(
            rendererTail.range(of: "private var senderUser: IMUser?")?.lowerBound
        )
        let renderer = rendererTail[..<rendererEnd]

        XCTAssertTrue(renderer.contains("HStack(alignment: .firstTextBaseline"))
        XCTAssertFalse(renderer.contains("VStack("))
        XCTAssertTrue(renderer.contains(".lineLimit(1)"))
        XCTAssertTrue(renderer.contains(".truncationMode(.tail)"))
        XCTAssertTrue(renderer.contains(".layoutPriority(0)"))
        XCTAssertTrue(renderer.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(renderer.contains(".layoutPriority(1)"))

        let nickname = try XCTUnwrap(renderer.range(of: "Text(name)"))
        let certification = try XCTUnwrap(renderer.range(of: "CertificationPillView("))
        let role = try XCTUnwrap(renderer.range(of: "ChatSenderRoleIcon(role: role)"))
        XCTAssertLessThan(nickname.lowerBound, certification.lowerBound)
        XCTAssertLessThan(certification.lowerBound, role.lowerBound)

        let badgeStart = try XCTUnwrap(
            source.range(of: "private struct ChatSenderRoleIcon: View")?.lowerBound
        )
        let badgeTail = source[badgeStart...]
        let badgeEnd = try XCTUnwrap(
            badgeTail.range(of: "private func groupRoleUser(")?.lowerBound
        )
        let badge = badgeTail[..<badgeEnd]
        XCTAssertTrue(badge.contains("Text(role.title)"))
        XCTAssertTrue(badge.contains(".lineLimit(1)"))
        XCTAssertTrue(badge.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(badge.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(badge.contains(".accessibilityLabel(role.title)"))

        let accessibleName = try XCTUnwrap(renderer.range(of: "name,"))
        // WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
        let accessibleCertification = try XCTUnwrap(renderer.range(of: "reference: certificationSource?.reference(forExactUID: exactUID)"))
        let assemblySource = try sourceText(relativePath: "../WenDaTong/App/ChatTimelineRowComposition.swift")
        // WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
        let accessibleRole = try XCTUnwrap(renderer.range(of: "role?.title"))
        XCTAssertLessThan(accessibleName.lowerBound, accessibleCertification.lowerBound)
        XCTAssertLessThan(accessibleCertification.lowerBound, accessibleRole.lowerBound)

        let roleProjectionStart = try XCTUnwrap(
            assemblySource.range(of: "private var senderGroupRole: ChatSenderGroupRole?")?.lowerBound
        )
        let roleProjectionTail = assemblySource[roleProjectionStart...]
        let roleProjectionEnd = try XCTUnwrap(
            roleProjectionTail.range(of: "private var displayMessageText: String")?.lowerBound
        )
        let roleProjection = roleProjectionTail[..<roleProjectionEnd]
        XCTAssertTrue(roleProjection.contains("state.group(forConversationID: conversationID)"))
        XCTAssertTrue(roleProjection.contains("return .owner"))
        XCTAssertTrue(roleProjection.contains("return .admin"))
        XCTAssertTrue(roleProjection.contains("return nil"))
    }
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END

    func testChatHeaderTitleDecisionUsesOnlyResolvedDirectPeerIdentity() {
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: " 客户王总 ",
                conversationTitle: "查看者本人"
            ),
            "客户王总"
        )
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: nil,
                conversationTitle: "查看者本人"
            ),
            ChatHeaderTitleDecision.safeDirectFallback
        )
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .group,
                resolvedPeerDisplayName: "不应使用的私聊对象",
                conversationTitle: " 产品研发群 "
            ),
            "产品研发群"
        )
    }

    @MainActor
    func testDirectChatHeaderTitleUsesViewerScopedRemarkWithoutCrossAccountLeakage() throws {
        let peer = makeRemarkContractUser(
            id: "peer-im-uid",
            userID: "WXT00000002",
            username: "peer002",
            name: "公共昵称"
        )
        let conversation = ConversationMessageSnapshot(
            id: "viewer-a:peer-im-uid",
            title: "查看者本人",
            subtitle: "",
            kind: .direct,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: nil,
            accentHex: 0,
            participants: [
                makeRemarkContractUser(id: "viewer-a", name: "查看者本人"),
                peer
            ],
            messages: []
        )

        let viewerA = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-a", imUID: "viewer-a")
        )
        viewerA.setCurrentUser(makeRemarkContractUser(id: "viewer-a", name: "查看者本人")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        viewerA.contacts = [peer]
        viewerA.contactRemarks = ["WXT00000002": "A 的私有备注"]
        let viewerAPeer = try XCTUnwrap(viewerA.directConversationProfilePeer(for: conversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: conversation.kind,
                resolvedPeerDisplayName: viewerA.remarkPreferredDisplayName(for: viewerAPeer),
                conversationTitle: conversation.title
            ),
            "A 的私有备注"
        )

        let viewerB = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-b", imUID: "viewer-b")
        )
        viewerB.setCurrentUser(makeRemarkContractUser(id: "viewer-b", name: "另一个查看者")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        viewerB.contacts = [peer]
        viewerB.contactRemarks = [:]
        let viewerBConversation = ConversationMessageSnapshot(
            id: "viewer-b:peer-im-uid",
            title: conversation.title,
            subtitle: conversation.subtitle,
            kind: conversation.kind,
            lastMessage: conversation.lastMessage,
            time: conversation.time,
            unread: conversation.unread,
            isPinned: conversation.isPinned,
            isMuted: conversation.isMuted,
            memberCount: conversation.memberCount,
            accentHex: conversation.accentHex,
            participants: [viewerB.currentUser, peer],
            messages: conversation.messages
        )
        let viewerBPeer = try XCTUnwrap(viewerB.directConversationProfilePeer(for: viewerBConversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: viewerBConversation.kind,
                resolvedPeerDisplayName: viewerB.remarkPreferredDisplayName(for: viewerBPeer),
                conversationTitle: viewerBConversation.title
            ),
            "公共昵称"
        )

        var selfOnlyConversation = conversation
        selfOnlyConversation.participants = [viewerA.currentUser]
        XCTAssertNil(viewerA.directConversationProfilePeer(for: selfOnlyConversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: nil,
                conversationTitle: selfOnlyConversation.title
            ),
            ChatHeaderTitleDecision.safeDirectFallback
        )
    }

    func testChatComposerToolDescriptorsKeepAttachmentAndCallActionsDistinct() throws {
        let directTools = chatComposerToolDescriptors(
            allowsVoiceCall: true,
            allowsVideoCall: true
        )
        XCTAssertEqual(
            directTools.map(\.action),
            [.mediaAttachment, .fileAttachment, .voiceCall, .videoCall, .contactCard]
        )
        XCTAssertEqual(
            directTools.map(\.title),
            ["照片/视频", "文件", "通话", "视频", "名片"]
        )
        XCTAssertFalse(directTools.contains(where: { $0.title == "表情" }))

        let media = try XCTUnwrap(directTools.first(where: { $0.action == .mediaAttachment }))
        let videoCall = try XCTUnwrap(directTools.first(where: { $0.action == .videoCall }))
        XCTAssertNotEqual(media.symbol, videoCall.symbol)
        XCTAssertNotEqual(media.accessibilityIdentifier, videoCall.accessibilityIdentifier)
        XCTAssertEqual(media.accessibilityLabel, "选择照片或视频附件")
        XCTAssertEqual(videoCall.accessibilityLabel, "发起视频通话")

        let groupTools = chatComposerToolDescriptors(
            allowsVoiceCall: false,
            allowsVideoCall: false
        )
        XCTAssertEqual(
            groupTools.map(\.action),
            [.mediaAttachment, .fileAttachment, .contactCard]
        )
        XCTAssertFalse(groupTools.contains(where: { $0.action == .voiceCall || $0.action == .videoCall }))
    }

    func testDirectChatToolbarAndComposerSourceContracts() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let source = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewHeaderAndStatus.swift")
        let toolbar = try sourceSection(source, startingAt: "struct ChatConversationHeaderView: View")
        XCTAssertTrue(try sourceText(relativePath: "../WenDaTong/App/ChatHeaderAssembly.swift").contains("return ChatConversationHeaderView(input: input, actions: actions)"))
        XCTAssertTrue(toolbar.contains("ZStack"))
        XCTAssertTrue(toolbar.contains("chat_centered_conversation_title"))
        XCTAssertTrue(toolbar.contains(".lineLimit(1)"))
        XCTAssertTrue(toolbar.contains(".truncationMode(.tail)"))
        XCTAssertTrue(toolbar.contains(".frame(width: 136)"))
        XCTAssertTrue(toolbar.contains(".environment(\\.layoutDirection, .leftToRight)"))
        XCTAssertTrue(toolbar.contains("chat_search_button"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"搜索聊天记录\")"))
        XCTAssertTrue(toolbar.contains("chat_more_button"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"会话详情\")"))
        XCTAssertFalse(toolbar.contains("chat_call_button"))
        XCTAssertFalse(toolbar.contains("chat_video_call_button"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let composer = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposer.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerTextEntry.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerAssembly.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerSections.swift") + sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerSections.swift")
        let composerActions = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerActions.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerActionAssembly.swift")
        XCTAssertTrue(composer.contains("chat_emoji_toggle_button"))
        XCTAssertTrue(composer.contains("ChatExpressionPanel("))
        XCTAssertTrue(composerActions.contains("case .voiceCall:"))
        XCTAssertTrue(composerActions.contains("startVoiceCall()"))
        XCTAssertTrue(composerActions.contains("case .videoCall:"))
        XCTAssertTrue(composerActions.contains("startVideoCall()"))
        XCTAssertTrue(composer.contains("sizeCategory.isAccessibilityCategory ? 2 : 4"))
        XCTAssertTrue(composer.contains("LazyVGrid(columns: toolGridColumns"))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END

        let layout = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewLayout.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerComposition.swift")
        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
        let chatComposerWiringStart = try XCTUnwrap(
            layout.range(of: #"ChatComposer\(\s+conversationID: conversationID"#, options: .regularExpression)?.lowerBound
        )
        let chatComposerWiringTail = layout[chatComposerWiringStart...]
        let chatComposerWiringEnd = try XCTUnwrap(
            chatComposerWiringTail.range(of: #"\n +send:"#, options: .regularExpression)?.lowerBound
        )
        // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
        let chatComposerWiring = chatComposerWiringTail[..<chatComposerWiringEnd]
        XCTAssertTrue(chatComposerWiring.contains("startVoiceCall: startVoiceCallFromConversation"))
        XCTAssertTrue(chatComposerWiring.contains("startVideoCall: startVideoCallFromConversation"))
        XCTAssertTrue(chatComposerWiring.contains("showsDisabledNotice: disabledBannerDecision.showsComposerDisabledNotice"))
        XCTAssertTrue(composer.contains("if isDisabled && showsDisabledNotice"))
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    func testGroupMuteBannerSourceUsesActiveAuthorityAndExistingServerBoundaryRefresh() throws {
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
        let chatSource = try sourceText(relativePath: "../WenDaTong/App/ChatHeaderStatusQueries.swift")
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_BEGIN
        let decisions = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatIdentityPresentation.swift")
        let decisionStart = try XCTUnwrap(
            decisions.range(of: "struct GroupMuteBannerDecision: Equatable")?.lowerBound
        )
        let decisionTail = decisions[decisionStart...]
        let decisionEnd = try XCTUnwrap(
            decisionTail.range(of: "\npublic struct ChatDisabledBannerDecision: Equatable")?.lowerBound
        )
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_END
        let decision = decisionTail[..<decisionEnd]
        XCTAssertTrue(decision.contains("if let active = group.allMuteActive"))
        XCTAssertTrue(decision.contains("guard isAuthoritativelyActive else { return nil }"))
        XCTAssertTrue(decision.contains("if group.allMuteRepairRequired"))
        XCTAssertFalse(decision.contains("Date()"))
        XCTAssertFalse(decision.contains("Calendar.current"))

        let visibilityStart = try XCTUnwrap(
            chatSource.range(of: "var shouldShowGroupMuteStatus: Bool")?.lowerBound
        )
        let visibilityTail = chatSource[visibilityStart...]
        let visibilityEnd = try XCTUnwrap(
            visibilityTail.range(of: "var currentGroupAnnouncement")?.lowerBound
        )
        let visibility = visibilityTail[..<visibilityEnd]
        XCTAssertTrue(visibility.contains("disabledBannerDecision.groupMuteBanner != nil"))
        XCTAssertFalse(visibility.contains("allMuteMode != .off"))

        let appStateSource = try sourceText(relativePath: "../WenDaTong/Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift")
        let boundaryStart = try XCTUnwrap(
            appStateSource.range(of: "func scheduleGroupMuteBoundaryRefresh")?.lowerBound
        )
        let boundaryTail = appStateSource[boundaryStart...]
        let boundaryEnd = try XCTUnwrap(
            boundaryTail.range(of: "func applyRemoteGroups")?.lowerBound
        )
        let boundary = boundaryTail[..<boundaryEnd]
        XCTAssertTrue(boundary.contains("boundary > serverTime"))
        XCTAssertTrue(boundary.contains("boundary.timeIntervalSince(serverTime)"))
        XCTAssertTrue(boundary.contains("refreshGroupBundle("))
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

    @MainActor
    func testDirectComposerPlusGridRendersDistinctAXActionsOnSimulator() throws {
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        let root = ChatComposerUITestHarness(
            onVoiceCall: {},
            onVideoCall: {}
        )
        .appStateEnvironment(state)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 540))
        defer { hosted.window.isHidden = true }

        let expectedIDs = [
            "chat_tool_media_attachment",
            "chat_tool_file_attachment",
            "chat_tool_voice_call",
            "chat_tool_video_call",
            "chat_tool_contact_card"
        ]
        let descriptors = chatComposerToolDescriptors(allowsVoiceCall: true, allowsVideoCall: true)
        XCTAssertEqual(descriptors.map(\.accessibilityIdentifier), expectedIDs)
        XCTAssertEqual(
            descriptors.map(\.accessibilityLabel),
            ["选择照片或视频附件", "选择文件附件", "发起语音通话", "发起视频通话", "发送联系人名片"]
        )
        XCTAssertFalse(descriptors.contains(where: { $0.title == "表情" }))

        let snapshot = hostedSnapshotImage(hosted)
        XCTAssertGreaterThan(snapshot.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(snapshot, name: "direct-plus-grid-dark-rtl-axxxl"))
    }

    @MainActor
    func testChatViewsRenderDirectTitlesAndActiveOnlyGroupBannerOnSimulator() throws {
        let directCases: [(String, String?, ColorScheme, LayoutDirection, ContentSizeCategory)] = [
            ("公共昵称", "客户王总", .light, .leftToRight, .large),
            ("无备注昵称", nil, .dark, .leftToRight, .extraExtraExtraLarge),
            ("公共昵称", "这是一条非常非常长且必须保持物理居中的客户备注名称", .dark, .rightToLeft, .accessibilityExtraExtraExtraLarge)
        ]

        for (index, fixture) in directCases.enumerated() {
            let state = try mountedLocalDirectChat(nickname: fixture.0, remark: fixture.1) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
            let root = NavigationView {
                ChatView(conversationID: "direct-ui-chat")
            }
            .navigationViewStyle(.stack)
            .appStateEnvironment(state)
            .environment(\.colorScheme, fixture.2)
            .environment(\.layoutDirection, fixture.3)
            .environment(\.sizeCategory, fixture.4)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 640))
            let image = hostedSnapshotImage(hosted)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "direct-chat-title-case-\(index + 1)"))
            hosted.window.isHidden = true
        }

        let memberState = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let memberRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .appStateEnvironment(memberState)
        .environment(\.colorScheme, .light)
        let memberHosted = hostForSimulatorUI(memberRoot, size: CGSize(width: 320, height: 640))
        let inactiveImage = hostedSnapshotImage(memberHosted)
        add(snapshotAttachment(inactiveImage, name: "group-scheduled-inactive-banner-hidden"))
        memberHosted.window.isHidden = true

        let activeMemberState = try mountedLocalGroupChat(role: "member", active: true, repairRequired: false) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let activeMemberRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .appStateEnvironment(activeMemberState)
        .environment(\.colorScheme, .light)
        let activeMemberHosted = hostForSimulatorUI(activeMemberRoot, size: CGSize(width: 320, height: 640))
        let activeMemberImage = hostedSnapshotImage(activeMemberHosted)
        XCTAssertNotEqual(inactiveImage.pngData(), activeMemberImage.pngData())
        add(snapshotAttachment(activeMemberImage, name: "group-scheduled-active-member-banner"))
        activeMemberHosted.window.isHidden = true

        let adminState = try mountedLocalGroupChat(role: "admin", active: true, repairRequired: false) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let adminRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .appStateEnvironment(adminState)
        .environment(\.colorScheme, .dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let adminHosted = hostForSimulatorUI(adminRoot, size: CGSize(width: 320, height: 640))
        let adminImage = hostedSnapshotImage(adminHosted)
        XCTAssertGreaterThan(adminImage.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(adminImage, name: "group-active-admin-dark-axxxl-banner"))
        adminHosted.window.isHidden = true

        let repairState = try mountedLocalGroupChat(role: "member", active: false, repairRequired: true) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let repairRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .appStateEnvironment(repairState)
        .environment(\.colorScheme, .light)
        let repairHosted = hostForSimulatorUI(repairRoot, size: CGSize(width: 320, height: 640))
        let repairImage = hostedSnapshotImage(repairHosted)
        XCTAssertGreaterThan(repairImage.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(repairImage, name: "group-repair-member-banner"))
        repairHosted.window.isHidden = true
    }

    @MainActor
    func testDirectChatToolbarRendersCenteredTitleAndActionsOnSimulator() throws {
        let remark = "这是一条非常非常长且必须保持物理居中的客户备注名称"
        let state = directChatUIState(
            nickname: "公共昵称",
            remark: remark
        )
        let root = ChatView(conversationID: "direct-ui-chat")
            .appStateEnvironment(state)
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let hosted = hostInNavigationForSimulatorUI(root, size: CGSize(width: 320, height: 640))
        defer { hosted.window.isHidden = true }

        XCTAssertTrue(hosted.navigationController.navigationBar.isHidden)
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: remark,
                conversationTitle: "不可信会话标题"
            ),
            remark
        )

        let image = hostedNavigationSnapshotImage(hosted)
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(image, name: "direct-toolbar-dark-rtl-axxxl-runtime-ax"))
    }
}

private struct ChatComposerUITestHarness: View {
    @State private var input = ""
    @State private var replyQuote: String?
    @State private var replyContext: MessageReplyContext?
    @State private var showTools = true
    @State private var showEmoji = false
    @State private var mentionAllSelected = false

    let onVoiceCall: () -> Void
    let onVideoCall: () -> Void

    var body: some View {
        VStack {
            Spacer()
            ChatComposer(
                conversationID: "direct-ui",
                input: $input,
                replyQuote: $replyQuote,
                replyContext: $replyContext,
                showTools: $showTools,
                showEmoji: $showEmoji,
                mentionAllSelected: $mentionAllSelected,
                allowsVoiceCall: true,
                allowsVideoCall: true,
                voiceCallAccessibilityHint: "语音通话测试动作",
                videoCallAccessibilityHint: "视频通话测试动作",
                startVoiceCall: onVoiceCall,
                startVideoCall: onVideoCall,
                send: { _, _, _ in }
            )
        }
    }
}

@MainActor
struct HostedSimulatorUI<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>
}

@MainActor
private struct HostedNavigationSimulatorUI<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>
    let navigationController: UINavigationController
}

@MainActor
func hostForSimulatorUI<Content: View>(
    _ root: Content,
    size: CGSize
) -> HostedSimulatorUI<Content> {
    let controller = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    controller.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: controller)
}

@MainActor
private func hostInNavigationForSimulatorUI<Content: View>(
    _ root: Content,
    size: CGSize
) -> HostedNavigationSimulatorUI<Content> {
    let controller = UIHostingController(rootView: root)
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.navigationBar.prefersLargeTitles = false
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = navigationController
    window.makeKeyAndVisible()
    navigationController.view.frame = window.bounds
    navigationController.view.setNeedsLayout()
    navigationController.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    navigationController.view.layoutIfNeeded()
    return HostedNavigationSimulatorUI(
        window: window,
        controller: controller,
        navigationController: navigationController
    )
}

@MainActor
func hostedSnapshotImage<Content: View>(_ hosted: HostedSimulatorUI<Content>) -> UIImage {
    let renderer = UIGraphicsImageRenderer(bounds: hosted.window.bounds)
    return renderer.image { context in
        hosted.window.layer.render(in: context.cgContext)
    }
}

@MainActor
private func hostedNavigationSnapshotImage<Content: View>(
    _ hosted: HostedNavigationSimulatorUI<Content>
) -> UIImage {
    let renderer = UIGraphicsImageRenderer(bounds: hosted.window.bounds)
    return renderer.image { context in
        hosted.window.layer.render(in: context.cgContext)
    }
}

func snapshotAttachment(_ image: UIImage, name: String) -> XCTAttachment {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_BEGIN
@MainActor
extension IdentityPresentationTests {
    func testExternalMentionKeepsOriginalAppendRuleAndMountedNextInputPosition() async throws {
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false), peer = makeRemarkContractUser(id: "peer", userID: "PEER", name: "成员😀") // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        var chat: ChatView?; ChatTimelineRenderDiagnostics.chatBody = { chat = $0 }; defer { ChatTimelineRenderDiagnostics.reset() }
        let hosted = hostForSimulatorUI(NavigationView { ChatView(conversationID: "group-ui-chat") }.navigationViewStyle(.stack).appStateEnvironment(state), size: CGSize(width: 320, height: 640))
        defer { hosted.window.isHidden = true }; try await Task.sleep(nanoseconds: 150_000_000)
        let current = try XCTUnwrap(chat), editor = try XCTUnwrap(f2Editor(hosted.controller.view)); XCTAssertTrue(editor.becomeFirstResponder())
        let mention = "@成员😀 "
        for before in ["", "draft", "draft ", " \n", "kept " + mention + "tail"] {
            editor.text = before; editor.selectedRange = NSRange(location: before.contains(mention) ? 1 : 0, length: before.contains(mention) ? 1 : 0); editor.delegate?.textViewDidChange?(editor)
            let previousRange = editor.selectedRange; current.mention(peer); try await Task.sleep(nanoseconds: 70_000_000)
            let expectedText = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? mention : before.contains(mention) ? before : before + (before.hasSuffix(" ") ? mention : " " + mention)
            let expectedRange = before.contains(mention) ? previousRange : NSRange(location: expectedText.utf16.count, length: 0)
            XCTAssertEqual(editor.text, expectedText); XCTAssertEqual(editor.selectedRange, expectedRange)
            let expectedAfter = (expectedText as NSString).replacingCharacters(in: expectedRange, with: "X"); editor.insertText("X"); editor.delegate?.textViewDidChange?(editor)
            XCTAssertEqual(editor.text, expectedAfter); XCTAssertEqual(current.composerState.draft.input, expectedAfter)
        }
    }
}
// WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_END
