import GhostKit
import SwiftData
import SwiftUI

/// Middle column for a site: its recent posts in Ghost (from any app, not only Quill).
struct SitePostsView: View {
    let siteID: UUID

    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(\.openURL) private var openURL
    @Query private var sites: [Site]
    @Query private var entries: [Entry]
    @State private var posts: [GhostPost] = []
    @State private var error: String?
    @State private var loading = false
    @State private var editing = false

    private var site: Site? { sites.first { $0.id == siteID } }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(posts) { post in
                Button { open(post) } label: { row(post) }
                    .buttonStyle(.plain)
            }
        }
        .overlay {
            if loading && posts.isEmpty { ProgressView() }
            else if posts.isEmpty && error == nil && !loading {
                ContentUnavailableView("No posts yet", systemImage: "doc.richtext")
            }
        }
        .navigationTitle(site?.name ?? "Site")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = true } label: { Label("Edit Site", systemImage: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $editing) {
            if let site { SiteFormView(site: site) }
        }
        .refreshable { await load() }
        .task(id: siteID) { await load() }
    }

    private func row(_ post: GhostPost) -> some View {
        let untitled = post.tags?.contains { $0.name == EntryBuilder.untitledTag } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text((post.publishedAt ?? .now).formatted(date: .abbreviated, time: .omitted).uppercased())
                Spacer()
                if post.status != .published { Text(post.status.rawValue.uppercased()) }
                if localEntry(for: post) != nil { Image(systemName: "pencil.circle") }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(untitled ? (post.excerpt ?? post.title) : post.title)
                .font(.system(.headline, design: .serif))
                .italic(untitled)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func localEntry(for post: GhostPost) -> Entry? {
        entries.first { $0.remotePostID == post.id && $0.siteID == siteID }
    }

    /// Entries written in Quill reopen in the editor; anything else opens in the browser.
    private func open(_ post: GhostPost) {
        if let entry = localEntry(for: post) {
            navigation.sidebar = .sent
            navigation.selectedEntry = entry
            navigation.preferredCompactColumn = .detail
        } else if let url = post.url {
            openURL(url)
        }
    }

    private func load() async {
        guard let site else { return }
        loading = true
        defer { loading = false }
        do {
            posts = try await lock.client(for: site).recentPosts(limit: 30)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
