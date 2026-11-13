import Foundation
import IM4Domain
import XCTest
@testable import WenDaTong

// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
final class DomainModuleContractTests: XCTestCase {
    @MainActor
    func testPackageValuesHaveOneIdentityAndFlowThroughRealStoreAndCache() throws {
        XCTAssertEqual(ObjectIdentifier(WenDaTong.ChatMessage.self), ObjectIdentifier(IM4Domain.ChatMessage.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.Conversation.self), ObjectIdentifier(IM4Domain.Conversation.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.ConversationMessageSnapshot.self), ObjectIdentifier(IM4Domain.ConversationMessageSnapshot.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.IMUser.self), ObjectIdentifier(IM4Domain.IMUser.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.GroupInfo.self), ObjectIdentifier(IM4Domain.GroupInfo.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.RTCCallRecordPayload.self), ObjectIdentifier(IM4Domain.RTCCallRecordPayload.self))
        let scopeA = try LocalMessageScope(accountID: "domain-a", tenantID: "tenant", appID: "app", actorID: "actor", deviceID: "device")
        let scopeB = try LocalMessageScope(accountID: "domain-b", tenantID: "tenant", appID: "app", actorID: "actor", deviceID: "device")
        let store = ConversationStore(scope: scopeA)
        let message = makeMessage()
        let snapshot = IM4Domain.ConversationMessageSnapshot(conversation: makeConversation(), messages: [message])
        store.commitConversationSnapshots([snapshot])
        XCTAssertEqual(store.conversationMessageSnapshot(id: snapshot.id), snapshot)
        let retained = try XCTUnwrap(store.messageMemoryStore.conversationMessages(for: snapshot.id))
        XCTAssertEqual(retained.messages, [message])
        let cached = try JSONEncoder().encode(CachedMessage(message: message))
        let restored = try JSONDecoder().decode(CachedMessage.self, from: cached).model
        XCTAssertEqual(restored.id, message.id)
        XCTAssertEqual(restored.senderId, message.senderId)
        XCTAssertEqual(restored.status, message.status)
        store.bindMessageScope(scopeB, preservesMessages: true)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(retained.messages.isEmpty)
        XCTAssertNil(store.conversationMessageSnapshot(id: snapshot.id))
        store.commitConversationSnapshots([snapshot])
        XCTAssertEqual(store.conversationMessageSnapshot(id: snapshot.id)?.messages, [message])
    }

    func testPublicInitializersPreserveDefaultsAndDetachedSnapshotMutation() {
        let message = makeMessage()
        XCTAssertEqual(message.senderId, " sender ", "The old synthesized initializer did not normalize IDs")
        XCTAssertEqual(message.senderProvenance, .unknown)
        XCTAssertNil(message.quote)
        XCTAssertNil(message.createdAt)
        XCTAssertNil(message.readCount)
        XCTAssertNil(message.attachmentUploadFailure)
        XCTAssertNil(message.rtcCallRecord)
        XCTAssertFalse(message.isPinned)
        XCTAssertEqual(message.attachmentCacheKey, "")
        let metadata = makeConversation()
        XCTAssertNil(metadata.memberCount)
        XCTAssertEqual(metadata.historyVisibleFromSeq, 1)
        XCTAssertFalse(metadata.historyBoundaryConfirmed)
        var value = IM4Domain.ConversationMessageSnapshot(conversation: metadata, messages: [message])
        value.title = "Changed"
        value.messages.removeAll()
        XCTAssertEqual(metadata.title, "Original")
        XCTAssertEqual(value.conversation.title, "Changed")
        XCTAssertEqual(value.withoutMessages, value.conversation)
        XCTAssertTrue(value.messages.isEmpty)
    }

