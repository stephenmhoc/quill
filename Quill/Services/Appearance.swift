import SwiftUI

extension Color {
    /// The writing surface: barely off white or black, so the text does the work.
    static let paper = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
            : UIColor(red: 0.98, green: 0.98, blue: 0.973, alpha: 1)
    })
    /// The only colour on the page while writing, whatever the site's colour.
    static let cursor = Color(red: 0.0, green: 0.56, blue: 0.94)
}

/// Light, dark, or follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    static let key = "appearance"

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
