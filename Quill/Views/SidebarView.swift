import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context
    @Environment(\.usesColumns) private var usesColumns
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @Query private var entries: [Entry]
    /// Ticks so a slow send shows up without anything else changing.
    @State private var now = Date.now
    /// Where each site's row is, so the new entry button can be dropped on one.
    @State private var siteFrames: [UUID: CGRect] = [:]
    @State private var dropSite: UUID?

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            // Selection plus NavigationLink pushes twice on iPhone.
            if usesColumns {
                List(selection: $navigation.sidebar) { rows }
            } else {
                List { rows.listRowBackground(Color.card) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper.ignoresSafeArea())
        .newEntryButton(isShown: !usesColumns, dropTargets: siteFrames.filter { frame in sites.contains { $0.id == frame.key } },
                        dropSite: $dropSite)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
            }
        }
        .toolbar {
            ToolbarItem(placement: usesColumns ? .topBarLeading : .topBarTrailing) {
                Button { navigation.showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            if usesColumns {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navigation.openBlankEntry(in: context) } label: {
                        Label("New Entry", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if usesColumns {
            Section("Sites") {
                ForEach(sites) { site in
                    link(.site(site.id)) {
                        Label {
                            HStack {
                                Text(site.name)
                                Spacer()
                                Image(systemName: site.accessIcon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Circle().fill(site.color.color).frame(width: 10, height: 10)
                        }
                    }
                }
                addSite
            }
        } else {
            Section {
                ForEach(sites) { site in
                    link(.site(site.id)) { SiteCard(site: site) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { siteFrames[site.id] = $0 }
                        .listRowBackground(cardBackground(site))
                }
            } header: {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(.subheadline, design: .monospaced))
                    .textCase(nil)
                    .accessibilityIdentifier("homeDate")
            }
            Section { addSite }
        }

        // Only when something needs attention.
        if let outbox = outboxCount {
            Section {
                row("Outbox", "tray.and.arrow.up", .outbox, count: outbox,
                    alert: entries.contains { $0.state == .failed })
            }
        }

        if drafts > 0 {
            Section {
                row("Drafts", "doc.text", .drafts, count: drafts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addSite: some View {
        Button {
            navigation.showingAddSite = true
        } label: {
            Label("Add Site", systemImage: "plus")
        }
    }

    private func cardBackground(_ site: Site) -> some View {
        Color.card.overlay(site.color.color.opacity(dropSite == site.id ? 0.4 : 0.12))
    }

    private var drafts: Int {
        entries.filter { $0.state == .editing && !$0.isBlank }.count
    }

    /// Nil while sends are going normally: the outbox only matters on an error or a slow send.
    private var outboxCount: Int? {
        let waiting = entries.filter { [.queued, .sending, .failed].contains($0.state) }
        let needsAttention = waiting.contains {
            $0.state == .failed || $0.lastError != nil || now.timeIntervalSince($0.updatedAt) > 30
        }
        return needsAttention ? waiting.count : nil
    }

    /// In the iPad sidebar a row selects; on iPhone it pushes onto the stack.
    @ViewBuilder private func link(_ item: SidebarItem, @ViewBuilder label: () -> some View) -> some View {
        if usesColumns {
            // The gesture takes over from the List's selection, and also sees the selected row
            // being tapped again, which has to close the floating sidebar too.
            NavigationLink(value: item, label: label)
                .simultaneousGesture(TapGesture().onEnded {
                    navigation.sidebar = item
                    navigation.closeSidebarOverlay()
                })
        } else {
            NavigationLink(value: Route.list(item), label: label)
        }
    }

    private func row(_ title: String, _ icon: String, _ item: SidebarItem, count: Int, alert: Bool = false) -> some View {
        link(item) {
            Label {
                HStack {
                    Text(title)
                    Spacer()
                    if alert {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }
}

/// A site on the iPhone home page, with the latest post from its list.
private struct SiteCard: View {
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(site.color.color).frame(width: 10, height: 10)
                Text(site.name).font(.headline)
                Spacer()
                Image(systemName: site.accessIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let latest = site.cachedPostList.first {
                Text(latest.title)
                    .font(.system(.subheadline, design: .serif))
                    .italic(latest.isUntitled)
                    .lineLimit(2)
                if let date = latest.date {
                    Text(date.formatted(.relative(presentation: .named)).uppercased())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
