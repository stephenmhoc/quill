import SwiftUI

extension Color {
    /// The writing surface: easy on the eyes whatever the site's colour.
    static let paper = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.094, blue: 0.086, alpha: 1)
            : UIColor(red: 0.98, green: 0.965, blue: 0.937, alpha: 1)
    })
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
