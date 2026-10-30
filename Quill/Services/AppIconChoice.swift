import UIKit

/// The nib on paper, in ink, or following the system's light or dark mode.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case auto, paper, ink

    var id: Self { self }
    var label: String { rawValue.capitalized }
    var iconName: String? {
        switch self {
        case .auto: nil
        case .paper: "AppIcon-Paper"
        case .ink: "AppIcon-Ink"
        }
    }

    static var current: AppIconChoice {
        allCases.first { $0.iconName == UIApplication.shared.alternateIconName } ?? .auto
    }
}
