import GhostKit
import SwiftData
import SwiftUI

/// Add or edit a site. The key is checked against the site before saving.
struct SiteFormView: View {
    let site: Site?

    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
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
    private var canSave: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty && (!isNew || !key.isEmpty) && !checking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Site") {
                    TextField("https://journal.example.com", text: $urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (uses the site title if empty)", text: $name)
                }
                Section {
                    SecureField(isNew ? "Staff Access Token or Admin API key" : "Leave blank to keep the current key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                } header: {
                    Text("Key")
                } footer: {
                    Text("Ghost Admin → your profile → Staff access token. Stored in this device's Keychain, protected by \(lock.biometryName), and never synced.")
                }
                Section {
                    Toggle("Public site", isOn: $isPublic)
                } footer: {
                    Text("Publishing to a public site always asks for confirmation.")
                }
                Section("Colour") {
                    HStack(spacing: 14) {
                        ForEach(SiteColor.allCases) { option in
                            Button { color = option } label: {
                                Circle().fill(option.color).frame(width: 30, height: 30)
                                    .overlay {
                                        if option == color {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.label)
                        }
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                if !isNew {
                    Section {
                        Button("Remove Site", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Removes the site and its key from this device. Nothing changes in Ghost.")
                    }
                }
            }
            .navigationTitle(isNew ? "Add Site" : "Edit Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
            .confirmationDialog("Remove \(site?.name ?? "site")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: remove)
            }
            .onAppear(perform: load)
        }
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
            let url = try GhostClient.normalizeSiteURL(urlText)
            let credentials: GhostCredentials? = key.isEmpty ? nil : try GhostCredentials(apiKey: key)
            var title = name.trimmingCharacters(in: .whitespaces)
            if let credentials {
                let client = GhostClient(baseURL: url, credentials: credentials)
                // `site/` is public; listing posts is what proves the key works.
                _ = try await client.recentPosts(limit: 1)
                if title.isEmpty { title = try await client.site().title }
            }
            let target: Site
            if let site {
                target = site
                target.name = title.isEmpty ? site.name : title
                target.urlString = url.absoluteString
                target.isPublic = isPublic
                target.color = color
            } else {
                target = Site(name: title.isEmpty ? (url.host() ?? "Site") : title, url: url, isPublic: isPublic, color: color)
                context.insert(target)
            }
            if let credentials { try lock.saveKey(credentials.apiKey, for: target.id) }
            try context.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        guard let site else { return }
        lock.deleteKey(for: site.id)
        context.delete(site)
        try? context.save()
        dismiss()
    }
}
