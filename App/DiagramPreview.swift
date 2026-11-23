import SwiftUI
import WebKit

struct DiagramPreview: View {
    let source: String
    @State private var showSource = false
    @State private var status = PreviewStatus.loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                Spacer()
                if case .ready = status {
                    Button(showSource ? "Preview" : "Source") { showSource.toggle() }
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("diagram-source")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(.secondary)
            Divider()
            if status == .unavailable {
                Text("Diagram preview unavailable. The source is below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            if showSource || status == .unavailable {
                CodePreview(source: source, language: "mermaid")
            }
            if status != .unavailable {
                DiagramCanvas(source: source) { height in
                    status = height > 0 ? .ready(height) : .unavailable
                }
                .frame(height: showSource ? 0 : status.height)
                .opacity(showSource || status == .loading ? 0 : 1)
                .accessibilityHidden(showSource || status == .loading)
                .accessibilityIdentifier("markdown-diagram")
                .overlay {
                    if status == .loading && !showSource { ProgressView().accessibilityLabel("Rendering diagram") }
                }
            }
        }
        .contentPanel()
    }

    private enum PreviewStatus: Equatable {
        case loading, ready(CGFloat), unavailable

        var height: CGFloat {
            switch self {
            case .ready(let height): min(max(50, height), 400)
            default: 64
            }
        }
    }
}

private struct DiagramCanvas: UIViewRepresentable {
    let source: String
    let rendered: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        if let document = context.coordinator.document {
            webView.loadFileURL(document, allowingReadAccessTo: document.deletingLastPathComponent())
        } else {
            Task { @MainActor in rendered(0) }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DiagramCanvas
        let document = Bundle.main.url(
            forResource: "diagram", withExtension: "html", subdirectory: "RichContent"
        )

        init(_ parent: DiagramCanvas) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.targetFrame?.isMainFrame == true && action.request.url == document ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let value = try? await webView.callAsyncJavaScript(
                    "return await window.renderDiagram(source);",
                    arguments: ["source": parent.source], in: nil, contentWorld: .page
                )
                let height = (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                guard height.isFinite, height > 0 else { parent.rendered(0); return }
                webView.scrollView.isScrollEnabled = height > 400
                parent.rendered(height)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            parent.rendered(0)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            parent.rendered(0)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.rendered(0)
        }
    }
}
