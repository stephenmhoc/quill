import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @Query private var entries: [Entry]

    var body: some View {
        @Bindable var navigation = navigation
        List(selection: $navigation.sidebar) {
            Section {
                row("Drafts", "doc.text", .drafts, count: count { $0.state == .editing && !$0.isBlank })
                row("Outbox", "tray.and.arrow.up", .outbox,
                    count: count { [.queued, .sending, .failed].contains($0.state) },
                    alert: entries.contains { $0.state == .failed })
                row("Sent", "paperplane", .sent, count: nil)
            }

            Section {
                ForEach(sites) { site in
                    Label {
                        HStack {
                            Text(site.name)
                            Spacer()
                            Image(systemName: site.isPublic ? "globe" : "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Circle().fill(site.color.color).frame(width: 10, height: 10)
                    }
                    .tag(SidebarItem.site(site.id))
                }
                Button {
                    navigation.showingAddSite = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }
            } header: {
                Text("Sites")
            }
        }
        .navigationTitle("Quill")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { navigation.showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigation.openBlankEntry(in: context) } label: {
                    Label("New Entry", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func count(_ predicate: (Entry) -> Bool) -> Int { entries.filter(predicate).count }

    private func row(_ title: String, _ icon: String, _ item: SidebarItem, count: Int?, alert: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if alert {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                } else if let count, count > 0 {
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(item)
    }
}
