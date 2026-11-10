import GhostKit
import SwiftData
import SwiftUI

/// Add or edit a Ghost site. The key is checked against the site before saving.
struct GhostSiteForm: View {
    let site: Site?
    let isCentered: Bool
    let onDone: () -> Void

    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var urlText = ""
    @State private var key = ""
    @State private var isPublic = false
    @State private var color: SiteColor = .rust
    @State private var checking = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var isNew: Bool { site == nil }
    private var keyPrompt: String { isNew ? "Staff Access Token or Admin API key" : "New key, or leave blank to keep the current one" }
    /// Nil once the site is gone: the sheet can still draw while it closes.
    private var siteName: String? { site.flatMap { $0.isLive ? $0.name : nil } }
    private var canSave: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty && (!isNew || !key.isEmpty) && !checking
    }

    var body: some View {
        Form {
            Section {
                TextField(fieldTitle(mac: "Address", iOS: "https://journal.example.com"), text: $urlText,
                          prompt: fieldPrompt("https://journal.example.com"))
                    .promptedField()
                    .urlKeyboard()
                    #if os(iOS)
                    .textContentType(.URL)
                    #endif
                    .literalEntry()
                    .disabled(!isNew)
                    .foregroundStyle(isNew ? .primary : .secondary)
                TextField(fieldTitle(mac: "Name", iOS: "Name (uses the site title if empty)"), text: $name,
                          prompt: fieldPrompt("Uses the site title if empty"))
                    .promptedField()
            } header: {
                sectionHeader("Site")
            }
            Section {
                SecretField(label: "Key", prompt: keyPrompt, text: $key)
            } header: {
                sectionHeader("Key")
            } footer: {
                Text("Ghost Admin → your profile → Staff access token. Stored in \(thisDevice)'s Keychain, protected by \(lock.biometryName), and never synced.")
                    .formNote()
                #if os(macOS)
                Link("About Ghost's keys", destination: URL(string: "https://ghost.org/docs/admin-api/#token-authentication")!)
                    .font(.callout)
                #endif
            }
            Section {
                #if os(macOS)
                // At the row's trailing edge, like the other controls in a grouped form.
                LabeledContent("Visibility") {
                    Picker("Visibility", selection: $isPublic) {
                        Text("Private").tag(false)
                        Text("Public").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                SiteColorSection(color: $color)
                #else
                Picker("Visibility", selection: $isPublic) {
                    Text("Private").tag(false)
                    Text("Public").tag(true)
                }
                .choiceStyle()
                #endif
            } footer: {
                Text("Uploading an image to a public site always asks first. To change a site's address, remove it and add it again.")
                    .formNote()
            }
            #if os(iOS)
            SiteColorSection(color: $color)
            #endif
            #if os(iOS)
            if let error { FormErrorRow(message: error) }
            #endif
            if !isNew { RemoveSiteSection(note: SiteKind.ghost.removalNote, isConfirming: $confirmingDelete) }
        }
        .siteFormStyle(isCentered: isCentered)
        .formTitle(isNew ? "Ghost Site" : "Edit Site")
        .compactTitle()
        .siteFormButtons(isNew: isNew, canSave: canSave, isWorking: checking, error: error, removeNote: isNew ? nil : SiteKind.ghost.removalNote,
                         isConfirmingRemove: $confirmingDelete) { Task { await save() } }
        .confirmationDialog("Remove \(siteName ?? "site")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            #if os(macOS)
            Text(SiteKind.ghost.removalNote)
            #endif
        }
        .onAppear(perform: load)
        // A swipe would lose what's been typed, the key above all.
        .interactiveDismissDisabled(checking || hasChanges)
    }

    private var hasChanges: Bool {
        guard let site else { return !urlText.isEmpty || !key.isEmpty || !name.isEmpty }
        // Removed, and the form is on its way out.
        guard site.isLive else { return false }
        return !key.isEmpty || name != site.name || isPublic != site.isPublic || color != site.color
    }

    private func load() {
        guard let site else { return }
        name = site.name
        urlText = site.urlString
        isPublic = site.isPublic
        color = site.color
    }

    private func save() async {
        checking = true
        defer { checking = false }
        error = nil
        do {
            let url = try site?.url ?? GhostClient.normalizeSiteURL(urlText)
            let credentials: GhostCredentials? = key.isEmpty ? nil : try GhostCredentials(apiKey: key)
            var title = name.trimmingCharacters(in: .whitespaces)
            if let credentials {
                let client = GhostClient(baseURL: url, credentials: credentials)
                // `site/` is public; listing posts is what proves the key works.
                _ = try await client.recentPosts(limit: 1)
                if title.isEmpty { title = try await client.site().title }
            }
            if let site {
                // Removed while the key was checked: there's nothing left to save to.
                guard site.isLive else { onDone(); return }
                if let credentials { try lock.saveKey(credentials.apiKey, for: site.id) }
                site.name = title.isEmpty ? site.name : title
                site.isPublic = isPublic
                site.color = color
            } else {
                // Key first, so a failed Keychain write leaves no site without one.
                let new = Site(name: title.isEmpty ? (url.host() ?? "Site") : title, url: url, isPublic: isPublic, color: color)
                if let credentials { try lock.saveKey(credentials.apiKey, for: new.id) }
                Site.add(new, to: context)
            }
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
