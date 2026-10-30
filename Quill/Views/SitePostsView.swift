import SwiftData
import SwiftUI

/// Middle column for a site: its recent posts in Ghost (from any app, not only Quill).
struct SitePostsView: View {
    let siteID: UUID

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Query private var sites: [Site]
    @Query private var entries: [Entry]
    @State private var posts: [SitePost] = []
    @State private var error: String?
    @State private var loading = false
    @State private var editing = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var opening: String?
    @State private var pendingDelete: SitePost?
    @State private var unsupported: SitePost?

    private var site: Site? { sites.first { $0.id == siteID } }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Section {
                ForEach(posts) { post in
                    Button { Task { await open(post) } } label: { row(post) }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = post }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = post }
                        }
                }
            } header: {
                if let site {
                    Label(site.accessLabel, systemImage: site.accessIcon)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task(id: page) { await Task { await loadMore() }.value }
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
            if let site { EditSiteView(site: site) }
        }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { post in
            Button("Delete from \(site?.name ?? "site")", role: .destructive) { Task { await delete(post) } }
        } message: { _ in
            Text("This permanently deletes the post. It can't be undone.")
        }
        .alert("Quill can't edit this post", isPresented: Binding(get: { unsupported != nil }, set: { if !$0 { unsupported = nil } }),
               presenting: unsupported) { post in
            if let url = post.url { Button("Open in Browser") { openURL(url) } }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("It has layouts Markdown can't hold, like galleries or embeds, and saving it here would remove them.")
        }
        // Unstructured: SwiftUI cancels view tasks during column transitions and list refreshes.
        .refreshable { await Task { await load() }.value }
        .task { await Task { await load() }.value }
        .onChange(of: publisher.lastResult?.id) { Task { await load() } }
    }

    private func row(_ post: SitePost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text((post.date ?? .now).formatted(date: .abbreviated, time: .omitted).uppercased())
                Spacer()
                if let badge = post.badge { Text(badge) }
                if opening == post.id { ProgressView().controlSize(.mini) }
                else if localEntry(for: post)?.state == .editing { Image(systemName: "pencil.circle") }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(post.title)
                .font(.system(.headline, design: .serif))
                .italic(post.isUntitled)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func localEntry(for post: SitePost) -> Entry? {
        entries.first { $0.remotePostID == post.id && $0.siteID == siteID }
    }

    private func open(_ post: SitePost) async {
        guard let site else { return }
        opening = post.id
        defer { opening = nil }
        do {
            var entry = localEntry(for: post)
            if entry == nil { entry = try await publisher.importPost(id: post.id, site: site) }
            guard let entry else {
                unsupported = post
                return
            }
            navigation.show(entry)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ post: SitePost) async {
        guard let site else { return }
        if let entry = localEntry(for: post), navigation.selectedEntry == entry { navigation.selectedEntry = nil }
        do {
            try await publisher.deletePost(id: post.id, site: site)
            posts.removeAll { $0.id == post.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        guard let site else { return }
        loading = true
        defer { loading = false }
        do {
            let first = try await publisher.backend(for: site).posts(limit: Self.pageSize, page: 1)
            posts = first
            page = 1
            hasMore = first.count == Self.pageSize
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let site else { return }
        do {
            let next = try await publisher.backend(for: site).posts(limit: Self.pageSize, page: page + 1)
            let known = Set(posts.map(\.id))
            posts += next.filter { !known.contains($0.id) }
            hasMore = next.count == Self.pageSize
            page += 1
        } catch {
            hasMore = false
            self.error = error.localizedDescription
        }
    }

    private static let pageSize = 30
}
