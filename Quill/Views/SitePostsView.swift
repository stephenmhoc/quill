import GhostKit
import SwiftData
import SwiftUI

/// Middle column for a site: its recent posts in Ghost (from any app, not only Quill).
struct SitePostsView: View {
    let siteID: UUID

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Environment(\.usesColumns) private var usesColumns
    @Query private var sites: [Site]
    @Query private var entries: [Entry]
    @State private var posts: [SitePost] = []
    @State private var error: String?
    @State private var loading = false
    @State private var editing = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var opening: String?
    /// Which open is the latest, because a Mac can select another row while one is loading.
    @State private var openRequest = 0
    @State private var pendingDelete: SitePost?
    @State private var unsupported: SitePost?
    #if os(macOS)
    @State private var selectedPost: String?
    #endif

    private var site: Site? { sites.first { $0.id == siteID } }

    var body: some View {
        posted
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) { statsFooter }
            #endif
            .overlay {
                if loading && posts.isEmpty { ProgressView() }
                else if posts.isEmpty && error == nil && !loading {
                    ContentUnavailableView("No posts yet", systemImage: "doc.richtext")
                }
            }
            #if os(iOS)
            .newEntryButton(site: siteID, tint: site?.color.color ?? .accentColor, isShown: !usesColumns)
            #endif
            .paperList()
            .navigationTitle(site?.name ?? "Site")
            .largeTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = true } label: { Label("Edit Site", systemImage: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $editing) {
                if let site { EditSiteView(site: site) }
            }
            .confirmationDialog(deleteQuestion, isPresented: isConfirmingDelete,
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
            .onAppear { if posts.isEmpty, let site { posts = site.cachedPostList } }
            .task { await Task { await load() }.value }
            .onChange(of: publisher.sentCount) { Task { await load() } }
    }

    @ViewBuilder private var posted: some View {
        #if os(macOS)
        List(selection: $selectedPost) { rows }
            .onChange(of: selectedPost) { _, id in
                if let post = posts.first(where: { $0.id == id }) { Task { await open(post) } }
            }
            // A new page isn't the post that's still highlighted.
            .onChange(of: navigation.selectedEntry) { _, entry in
                if let post = posts.first(where: { $0.id == selectedPost }), localEntry(for: post) != entry, opening == nil {
                    selectedPost = nil
                }
            }
        #else
        List { rows }
        #endif
    }

    @ViewBuilder private var rows: some View {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            #if os(iOS)
            if let stats = site?.stats {
                SiteStatsRow(stats: stats)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            #endif
            Section {
                ForEach(posts) { post in
                    postRow(post)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = post }
                        }
                        .contextMenu {
                            #if os(macOS)
                            if let url = post.url { Button("Open in Browser", systemImage: "safari") { openURL(url) } }
                            #endif
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

    #if os(macOS)
    /// Totals are a footnote on a Mac, where the list is what you came for.
    @ViewBuilder private var statsFooter: some View {
        if let stats = site?.stats {
            Text("\(stats.posts.formatted()) \(stats.posts == 1 ? "post" : "posts") · \(stats.words.formatted()) \(stats.words == 1 ? "word" : "words")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
    }
    #endif

    /// A Mac selects a row; iOS taps a button.
    @ViewBuilder private func postRow(_ post: SitePost) -> some View {
        #if os(macOS)
        row(post).tag(post.id)
        #else
        Button { Task { await open(post) } } label: { row(post) }
            .buttonStyle(.plain)
            .cardRow()
            .disabled(opening != nil)
        #endif
    }

    private var deleteQuestion: String { "Delete “\(pendingDelete?.title ?? "")”?" }
    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
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
        openRequest += 1
        let request = openRequest
        opening = post.id
        defer { if request == openRequest { opening = nil } }
        let (shownEntry, shownPath) = (navigation.selectedEntry, navigation.path)
        do {
            var entry = localEntry(for: post)
            if let entry {
                await publisher.refresh(entry, site: site)
            } else {
                entry = try await publisher.importPost(id: post.id, site: site)
            }
            // Someone who moved on while this loaded stays where they went.
            guard request == openRequest, navigation.selectedEntry == shownEntry, navigation.path == shownPath else { return }
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
            publisher.remember(posts, on: site)
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
            let first = try await publisher.loadPosts(of: site)
            posts = first
            page = 1
            hasMore = first.count == SitePost.pageSize
            error = nil
            Task(priority: .utility) { await publisher.refreshStats(of: site) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let site else { return }
        do {
            let next = try await publisher.backend(for: site).posts(limit: SitePost.pageSize, page: page + 1)
            let known = Set(posts.map(\.id))
            posts += next.filter { !known.contains($0.id) }
            hasMore = next.count == SitePost.pageSize
            page += 1
        } catch {
            hasMore = false
            self.error = error.localizedDescription
        }
    }
}

/// A site's totals, above its posts.
private struct SiteStatsRow: View {
    let stats: PostStats

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            figure(stats.posts.formatted(), "Posts")
            figure(stats.words.formatted(), "Words")
            Spacer()
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .serif).weight(.semibold))
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
