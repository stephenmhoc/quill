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
    @Query(sort: Site.order) private var sites: [Site]
    @State private var offset = CGSize.zero
    private static let reach: CGFloat = 16
    private static let tapSlop: CGFloat = 44

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
                            // A near miss still counts, even with a row right behind the button.
                            .padding(Self.reach)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Entry")
                    .accessibilityIdentifier("floatingNewEntry")
                    .hoverEffect(.lift)
                    // What dragging onto a site does, for anyone who can't or wouldn't think to drag.
                    .contextMenu { if !dropTargets.isEmpty { siteChoices } }
                    .accessibilityActions { if !dropTargets.isEmpty { siteChoices } }
                    .scaleEffect(offset == .zero ? 1 : 1.12)
                    .offset(offset)
                    .highPriorityGesture(dropTargets.isEmpty ? nil : drag)
                    .sensoryFeedback(.selection, trigger: dropSite)
                    .padding(20 - Self.reach)
                }
            }
    }

    private var siteChoices: some View {
        ForEach(sites.filter { dropTargets[$0.id] != nil }) { site in
            Button("New Entry in \(site.name)") { navigation.openBlankEntry(in: context, site: site.id) }
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
            .onEnded { value in
                if let target = dropSite {
                    navigation.openBlankEntry(in: context, site: target)
                } else if hypot(value.translation.width, value.translation.height) < Self.tapSlop {
                    // A finger that shifted during a tap meant a tap, not a drag to nowhere.
                    navigation.openBlankEntry(in: context, site: site)
                }
                dropSite = nil
                withAnimation(.spring(duration: 0.3)) { offset = .zero }
            }
    }
}
