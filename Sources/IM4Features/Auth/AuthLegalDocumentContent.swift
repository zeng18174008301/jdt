// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthLegalDocumentSheetContent<Content: View>: View {
    let title: String
    let identifier: String
    let onDone: () -> Void
    let content: Content

    public init(title: String, identifier: String, onDone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.onDone = onDone
        self.content = content()
    }

    public var body: some View {
        NavigationStackCompat {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            onDone()
                        }
                        .accessibilityIdentifier("legal_document_done_button")
                    }
                }
        }
        .accessibilityIdentifier(
            identifier
        )
    }
}

public struct AuthLegalDocumentFailureContent: View {
    let message: String
    let onRetry: () -> Void

    public init(message: String, onRetry: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .multilineTextAlignment(.center)
            Button("重试") {
                onRetry() // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110: the changed request ID restarts the sheet task.
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("legal_document_retry_button")
        }
        .padding(24)
        .accessibilityIdentifier("legal_document_error")
    }
}

public struct AuthLegalDocumentLoadingContent: View {
    public init() {}

    public var body: some View {
        ProgressView("正在加载协议内容...")
            .font(.system(size: 14, weight: .semibold))
            .accessibilityIdentifier("legal_document_loading")
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
