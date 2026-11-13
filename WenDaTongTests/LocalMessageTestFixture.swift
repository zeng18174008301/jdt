import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

enum LocalMessageTestFixture {
    static func context(actor: String = "actor-a", device: String = "device-a") -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account",
            tenantID: "tenant",
            imUID: actor,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "app",
            deviceID: device
        )
    }

    static func message(
        id: String,
        sequence: Int64,
        outgoing: Bool = false,
        status: MessageDelivery = .sent,
        text: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            senderId: outgoing ? "actor-a" : "peer",
            senderName: outgoing ? "Me" : "Peer",
            text: text ?? "message \(sequence)",
            time: "09:00",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            channelSeq: sequence,
            isOutgoing: outgoing,
            status: status,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
    }

    static func attachmentMessage(id: String, sizeBytes: Int64) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            senderId: "actor-a",
            senderName: "Me",
            text: "fixture.bin",
            time: "09:00",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            channelSeq: 0,
            isOutgoing: true,
            status: .sending,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: [],
            attachmentName: "fixture.bin",
            attachmentSizeBytes: sizeBytes
        )
        message.contentType = "file"
        message.attachmentMimeType = "application/octet-stream"
        message.attachmentMediaCategory = "document"
        message.attachmentExtension = "bin"
        return message
    }

    static func outgoingAttachmentIntent(
        message: ChatMessage,
        sourceURL: URL,
        sizeBytes: Int64
    ) -> LocalMessageOutgoingIntent {
        var conversation = conversation(id: "attachment-\(message.id)", sequences: [])
        conversation.messages = [message]
        return LocalMessageOutgoingIntent(
            conversation: LocalMessageConversationSnapshot(
                conversation: conversation,
                channelID: "channel-\(message.id)",
                channelType: "person",
                currentActorID: "actor-a"
            ),
            message: CachedMessage(message: message),
            operationKind: "send_attachment",
            attachment: LocalMessageAttachmentIntent(
                fileURL: sourceURL,
                fileName: message.attachmentName ?? "fixture.bin",
                mimeType: message.attachmentMimeType,
                sizeBytes: sizeBytes
            )
        )
    }

    static func conversation(
        id: String,
        sequences: [Int64],
        kind: ConversationKind = .direct,
        coveredThrough: Int64? = nil,
        lastMsgSeq: Int64? = nil,
        unread: Int = 0,
        textPrefix: String = "message"
    ) -> ConversationMessageSnapshot {
        let messages = sequences.map { sequence in
            message(
                id: "\(id)-message-\(sequence)",
                sequence: sequence,
                text: "\(textPrefix)\(sequence)"
            )
        }
        var conversation = ConversationMessageSnapshot(
            id: id,
            title: id,
            subtitle: "Peer",
            kind: kind,
            lastMessage: messages.last?.text ?? "",
            time: "09:00",
            unread: unread,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0x2266CC,
            participants: [],
            messages: messages,
            sortTimestamp: 1_700_000_000 + Double(sequences.last ?? 0)
        )
        conversation.lastMsgSeq = lastMsgSeq ?? sequences.max() ?? 0
        conversation.messageCoveredThroughSeq = coveredThrough ?? sequences.max() ?? 0
        return conversation
    }

    static func snapshot(
        id: String,
        count: Int,
        actor: String = "actor-a",
        kind: ConversationKind = .direct,
        requiresServerRevalidation: Bool = false,
        textPrefix: String = "message"
    ) -> LocalMessageConversationSnapshot {
        snapshot(
            id: id,
            sequences: count > 0 ? Array(1...count).map(Int64.init) : [],
            coveredThrough: Int64(count),
            lastMsgSeq: Int64(count),
            unread: 0,
            actor: actor,
            kind: kind,
            requiresServerRevalidation: requiresServerRevalidation,
            textPrefix: textPrefix
        )
    }

    static func snapshot(
        id: String,
        sequences: [Int64],
        coveredThrough: Int64,
        lastMsgSeq: Int64,
        unread: Int,
        actor: String = "actor-a",
        kind: ConversationKind = .direct,
        requiresServerRevalidation: Bool = false,
        textPrefix: String = "message"
    ) -> LocalMessageConversationSnapshot {
        let conversation = conversation(
            id: id,
            sequences: sequences,
            kind: kind,
            coveredThrough: coveredThrough,
            lastMsgSeq: lastMsgSeq,
            unread: unread,
            textPrefix: textPrefix
        )
        return LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: "channel-\(id)",
            channelType: kind == .group ? "group" : "person",
            currentActorID: actor,
            requiresServerRevalidation: requiresServerRevalidation
        )
    }

    static func profileContactProjection(
        revision: UInt64,
        actor: String,
        remark: String,
        blocked: Bool
    ) -> LocalProfileContactProjection {
        let user = IMUser(
            id: actor,
            userID: "user-\(actor)",
            username: "account-\(actor)",
            name: "Contact \(actor)",
            title: "",
            department: "Engineering",
            departmentPathNames: ["Engineering"],
            phone: "",
            email: "",
            status: "在线",
            enterprise: "Tenant",
            avatarSeed: 42,
            badges: []
        )
        return LocalProfileContactProjection(
            revision: revision,
            contacts: [PersistedContactUser(user)],
            remarks: [actor: remark],
            blacklist: blocked
                ? [PersistedBlacklistItem(BlacklistItem(id: actor, name: user.name, reason: "已拉黑"))]
                : [],
            originalNames: [actor: user.name]
        )
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
