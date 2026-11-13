// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
public enum QuickAddFlow: String, Equatable, Sendable {
    case actions
    case directChat
    case findUser
    case createGroup
}

public struct QuickAddPresentationState: Equatable, Sendable {
    public var isPresented = false
    public var flow: QuickAddFlow = .actions

    public init() {}

    public mutating func presentActions() {
        flow = .actions
        isPresented = true
    }

    public mutating func select(_ nextFlow: QuickAddFlow) {
        flow = nextFlow
        isPresented = true
    }

    public mutating func dismiss() {
        isPresented = false
        flow = .actions
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
