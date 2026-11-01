import SwiftUI

/// A popover, because a Mac menu won't draw a coloured dot beside its items.
struct MacSitePicker: View {
    @Bindable var entry: Entry
    let sites: [Site]
    let locked: Bool
    @State private var choosing = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }

    var body: some View {
        Button { choosing = true } label: { SitePickerLabel(site: site, locked: locked) }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityLabel("Site: \(site?.name ?? "none")")
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sites) { s in
                        Button {
                            entry.siteID = s.id
                            choosing = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(s.color.color).frame(width: 9, height: 9)
                                Text(s.name)
                                Spacer(minLength: 16)
                                if s.id == entry.siteID { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(minWidth: 180)
            }
    }
}
