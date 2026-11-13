import IM4Domain
import SwiftUI

// WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_BEGIN
public struct ChatMessageDeletionAlerts: ViewModifier {
    @Binding private var adminDeleteCandidate: ChatMessage?
    @Binding private var failedDeleteCandidate: ChatMessage?
    private let deletionActions: ChatDeletionActions

    public init(
        adminDeleteCandidate: Binding<ChatMessage?>,
        failedDeleteCandidate: Binding<ChatMessage?>,
        actions: ChatDeletionActions
    ) {
        _adminDeleteCandidate = adminDeleteCandidate
        _failedDeleteCandidate = failedDeleteCandidate
        deletionActions = actions
    }

    public func body(content: Content) -> some View {
        content
        .alert("对全员删除该消息？", isPresented: Binding(
            get: { adminDeleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    adminDeleteCandidate = nil
                }
            }
        )) {
            Button("取消", role: .cancel, action: cancelAdminDeletion)
            Button("删除", role: .destructive, action: confirmAdminDeletion)
        } message: {
            Text("删除后群内所有成员不可见。")
        }
        .alert("删除失败消息？", isPresented: Binding(
            get: { failedDeleteCandidate != nil },
            set: { if !$0 { failedDeleteCandidate = nil } }
        ), presenting: failedDeleteCandidate) { message in
            Button("取消", role: .cancel, action: cancelFailedDeletion)
            Button("删除", role: .destructive) { confirmFailedDeletion(message) }
        } message: { _ in
            Text("这条消息尚未发送成功，删除后将从本机移除。")
        }
    }

    func cancelAdminDeletion() {
        adminDeleteCandidate = nil
    }

    func confirmAdminDeletion() {
        if let message = adminDeleteCandidate {
            deletionActions.adminDelete(message)
        }
        adminDeleteCandidate = nil
    }

    func cancelFailedDeletion() {
        failedDeleteCandidate = nil
    }

    func confirmFailedDeletion(_ message: ChatMessage) {
        failedDeleteCandidate = nil
        deletionActions.failedDelete(message)
    }
}
// WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_END
