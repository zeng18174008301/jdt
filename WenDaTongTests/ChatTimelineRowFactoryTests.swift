@testable import IM4Features
import XCTest
import SwiftUI
import UIKit
import CryptoKit
import MachO
import Combine
@testable import WenDaTong

// WDT_IOS1_CHAT_ROW_FACTORY_20261110_BEGIN
extension DomainStoreTests {
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
    @MainActor
    func testAppRowFactoryMountedTimelineKeepsInputAndOtherWindowIsolated() async throws {
        let state = rowFactoryState()
        let owner = ComposerState()
        var conversation = rowFactoryConversation(state: state)
        state.conversationStore.commitConversationSnapshots([conversation])
        var mounted: [String: MessageBubble] = [:]
        var bodies: [String] = []
        var factoryInputs: [String] = []
        let realFactory = AppFeatureComposition.timelineRowFactory(state: state)
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.enabled = true
        ChatTimelineRenderDiagnostics.batchForwardBubble = { bubble in
            if bubble.conversationID == conversation.id { mounted[bubble.message.id] = bubble }
        }
        ChatTimelineRenderDiagnostics.scopedBubbleBody = { id, message in
            if id == conversation.id { bodies.append(message.id) }
        }
        let hosted = hostForSimulatorUI(NavigationStackCompat {
            ChatView(composerState: owner, conversationID: conversation.id)
                .environment(\.chatTimelineRowFactory, ChatTimelineRowFactory(makeRow: { input, actions in
                    factoryInputs.append(input.row.id)
                    return realFactory.makeRow(input, actions)
                }))
        }.appStateEnvironment(state), size: CGSize(width: 390, height: 950))
        defer {
            hosted.window.isHidden = true; hosted.window.rootViewController = nil
            ChatTimelineRenderDiagnostics.reset()
        }
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let messageIDs = Set(conversation.messages.map(\.id))
        try await rowFactoryWait { Set(mounted.keys) == messageIDs }
        try await Task.sleep(nanoseconds: 700_000_000)
        let rows = mounted.mapValues(\.rowModel)
        XCTAssertEqual(Set(factoryInputs), messageIDs, "Every real timeline row used the injected App factory")
        let editor = try XCTUnwrap(rowFactoryEditor(hosted.controller.view))
        let editorID = ObjectIdentifier(editor)
        bodies.removeAll()
        editor.text = "factory draft 中😀"
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.delegate?.textViewDidChange?(editor)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(owner.draft.input, "factory draft 中😀")
        XCTAssertTrue(bodies.isEmpty, "Input must not render an unchanged bubble")
        var other = makeConversation(id: "factory-unrelated", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        other.hasUnreadReaction = false; other.unreadReactionCount = 0
        other.messages = [makeMessage(id: "factory-other", seq: 1)]
        state.conversationStore.commitConversationSnapshots(state.conversationStore.conversationMessageSnapshots() + [other])
        try await Task.sleep(nanoseconds: 250_000_000)
        bodies.removeAll()
        XCTAssertTrue(state.conversationStore.applyMessageReaction(messageID: "factory-other", emoji: "ok", operatorUID: "peer", action: "add", currentUserIDs: []))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(bodies.isEmpty, "Another message window cannot redraw these rows")
        XCTAssertTrue(state.conversationStore.applyMessageReaction(messageID: "factory-2", emoji: "ok", operatorUID: "peer", action: "add", currentUserIDs: []))
        try await rowFactoryWait { mounted["factory-2"]?.message.reactions.first?.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Set(bodies), ["factory-1", "factory-2", "factory-3"])
        for id in ["factory-0", "factory-4"] { XCTAssertEqual(mounted[id]?.rowModel, rows[id]) }
        for id in ["factory-1", "factory-2", "factory-3"] {
            XCTAssertEqual(mounted[id]?.rowModel.id, rows[id]?.id)
            XCTAssertEqual(mounted[id]?.rowModel.generation, rows[id]?.generation)
            XCTAssertGreaterThan(mounted[id]?.rowModel.renderVersion ?? 0, rows[id]?.renderVersion ?? 0)
        }
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
        XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(rowFactoryEditor(hosted.controller.view))), editorID)
        XCTAssertEqual(owner.draft.input, "factory draft 中😀")
        conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: conversation.id))
        XCTAssertEqual(conversation.messages.map(\.id), (0..<5).map { "factory-\($0)" })
    }
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END

    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
    @MainActor
    func testAppRowFactoryMatchesDirectAssemblyPixelsForCurrentLightAndDarkRows() throws {
        let state = rowFactoryState()
        let conversation = rowFactoryConversation(state: state)
        let rows = conversation.messages.prefix(2).enumerated().map { index, message in
            MessageRowModel(index: index, message: message, showsSenderHeader: false,
                senderUser: nil, displaySenderName: "Peer", timeSeparatorText: nil)
        }
        for appearance in [ColorScheme.light, .dark] {
            func surface(factory: Bool) -> some View {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        if factory {
                            ChatTimelineRow(row: row, conversationID: conversation.id, isGroupConversation: false,
                                onLongPress: {}, onReadTap: {})
                        } else {
                            AppFeatureComposition.makeTimelineBubble(
                                state: state, row: row, conversationID: conversation.id,
                                isGroupConversation: false, onLongPress: {}, onReadTap: {}
                            )
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.white).appStateEnvironment(state).environment(\.colorScheme, appearance)
            }
            let before = hostForSimulatorUI(surface(factory: false), size: CGSize(width: 390, height: 300))
            let beforeImage = hostedSnapshotImage(before)
            before.window.isHidden = true; before.window.rootViewController = nil
            let after = hostForSimulatorUI(surface(factory: true), size: CGSize(width: 390, height: 300))
            let afterImage = hostedSnapshotImage(after)
            after.window.isHidden = true; after.window.rootViewController = nil
            let label = appearance == .light ? "light" : "dark"
            add(snapshotAttachment(beforeImage, name: "row-factory-\(label)-before-current"))
            add(snapshotAttachment(afterImage, name: "row-factory-\(label)-after-current"))
            let beforePixels = try rowFactoryPixels(beforeImage), afterPixels = try rowFactoryPixels(afterImage)
            XCTAssertEqual(beforePixels.count, afterPixels.count)
            let changedPixels = stride(from: 0, to: min(beforePixels.count, afterPixels.count), by: 4).filter { offset in
                beforePixels[offset..<offset + 4] != afterPixels[offset..<offset + 4]
            }.count
            let metrics = XCTAttachment(string: "appearance=\(label); changed_pixels=\(changedPixels); width=\(beforeImage.cgImage?.width ?? 0); height=\(beforeImage.cgImage?.height ?? 0)")
            metrics.name = "row-factory-\(label)-pixel-metrics"; metrics.lifetime = .keepAlways; add(metrics)
            XCTAssertEqual(changedPixels, 0, "Current \(label) before/after pixels")
        }
    }
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END

    @MainActor
    func testAppRowFactoryConversationListLazilyForwardsRouteAndSearchTarget() async throws {
        let state = rowFactoryState()
        let conversation = rowFactoryConversation(state: state)
        state.conversationStore.commitConversationSnapshots([conversation])
        var list: ConversationListView?
        var chat: ChatView?
        var requests: [(String, RemoteTenantSearchJumpTarget?)] = []
        let real = AppFeatureComposition.chatRouting()
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.conversationListBody = { list = $0 }
        ChatTimelineRenderDiagnostics.chatBody = { chat = $0 }
        let hosted = hostForSimulatorUI(NavigationStackCompat {
            ConversationListView().environment(\.chatFeatureRouting, ChatFeatureRouting(makeChat: { id, jump in
                requests.append((id, jump))
                return real.makeChat(id, initialSearchJumpTarget: jump)
            }))
        }.appStateEnvironment(state), size: CGSize(width: 390, height: 844))
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil; ChatTimelineRenderDiagnostics.reset() }
        try await rowFactoryWait { list != nil }
        XCTAssertTrue(requests.isEmpty, "A destination is created only when its original route becomes active")
        let target = try JSONDecoder().decode(RemoteTenantSearchJumpTarget.self,
            from: Data(#"{"kind":"message","channel_id":"factory-chat","channel_type":"direct","message_id":"factory-2","channel_seq":3}"#.utf8))
        let route = ConversationListRoute(conversationID: conversation.id, initialSearchJumpTarget: target)
        list?.selectedConversationRoute = route
        try await rowFactoryWait { chat?.conversationID == conversation.id }
        XCTAssertEqual(list?.selectedConversationRoute?.id, route.id)
        XCTAssertEqual(requests.last?.0, conversation.id)
        XCTAssertEqual(requests.last?.1, target)
        XCTAssertEqual(chat?.initialSearchJumpTarget, target)
        list?.selectedConversationRoute = nil
        try await rowFactoryWait { list?.selectedConversationRoute == nil }
        requests.removeAll()
        let next = ConversationListRoute(conversationID: conversation.id, initialSearchJumpTarget: nil)
        XCTAssertNotEqual(next.id, route.id)
        list?.selectedConversationRoute = next
        try await rowFactoryWait { !requests.isEmpty }
        XCTAssertEqual(requests.last?.0, conversation.id)
        XCTAssertNil(requests.last?.1)
        XCTAssertEqual(list?.selectedConversationRoute?.id, next.id)
    }

    @MainActor
    private func rowFactoryState() -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("row-factory-\(UUID())")
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"isolated fixture"}}"#.utf8), isHTTPResponse: true, statusCode: 503)])
        let state = AppState(api: makeCallEndingAPI(transport: transport), realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        state.setCurrentUser(makeUser(id: "uid-1", name: "Viewer")); state.setAuthenticated(true)
        return state
    }

    @MainActor
    private func rowFactoryConversation(state: AppState) -> ConversationMessageSnapshot {
        var value = makeConversation(id: "factory-chat", unread: 0, lastMsgSeq: 5, lastReadSeq: 5)
        value.hasUnreadReaction = false; value.unreadReactionCount = 0
        value.firstUnreadSeq = 0; value.firstUnreadMessageID = ""; value.unreadAnchorState = "read"
        value.participants = [state.currentUser, makeUser(id: "uid-2", name: "Peer")]
        value.messages = (0..<5).map { index in
            var message = makeMessage(id: "factory-\(index)", senderId: index == 1 ? "uid-1" : "uid-2", seq: Int64(index + 1), isOutgoing: index == 1, text: index == 1 ? "Reply text 😀" : "Row \(index)")
            message.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            message.senderProvenance = .authoritativeStored
            return message
        }
        return value
    }

    @MainActor
    private func rowFactoryWait(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(condition(), "Real mounted row/navigation condition did not arrive")
    }

    @MainActor
    private func rowFactoryEditor(_ view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap(rowFactoryEditor).first
    }

    private func rowFactoryPixels(_ image: UIImage) throws -> Data {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = Data(count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
// WDT_IOS1_CHAT_ROW_FACTORY_20261110_END

// WDT_IOS1_ACTUAL_INPUT_100_EVENTS_20261111_BEGIN
extension DomainStoreTests {
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
    @MainActor
    func testAppRowFactoryOneHundredRealInputEventsKeepExistingBubblesUnchangedWithLiveRowControl() async throws {
        try input100CaptureActualLoadedImages(self, phase: "input100-begin")
        let state = rowFactoryState()
        let owner = ComposerState()
        let conversation = rowFactoryConversation(state: state)
        state.conversationStore.commitConversationSnapshots([conversation])
        var probe: ChatComposerInputProbe?
        var inputRenders = 0
        var mounted: [String: MessageBubble] = [:]
        var factoryInputs: [String] = []
        var bodyEvents: [[String: Any]] = []
        var events: [[String: Any]] = []
        var phase = "mount"
        var hostRetired = false
        var fixture: [String: Any] = ["conversationID": conversation.id,
            "messageIDs": conversation.messages.map(\.id), "hostPoints": [390, 950],
            "insertTextEventCount": 100, "eventUIOpportunityNanoseconds": 90_000_000,
            "bubbleContract": "Every one of100 real input events has zero cumulative bubble-body delta",
            "timelineContract": "Record every event; the original unchanged A/emoji/B and orderedIME cases retain their strict zero-timeline assertions",
            "positiveControl": "Current-scope existing factory-3 reaction; expected visible neighbors factory-2/3/4"]
        let realFactory = AppFeatureComposition.timelineRowFactory(state: state)
        ChatTimelineRenderDiagnostics.reset(); ChatTimelineRenderDiagnostics.enabled = true
        ChatComposerInputDiagnostics.capture = { value in
            if value.conversationID == conversation.id { probe = value; inputRenders += 1 }
        }
        ChatTimelineRenderDiagnostics.batchForwardBubble = { value in
            if value.conversationID == conversation.id { mounted[value.message.id] = value }
        }
        ChatTimelineRenderDiagnostics.scopedBubbleBody = { id, message in
            bodyEvents.append(["phase": phase, "conversationID": id, "messageID": message.id,
                "bubbleBodies": ChatTimelineRenderDiagnostics.bubbleBodies,
                "timelineBodies": ChatTimelineRenderDiagnostics.timelineBodies,
                "uptime": ProcessInfo.processInfo.systemUptime])
        }
        let hosted = try input100HostUsingOriginalComposerBoundary(AnyView(NavigationStackCompat {
            ChatView(composerState: owner, conversationID: conversation.id)
                .environment(\.chatTimelineRowFactory, ChatTimelineRowFactory(makeRow: { input, actions in
                    factoryInputs.append(input.row.id)
                    return realFactory.makeRow(input, actions)
                }))
        }.appStateEnvironment(state).onDisappear { hostRetired = true }), size: CGSize(width: 390, height: 950))
        defer {
            let record: [String: Any] = ["fixture": fixture, "events": events, "rawBubbleBodyEvents": bodyEvents,
                "completedInputEvents": events.count, "finalDiagnosticsEnabled": ChatTimelineRenderDiagnostics.enabled]
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "input100-raw-every-event-and-positive-control"; attachment.lifetime = .keepAlways; add(attachment)
            hosted.controller.view.endEditing(true); hosted.window.isHidden = true; hosted.window.rootViewController = nil
            ChatComposerInputDiagnostics.capture = nil; ChatTimelineRenderDiagnostics.reset()
        }
        try await rowFactoryWait { probe != nil && Set(mounted.keys) == Set(conversation.messages.map(\.id)) }
        let editor = try XCTUnwrap(rowFactoryEditor(hosted.controller.view))
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let editorID = ObjectIdentifier(editor)
        XCTAssertTrue(hosted.window.isKeyWindow && editor.window === hosted.window)
        XCTAssertTrue(try XCTUnwrap(probe).owner === owner)
        XCTAssertEqual(Set(factoryInputs), Set(conversation.messages.map(\.id)))
        XCTAssertGreaterThan(ChatTimelineRenderDiagnostics.bubbleBodies, 0)
        XCTAssertEqual(editor.text, ""); XCTAssertEqual(owner.draft.input, "")
        phase = "keyboard"
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 300_000_000)
        phase = "initial-settle"
        var previous = [ChatTimelineRenderDiagnostics.bubbleBodies, ChatTimelineRenderDiagnostics.timelineBodies]
        var stableOpportunities = 0
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            hosted.controller.view.layoutIfNeeded()
            let current = [ChatTimelineRenderDiagnostics.bubbleBodies, ChatTimelineRenderDiagnostics.timelineBodies]
            stableOpportunities = current == previous ? stableOpportunities + 1 : 0
            previous = current
            if stableOpportunities == 4 { break }
        }
        XCTAssertEqual(stableOpportunities, 4, "Establish the mounted/keyboard baseline before input, never resample it per event")
        let baselineBubbles = ChatTimelineRenderDiagnostics.bubbleBodies
        let baselineTimelines = ChatTimelineRenderDiagnostics.timelineBodies
        let baselineRows = mounted.mapValues(\.rowModel)
        fixture["baselineBubbleBodies"] = baselineBubbles; fixture["baselineTimelineBodies"] = baselineTimelines
        fixture["hostID"] = String(describing: hostID); fixture["editorID"] = String(describing: editorID)
        fixture["ownerID"] = String(describing: ObjectIdentifier(owner))
        XCTAssertGreaterThan(baselineBubbles, 0); XCTAssertTrue(ChatTimelineRenderDiagnostics.enabled)
        let alphabet = ["A", "中", "😀", "b", "文", "🚀", "C", "字", "🙂", "d"]
        let characters = (0..<100).map { alphabet[$0 % alphabet.count] }
        var expected = ""
        for (offset, character) in characters.enumerated() {
            phase = String(format: "input-%03d", offset + 1)
            let rendersBefore = inputRenders
            let bubblesBefore = ChatTimelineRenderDiagnostics.bubbleBodies
            let timelinesBefore = ChatTimelineRenderDiagnostics.timelineBodies
            expected += character
            editor.insertText(character)
            editor.delegate?.textViewDidChange?(editor)
            try await Task.sleep(nanoseconds: 90_000_000)
            hosted.controller.view.layoutIfNeeded()
            let expectedSelection = NSRange(location: expected.utf16.count, length: 0)
            let sameEditor = rowFactoryEditor(hosted.controller.view) === editor
            let value = try XCTUnwrap(probe)
            events.append(["index": offset + 1, "insertedCharacter": character, "expectedDraft": expected,
                "editorText": editor.text ?? "", "ownerDraft": owner.draft.input,
                "renderedComposerDraft": value.composer.composerRenderDraft.input,
                "expectedUTF16Selection": [expectedSelection.location, expectedSelection.length],
                "editorSelection": [editor.selectedRange.location, editor.selectedRange.length],
                "ownerSelection": [owner.draft.selection.location, owner.draft.selection.length],
                "inputRendersBefore": rendersBefore, "inputRendersAfter": inputRenders,
                "bubbleBodiesBefore": bubblesBefore, "bubbleBodiesAfter": ChatTimelineRenderDiagnostics.bubbleBodies,
                "cumulativeBubbleDelta": ChatTimelineRenderDiagnostics.bubbleBodies - baselineBubbles,
                "timelineBodiesBefore": timelinesBefore, "timelineBodiesAfter": ChatTimelineRenderDiagnostics.timelineBodies,
                "cumulativeTimelineDelta": ChatTimelineRenderDiagnostics.timelineBodies - baselineTimelines,
                "sameEditor": sameEditor, "sameOwner": value.owner === owner,
                "diagnosticsEnabled": ChatTimelineRenderDiagnostics.enabled, "canSend": value.input.canSend,
                "uptime": ProcessInfo.processInfo.systemUptime])
            XCTAssertTrue(ChatTimelineRenderDiagnostics.enabled)
            XCTAssertEqual(ChatTimelineRenderDiagnostics.bubbleBodies, baselineBubbles, "event \(offset + 1)")
            XCTAssertGreaterThan(inputRenders, rendersBefore, "Each insert must reach the real input component")
            XCTAssertEqual(editor.text, expected); XCTAssertEqual(owner.draft.input, expected)
            XCTAssertEqual(value.composer.composerRenderDraft.input, expected)
            XCTAssertEqual(editor.selectedRange, expectedSelection); XCTAssertEqual(owner.draft.selection, expectedSelection)
            XCTAssertTrue(value.input.canSend && !value.input.isDisabled)
            XCTAssertTrue(sameEditor && value.owner === owner)
            XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
            XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
            XCTAssertEqual(ObjectIdentifier(editor), editorID)
        }
        XCTAssertEqual(events.count, 100); XCTAssertEqual(expected.count, 100)
        XCTAssertEqual(expected.utf16.count, 130)
        phase = "positive-control"
        let positiveStart = bodyEvents.count, positiveBubbles = ChatTimelineRenderDiagnostics.bubbleBodies
        XCTAssertTrue(state.conversationStore.applyMessageReaction(messageID: "factory-3", emoji: "ok",
            operatorUID: "peer", action: "add", currentUserIDs: []))
        try await rowFactoryWait { mounted["factory-3"]?.message.reactions.first?.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let changedRows = Set(bodyEvents.dropFirst(positiveStart).compactMap { $0["messageID"] as? String })
        XCTAssertGreaterThan(ChatTimelineRenderDiagnostics.bubbleBodies, positiveBubbles)
        XCTAssertEqual(changedRows, ["factory-2", "factory-3", "factory-4"])
        for id in ["factory-0", "factory-1"] { XCTAssertEqual(mounted[id]?.rowModel, baselineRows[id]) }
        for id in ["factory-2", "factory-3", "factory-4"] {
            XCTAssertEqual(mounted[id]?.rowModel.id, baselineRows[id]?.id)
            XCTAssertEqual(mounted[id]?.rowModel.generation, baselineRows[id]?.generation)
            XCTAssertGreaterThan(mounted[id]?.rowModel.renderVersion ?? 0, baselineRows[id]?.renderVersion ?? 0)
        }
        fixture["positiveBubbleDelta"] = ChatTimelineRenderDiagnostics.bubbleBodies - positiveBubbles
        fixture["positiveRenderedMessageIDs"] = changedRows.sorted()
        fixture["inputFinalTimelineDelta"] = events.last?["cumulativeTimelineDelta"]
        XCTAssertTrue(ChatTimelineRenderDiagnostics.enabled && probe?.owner === owner)
        XCTAssertTrue(rowFactoryEditor(hosted.controller.view) === editor)
        XCTAssertEqual(owner.draft.input, expected); XCTAssertEqual(editor.text, expected)
        add(snapshotAttachment(hostedSnapshotImage(hosted), name: "input100-same-host-visible-row-positive-control"))
        phase = "host-retirement"
        hosted.controller.view.endEditing(true)
        hosted.controller.rootView = AnyView(EmptyView())
        try await rowFactoryWait { hostRetired && !editor.isFirstResponder && editor.window == nil }
    }
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
}
// WDT_IOS1_ACTUAL_INPUT_100_EVENTS_20261111_END

// WDT_IOS1_ACTUAL_DYLD_IMAGE_IDENTITY_20261111_BEGIN
@MainActor private var input100RetainedImagePIDs = Set<Int32>()

@MainActor
func input100CaptureActualLoadedImages(_ test: XCTestCase, phase: String) throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let retainBytes = input100RetainedImagePIDs.insert(pid).inserted
    var images: [[String: Any]] = []
    for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
        let path = String(cString: name)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard ["WenDaTong", "WenDaTongTests", "WenDaTong.debug.dylib"].contains(fileName) else { continue }
        let raw = UnsafeRawPointer(header)
        let mach = raw.load(as: mach_header_64.self)
        XCTAssertEqual(mach.magic, MH_MAGIC_64)
        var offset = MemoryLayout<mach_header_64>.size
        let commandEnd = offset + Int(mach.sizeofcmds)
        var loadedUUID: String?
        for _ in 0..<mach.ncmds {
            let command = raw.advanced(by: offset).load(as: load_command.self)
            guard command.cmdsize >= MemoryLayout<load_command>.size,
                  offset + Int(command.cmdsize) <= commandEnd else {
                throw NSError(domain: "Input100LoadedMachO", code: 1)
            }
            if command.cmd == LC_UUID {
                let value = raw.advanced(by: offset).load(as: uuid_command.self)
                loadedUUID = UUID(uuid: value.uuid).uuidString
            }
            offset += Int(command.cmdsize)
        }
        let uuid = try XCTUnwrap(loadedUUID, "Read LC_UUID from this actual dyld-loaded header")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        images.append(["dyldIndex": index, "actualLoadedPath": path,
            "actualLoadedHeaderAddress": String(describing: header), "inMemoryLC_UUID": uuid,
            "actualLoadedFileSHA256": digest, "actualLoadedFileBytes": bytes.count,
            "fileName": fileName, "pid": pid])
        if retainBytes {
            let binary = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
            binary.name = "actual-dyld-loaded-\(fileName)-\(pid).bin"
            binary.lifetime = .keepAlways; test.add(binary)
        }
    }
    XCTAssertTrue(images.contains { ($0["fileName"] as? String) == "WenDaTong" })
    XCTAssertTrue(images.contains { ($0["fileName"] as? String) == "WenDaTongTests" })
    let record: [String: Any] = ["phase": phase, "testCase": test.name, "pid": pid,
        "uptime": ProcessInfo.processInfo.systemUptime,
        "bundleMainExecutable": Bundle.main.executableURL?.path ?? "",
        "testClassBundleExecutable": Bundle(for: DomainStoreTests.self).executableURL?.path ?? "",
        "identitySource": "dyld actual header LC_UUID plus SHA256 of the actual dyld image path while this native process is alive",
        "retainedActualLoadedBytes": retainBytes, "loadedImages": images]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]),
        uniformTypeIdentifier: "public.json")
    attachment.name = "actual-runtime-loaded-images-\(phase)-\(pid)"; attachment.lifetime = .keepAlways; test.add(attachment)
}
// WDT_IOS1_ACTUAL_DYLD_IMAGE_IDENTITY_20261111_END


// WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testContactCardFeatureProjectionPreservesDirectoryAndFallbackFields() {
        let directoryNumberMatch = IMUser(
            id: "directory-id", userID: "card-subject", name: "Directory name",
            title: "Title", department: "Department", phone: "123", email: "test@example.test",
            status: "在线", enterprise: "Directory enterprise", avatarSeed: 42,
            avatarURL: "https://avatar.example.test/photo.png", avatarVersion: "v2",
            avatarUpdatedAt: "updated", badges: ["Badge"]
        )
        let directoryIDMatch = makeUser(id: "card-subject", name: "Second match")

        func project(text: String, name: String? = nil, meta: String?, contacts: [IMUser] = []) -> ContactCardPresentationContent {
            var message = makeMessage(id: "card-message", seq: 1, text: text, kind: .contactCard)
            message.attachmentName = name
            message.attachmentMeta = meta
            return ContactCardPresentationContent(
                message: message, contacts: contacts, enterpriseName: "Scoped enterprise",
                outgoing: true, onOpen: { _ in }
            )
        }
        func fallback(id: String, name: String, seed: String) -> IMUser {
            IMUser(id: id, name: name, title: "", department: "", phone: "", email: "",
                   status: "在线", enterprise: "Scoped enterprise",
                   avatarSeed: UInt(bitPattern: seed.hashValue), badges: [])
        }

        let known = project(text: "个人名片：Ignored", name: "Other", meta: " card-subject\n",
                            contacts: [directoryNumberMatch, directoryIDMatch])
        XCTAssertEqual(known.contactID, "card-subject")
        XCTAssertEqual(known.contact, directoryNumberMatch)
        XCTAssertEqual(known.displayContact, directoryNumberMatch)
        XCTAssertTrue(known.outgoing)

        let explicit = project(text: "个人名片：Ignored", name: " 推荐名片：Explicit ", meta: " missing ")
        let explicitContact = fallback(id: "missing", name: "推荐名片：Explicit", seed: "missing")
        XCTAssertEqual(explicit.contactID, "missing")
        XCTAssertEqual(explicit.contact, explicitContact)
        XCTAssertEqual(explicit.displayContact, explicitContact)

        let fromText = project(text: " 个人名片：推荐名片：Original ", meta: "missing")
        XCTAssertEqual(fromText.contact, fallback(id: "missing", name: "Original", seed: "missing"))

        let emptyName = project(text: "个人名片：Ignored", name: " \n", meta: "missing")
        XCTAssertEqual(emptyName.contact, fallback(id: "missing", name: "missing", seed: "missing"))

        let displayOnly = project(text: "推荐名片：Original", meta: " \n ")
        XCTAssertNil(displayOnly.contact)
        XCTAssertTrue(displayOnly.contactID.isEmpty)
        XCTAssertEqual(displayOnly.displayContact, fallback(id: "contact_card_display", name: "Original", seed: "Original"))

        let defaultDisplay = project(text: "个人名片：", meta: nil)
        XCTAssertNil(defaultDisplay.contact)
        XCTAssertEqual(defaultDisplay.displayContact, fallback(id: "contact_card_display", name: "个人名片", seed: ""))
    }
}
// WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_END
