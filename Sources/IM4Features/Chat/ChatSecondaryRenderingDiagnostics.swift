import SwiftUI

#if DEBUG
struct ChatSecondaryEditProbe { let isSaving: Bool; let submit: () -> Void }
struct ChatSecondaryReportProbe {
    let isSubmitting: Bool
    let isLookingUp: Bool
    let readOnly: Bool
    let reason: Binding<String>
    let description: Binding<String>
    let submit: () -> Void
}
struct ChatSecondaryAnnouncementEditorProbe { let isPublishing: Bool; let submit: () -> Void }
@MainActor public enum ChatSecondaryRenderingDiagnostics {
    public internal(set) static var receipt: ((ChatReceiptInput) -> Void)?
    static var edit: ((ChatSecondaryEditProbe) -> Void)?
    static var report: ((ChatSecondaryReportProbe) -> Void)?
    static var announcement: ((Binding<Bool>) -> Void)?
    static var announcementEditor: ((ChatSecondaryAnnouncementEditorProbe) -> Void)?
    static var reaction: ((@escaping (String) -> Void) -> Void)?
    static var confirmation: ((@escaping () -> Void) -> Void)?
    public internal(set) static var forward: ((ChatForwardInput, ChatForwardActions) -> Void)?
}
#endif
