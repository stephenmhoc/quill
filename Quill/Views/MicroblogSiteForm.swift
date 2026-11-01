import GhostKit
import SwiftData
import SwiftUI

/// Add or edit a Micro.blog blog. The token is checked before saving, and an account with several
/// blogs chooses one.
struct MicroblogSiteForm: View {
    let site: Site?
    let isCentered: Bool
    let onDone: () -> Void

    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var token = ""
    @State private var color: SiteColor = .rust
    @State private var blogs: [MicropubClient.Destination] = []
    @State private var chosenBlog: String?
    @State private var checking = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var isNew: Bool { site == nil }
    private var tokenPrompt: String { isNew ? "App token" : "New token, or leave blank to keep the current one" }
    private var canSave: Bool {
        (!isNew || !token.isEmpty) && !checking && (blogs.count < 2 || chosenBlog != nil)
    }

    var body: some View {
        Form {
            Section {
                SecretField(prompt: tokenPrompt, text: $token)
                    .onChange(of: token) { blogs = []; chosenBlog = nil }
            } header: {
                Text("Token")
            } footer: {
                Text("Micro.blog → Account → App tokens. Stored in this device's Keychain, protected by \(lock.biometryName), and never synced.")
            }
            if blogs.count > 1 {
                Section("Blog") {
                    Picker("Blog", selection: $chosenBlog) {
                        ForEach(blogs) { blog in Text(blog.title ?? blog.name).tag(Optional(blog.uid)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section {
                TextField("Name (uses the blog's title if empty)", text: $name, prompt: fieldPrompt("Name (uses the blog's title if empty)"))
                    .promptedField()
            } footer: {
                Text("Micro.blog sites are public, so uploading an image always asks first. Published posts also go to anywhere your blog cross-posts to.")
            }
            SiteColorSection(color: $color)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if !isNew { RemoveSiteSection(note: "Removes the site and its token from this device. Nothing changes on Micro.blog.", isConfirming: $confirmingDelete) }
        }
        .siteFormStyle(isCentered: isCentered)
        .navigationTitle(isNew ? "Micro.blog" : "Edit Site")
        .compactTitle()
        .toolbar {
            #if os(macOS)
            if !isNew { RemoveSiteToolbarItem(note: "Removes the site and its token from this device. Nothing changes on Micro.blog.", isConfirming: $confirmingDelete) }
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
        .onAppear {
            guard let site else { return }
            name = site.name
            color = site.color
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }
        error = nil
        do {
            var title = name.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty {
                // Listing blogs is what proves the token works.
                let found = try await MicropubClient(token: token).destinations()
                guard !found.isEmpty else {
                    error = "This account has no blog to post to yet."
                    return
                }
                if isNew, found.count > 1, chosenBlog == nil {
                    blogs = found
                    return
                }
                if let site {
                    try lock.saveKey(token, for: site.id)
                } else {
                    let blog = found.first { $0.uid == chosenBlog } ?? found[0]
                    guard let url = URL(string: blog.uid) else { throw GhostError.invalidURL }
                    if title.isEmpty { title = blog.title ?? blog.name }
                    // Token first, so a failed Keychain write leaves no site without one.
                    let new = Site(name: title, url: url, isPublic: true, color: color, kind: .microblog)
                    try lock.saveKey(token, for: new.id)
                    context.insert(new)
                }
            }
            if let site {
                site.name = title.isEmpty ? site.name : title
                site.color = color
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
