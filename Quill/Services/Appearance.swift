import SwiftUI

#if os(macOS)
private func adaptive(dark: Double, light: NSColor) -> Color {
    Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: dark, green: dark, blue: dark, alpha: 1) : light
    })
}
#else
private func adaptive(dark: Double, light: UIColor) -> Color {
    Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: dark, green: dark, blue: dark, alpha: 1) : light
    })
}
#endif

extension Color {
    /// The writing surface: barely off white or black, so the text does the work.
    static let paper = adaptive(dark: 0.102, light: .init(red: 0.98, green: 0.98, blue: 0.973, alpha: 1))
    /// List rows, a step up from `paper` so they read as separate from it.
    static let card = adaptive(dark: 0.165, light: .white)
    /// The only colour on the page while writing, whatever the site's colour.
    static let cursor = Color(red: 0.0, green: 0.56, blue: 0.94)
}

/// Light, dark, or follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    static let key = "appearance"

    #if os(iOS)
    /// Large titles sit at the bar's margin; this moves them over to the text in list rows.
    static func alignLargeTitles() {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 20
        UINavigationBar.appearance().largeTitleTextAttributes = [.paragraphStyle: style]
    }
    #endif

    var id: Self { self }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
