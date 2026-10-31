import GhostKit
import SwiftUI
import WebKit

#if os(iOS)
/// The entry rendered from its Markdown, before it goes anywhere.
struct EntryPreview: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            PreviewPage(html: EntryPage.html(title: title, markdown: markdown, isDark: colorScheme == .dark))
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
}
#endif

/// The HTML behind a preview.
enum EntryPage {
    /// `isDark` comes from SwiftUI: the page's own dark mode query doesn't follow the app's
    /// Appearance setting. `imageHosts` limits where pictures can load from, for a preview that
    /// updates by itself: pasting a tracked image shouldn't call its server from a private draft.
    static func html(title: String, markdown: String, isDark: Bool, imageHosts: [String]? = nil) -> String {
        let heading = title.isEmpty ? "" : "<h1>\(escaped(title))</h1>"
        let images = imageHosts.map { hosts in hosts.flatMap { ["https://\($0)", "http://\($0)"] }.joined(separator: " ") } ?? "http: https:"
        return """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; \
        img-src data: \(LocalBackend.imageScheme): \(images); form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: \(isDark ? "dark" : "light"); --ink: \(isDark ? "#ececec" : "#1a1a1a");
                --quiet: \(isDark ? "#9a9a9a" : "#6b6b6b"); --rule: \(isDark ? "#3a3a3a" : "#d9d9d4"); }
        body { margin: 0 auto; padding: 24px 20px 64px; max-width: 680px; background: \(isDark ? "#1a1a1a" : "#fafaf8"); color: var(--ink);
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

    /// Where a site's own images live.
    static func imageHosts(of site: Site?) -> [String] {
        guard let site, site.kind != .local else { return [] }
        return site.kind == .microblog ? [site.host, "*.micro.blog", "micro.blog"] : [site.host, "*.\(site.host)"]
    }

    /// Markdown can carry raw HTML. Show it, but don't run it or let it keep anything.
    static func webConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LocalImages(), forURLScheme: LocalBackend.imageScheme)
        return configuration
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}

#if os(macOS)
struct PreviewPage: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator, context.environment) }
}
#else
struct PreviewPage: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator, context.environment) }
}
#endif

extension PreviewPage {
    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: EntryPage.webConfiguration())
        view.navigationDelegate = coordinator
        #if os(iOS)
        view.isOpaque = false
        #endif
        return view
    }

    /// Keeps its place when the page changes, so a live preview doesn't jump to the top.
    fileprivate func update(_ view: WKWebView, _ coordinator: Coordinator, _ environment: EnvironmentValues) {
        coordinator.openURL = environment.openURL
        guard coordinator.html != html else { return }
        let isFirstLoad = coordinator.html == nil
        coordinator.html = html
        if isFirstLoad {
            view.loadHTMLString(html, baseURL: nil)
            return
        }
        view.evaluateJavaScript("window.scrollY") { offset, _ in
            coordinator.restoredOffset = offset as? Double
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var openURL: OpenURLAction?
        var html: String?
        var restoredOffset: Double?

        /// The page stays the preview: links go to the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme != "about" else {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated { openURL?(url) }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let offset = restoredOffset else { return }
            restoredOffset = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(offset))", completionHandler: nil)
        }
    }
}

/// Serves images saved to a local site, which only exist on this device.
final class LocalImages: NSObject, WKURLSchemeHandler {
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
