import SwiftData
import SwiftUI

extension View {
    /// A floating button for a new entry, in `site` if given, else the default site.
    /// With `dropTargets` it can also be dragged onto a site to start an entry there.
    func newEntryButton(site: UUID? = nil, tint: Color = .accentColor, isShown: Bool = true,
                        dropTargets: [UUID: CGRect] = [:],
                        dropSite: Binding<UUID?> = .constant(nil)) -> some View {
        modifier(NewEntryButton(site: site, tint: tint, isShown: isShown, dropTargets: dropTargets, dropSite: dropSite))
    }
}

private struct NewEntryButton: ViewModifier {
    let site: UUID?
    let tint: Color
    let isShown: Bool
    let dropTargets: [UUID: CGRect]
    @Binding var dropSite: UUID?
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context
    @State private var offset = CGSize.zero

    func body(content: Content) -> some View {
        content
            // So the last row can scroll clear of the button.
            .contentMargins(.bottom, isShown ? 84 : 0, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                if isShown {
                    Button { navigation.openBlankEntry(in: context, site: site) } label: {
                        surface(Image(systemName: "square.and.pencil")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Entry")
                    .scaleEffect(offset == .zero ? 1 : 1.12)
                    .offset(offset)
                    .highPriorityGesture(dropTargets.isEmpty ? nil : drag)
                    .sensoryFeedback(.selection, trigger: dropSite)
                    .padding(20)
                }
            }
    }

    @ViewBuilder private func surface(_ icon: some View) -> some View {
        if #available(iOS 26, *) {
            icon.glassEffect(.regular.tint(tint.opacity(0.85)).interactive(), in: .circle)
        } else {
            icon.background(tint, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                offset = value.translation
                // Rows are taller than their text.
                dropSite = dropTargets.first { $0.value.insetBy(dx: -16, dy: -10).contains(value.location) }?.key
            }
            .onEnded { _ in
                if let target = dropSite {
                    navigation.openBlankEntry(in: context, site: target)
                }
                dropSite = nil
                withAnimation(.spring(duration: 0.3)) { offset = .zero }
            }
    }
}