    func testReplyAndMentionCodableKeepOriginalKeysAndDifferentDecodeNormalization() throws {
        let legacyReply = Data(#"{"messageID":" m ","senderID":" u ","senderName":" Name ","summary":" Body "}"#.utf8)
        let reply = try JSONDecoder().decode(IM4Domain.MessageReplyContext.self, from: legacyReply)
        XCTAssertEqual(reply.id, "m")
        XCTAssertEqual(reply.quoteText, "Name：Body")
        XCTAssertEqual(reply.thumbnailURL, "")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(["messageID", "senderID", "senderName", "summary", "contentType", "channelSeq", "isUnavailable", "thumbnailURL"]))
        XCTAssertEqual(encoded["channelSeq"] as? Int, 0)
        let rawMention = Data(#"{"imUID":" u ","userID":" n ","username":" login ","displayText":" Name "}"#.utf8)
        let decoded = try JSONDecoder().decode(IM4Domain.MentionIdentity.self, from: rawMention)
        XCTAssertEqual(decoded.imUID, " u ", "Original synthesized Codable bypasses the normalizing initializer")
        let initialized = IM4Domain.MentionIdentity(imUID: " u ", userID: " n ", username: " login ", displayText: " Name ")
        XCTAssertEqual(initialized.id, "u")
        XCTAssertEqual(initialized.mentionToken, "@Name")
        XCTAssertNotEqual(decoded, initialized)
        XCTAssertEqual(try JSONDecoder().decode(IM4Domain.MentionIdentity.self, from: JSONEncoder().encode(initialized)), initialized)
    }

    func testStickerLegacyAliasesCanonicalEncodingAndSendPayloadRemainDistinct() throws {
        let data = Data(#"{"kind":" gif ","fileID":" canonical ","file_id":"legacy","mime_type":" image/gif ","url":" /asset ","cache_key":" cache ","size_bytes":42}"#.utf8)
        let variant = try JSONDecoder().decode(IM4Domain.StickerMessageVariantSnapshot.self, from: data)
        XCTAssertEqual(variant.fileID, "canonical")
        XCTAssertEqual(variant.assetURL, "/asset")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(variant)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(["kind", "fileID", "mimeType", "assetURL", "sizeBytes", "thumbnailURL", "cacheKey"]))
        XCTAssertNil(encoded["file_id"])
        let sticker = IM4Domain.StickerMessageSnapshot(stickerID: " sticker ", fileID: " original ", mimeType: " image/gif ", variants: [variant], fallbackText: " ")
        XCTAssertEqual(sticker.cacheIdentity, "original|cache|gif|sticker")
        XCTAssertEqual(sticker.fallbackText, "[GIF表情]")
        let cachedVariants = sticker.dictionary["variants"] as? [[String: Any]]
        let sendVariants = sticker.messageSendDictionary["variants"] as? [[String: Any]]
        XCTAssertEqual(cachedVariants?.first?["url"] as? String, "/asset")
        XCTAssertNil(sendVariants?.first?["url"])
        XCTAssertEqual(sendVariants?.first?["file_id"] as? String, "canonical")
    }

    func testRTCValueCodableAndEnumRawContractsDoNotAcquireModuleDiscriminators() throws {
        let record = IM4Domain.RTCCallRecordPayload(
            schemaVersion: 1, callID: "call", callType: .video, callerUID: "caller", calleeUID: "callee",
            finalOutcome: .completed, startedAt: Date(timeIntervalSince1970: 1), answeredAt: Date(timeIntervalSince1970: 2),
            mediaConnectedAt: Date(timeIntervalSince1970: 3), endedAt: Date(timeIntervalSince1970: 6), durationSeconds: 3,
            reasonCode: "completed", fallbackText: "通话结束", endActorUID: "caller", finalMediaMode: "audio"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "callID", "callType", "callerUID", "calleeUID", "finalOutcome", "startedAt", "answeredAt", "mediaConnectedAt", "endedAt", "durationSeconds", "reasonCode", "fallbackText", "endActorUID", "finalMediaMode"]))
        XCTAssertEqual(object["startedAt"] as? Double, 1)
        XCTAssertEqual(object["callType"] as? String, "video")
        XCTAssertEqual(object["finalOutcome"] as? String, "completed")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("IM4Domain"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(IM4Domain.RTCCallRecordPayload.self, from: data), record)
        XCTAssertEqual(IM4Domain.ConversationKind.direct.rawValue, "单聊")
        XCTAssertEqual(IM4Domain.MessageKind.rtcCallRecord.rawValue, "rtc_call_record")
        XCTAssertEqual(IM4Domain.MessageDelivery.failed.rawValue, "未送达 · 点按重发")
        XCTAssertEqual(IM4Domain.BatchForwardSenderProvenance.authoritativeStored.rawValue, "authoritative_stored")
        XCTAssertEqual(IM4Domain.GroupMuteMode.scheduled.rawValue, "scheduled")
        XCTAssertEqual(IM4Domain.RTCCallRecordOutcome.callerCanceled.rawValue, "caller_canceled")
    }

    func testContactAndGroupValuesPreserveIdentityDefaultsAndCheckedSendability() {
        let user = makeUser(id: " uid ", name: "Peer")
        XCTAssertEqual(user.id, " uid ")
        XCTAssertEqual(user.userID, " uid ")
        XCTAssertEqual(user.withName("New").id, user.id)
        XCTAssertEqual(user.withDepartment("Dept", pathNames: ["Root", "Dept"]).departmentPathNames, ["Root", "Dept"])
        let cancelled = IM4Domain.IMUser(id: "gone", name: "Hidden", title: "", department: "", phone: "", email: "", status: " CANCELED ", enterprise: "", avatarSeed: 0, badges: [])
        XCTAssertEqual(cancelled.displayName, "用户已注销")
        let group = IM4Domain.GroupInfo(id: "group", name: "Group", notice: "", owner: "Owner", members: [user], admins: [], muted: false, allMuted: false)
        XCTAssertEqual(group.myRole, "member")
        XCTAssertNil(group.allMuteMode)
        XCTAssertEqual(group.effectiveMemberCount, 1)
        XCTAssertNil(group.visibleMemberCount)
        XCTAssertTrue(group.historyVisible)
        XCTAssertEqual(group.historyVisibleFromSeq, 1)
        assertCheckedSendable(group)
        assertCheckedSendable(IM4Domain.FriendRequest(id: "request", name: "Name", source: "", message: "", accepted: false))
    }

    private func assertCheckedSendable<Value: Sendable>(_ value: Value) {}
    private func makeUser(id: String = "peer", name: String = "Peer") -> IM4Domain.IMUser {
        IM4Domain.IMUser(id: id, name: name, title: "", department: "", phone: "", email: "", status: "", enterprise: "", avatarSeed: 0, badges: [])
    }
    private func makeMessage() -> IM4Domain.ChatMessage {
        IM4Domain.ChatMessage(id: "message", senderId: " sender ", senderName: "Name", text: "Body", time: "T", isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: [], unreadBy: [])
    }
    private func makeConversation() -> IM4Domain.Conversation {
        IM4Domain.Conversation(id: "conversation", title: "Original", subtitle: "", kind: .direct, lastMessage: "Body", time: "T", unread: 1, isPinned: false, isMuted: false, accentHex: 0, participants: [makeUser()])
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
extension DomainModuleContractTests {
    func testPublicSearchMatcherRetainsWidthPinyinAndStableTieContracts() {
        let first = makeUser(id: "b", name: "Alice")
        let second = makeUser(id: "a", name: "Alice")
        let fullWidthQuery = "\u{FF21}\u{FF2C}\u{FF29}\u{FF23}\u{FF25}"
        XCTAssertEqual(IM4Domain.IMUserSearchMatcher.sortedMatches(users: [first, second], query: fullWidthQuery).map(\.id), ["a", "b"])
        XCTAssertEqual(WenDaTong.IMUserSearchMatcher.sortedMatches(users: [first, second], query: " ").map(\.id), ["b", "a"])
        let chinese = makeUser(id: "pinyin", name: "\u{5F20}\u{4E09}")
        XCTAssertTrue(IM4Domain.IMUserSearchMatcher.matches(user: chinese, query: "zhangsan"))
        XCTAssertTrue(WenDaTong.IMUserSearchMatcher.matches(user: chinese, query: "zs"))
        XCTAssertFalse(IM4Domain.IMUserSearchMatcher.matches(user: chinese, query: "unrelated"))
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
