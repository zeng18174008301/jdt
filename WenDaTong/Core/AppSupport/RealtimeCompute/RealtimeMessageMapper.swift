import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
/// Local to one synchronous pure calculation. No AppState, Store or shared formatter.
final class RealtimeMessageMapper {
    let input: RealtimeMappingIdentity
    let reducer: RealtimeConversationReducer
    let fractional = ISO8601DateFormatter()
    let standard = ISO8601DateFormatter()
    let today = DateFormatter()
    let otherDay = DateFormatter()
    var currentUser: IMUser { input.currentUser }
    var contacts: [IMUser] { input.contacts }
    var contactRemarks: [String: String] { input.remarks }
    var groups: [RealtimeMappingIdentity.GroupName] { input.groups }
    var shouldShowGroupMemberCount: Bool { input.showsGroupMemberCount }

    init(input: RealtimeMappingIdentity, reducer: RealtimeConversationReducer) {
        self.input = input; self.reducer = reducer
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (formatter, format) in [(today, "HH:mm"), (otherDay, "M月d日")] {
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = input.clock.calendar; formatter.timeZone = input.clock.timeZone
            formatter.dateFormat = format
        }
    }
    func parseRemoteDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? standard.date(from: raw)
    }
    func displayTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "刚刚" }
        return parseRemoteDate(raw).map(displayTime) ?? raw
    }
    func displayTime(_ date: Date) -> String {
        (input.clock.calendar.isDate(date, inSameDayAs: input.clock.day) ? today : otherDay).string(from: date)
    }
    func rtcMessageDisplayTime(_ remote: RemoteMessage) -> String {
        let record = remote.channelSeq > 0 && !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RTCCallRecordPayload.parse(contentType: remote.contentType, channelType: remote.channelType,
                fromUID: remote.fromUID, payload: remote.payload) : nil
        return RTCCallRecordTimeProjection.messageDate(outerDate: parseRemoteDate(remote.createdAt), record: record,
            contentType: remote.contentType, channelType: remote.channelType, fromUID: remote.fromUID).map(displayTime) ?? "时间未知"
    }
    func currentUserIdentitySet() -> Set<String> { input.currentIdentities }
    func currentMessageSenderIdentitySet() -> Set<String> { input.senderIdentities }
    func isCurrentUserIdentity(_ raw: String) -> Bool { input.currentIdentities.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func isCurrentMessageSender(_ raw: String) -> Bool { input.senderIdentities.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func localOutgoingMessageSenderID() -> String { input.outgoingSenderID }
    func resolveTenantAssetURL(_ value: String) -> String { input.resolvedAvatarURLs[value] ?? value }
    func user(_ value: IMUser, matchesIdentifier id: String) -> Bool {
        ConversationChannelIdentityMapper.user(value, matchesIdentifier: id)
    }
    func user(for id: String) -> IMUser? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if input.currentIdentities.contains(id) { return currentUser }
        return contacts.first { user($0, matchesIdentifier: id) } ?? input.directoryUsers.first { user($0, matchesIdentifier: id) }
    }
    func knownSenderUsers(for senderID: String, participants: [IMUser]) -> [IMUser] {
        let id = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        var result: [IMUser] = []
        if let participant = participants.first(where: { user($0, matchesIdentifier: id) }) { result.append(participant) }
        if let cached = user(for: id), !result.contains(where: {
            user($0, matchesIdentifier: cached.id) || user($0, matchesIdentifier: cached.userID) || user($0, matchesIdentifier: cached.username)
        }) { result.append(cached) }
        return result
    }
    func contactRemarkValue(matching identifiers: [String], contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
                            directory: ContactStore.DirectoryPresentationSnapshot? = nil) -> String? {
        guard !identifiers.isEmpty, !identifiers.contains(where: isCurrentUserIdentity) else { return nil }
        let remarks = directory?.remarks ?? contactRemarks
        for id in identifiers {
            if let remark = remarks[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty { return remark }
        }
        let matched: IMUser?
        if let contactLookup {
            matched = contactLookup.firstContact(matchingAny: identifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        } else { matched = (directory?.contacts ?? contacts).first { contact in identifiers.contains { user(contact, matchesIdentifier: $0) } } }
        guard let contact = matched else { return nil }
        for id in [contact.id, contact.userID, contact.username] {
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let remark = remarks[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty { return remark }
        }
        return nil
    }
    func isPendingLocalMessage(_ value: ChatMessage) -> Bool { reducer.isPendingLocalMessage(value) }
    func applyRemoteReadSummary(from remote: RemoteMessage, to message: inout ChatMessage) {
        reducer.applyRemoteReadSummary(from: remote, to: &message, readReceiptsEnabled: input.readReceiptsEnabled)
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
