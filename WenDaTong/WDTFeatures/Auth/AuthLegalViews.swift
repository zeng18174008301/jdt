import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

struct LegalDocumentLinksView: View {
    typealias Style = AuthLegalLinksStyle

    @EnvironmentObject private var state: AppState
    @Binding private var isAccepted: Bool
    let prefix: String
    var style: Style = .auth
    private let showsConsentToggle: Bool
    private let shakeTrigger: Int
    private let consentAccessibilityIdentifier: String?
    @State private var presentationRouter = LegalDocumentPresentationRouter()

    init(
        prefix: String,
        style: Style = .auth,
        isAccepted: Binding<Bool>? = nil,
        shakeTrigger: Int = 0,
        consentAccessibilityIdentifier: String? = nil
    ) {
        self.prefix = prefix
        self.style = style
        self._isAccepted = isAccepted ?? .constant(false)
        self.showsConsentToggle = isAccepted != nil
        self.shakeTrigger = shakeTrigger
        self.consentAccessibilityIdentifier = consentAccessibilityIdentifier
    }

    var body: some View {
        content
            .sheet(item: presentationBinding) { _ in
                LegalDocumentSheet(router: $presentationRouter)
                    .environmentObject(state)
            }
    }

    private var presentationBinding: Binding<LegalDocumentPresentation?> {
        Binding(
            get: { presentationRouter.presentation },
            set: { value in
                if value == nil {
                    presentationRouter.dismiss()
                }
            }
        )
    }

    private var content: some View {
        AuthLegalLinksContent(prefix: prefix, style: style, isAccepted: $isAccepted, showsConsentToggle: showsConsentToggle,
            shakeTrigger: shakeTrigger, consentAccessibilityIdentifier: consentAccessibilityIdentifier,
            links: LegalDocumentType.allCases, terms: .terms, privacy: .privacy,
            activeType: presentationRouter.presentation?.type, isPresented: presentationRouter.presentation != nil,
            title: { $0.title }, symbol: { $0.symbol }, open: open)
    }

    private func open(_ type: LegalDocumentType) {
        _ = presentationRouter.present(type)
    }
}

struct LegalDocumentPresentation: Identifiable, Equatable {
    enum LoadState: Equatable {
        case loading
        // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：展示受控拉取的协议正文，不把 URL 交给 Safari
        case ready(content: LegalDocumentContent)
        // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
        case failed(message: String)
    }

    let type: LegalDocumentType
    var loadState: LoadState

    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
    let id = UUID()
    var requestID = UUID()
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END
    let accessibilityIdentifier = "legal_document_presentation"
}

struct LegalDocumentPresentationRouter {
    private(set) var presentation: LegalDocumentPresentation?

    @discardableResult
    mutating func present(_ type: LegalDocumentType) -> Bool {
        guard presentation == nil else { return false }
        presentation = LegalDocumentPresentation(type: type, loadState: .loading)
        return true
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：路由状态承载协议正文内容
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
    mutating func finish(_ result: Result<LegalDocumentContent, LegalDocumentLoadFailure>, requestID: UUID) {
        guard var current = presentation, current.requestID == requestID, current.loadState == .loading else {
            return
        }
        switch result {
        case .success(let content):
            current.loadState = .ready(content: content)
        case .failure(let error):
            current.loadState = .failed(message: error.message)
        }
        presentation = current
    }
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    @discardableResult
    mutating func retry() -> Bool {
        guard var current = presentation else { return false }
        guard case .failed = current.loadState else { return false }
        current.requestID = UUID() // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110
        current.loadState = .loading
        presentation = current
        return true
    }

    mutating func dismiss() {
        presentation = nil
    }
}

private struct LegalDocumentSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var router: LegalDocumentPresentationRouter

    var body: some View {
        let presentation = router.presentation // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110
        return AuthLegalDocumentSheetContent(title: presentation?.type.title ?? "协议内容",
            identifier: presentation?.accessibilityIdentifier ?? "legal_document_presentation", onDone: {
                router.dismiss()
                dismiss()
            }) {
            content
        }
        // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
        .task(id: presentation?.requestID) {
            guard let presentation, presentation.loadState == .loading, !Task.isCancelled else { return }
            await resolve(presentation)
        }
        // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END
    }

    @ViewBuilder
    private var content: some View {
        switch router.presentation?.loadState {
        case .ready(let content):
            LegalDocumentWebView(content: content)
        case .failed(let message):
            AuthLegalDocumentFailureContent(message: message) { router.retry() }
        case .loading, .none:
            AuthLegalDocumentLoadingContent()
        }
    }

    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_BEGIN
    @MainActor
    private func resolve(_ presentation: LegalDocumentPresentation) async {
        let result = await state.legalDocumentContent(for: presentation.type)
        guard !Task.isCancelled else { return }
        router.finish(result, requestID: presentation.requestID)
    }
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110_END
}

// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：内嵌展示协议正文并限制后续导航同源
private struct LegalDocumentWebView: UIViewRepresentable {
    let content: LegalDocumentContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedBaseURL = content.baseURL
        let loadKey = [
            content.sourceURL.absoluteString,
            String(content.manifest.manifestRevision),
            content.manifest.manifestHash
        ].joined(separator: "|")
        guard context.coordinator.loadedKey != loadKey else { return }
        context.coordinator.loadedKey = loadKey
        webView.loadHTMLString(content.displayHTML, baseURL: content.baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var allowedBaseURL: URL?
        var loadedKey: String?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame != nil else {
                decisionHandler(.cancel)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
                return
            }
            guard let allowedBaseURL,
                  IMAPIClient.isAllowedLegalDocAssetURL(url, base: allowedBaseURL) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            guard let url = navigationResponse.response.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
                return
            }
            guard let allowedBaseURL,
                  IMAPIClient.isAllowedLegalDocAssetURL(url, base: allowedBaseURL) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
