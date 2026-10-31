import SwiftUI

extension Color {
    /// The writing surface: barely off white or black, so the text does the work.
    static let paper = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
            : UIColor(red: 0.98, green: 0.98, blue: 0.973, alpha: 1)
    })
    /// List rows, a step up from `paper` so they read as separate from it.
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.165, blue: 0.165, alpha: 1)
            : .white
    })
    /// The only colour on the page while writing, whatever the site's colour.
    static let cursor = Color(red: 0.0, green: 0.56, blue: 0.94)
}

/// Light, dark, or follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    static let key = "appearance"

    /// Large titles sit at the bar's margin; this moves them over to the text in list rows.
    static func alignLargeTitles() {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 20
        UINavigationBar.appearance().largeTitleTextAttributes = [.paragraphStyle: style]
    }

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
