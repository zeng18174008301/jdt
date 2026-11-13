import IM4Domain

public struct ChatForwardDraftPresentation: Equatable, Sendable {
    public let actorUID: String
    public let activeTargetTab: BatchForwardTargetTab
    public let selectedSourceCount: Int
    public let selectedTargetCount: Int
    public let selectedTargetIdentityKeysInOrder: [String]
    public let targetSearchQuery: String
    public let targetsByIdentity: [String: BatchForwardTarget]
    public let submissionPhase: BatchForwardSubmissionPhase
    public init(actorUID: String, activeTargetTab: BatchForwardTargetTab,
        selectedSourceCount: Int, selectedTargetCount: Int,
        selectedTargetIdentityKeysInOrder: [String], targetSearchQuery: String,
        submissionPhase: BatchForwardSubmissionPhase, targetsByIdentity: [String: BatchForwardTarget]) {
        self.actorUID = actorUID; self.activeTargetTab = activeTargetTab
        self.selectedSourceCount = selectedSourceCount; self.selectedTargetCount = selectedTargetCount
        self.selectedTargetIdentityKeysInOrder = selectedTargetIdentityKeysInOrder
        self.targetSearchQuery = targetSearchQuery; self.submissionPhase = submissionPhase; self.targetsByIdentity = targetsByIdentity
    }
}
