import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

struct HTMLWidgetAction: Hashable {
    let id: String
    let message: String
}

struct HTMLArtifact: Identifiable, Hashable {
    let id: String
    let reference: String
    let title: String
    let html: String
    let height: Int
    let actions: [HTMLWidgetAction]

    var marker: String { "[[pig-ui:\(reference)]]" }

    init?(tool: ToolDisplay) {
        guard tool.shortName == "html_render", tool.status == .succeeded, !tool.isError,
              let details = tool.details?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: details) as? [String: Any],
              let artifact = object["pigHtml"] as? [String: Any],
              let version = artifact["version"] as? Int, version == 1 || version == 2,
              let html = artifact["html"] as? String,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              html.utf8.count <= 256 * 1024 else { return nil }
        id = tool.id
        if version == 2 {
            guard let reference = artifact["reference"] as? String,
                  Self.reference(in: "[[pig-ui:\(reference)]]") == reference else { return nil }
            self.reference = reference
        } else {
            // Earlier experimental sessions have no placement marker or actions.
            reference = tool.id
        }
        let title = (artifact["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? "Interactive controls" : String(title.prefix(120))
        self.html = html
        height = min(1000, max(1, artifact["height"] as? Int ?? 44))
        var actions: [HTMLWidgetAction] = []
        var seenIDs = Set<String>()
        if version == 2, let declared = artifact["actions"] as? [[String: Any]] {
            for action in declared.prefix(16) {
                guard let id = action["id"] as? String,
                      id.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                      let message = action["message"] as? String else { continue }
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.utf16.count <= 2000,
                      !trimmed.hasPrefix("/"), !trimmed.hasPrefix("!"),
                      seenIDs.insert(id).inserted else { continue }
                actions.append(HTMLWidgetAction(id: id, message: trimmed))
            }
        }
        self.actions = actions
    }

    static func reference(in text: String) -> String? {
        guard text.hasPrefix("[[pig-ui:"), text.hasSuffix("]]"), text.count == 27 else { return nil }
        let reference = String(text.dropFirst(9).dropLast(2))
        guard reference.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return reference
    }

    static func references(in markdown: String) -> Set<String> {
        Set(MarkdownRenderSegment.segments(from: MarkdownBlockParser.parse(markdown)).compactMap {
            if case .htmlWidget(let reference) = $0 { return reference }
            return nil
        })
    }

    static func selected(from artifacts: [String: HTMLArtifact], in markdown: String) -> [String: HTMLArtifact] {
        let references = references(in: markdown)
        return artifacts.filter { references.contains($0.key) }
    }
}

// A frameless, content-sized piece of a native Markdown reply. The utility menu
// appears only on hover/right-click; no title, card, or toolbar surrounds it.
struct HTMLArtifactView: View {
    @Environment(\.appTheme) private var appTheme
    let artifact: HTMLArtifact
    let theme: AppThemeChoice
    var textSizeStep: Int = TextSizePreference.step
    var onSendMessage: ((String) -> Void)? = nil
    @State private var measuredHeight: CGFloat = 44
    @State private var hovering = false
    @State private var showsSource = false
    @State private var reloadToken = 0
    @State private var previewError: String?
    @State private var pendingAction: HTMLWidgetAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HTMLArtifactWebView(
                artifact: artifact, theme: theme, textSizeStep: textSizeStep,
                onHeight: { measuredHeight = $0 },
                onAction: { action in
                    if onSendMessage != nil, pendingAction == nil { pendingAction = action }
                },
                onError: { previewError = $0 }
            )
            .id(reloadToken)
            .frame(height: measuredHeight)
            .accessibilityLabel(artifact.title)
            if let previewError {
                Text(previewError)
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { utilityMenu }
        .overlay(alignment: .topTrailing) {
            Menu { utilityMenu } label: {
                Image(systemName: "ellipsis")
                    .font(AppFonts.ui(12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(appTheme.panel, in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Interactive controls options")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
        .onAppear { measuredHeight = CGFloat(artifact.height) }
        .sheet(isPresented: $showsSource) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(artifact.title).font(AppFonts.ui(14, weight: .semibold))
                    Spacer()
                    Button("Done") { showsSource = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    NativeCodeBlockView(code: artifact.html, language: "html", theme: theme, textSizeStep: textSizeStep)
                }
            }
            .padding(18)
            .frame(width: 900, height: 650)
            .background(appTheme.background)
        }
        .alert("Send message to the agent?", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("Send") {
                pendingAction = nil
                onSendMessage?(action.message)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
    }

    @ViewBuilder private var utilityMenu: some View {
        Button("View Source…") { showsSource = true }
        Button("Copy HTML") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(artifact.html, forType: .string)
        }
        Button("Save HTML…", action: save)
        Divider()
        Button("Reload Controls") {
            previewError = nil
            pendingAction = nil
            reloadToken += 1
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Save the original HTML fragment. PiG's styling and sandbox do not apply outside the app."
        let invalid = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        panel.nameFieldStringValue = artifact.title.components(separatedBy: invalid).joined(separator: "-") + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try artifact.html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct HTMLArtifactWebView: NSViewRepresentable {
    let artifact: HTMLArtifact
    let theme: AppThemeChoice
    let textSizeStep: Int
    let onHeight: (CGFloat) -> Void
    let onAction: (HTMLWidgetAction) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let world = WKContentWorld.world(name: HTMLWidgetDocument.worldName)
        configuration.userContentController.add(coordinator, contentWorld: world, name: HTMLWidgetDocument.handlerName)
        let webView = ChatWidgetWKWebView(frame: .zero, configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // Never load generated markup until offline content rules are installed.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PiG.HTMLArtifact.Offline.v1", encodedContentRuleList: HTMLWidgetDocument.contentRules
        ) { [weak webView, weak coordinator] list, error in
            DispatchQueue.main.async {
                guard let webView, let coordinator, !coordinator.isDismantled else { return }
                guard let list else {
                    coordinator.onError?("Controls blocked: \(error?.localizedDescription ?? "could not configure offline content rules").")
                    return
                }
                webView.configuration.userContentController.add(list)
                coordinator.isReady = true
                coordinator.loadIfNeeded(in: webView)
            }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeight = onHeight
        coordinator.onAction = onAction
        coordinator.onError = onError
        webView.underPageBackgroundColor = theme.palette.background.nsColor
        if coordinator.artifact != artifact || coordinator.theme != theme || coordinator.textSizeStep != textSizeStep {
            coordinator.artifact = artifact
            coordinator.theme = theme
            coordinator.textSizeStep = textSizeStep
            coordinator.loadedDocument = nil
            coordinator.document = HTMLWidgetDocument.make(artifact: artifact, theme: theme, textSizeStep: textSizeStep)
        }
        coordinator.loadIfNeeded(in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.isReady = false
        coordinator.onError = nil
        coordinator.onHeight = nil
        coordinator.onAction = nil
        webView.stopLoading()
        (webView as? ChatWidgetWKWebView)?.stopMonitoringScroll()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: HTMLWidgetDocument.handlerName, contentWorld: .world(name: HTMLWidgetDocument.worldName)
        )
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var artifact: HTMLArtifact?
        var theme: AppThemeChoice?
        var textSizeStep: Int?
        var document: String?
        var loadedDocument: String?
        var generation = ""
        var isReady = false
        var isDismantled = false
        var onHeight: ((CGFloat) -> Void)?
        var onAction: ((HTMLWidgetAction) -> Void)?
        var onError: ((String) -> Void)?

        func loadIfNeeded(in webView: WKWebView) {
            guard isReady, let document, loadedDocument != document else { return }
            loadedDocument = document
            generation = UUID().uuidString
            let content = webView.configuration.userContentController
            content.removeAllUserScripts()
            content.addUserScript(WKUserScript(
                source: HTMLWidgetDocument.disableWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
            ))
            content.addUserScript(WKUserScript(
                source: HTMLWidgetDocument.bootstrap(generation: generation), injectionTime: .atDocumentEnd,
                forMainFrameOnly: false, in: .world(name: HTMLWidgetDocument.worldName)
            ))
            webView.loadHTMLString(document, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isDismantled, message.webView === webView, !message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString.components(separatedBy: "#").first == "about:srcdoc",
                  let body = message.body as? [String: Any], body["generation"] as? String == generation else { return }
            switch body["kind"] as? String {
            case "height":
                guard let height = (body["height"] as? NSNumber)?.doubleValue,
                      height.isFinite, height >= 0, height <= 1_000_000 else { return }
                (webView as? ChatWidgetWKWebView)?.contentHeight = CGFloat(height)
                onHeight?(CGFloat(min(1000, max(1, ceil(height)))))
            case "action":
                guard let id = body["id"] as? String,
                      let action = artifact?.actions.first(where: { $0.id == id }) else { return }
                onAction?(action)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let documentURL = navigationAction.request.url?.absoluteString.components(separatedBy: "#").first
            if documentURL == "about:blank" || documentURL == "about:srcdoc" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            offerExternalLink(navigationAction)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            offerExternalLink(navigationAction)
            return nil
        }

        private func offerExternalLink(_ action: WKNavigationAction) {
            guard action.navigationType == .linkActivated, let url = action.request.url,
                  url.scheme == "https" || url.scheme == "http" else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Open link outside PiG?"
                alert.informativeText = url.absoluteString
                alert.addButton(withTitle: "Open Link")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onError?("Controls stopped. Use Reload Controls to restart them.")
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    }
}
