import GhostKit
import SwiftUI
import WebKit

/// The entry rendered from its Markdown, before it goes anywhere.
struct EntryPreview: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            PreviewPage(html: page)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.paper.ignoresSafeArea())
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .opensLinksInChosenBrowser()
    }

    private var page: String {
        // From SwiftUI: the page's own dark mode query doesn't follow the app's Appearance setting.
        let isDark = colorScheme == .dark
        let heading = title.isEmpty ? "" : "<h1>\(escaped(title))</h1>"
        return """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: \(isDark ? "dark" : "light"); --ink: \(isDark ? "#ececec" : "#1a1a1a");
                --quiet: \(isDark ? "#9a9a9a" : "#6b6b6b"); --rule: \(isDark ? "#3a3a3a" : "#d9d9d4"); }
        body { margin: 0 auto; padding: 24px 20px 64px; max-width: 680px; background: transparent; color: var(--ink);
               font: -apple-system-body; font-family: ui-serif, Georgia, serif; line-height: 1.6; overflow-wrap: anywhere; }
        h1, h2, h3, h4 { line-height: 1.25; }
        a { color: inherit; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        blockquote { margin-left: 0; padding-left: 16px; border-left: 3px solid var(--rule); color: var(--quiet); }
        code { font-family: ui-monospace, monospace; font-size: 0.9em; }
        pre { overflow-x: auto; padding: 12px; border: 1px solid var(--rule); border-radius: 6px; }
        table { border-collapse: collapse; } th, td { padding: 4px 10px; border: 1px solid var(--rule); }
        hr { border: 0; border-top: 1px solid var(--rule); }
        </style>
        \(heading)\(EntryBuilder.html(fromMarkdown: markdown))
        """
    }

    private func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}

private struct PreviewPage: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Markdown can carry raw HTML. Show it, but don't run it or let it keep anything.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LocalImages(), forURLScheme: LocalBackend.imageScheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        if context.coordinator.html != html {
            context.coordinator.html = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var openURL: OpenURLAction?
        var html: String?

        /// The page stays the preview: links go to the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            openURL?(url)
            decisionHandler(.cancel)
        }
    }
}

/// Serves images saved to a local site, which only exist on this device.
private final class LocalImages: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let image = try? LocalBackend.image(named: url.lastPathComponent) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: image.count, textEncodingName: nil))
        task.didReceive(image)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
