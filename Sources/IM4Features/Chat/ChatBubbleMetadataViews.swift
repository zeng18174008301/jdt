import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
public struct ContactCardPresentationContent: View {
    let contact: IMUser?
    let displayContact: IMUser
    let contactID: String
    let outgoing: Bool
    let onOpen: (IMUser) -> Void
    @Environment(\.chatCertificationRendering) private var certificationSource

    public var body: some View {
        Button {
            guard let contact else { return }
            onOpen(contact)
        } label: {
            HStack(spacing: 10) {
                ChatAvatarView(name: displayContact.name, seed: displayContact.avatarSeed, size: 42, imageURL: displayContact.avatarURL, avatarVersion: displayContact.avatarVersion, avatarUpdatedAt: displayContact.avatarUpdatedAt, certificationReference: certificationSource?.reference(forExactUID: contactID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(displayContact.name)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.ink)
                            .lineLimit(1)
                        ChatCertificationPillView(
                            exactUID: contactID,
                            compact: true
                        )
                    }
                    Text("个人名片")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(outgoing ? .white.opacity(0.78) : IMColor.muted)
                }
                Spacer(minLength: 4)
                if contact != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(outgoing ? .white.opacity(0.72) : IMColor.muted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_BEGIN
    public init(
        message: ChatMessage,
        contacts: [IMUser],
        enterpriseName: String,
        outgoing: Bool,
        onOpen: @escaping (IMUser) -> Void
    ) {
        let contactName = (message.attachmentName
            ?? message.text
                .replacingOccurrences(of: "个人名片：", with: "")
                .replacingOccurrences(of: "推荐名片：", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contactID = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        func fallbackContact(id: String, name: String, avatarSeed: UInt) -> IMUser {
            IMUser(id: id, name: name, title: "", department: "", phone: "", email: "",
                   status: "在线", enterprise: enterpriseName, avatarSeed: avatarSeed, badges: [])
        }

        let contact: IMUser?
        if contactID.isEmpty {
            contact = nil
        } else {
            contact = contacts.first { $0.id == contactID || $0.userID == contactID }
                ?? fallbackContact(id: contactID, name: contactName.isEmpty ? contactID : contactName,
                                   avatarSeed: UInt(bitPattern: contactID.hashValue))
        }
        self.init(
            contact: contact,
            displayContact: contact ?? fallbackContact(
                id: "contact_card_display", name: contactName.isEmpty ? "个人名片" : contactName,
                avatarSeed: UInt(bitPattern: contactName.hashValue)
            ),
            contactID: contactID,
            outgoing: outgoing,
            onOpen: onOpen
        )
    }
    // WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_END

    public init(contact: IMUser? = nil,
        displayContact: IMUser,
        contactID: String,
        outgoing: Bool,
        onOpen: @escaping (IMUser) -> Void) {
        self.contact = contact
        self.displayContact = displayContact
        self.contactID = contactID
        self.outgoing = outgoing
        self.onOpen = onOpen
    }
}

struct MessageEditedBadge: View {
    let outgoing: Bool

    var body: some View {
        Text("已编辑")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(outgoing ? .white.opacity(0.82) : IMColor.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(outgoing ? .white.opacity(0.16) : IMColor.muted.opacity(0.13))
            )
    }
}

struct PinnedMessageIconBadge: View {
    let outgoing: Bool

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(outgoing ? IMColor.warning : .white)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(outgoing ? .white : IMColor.warning)
                    .shadow(color: IMColor.warning.opacity(0.22), radius: 6, y: 3)
            )
            .overlay(
                Circle()
                    .stroke(outgoing ? IMColor.warning.opacity(0.45) : .white.opacity(0.9), lineWidth: 1)
            )
            .accessibilityLabel("已置顶")
    }
}

struct MessageMetaTags: View {
    let message: ChatMessage

    private var tags: [(String, Color)] {
        var items: [(String, Color)] = []
        if message.isFavorited {
            items.append(("收藏", IMColor.brand))
        }
        if let reportState = message.reportState {
            items.append((reportState, IMColor.danger))
        }
        for tag in message.auditTags {
            items.append((tag, IMColor.warning))
        }
        return items
    }

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.0) { tag in
                        StatusPill(title: tag.0, color: tag.1)
                    }
                }
            }
            .frame(maxWidth: 220, alignment: message.isOutgoing ? .trailing : .leading)
        }
    }
}
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
