import AppKit
import WebKit

/// Prints the entry as it'd be read, from a page that's never on screen.
final class EntryPrinter: NSObject, WKNavigationDelegate {
    /// The page loads and prints long after `print` returns, so the last one stays around.
    private static var current: EntryPrinter?
    private let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: EntryPage.webConfiguration())

    static func print(title: String, markdown: String, site: Site?) {
        let printer = EntryPrinter()
        current = printer
        printer.page.navigationDelegate = printer
        printer.page.loadHTMLString(EntryPage.html(title: title, markdown: markdown, isDark: false, imageHosts: EntryPage.imageHosts(of: site)),
                                    baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let operation = webView.printOperation(with: .shared)
        operation.view?.frame = webView.bounds
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
