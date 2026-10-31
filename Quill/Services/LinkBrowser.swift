import SafariServices
import SwiftUI

/// Where web links open.
enum LinkBrowser: String, CaseIterable, Identifiable {
    case inApp, external

    static let key = "linkBrowser"

    var id: Self { self }
    var label: String {
        switch self {
        case .inApp: "In App"
        case .external: "Default Browser"
        }
    }
}

extension View {
    /// Sends `openURL` to the browser picked in Settings. Applies to everything below it, but
    /// each sheet with links needs its own: a sheet can't present over itself from the root.
    func opensLinksInChosenBrowser() -> some View { modifier(LinkBrowserModifier()) }
}

private struct LinkBrowserModifier: ViewModifier {
    @AppStorage(LinkBrowser.key) private var browser = LinkBrowser.inApp
    @State private var page: WebPage?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard browser == .inApp, ["http", "https"].contains(url.scheme?.lowercased()) else { return .systemAction }
                page = WebPage(url: url)
                return .handled
            })
            .fullScreenCover(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private struct WebPage: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
