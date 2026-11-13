import SwiftUI
import IM4Domain

// WDT_IOS1_COMPOSER_DRAFT_OWNER_BOUNDARY_20261111_BEGIN
@MainActor
final public class ComposerState: ObservableObject {
    public typealias Draft = ChatComposerDraft
    public typealias Token = ChatComposerToken
    @Published public var draft = Draft()
    private(set) public var token: Token?
    private var savedDrafts: [String: Draft] = [:]
    private var epoch: UInt64 = 0

    public func activate(scope: [String?], conversationID: String) {
        guard token?.scope != scope || token?.conversationID != conversationID else { return }
        if token?.scope != scope {
            savedDrafts.removeAll()
            epoch &+= 1
        } else if let token {
            savedDrafts[token.conversationID] = draft
        }
        token = .init(scope: scope, conversationID: conversationID, epoch: epoch)
        draft = savedDrafts[conversationID] ?? Draft()
    }

    public func binding<Value>(_ key: WritableKeyPath<Draft, Value>, conversationID: String? = nil, scope: [String?]? = nil) -> Binding<Value> {
        guard let conversationID, let scope else {
            return Binding(get: { self.draft[keyPath: key] }, set: { self.draft[keyPath: key] = $0 })
        }
        // Bindings made before onAppear belong to the immediately upcoming scope epoch.
        let expectedEpoch = token?.scope == scope ? epoch : epoch &+ 1
        return Binding(get: {
            guard self.epoch == expectedEpoch, self.token?.scope == scope else { return Draft()[keyPath: key] }
            return (self.token?.conversationID == conversationID ? self.draft : self.savedDrafts[conversationID] ?? Draft())[keyPath: key]
        }, set: { value in
            guard self.epoch == expectedEpoch, self.token?.scope == scope else { return }
            if self.token?.conversationID == conversationID { self.draft[keyPath: key] = value }
            else {
                var saved = self.savedDrafts[conversationID] ?? Draft()
                saved[keyPath: key] = value
                self.savedDrafts[conversationID] = saved
            }
        })
    }

    // Use the exact existing text/reply/mention merge, addressed to the originating draft.
    public func restoreFailedSend(_ sent: Draft, origin: Token) {
        guard let current = token, current.scope == origin.scope, current.epoch == origin.epoch else { return }
        var value = current.conversationID == origin.conversationID ? draft : savedDrafts[origin.conversationID] ?? Draft()
        // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_BEGIN
        if value.input.isEmpty {
            value.prependInputPreservingSelection(sent.input)
        } else if value.input != sent.input && !value.input.contains(sent.input) {
            value.prependInputPreservingSelection(sent.input + "\n")
        }
        // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_END
        if value.replyQuote == nil {
            value.replyQuote = sent.replyQuote
            value.replyContext = sent.replyContext
        }
        value.mentionAll = value.mentionAll || sent.mentionAll
        var seen = Set<String>()
        value.externalMentions = (value.externalMentions + sent.mentions + sent.externalMentions).filter {
            value.input.contains($0.mentionToken) && !$0.id.isEmpty && seen.insert($0.id).inserted
        }
        if current.conversationID == origin.conversationID { draft = value }
        else { savedDrafts[origin.conversationID] = value }
    }

    public init() {}
}
// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END

// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
public struct ComposerStateObservation<Content: View>: View {
    @ObservedObject var owner: ComposerState
    @ViewBuilder var content: () -> Content
    public var body: some View { content() }

    public init(owner: ComposerState,
        @ViewBuilder content: @escaping () -> Content) {
        self.owner = owner
        self.content = content
    }
}
// WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
// WDT_IOS1_COMPOSER_DRAFT_OWNER_BOUNDARY_20261111_END
