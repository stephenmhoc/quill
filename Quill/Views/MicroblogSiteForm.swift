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
    /// Nil once the site is gone: the sheet can still draw while it closes.
    private var siteName: String? { site.flatMap { $0.isLive ? $0.name : nil } }
    private var canSave: Bool {
        (!isNew || !token.isEmpty) && !checking && (blogs.count < 2 || chosenBlog != nil)
    }

    var body: some View {
        Form {
            Section {
                SecretField(label: "Token", prompt: tokenPrompt, text: $token)
                    .onChange(of: token) { blogs = []; chosenBlog = nil }
            } header: {
                sectionHeader("Token")
            } footer: {
                Text("Micro.blog → Account → App tokens. Stored in \(thisDevice)'s Keychain, protected by \(lock.biometryName), and never synced.")
                    .formNote()
                #if os(macOS)
                Link("Open App Tokens on Micro.blog", destination: URL(string: "https://micro.blog/account/apps")!)
                    .font(.callout)
                #endif
            }
            if blogs.count > 1 {
                Section {
                    Picker(fieldTitle(mac: "Blog", iOS: "Blog"), selection: $chosenBlog) {
                        ForEach(blogs) { blog in Text(blog.title ?? blog.name).tag(Optional(blog.uid)) }
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.inline)
                    .labelsHidden()
                    #endif
                } header: {
                    sectionHeader("Blog")
                }
            }
            Section {
                TextField(fieldTitle(mac: "Name", iOS: "Name (uses the blog's title if empty)"), text: $name,
                          prompt: fieldPrompt("Uses the blog's title if empty"))
                    .promptedField()
                #if os(macOS)
                SiteColorSection(color: $color)
                #endif
            } footer: {
                Text("Micro.blog sites are public, so uploading an image always asks first. Published posts also go to anywhere your blog cross-posts to.")
                    .formNote()
            }
            #if os(iOS)
            SiteColorSection(color: $color)
            #endif
            if let error { FormErrorRow(message: error) }
            if !isNew { RemoveSiteSection(note: SiteKind.microblog.removalNote, isConfirming: $confirmingDelete) }
        }
        .siteFormStyle(isCentered: isCentered)
        .formTitle(isNew ? "Micro.blog" : "Edit Site")
        .compactTitle()
        .siteFormButtons(isNew: isNew, canSave: canSave, isWorking: checking, removeNote: isNew ? nil : SiteKind.microblog.removalNote,
                         isConfirmingRemove: $confirmingDelete) { Task { await save() } }
        .confirmationDialog("Remove \(siteName ?? "site")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            #if os(macOS)
            Text(SiteKind.microblog.removalNote)
            #endif
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
                    Site.add(new, to: context)
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
