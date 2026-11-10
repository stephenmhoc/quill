import SwiftData
import SwiftUI

/// A local site is only a name and a colour.
struct LocalSiteForm: View {
    let site: Site?
    let isCentered: Bool
    let onDone: () -> Void

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var color: SiteColor = .rust
    @State private var error: String?
    @State private var confirmingDelete = false

    /// On a Mac the field shows "Notebook" as its placeholder, and an empty field means that.
    private var trimmedName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        #if os(macOS)
        return typed.isEmpty && site == nil ? "Notebook" : typed
        #else
        return typed
        #endif
    }
    /// Nil once the site is gone: the sheet can still draw while it closes.
    private var siteName: String? { site.flatMap { $0.isLive ? $0.name : nil } }

    var body: some View {
        Form {
            Section {
                TextField(fieldTitle(mac: "Name", iOS: "Name"), text: $name, prompt: fieldPrompt("Notebook"))
                    .promptedField()
                #if os(macOS)
                SiteColorSection(color: $color)
                #endif
            } footer: {
                Text("Entries on a local site stay on \(thisDevice) and are never sent anywhere.")
                    .formNote()
            }
            #if os(iOS)
            SiteColorSection(color: $color)
            #endif
            if let error { FormErrorRow(message: error) }
            if site != nil { RemoveSiteSection(note: SiteKind.local.removalNote, isConfirming: $confirmingDelete) }
        }
        .siteFormStyle(isCentered: isCentered)
        .formTitle(site == nil ? "Local Site" : "Edit Site")
        .compactTitle()
        .siteFormButtons(isNew: site == nil, canSave: !trimmedName.isEmpty, removeNote: site == nil ? nil : SiteKind.local.removalNote,
                         isConfirmingRemove: $confirmingDelete, save: save)
        .confirmationDialog("Remove \(siteName ?? "site") and all its entries?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive, action: remove)
        } message: {
            Text("They exist only on \(thisDevice), so this can't be undone.")
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
            Site.add(Site(name: trimmedName, kind: .local, color: color), to: context)
        }
        do {
            try context.save()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        guard let site, site.isLive else { return }
        navigation.leaveSite(site.id)
        do {
            try publisher.removeSite(site)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
