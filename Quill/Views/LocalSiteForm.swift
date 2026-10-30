import SwiftData
import SwiftUI

/// A local site is only a name and a colour.
struct LocalSiteForm: View {
    let site: Site?
    let isCentered: Bool
    let onDone: () -> Void

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var color: SiteColor = .rust
    @State private var error: String?
    @State private var confirmingDelete = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } footer: {
                Text("Entries on a local site stay on this device and are never sent anywhere.")
            }
            SiteColorSection(color: $color)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if site != nil {
                Section {
                    Button("Remove Site", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Permanently deletes this site and every entry on it.")
                }
            }
        }
        .safeAreaPadding(.horizontal, isCentered && sizeClass == .regular ? 180 : 0)
        .navigationTitle(site == nil ? "Local Site" : "Edit Site")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(trimmedName.isEmpty)
            }
        }
        .confirmationDialog("Remove \(site?.name ?? "site") and all its entries?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive, action: remove)
        } message: {
            Text("They exist only on this device, so this can't be undone.")
        }
        .onAppear {
            guard let site else { return }
            name = site.name
            color = site.color
        }
    }

    private func save() {
        if let site {
            site.name = trimmedName
            site.color = color
        } else {
            context.insert(Site(name: trimmedName, kind: .local, color: color))
        }
        do {
            try context.save()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        guard let site else { return }
        navigation.leaveSite(site.id)
        do {
            try publisher.backend(for: site).removeSiteData()
            context.delete(site)
            try context.save()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
