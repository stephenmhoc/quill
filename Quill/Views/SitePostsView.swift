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
    @State private var pendingDelete: SitePost?
    @State private var filter: SiteTag?
    /// Each tag's posts from this visit, so going back to one doesn't wait for the site.
    @State private var tagged: [SiteTag: [SitePost]] = [:]
    #if os(macOS)
    @State private var selectedPost: String?
    @Environment(\.listQuery) private var query
    @Environment(\.isCovered) private var isCovered
    @Environment(\.hidesTitle) private var hidesTitle
    @State private var opening: String?
    /// Which open is the latest, because a Mac can select another row while one is loading.
    @State private var openRequest = 0
    @State private var unsupported: SitePost?
    #else
    @Environment(AppLock.self) private var lock
    #endif

    private var site: Site? { sites.first { $0.id == siteID } }

    /// What the list shows: on a Mac, narrowed by the search field.
    private var shown: [SitePost] {
        #if os(macOS)
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? posts : posts.filter { $0.title.localizedStandardContains(q) }
        #else
        posts
        #endif
    }

    var body: some View {
        posted
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) { statsFooter }
            #endif
            .overlay {
                if loading && posts.isEmpty { ProgressView() }
                else if posts.isEmpty && error == nil && !loading {
                    if let filter {
                        ContentUnavailableView("No posts tagged #\(filter.name)", systemImage: "tag")
                    } else {
                        ContentUnavailableView("No posts yet", systemImage: "doc.richtext")
                    }
                }
            }
            #if os(iOS)
            .newEntryButton(site: siteID, tint: site?.color.color ?? .accentColor, isShown: !usesColumns)
            #endif
            .paperList()
            #if os(macOS)
            .navigationTitle(isCovered ? "Quill" : hidesTitle ? "" : site?.name ?? "Site")
            #else
            .navigationTitle(site?.name ?? "Site")
            #endif
            .largeTitle()
            .toolbar {
                #if os(macOS)
                if let tags = site?.cachedTagList, !tags.isEmpty {
                    ToolbarItem(placement: .primaryAction) { TagFilterMenu(tags: tags, selection: $filter) }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = true } label: { Label("Edit Site", systemImage: "slider.horizontal.3") }
                        #if os(macOS)
                        .help("Edit Site")
                        #endif
                }
            }
            .sheet(isPresented: $editing) {
                if let site { EditSiteView(site: site) }
            }
            #if os(macOS)
            // Nothing stays open over the lock screen.
            .onChange(of: isCovered) { _, covered in
                guard covered else { return }
                editing = false
                pendingDelete = nil
                unsupported = nil
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
            #else
            // Loading while locked fails without the key, so try again once there is one.
            .onChange(of: lock.isUnlocked) { _, unlocked in if unlocked { Task { await load() } } }
            #endif
            // Unstructured: SwiftUI cancels view tasks during column transitions and list refreshes.
            .refreshable { await Task { await load() }.value }
            .onAppear { if posts.isEmpty, let site { posts = site.cachedPostList } }
            .task { await Task { await load() }.value }
            .onChange(of: publisher.sentCount) { Task { await load() } }
            .onChange(of: navigation.reloadRequest) { Task { await load() } }
            .onChange(of: filter) { showKnownPosts(); Task { await load() } }
    }

    @ViewBuilder private var posted: some View {
        #if os(macOS)
        List(selection: $selectedPost) { rows }
            .onDeleteCommand {
                if let post = posts.first(where: { $0.id == selectedPost }) { pendingDelete = post }
            }
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
        // Selection lets a keyboard and pointer move through the posts. On iPhone a row pushes.
        if usesColumns {
            List(selection: Binding(get: { selectedPostID }, set: { id in
                if let post = posts.first(where: { $0.id == id }) { openNow(post) }
            })) { rows }
        } else {
            List { rows }
        }
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
            // A Mac filters from the toolbar instead.
            if let tags = site?.cachedTagList, !tags.isEmpty {
                TagFilterBar(tags: tags, selection: $filter, tint: site?.color.color ?? .accentColor)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            #endif
            Section {
                ForEach(shown) { post in
                    postRow(post)
                        .swipeActions(edge: .trailing) {
                            #if os(iOS)
                            // Not a destructive role, which takes the row away before the question is answered.
                            Button("Delete", systemImage: "trash") { pendingDelete = post }
                                .tint(.red)
                            #else
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = post }
                            #endif
                        }
                        .contextMenu {
                            #if os(macOS)
                            Button("Edit", systemImage: "pencil") { Task { await open(post, edit: true) } }
                            if let url = post.url {
                                Button("Open in Browser", systemImage: "safari") { openURL(url) }
                                Button("Copy Link", systemImage: "link") { copyLink(url) }
                            }
                            if let entry = localEntry(for: post) {
                                Button("Export as Markdown…", systemImage: "square.and.arrow.up") { MarkdownFile.export([entry]) }
                            }
                            Divider()
                            Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = post }
                            #else
                            if let url = post.url {
                                Button("Open in Browser", systemImage: "safari") { openURL(url) }
                                ShareLink(item: url)
                                Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = post }
                            #endif
                        }
                        #if os(iOS)
                        // On the row, so on iPad it points at what it would delete.
                        .confirmationDialog("Delete “\(post.title)”?",
                                            isPresented: Binding(get: { pendingDelete?.id == post.id }, set: { if !$0 { pendingDelete = nil } }),
                                            titleVisibility: .visible) {
                            Button("Delete from \(site?.name ?? "site")", role: .destructive) { Task { await delete(post) } }
                        } message: {
                            Text("This permanently deletes the post. It can't be undone.")
                        }
                        #endif
                }
            } header: {
                #if os(iOS)
                if let site {
                    Label(site.accessLabel, systemImage: site.accessIcon)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            if hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task(id: page) { await Task { await loadMore() }.value }
            }
    }

    #if os(macOS)
    /// Who can read it and the totals are a footnote on a Mac, where the list is what you came for.
    @ViewBuilder private var statsFooter: some View {
        if let site {
            HStack {
                Label(site.accessLabel, systemImage: site.accessIcon)
                Spacer()
                if let stats = site.stats {
                    Text("\(stats.posts.formatted()) \(stats.posts == 1 ? "post" : "posts") · \(stats.words.formatted()) \(stats.words == 1 ? "word" : "words")")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
    #endif

    #if os(macOS)
    private func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    #endif

    /// A Mac selects a row; iOS taps a button.
    @ViewBuilder private func postRow(_ post: SitePost) -> some View {
        #if os(macOS)
        if let entry = localEntry(for: post) {
            row(post).tag(post.id).draggable(MarkdownFile(entry: entry))
        } else {
            row(post).tag(post.id)
        }
        #else
        Group {
            if usesColumns {
                row(post).tag(post.id)
            } else {
                Button { openNow(post) } label: { row(post) }
                    .buttonStyle(.plain)
            }
        }
        .cardRow(isSelected: usesColumns && selectedPostID == post.id)
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
                if isOpening(post) { ProgressView().controlSize(.mini) }
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

    private func isOpening(_ post: SitePost) -> Bool {
        #if os(macOS)
        opening == post.id
        #else
        navigation.openingPost.map { $0.post.id == post.id && $0.siteID == siteID && $0.failure == nil && !$0.isUnsupported } == true
        #endif
    }

    #if os(iOS)
    /// The post that's open beside the list, or on its way.
    private var selectedPostID: String? {
        if let opening = navigation.openingPost, opening.siteID == siteID { return opening.post.id }
        guard let entry = navigation.selectedEntry, entry.siteID == siteID else { return nil }
        return entry.remotePostID
    }

    /// The page opens at once and fills in when the post arrives.
    private func openNow(_ post: SitePost) {
        guard let site else { return }
        navigation.open(post, on: site, publisher: publisher)
    }
    #endif

    private func localEntry(for post: SitePost) -> Entry? {
        entries.first { $0.remotePostID == post.id && $0.siteID == siteID }
    }

    #if os(macOS)
    private func open(_ post: SitePost, edit: Bool = false) async {
        guard let site else { return }
        openRequest += 1
        let request = openRequest
        opening = post.id
        defer { if request == openRequest { opening = nil } }
        let (shownEntry, shownPath) = (navigation.selectedEntry, navigation.path)
        do {
            let entry = try await publisher.entry(for: post, on: site)
            // Someone who moved on while this loaded stays where they went.
            guard request == openRequest, navigation.selectedEntry == shownEntry, navigation.path == shownPath else { return }
            guard let entry else {
                unsupported = post
                return
            }
            navigation.show(entry)
            if edit, entry.state == .sent { entry.beginEdit() }
        } catch {
            self.error = error.localizedDescription
        }
    }
    #endif

    private func delete(_ post: SitePost) async {
        guard let site else { return }
        localEntry(for: post)?.cancelEdit()
        if let entry = localEntry(for: post) { navigation.forget(entry) }
        do {
            try await publisher.deletePost(id: post.id, site: site)
            posts.removeAll { $0.id == post.id }
            tagged = [:]
            if filter == nil { publisher.remember(posts, on: site) }
            error = nil
        } catch {
            self.error = error.localizedDescription
            Telemetry.report(error, while: "delete post")
        }
    }

    /// A site can take a while to reach, so a filter shows what's already here at once and `load`
    /// completes it.
    private func showKnownPosts() {
        let whole = site?.cachedPostList ?? []
        if let filter {
            posts = tagged[filter] ?? whole.filter { $0.tags?.contains(filter.id) == true }
        } else {
            posts = whole
        }
        page = 1
        hasMore = false
        loading = true
    }

    private func load() async {
        guard let site else { return }
        let tag = filter
        loading = true
        // A newer filter's load is still going, and its list is still to come.
        defer { if tag == filter { loading = false } }
        do {
            // Only the whole list is kept for next time.
            let first = if let tag {
                try await publisher.backend(for: site).posts(limit: SitePost.pageSize, page: 1, tag: tag)
            } else {
                try await publisher.loadPosts(of: site)
            }
            if let tag { tagged[tag] = first }
            guard tag == filter else { return }
            posts = first
            page = 1
            hasMore = first.count == SitePost.pageSize
            error = nil
            // The site can be removed while its posts load, or while its tags do.
            guard tag == nil, site.isLive else { return }
            Task(priority: .utility) {
                await publisher.refreshTags(of: site)
                guard site.isLive else { return }
                await publisher.refreshStats(of: site)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let site else { return }
        let tag = filter
        do {
            let next = try await publisher.backend(for: site).posts(limit: SitePost.pageSize, page: page + 1, tag: tag)
            guard tag == filter else { return }
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

#if os(macOS)
/// The site's tags as a toolbar pop-up, the Mac's way to narrow a list.
private struct TagFilterMenu: View {
    let tags: [SiteTag]
    @Binding var selection: SiteTag?

    var body: some View {
        Menu {
            Picker("Filter by Tag", selection: $selection) {
                Text("All Posts").tag(SiteTag?.none)
                Divider()
                ForEach(tags) { tag in Text(verbatim: "#\(tag.name)").tag(Optional(tag)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter by Tag", systemImage: selection == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(selection.map { "Showing posts tagged #\($0.name)" } ?? "Filter by Tag")
    }
}
#endif

/// Small tags above the posts, which scroll away with them. One narrows the list, and pressing it
/// again brings everything back.
private struct TagFilterBar: View {
    let tags: [SiteTag]
    @Binding var selection: SiteTag?
    let tint: Color
    @Environment(\.usesColumns) private var usesColumns

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    let isSelected = tag == selection
                    Button { selection = isSelected ? nil : tag } label: {
                        Text(verbatim: "#\(tag.name)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? tint.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                            .foregroundStyle(isSelected ? tint : .secondary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter by \(tag.name)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            // In line with the text of the posts below.
            #if os(macOS)
            .padding(.horizontal, 6)
            #else
            .padding(.horizontal, usesColumns ? 8 : 20)
            #endif
        }
        .scrollIndicators(.hidden)
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
