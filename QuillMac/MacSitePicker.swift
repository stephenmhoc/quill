import SwiftUI

/// Where the entry goes: the coloured pill, opening a menu of sites with their colours.
struct MacSitePicker: View {
    @Bindable var entry: Entry
    let sites: [Site]
    let locked: Bool

    private var site: Site? { sites.first { $0.id == entry.siteID } }

    var body: some View {
        Menu {
            MacSiteChoices(entry: entry, sites: sites)
        } label: {
            SitePickerLabel(site: site, locked: locked)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(locked)
        .help(locked ? "\(site?.name ?? "No site"): this entry stays on its site" : "Choose where this entry goes")
        .accessibilityLabel("Site: \(site?.name ?? "none")")
    }
}

/// The sites as menu items with a tick, for the pill and Entry > Move to Site.
struct MacSiteChoices: View {
    @Bindable var entry: Entry
    let sites: [Site]

    var body: some View {
        Picker("Site", selection: Binding(get: { entry.siteID }, set: { entry.siteID = $0 })) {
            ForEach(sites) { site in
                Label { Text(site.name) } icon: { Image(nsImage: site.color.swatch) }
                    .tag(Optional(site.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
