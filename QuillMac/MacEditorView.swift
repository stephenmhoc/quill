import GhostKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MacEditorView: View {
    @Bindable var entry: Entry

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @AppStorage("showsPreview") private var showsPreview = false

    @State private var selection: TextSelection?
    @State private var focusRequest = 0
    @State private var showingTags = false
    @State private var showingImagePicker = false
    /// The title stays out of the way unless it's turned on, or the entry already has one.
    @State private var showsTitle = false
    @State private var focusTitle = false
    @State private var uploading = false
    @State private var uploadError: String?
    @State private var pendingPublicImages: [Data] = []
    @State private var saveFailed = false
    @State private var bodyHasFocus = false
    @State private var showsFocusHint = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isEditable: Bool { entry.state == .editing }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !publisher.sending.contains(entry.id)
    }
    private var isPreviewing: Bool { showsPreview && !entry.isBlank && fitsPreview && !navigation.isFocused }
    /// Measured from the window, because an open preview's own minimum would hold this view wide
    /// and push the columns out of it.
    private var fitsPreview: Bool {
        let columns: CGFloat = switch navigation.columnVisibility {
        case .detailOnly: 0
        case .doubleColumn: 320
        default: 550
        }
        return navigation.windowWidth - columns >= 280 + 240
    }

    var body: some View {
        HSplitView {
            page.frame(minWidth: 280, maxWidth: .infinity)
            if isPreviewing {
                LivePreview(title: entry.title, markdown: entry.body, site: site)
                    .frame(minWidth: 240, maxWidth: .infinity)
            }
        }
        .background(Color.paper)
        .overlay(alignment: .bottom) {
            if showsFocusHint {
                Text("Press Esc to leave Focus Mode")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .task(id: navigation.isFocused) {
            withAnimation { showsFocusHint = navigation.isFocused }
            guard navigation.isFocused else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { withAnimation { showsFocusHint = false } }
        }
        .navigationTitle(entry.isBlank ? "New Entry" : entry.displayTitle)
        .toolbar(navigation.isFocused ? .hidden : .automatic, for: .windowToolbar)
        .toolbar { toolbar }
        .focusedSceneValue(\.editorActions, actions)
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            receive(urls.compactMap { url in
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        .confirmationDialog("Upload image to \(site?.name ?? "")?", isPresented: Binding(
            get: { !pendingPublicImages.isEmpty }, set: { if !$0 { pendingPublicImages = [] } }
        ), titleVisibility: .visible) {
            Button("Upload to public site") {
                let images = pendingPublicImages
                pendingPublicImages = []
                Task { await insert(images) }
            }
        } message: {
            Text("The image goes to \(site?.host ?? "the site") now, before you publish, and this entry stays on that site.")
        }
        .alert("Image upload failed", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
            Button("OK") { uploadError = nil }
        } message: { Text(uploadError ?? "") }
        // Throttled: updatedAt re-sorts every list on screen.
        .onChange(of: entry.title) { touchIfStale() }
        .onChange(of: entry.body) { touchIfStale() }
        // Saved as you type, so there's nothing to do to keep a draft.
        .task(id: "\(entry.title)\(entry.body)") {
            try? await Task.sleep(for: .seconds(1))
            await saveUntilItWorks()
        }
        .onAppear {
            showsTitle = !entry.title.isEmpty
            if isEditable && entry.isBlank && navigation.focusNextEntry { focusRequest += 1 }
            navigation.focusNextEntry = false
        }
    }

    private var page: some View {
        MacTextEditor(text: $entry.body, selection: $selection, focusRequest: focusRequest, isEditable: isEditable,
                      isCentered: navigation.isFocused, onImages: receive, onFocus: { bodyHasFocus = $0 }) {
            // Hosted inside AppKit, so the environment has to be passed along.
            EditorHeader(entry: entry, site: site, isEditable: isEditable, showsTitle: showsTitle,
                         focusesTitle: focusTitle, onTags: { showingTags = true }, onSubmit: { focusRequest += 1 },
                         onEdit: {
                             selection = TextSelection(insertionPoint: entry.body.endIndex)
                             focusRequest += 1
                         })
                .environment(navigation)
                .environment(publisher)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !navigation.isFocused || saveFailed { statusBar }
        }
        .background(Color.paper)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if saveFailed {
                Label("Couldn't save to this Mac. Keep this page open and free up some space.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if uploading { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(wordCount.formatted()) \(wordCount == 1 ? "word" : "words")")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var wordCount: Int { entry.body.split(whereSeparator: \.isWhitespace).count }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Automatic, not navigation: that puts it beside the sidebar, over another column.
        ToolbarItem(placement: .automatic) {
            MacSitePicker(entry: entry, sites: sites, locked: entry.remotePostID != nil || entry.uploadedToSiteID != nil || uploading || !isEditable)
        }
        // The pill is its own background: the toolbar's would ring it in grey.
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .automatic) {
            Button { showingTags = true } label: { Label("Tags", systemImage: "tag") }
                .help("Tags")
                .disabled(!isEditable)
                .popover(isPresented: $showingTags, arrowEdge: .bottom) { MacTagEditor(entry: entry, site: site) }
            Toggle(isOn: Binding(get: { showsPreview }, set: { showsPreview = $0 })) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(fitsPreview ? "Show the rendered Markdown beside the text" : "Make the window wider to show the preview")
            .disabled(entry.isBlank || !fitsPreview)
            Button { navigation.toggleFocus() } label: { Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Focus Mode (⇧⌘F)")
        }
        if isEditable {
            ToolbarItem(placement: .automatic) {
                Button(action: send) {
                    if publisher.sending.contains(entry.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(sendLabel).padding(.horizontal, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSend)
                .accessibilityIdentifier("sendButton")
            }
        }
    }

    private var actions: EditorActions {
        EditorActions(canPublish: canSend, canPreview: !entry.isBlank,
                      canShowPreview: !entry.isBlank && fitsPreview, canEdit: isEditable,
                      canFormat: isEditable && bodyHasFocus, hasTitle: showsTitle, isPreviewing: isPreviewing,
                      publishLabel: sendLabel, publish: send, format: apply, togglePreview: { showsPreview.toggle() },
                      print: { EntryPrinter.print(title: entry.title, markdown: entry.body, site: site) },
                      toggleTitle: toggleTitle, chooseImage: { showingImagePicker = true })
    }

    private var sendLabel: String {
        let kind = site?.kind ?? .ghost
        if entry.remotePostID != nil, entry.remoteStatus != .draft { return kind.updateLabel }
        return kind.publishLabel
    }

    // MARK: Actions

    private func saveUntilItWorks() async {
        while !Task.isCancelled {
            do {
                try context.save()
                saveFailed = false
                return
            } catch {
                saveFailed = true
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func touchIfStale() {
        if Date.now.timeIntervalSince(entry.updatedAt) > 30 { entry.touch() }
    }

    private func toggleTitle() {
        guard isEditable else { return }
        showsTitle.toggle()
        focusTitle = showsTitle
        if showsTitle {
            entry.title = entry.hiddenTitle ?? ""
            entry.hiddenTitle = nil
        } else {
            entry.hiddenTitle = entry.title
            entry.title = ""
        }
    }

    private func send() {
        guard canSend else { return }
        let sent = entry
        let isNew = sent.remotePostID == nil
        sent.publishStatus = .published
        Task {
            await publisher.publish(sent)
            // A new entry is done, so start a fresh page. An update stays on the entry.
            if isNew, sent.state == .sent, navigation.selectedEntry == sent {
                navigation.openBlankEntry(in: context)
            }
        }
    }

    private func apply(_ format: MarkdownFormat) {
        guard isEditable else { return }
        let (text, newSelection) = format.apply(to: entry.body, selection: selection)
        entry.body = text
        selection = newSelection
        focusRequest += 1
    }

    /// Pasted, dropped or chosen. A public site asks first, because an upload can't wait for Publish.
    private func receive(_ images: [Data]) {
        guard isEditable, site != nil, !uploading else { return }
        guard !images.isEmpty else {
            uploadError = "Couldn't read that image."
            return
        }
        if site?.isPublic == true { pendingPublicImages = images } else { Task { await insert(images) } }
    }

    private func insert(_ images: [Data]) async {
        guard let site else { return }
        uploading = true
        defer { uploading = false }
        do {
            for image in images {
                guard let jpeg = ImagePrep.jpeg(from: image) else {
                    uploadError = "Couldn't read that image."
                    return
                }
                let url = try await publisher.backend(for: site)
                    .uploadImage(jpeg, filename: "quill-\(UUID().uuidString).jpg")
                // Leaving an edit cancels it, and the picture goes with it.
                guard entry.modelContext != nil, !entry.isDeleted, entry.state == .editing else { return }
                entry.uploadedToSiteID = site.id
                let (text, newSelection) = MarkdownFormat.insert("\n![](\(url.absoluteString))\n", into: entry.body, at: selection)
                entry.body = text
                selection = newSelection
            }
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

/// Follows the text a moment behind, so typing never waits on a page load.
private struct LivePreview: View {
    let title: String
    let markdown: String
    let site: Site?
    @Environment(\.colorScheme) private var colorScheme
    @State private var html: String?

    private var source: String {
        EntryPage.html(title: title, markdown: markdown, isDark: colorScheme == .dark, imageHosts: EntryPage.imageHosts(of: site))
    }

    var body: some View {
        PreviewPage(html: html ?? source)
            .task(id: source) {
                try? await Task.sleep(for: .seconds(0.25))
                if !Task.isCancelled { html = source }
            }
    }
}

/// Tags in a popover: added by typing, removed by clicking, with the site's own as suggestions.
private struct MacTagEditor: View {
    @Bindable var entry: Entry
    let site: Site?

    @Environment(Publisher.self) private var publisher
    @State private var input = ""
    @State private var suggestions: [String] = []

    private var visibleTags: [String] { entry.tags.filter { !$0.hasPrefix("#") } }
    private var matches: [String] {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions.filter { s in
            !entry.tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                && (q.isEmpty || s.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Add a tag", text: $input)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(addInput)
            ForEach(visibleTags, id: \.self) { tag in
                HStack {
                    Text(tag)
                    Spacer()
                    Button { entry.tags.removeAll { $0 == tag } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(tag)")
                }
            }
            if !matches.isEmpty {
                Divider()
                Text("On \(site?.name ?? "this site")").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(matches.prefix(30), id: \.self) { tag in
                            Button(tag) { add(tag) }.buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(12)
        .frame(width: 240)
        .task { await loadSuggestions() }
        .onDisappear(perform: addInput)
    }

    private func addInput() {
        for part in input.split(separator: ",") { add(String(part)) }
        input = ""
    }

    private func add(_ tag: String) {
        entry.tags = EntryBuilder.normalizedTags(entry.tags + [tag])
    }

    private func loadSuggestions() async {
        guard let site, let backend = try? publisher.backend(for: site) else { return }
        suggestions = (try? await backend.tags()) ?? []
    }
}
