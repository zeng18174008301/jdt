public struct ChatTimelinePolicy: Equatable, Sendable {
    public let recallEnabled: Bool?
    public let editEnabled: Bool?
    public let forwardEnabled: Bool?
    public let showsProcessingNotices: Bool
    public init(recallEnabled: Bool?, editEnabled: Bool?, forwardEnabled: Bool?, showsProcessingNotices: Bool) {
        self.recallEnabled = recallEnabled; self.editEnabled = editEnabled
        self.forwardEnabled = forwardEnabled; self.showsProcessingNotices = showsProcessingNotices
    }
}
