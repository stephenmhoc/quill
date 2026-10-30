import SwiftUI

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
