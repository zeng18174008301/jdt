import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

public struct MessageEditContent: View {
    let message: ChatMessage
    let conversationID: String
    let save: (String) async -> Bool
    @State private var draft: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    public init(
        message: ChatMessage,
        conversationID: String,
        save: @escaping (String) async -> Bool
    ) {
        self.message = message
        self.conversationID = conversationID
        self.save = save
        _draft = State(initialValue: message.text)
    }

    public var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.edit?(ChatSecondaryEditProbe(isSaving: isSaving, submit: submitEdit))
#endif
        NavigationStackCompat {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(symbol: "pencil.and.outline", title: "编辑消息", subtitle: "修改发送内容，保存后会显示已编辑状态。", showsCloseButton: true)
                TextEditor(text: $draft)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minHeight: 130)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(im4Hex: 0xF3F5FA)))
                    .im4ScrollContentBackgroundHiddenCompat()
                if isSaving {
                    Text("等待服务端确认编辑结果…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                PrimaryButton(title: isSaving ? "正在保存" : "保存编辑", systemImage: "checkmark", disabled: isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    submitEdit()
                }
                Spacer()
            }
            .padding(18)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func submitEdit() {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        let submittedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let accepted = await save(submittedText)
                        isSaving = false
                        guard accepted else { return }
                        dismiss()
                    }
    }

}

public struct MessageReportContent: View {
    let senderName: String
    let certification: ChatCertificationRendering.Reference?
    let actions: ChatReportActions
    let message: ChatMessage
    let conversationID: String
    @State private var reason = MessageReportCategory.illegalTrade.rawValue
    @State private var description = ""
    @State private var inlineMessage: String?
    @State private var isSubmitting = false
    @State private var isLookingUp = false
    @State private var readOnlyReport: ChatReportDisplay?
    @Environment(\.dismiss) private var dismiss

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReadOnly: Bool {
        readOnlyReport != nil
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !isLookingUp
            && !isReadOnly
            && MessageReportCategory.allowedReasons.contains(reason)
            && !trimmedDescription.isEmpty
    }

    private var senderUserID: String {
        let uid = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return uid.isEmpty ? "未知用户ID" : uid
    }

    private var senderAvatarSeed: UInt {
        message.senderAvatarSeed == 0 ? UInt(bitPattern: senderUserID.hashValue) : message.senderAvatarSeed
    }

    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_BEGIN
    public var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.report?(ChatSecondaryReportProbe(isSubmitting: isSubmitting,
            isLookingUp: isLookingUp, readOnly: isReadOnly, reason: $reason, description: $description, submit: submitReport))
#endif
        reportContent
    }
    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_END

    private var reportContent: some View {
        NavigationStackCompat {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(
                        symbol: "exclamationmark.shield.fill",
                        title: "举报此消息",
                        subtitle: isReadOnly ? "该消息已举报成功，以下为上次提交内容。" : "请选择违规类型并填写理由，举报内容会提交给企业审核。",
                        showsCloseButton: true
                    )
                    if isLookingUp {
                        Label("正在检查举报状态", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.72)))
                            .accessibilityIdentifier("message_report_lookup_loading")
                    }
                    if isReadOnly {
                        Label("已举报成功", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.success.opacity(0.12)))
                            .accessibilityIdentifier("message_report_readonly_banner")
                    }
                    reportedSenderCard
                    reportedMessageCard
                    VStack(alignment: .leading, spacing: 10) {
                        Text("举报分类")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        VStack(spacing: 9) {
                            ForEach(MessageReportCategory.allCases, id: \.self) { item in
                                Button {
                                    guard !isReadOnly, !isLookingUp else { return }
                                    reason = item.rawValue
                                    inlineMessage = nil
                                } label: {
                                    HStack {
                                        Text(item.rawValue)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(IMColor.ink)
                                        Spacer()
                                        Image(systemName: reason == item.rawValue ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(reason == item.rawValue ? IMColor.brand : IMColor.muted)
                                    }
                                    .padding(14)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.82)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isReadOnly || isLookingUp)
                                .accessibilityIdentifier("message_report_reason_\(item.rawValue)")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("举报理由")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $description)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(minHeight: 118)
                                .padding(10)
                                .im4ScrollContentBackgroundHiddenCompat()
                                .disabled(isReadOnly || isLookingUp)
                                .accessibilityIdentifier("message_report_description_input")
                            if description.isEmpty && !isReadOnly {
                                Text("请补充举报理由")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(IMColor.muted.opacity(0.56))
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.86)))
                    }
                    if let inlineMessage {
                        Text(inlineMessage)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isReadOnly ? IMColor.success : IMColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("message_report_inline_error")
                    }
                    if !isReadOnly {
                        PrimaryButton(
                            title: isLookingUp ? "检查中..." : (isSubmitting ? "提交中..." : "提交举报"),
                            systemImage: "paperplane.fill",
                            disabled: !canSubmit,
                            action: submitReport
                        )
                        .accessibilityIdentifier("message_report_submit_button")
                    }
                }
                .padding(18)
            }
            .background(AuroraBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: message.id) {
            await loadExistingReportIfNeeded()
        }
    }

    private var reportedSenderCard: some View {
        HStack(spacing: 12) {
            ChatAvatarView(
                name: senderName,
                seed: senderAvatarSeed,
                size: 48,
                imageURL: message.senderAvatarURL,
                avatarVersion: message.senderAvatarVersion,
                avatarUpdatedAt: message.senderAvatarUpdatedAt,
                certificationReference: certification
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    ChatCertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
                Text("用户ID \(senderUserID)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.84)))
        .accessibilityIdentifier("message_report_sender_card")
    }

    private var reportedMessageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("被举报消息")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted)
            Text(messageReportPreviewText(for: message))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.84)))
        .accessibilityIdentifier("message_report_message_card")
    }

    private func submitReport() {
        guard !isSubmitting else { return }
        guard canSubmit else {
            inlineMessage = "请选择分类并填写举报理由"
            return
        }
        isSubmitting = true
        inlineMessage = nil
        let selectedReason = reason
        let reportDescription = trimmedDescription
        let reportMessageID = message.id
        let reportConversationID = conversationID
        Task {
            let result = await actions.submit(selectedReason, reportDescription)
            await MainActor.run {
                isSubmitting = false
                switch result {
                case .submitted:
                    dismiss()
                case .alreadyReported(let report):
                    applyReadOnlyReport(report)
                case .rejected:
                    break
                case .failed:
                    inlineMessage = "提交失败，请稍后重试"
                }
            }
        }
    }

    @MainActor
    private func applyReadOnlyReport(_ report: ChatReportDisplay) {
        readOnlyReport = report
        let reportedReason = report.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reportedReason.isEmpty {
            reason = reportedReason
        }
        description = report.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        inlineMessage = nil
    }

    private func loadExistingReportIfNeeded() async {
        guard !isSubmitting, readOnlyReport == nil else { return }
        await MainActor.run {
            isLookingUp = true
            inlineMessage = nil
        }
        let report = await actions.lookup()
        await MainActor.run {
            isLookingUp = false
            if let report {
                applyReadOnlyReport(report)
            }
        }
    }

    public init(senderName: String,
        certification: ChatCertificationRendering.Reference? = nil,
        actions: ChatReportActions,
        message: ChatMessage,
        conversationID: String) {
        self.senderName = senderName
        self.certification = certification
        self.actions = actions
        self.message = message
        self.conversationID = conversationID
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
