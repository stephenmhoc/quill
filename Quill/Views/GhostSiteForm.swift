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
    private var canSave: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty && (!isNew || !key.isEmpty) && !checking
    }

    var body: some View {
        Form {
            Section("Site") {
                TextField("https://journal.example.com", text: $urlText, prompt: fieldPrompt("https://journal.example.com"))
                    .promptedField()
                    .urlKeyboard()
                    #if os(iOS)
                    .textContentType(.URL)
                    #endif
                    .literalEntry()
                    .disabled(!isNew)
                    .foregroundStyle(isNew ? .primary : .secondary)
                TextField("Name (uses the site title if empty)", text: $name, prompt: fieldPrompt("Name (uses the site title if empty)"))
                    .promptedField()
            }
            Section {
                SecretField(prompt: keyPrompt, text: $key)
            } header: {
                Text("Key")
            } footer: {
                Text("Ghost Admin → your profile → Staff access token. Stored in this device's Keychain, protected by \(lock.biometryName), and never synced.")
            }
            Section {
                Picker("Visibility", selection: $isPublic) {
                    Text("Private").tag(false)
                    Text("Public").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Uploading an image to a public site always asks first. To change a site's address, remove it and add it again.")
            }
            SiteColorSection(color: $color)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            #if os(iOS)
            if !isNew {
                Section {
                    Button("Remove Site", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Removes the site and its key from this device. Nothing changes in Ghost.")
                }
            }
            #endif
        }
        .siteFormStyle(isCentered: isCentered)
        .navigationTitle(isNew ? "Ghost Site" : "Edit Site")
        .compactTitle()
        .toolbar {
            #if os(macOS)
            if !isNew {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove Site…", role: .destructive) { confirmingDelete = true }
                        .help("Removes the site and its key from this device. Nothing changes in Ghost.")
                }
            }
            #endif
            ToolbarItem(placement: .confirmationAction) {
                if checking { ProgressView() } else {
                    Button { Task { await save() } } label: { Text("Save").sheetButtonLabel() }
                        .accessibilityIdentifier("saveSite")
                        .disabled(!canSave)
                }
            }
        }
        .confirmationDialog("Remove \(site?.name ?? "site")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        }
        .onAppear(perform: load)
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
                if let credentials { try lock.saveKey(credentials.apiKey, for: site.id) }
                site.name = title.isEmpty ? site.name : title
                site.isPublic = isPublic
                site.color = color
            } else {
                // Key first, so a failed Keychain write leaves no site without one.
                let new = Site(name: title.isEmpty ? (url.host() ?? "Site") : title, url: url, isPublic: isPublic, color: color)
                if let credentials { try lock.saveKey(credentials.apiKey, for: new.id) }
                context.insert(new)
            }
            try context.save()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        guard let site else { return }
        navigation.leaveSite(site.id)
        try? publisher.backend(for: site).removeSiteData()
        lock.deleteKey(for: site.id)
        context.delete(site)
        try? context.save()
        onDone()
    }
}
