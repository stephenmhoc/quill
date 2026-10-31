import SwiftData
import SwiftUI

extension View {
    /// A floating button for a new entry, in `site` if given, else the default site.
    func newEntryButton(site: UUID? = nil, isShown: Bool = true) -> some View {
        modifier(NewEntryButton(site: site, isShown: isShown))
    }
}

private struct NewEntryButton: ViewModifier {
    let site: UUID?
    let isShown: Bool
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            // So the last row can scroll clear of the button.
            .contentMargins(.bottom, isShown ? 84 : 0, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                if isShown {
                    Button { navigation.openBlankEntry(in: context, site: site) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(Color.paper)
                            .frame(width: 58, height: 58)
                            .background(Color.primary, in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Entry")
                    .padding(20)
                }
            }
    }
}
