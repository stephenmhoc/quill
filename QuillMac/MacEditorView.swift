import GhostKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MacEditorView: View {
    @Bindable var entry: Entry

    @Environment(Navigation.self) private var navigation
    @Environment(MacWindowState.self) private var window
    @Environment(Publisher.self) private var publisher
    @Environment(AppLock.self) private var lock
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.undoManager) private var undoManager
    @Query(sort: Site.order) private var sites: [Site]
    @AppStorage("showsPreview") private var showsPreview = false
    @AppStorage(MarkdownStyler.textSizeKey) private var textSize = MarkdownStyler.defaultTextSize

    @State private var selection: TextSelection?
    @State private var focusRequest = 0
    @State private var titleFocusRequest = 0
    @State private var command: EditorCommand?
    @State private var showingTags = false
    @State private var showingImagePicker = false
    @State private var showingExporter = false
    /// The title stays out of the way unless it's turned on, or the entry already has one.
    @State private var showsTitle = false
    @State private var focusTitle = false
    @State private var uploading = false
    @State private var uploadError: String?
    @State private var pendingPublicImages: [Data] = []
    @State private var saveFailed = false
    @State private var bodyHasFocus = false
    @State private var confirmingRevert = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isEditable: Bool { entry.state == .editing }
    private var isSending: Bool { publisher.sending.contains(entry.id) }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !isSending
    }
    /// Images already on a site, or a post that's there, keep an entry where it is.
    private var siteIsFixed: Bool { entry.remotePostID != nil || entry.uploadedToSiteID != nil || uploading || !isEditable }
    private var isPreviewing: Bool { showsPreview && !entry.isBlank && fitsPreview && !window.isFocused }
    /// Measured from the columns beside it, because an open preview's own minimum would hold
    /// this view wide and push the columns out of it.
    private var fitsPreview: Bool {
        let columns: CGFloat = switch navigation.columnVisibility {
        case .detailOnly: 0
        case .doubleColumn: window.listWidth
        default: window.sidebarWidth + window.listWidth
        }
        return navigation.windowWidth - columns >= 280 + 240
    }
    /// Only a draft that's never been sent lives nowhere else, so only it can be deleted here.
    private var canDelete: Bool { isEditable && entry.remotePostID == nil && !entry.isBlank }

    var body: some View {
        HSplitView {
            page.frame(minWidth: 280, maxWidth: .infinity)
            if isPreviewing {
                LivePreview(title: entry.title, markdown: entry.body, site: site)
                    .frame(minWidth: 240, maxWidth: .infinity)
            }
        }
        .background(Color.paper)
        // Locked, the window shows nothing of what's behind it, title included.
        // Focus Mode shows the page and nothing about it, title bar included.
        .navigationTitle(!lock.isUnlocked ? "Quill" : window.isFocused ? "" : entry.isBlank ? "New Entry" : entry.displayTitle)
        .navigationSubtitle(lock.isUnlocked && !window.isFocused ? site?.name ?? "" : "")
        // Focus Mode empties the toolbar rather than hiding it, so the window keeps its size.
        .toolbar { if !window.isFocused { toolbar } }
        .focusedSceneValue(\.editorActions, actions)
        .onChange(of: lock.isUnlocked) { _, isUnlocked in
            guard !isUnlocked else { return }
            showingTags = false
            showingImagePicker = false
            showingExporter = false
            pendingPublicImages = []
            uploadError = nil
            confirmingRevert = false
        }
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
            Button("Upload") {
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
        .alert("Revert to the published version?", isPresented: $confirmingRevert) {
            Button("Revert") { revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes since it was published are removed. You can undo this with Edit > Undo.")
        }
        // Throttled: updatedAt re-sorts every list on screen.
        .onChange(of: entry.title) { touchIfStale() }
        .onChange(of: entry.body) {
            touchIfStale()
            // Writing in Focus Mode puts the bars away again.
            if window.isFocused { window.hideFocusChrome() }
        }
        // Saved as you type, so there's nothing to do to keep a draft.
        .task(id: "\(entry.title)\(entry.body)") {
            try? await Task.sleep(for: .seconds(1))
            await saveUntilItWorks()
        }
        .onAppear {
            showsTitle = !entry.title.isEmpty
            if isEditable && navigation.focusNextEntry { focusRequest += 1 }
            navigation.focusNextEntry = false
        }
        // Switching entries or closing the window inside the second the save waits for.
        .onDisappear { try? context.save() }
    }

    private var page: some View {
        MacTextEditor(text: $entry.body, selection: $selection, focusRequest: focusRequest, isEditable: isEditable,
                      isLocked: !lock.isUnlocked, textSize: textSize, command: command, onImages: receive,
                      onFocus: { bodyHasFocus = $0 },
                      onLeaveTop: showsTitle && isEditable ? { titleFocusRequest += 1 } : nil,
                      onEscape: leaveFocus,
                      onSave: save, stage: window.focusStage) {
            // Hosted inside AppKit, so the environment has to be passed along.
            EditorHeader(entry: entry, site: site, isEditable: isEditable, showsTitle: showsTitle,
                         focusesTitle: focusTitle, onTags: { showingTags = true }, onSubmit: { focusRequest += 1 },
                         titleFocusRequest: titleFocusRequest, onEscape: leaveFocus)
                .environment(navigation)
                .environment(publisher)
                // Behind the lock, the title and the banner's buttons take nothing either.
                .disabled(!lock.isUnlocked)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !window.isFocused || saveFailed { statusBar }
        }
        .background(Color.paper)
    }

    /// Esc on the page or in the title. True if it was used.
    private func leaveFocus() -> Bool {
        guard window.isFocused else { return false }
        window.exitFocus()
        return true
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if saveFailed {
                Label("Couldn't save to this Mac. Keep this page open and free up some space.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let notice = window.notice, entry.isBlank {
                Label(notice, systemImage: "checkmark.circle")
                    .transition(.opacity)
            } else {
                entryStatus
            }
            if uploading { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(wordCount.formatted()) \(wordCount == 1 ? "word" : "words")")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        // Fixed, or the page would shift when a button comes and goes.
        .frame(height: 26)
        .animation(.default, value: window.notice)
    }

    /// Where the entry stands, down here so the page above is only the writing. Problems that need
    /// a decision stay above the text, in `StatusBanner`.
    @ViewBuilder private var entryStatus: some View {
        switch entry.state {
        case .editing where entry.remotePostID != nil:
            Text("Editing")
                .help("Keeps until you publish or revert it.")
            statusButton("Revert to Published…", icon: "arrow.uturn.backward") { confirmingRevert = true }
        case .sending:
            Text("Sending to \(site?.name ?? "the site")…")
        case .sent:
            Text(sentLabel)
            if viewURL != nil {
                statusButton("View on Site", icon: "arrow.up.right", action: viewOnSite)
            }
        default:
            EmptyView()
        }
    }

    private func statusButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.primary)
    }

    private var sentLabel: String {
        entry.remoteStatus == .draft ? "Draft" : site?.kind.doneLabel ?? "Published"
    }

    private var viewURL: URL? { entry.remoteStatus == .draft ? nil : entry.remoteURL }

    private var wordCount: Int { entry.body.split(whereSeparator: \.isWhitespace).count }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Automatic, not navigation: that puts it beside the sidebar, over another column.
        ToolbarItem(placement: .automatic) {
            MacSitePicker(entry: entry, sites: sites, locked: siteIsFixed)
        }
        // The pill is its own background: the toolbar's would ring it in grey.
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .automatic) {
            Button { showingTags = true } label: { Label("Tags", systemImage: "tag") }
                .help("Tags (⌥⌘T)")
                .disabled(!isEditable)
                .popover(isPresented: $showingTags, arrowEdge: .bottom) { MacTagEditor(entry: entry, site: site) }
            Toggle(isOn: Binding(get: { isPreviewing }, set: { showsPreview = $0 })) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(fitsPreview ? "Show the rendered Markdown beside the text (⌥⌘P)" : "Make the window wider to show the preview")
            .disabled(entry.isBlank || !fitsPreview)
            Button { window.toggleFocus() } label: { Label("Focus", systemImage: "rectangle.center.inset.filled") }
                .help("Enter Focus Mode (⇧⌘F)")
        }
        // Edit takes Publish's place, so the window's main action never moves.
        if entry.state == .sent {
            ToolbarItem(placement: .automatic) {
                // A real button like Publish, softened so that Publish stays the loud one.
                Button(action: beginEditing) { Label("Edit", systemImage: "pencil").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent)
                    .tint((site?.color.color ?? .gray).opacity(0.7))
                    .help("Edit This Entry (⌘↩)")
            }
        }
        if isEditable {
            ToolbarItem(placement: .automatic) {
                Button(action: send) {
                    // The label keeps its width under the spinner, so nothing beside it moves.
                    Text(sendLabel)
                        .padding(.horizontal, 6)
                        .opacity(isSending ? 0 : 1)
                        .overlay { if isSending { ProgressView().controlSize(.small) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help("\(sendLabel) to \(site?.name ?? "the site") (⌘↩)")
                .accessibilityIdentifier("sendButton")
            }
        }
    }

    private var actions: EditorActions {
        EditorActions(canPublish: canSend && lock.isUnlocked, canPreview: !entry.isBlank,
                      canShowPreview: !entry.isBlank && fitsPreview && !window.isFocused, canEdit: isEditable,
                      canFormat: isEditable && bodyHasFocus, hasTitle: showsTitle, isPreviewing: isPreviewing,
                      publishLabel: sendLabel, publish: send, format: apply, togglePreview: { showsPreview.toggle() },
                      print: { EntryPrinter.print(title: entry.title, markdown: entry.body, site: site) },
                      toggleTitle: toggleTitle, chooseImage: { showingImagePicker = true },
                      canBeginEditing: entry.state == .sent, canRevert: isEditable && entry.remotePostID != nil,
                      canViewOnSite: viewURL != nil, beginEditing: beginEditing, revert: { confirmingRevert = true },
                      viewOnSite: viewOnSite, showTags: showTags,
                      canMove: !siteIsFixed, siteID: entry.siteID,
                      moveTo: { entry.siteID = $0 }, copyLink: copyLink,
                      export: { MarkdownFile.export([entry]) }, canDelete: canDelete, delete: delete)
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
                if !saveFailed { Telemetry.report(error, while: "save") }
                saveFailed = true
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// ⌘S. Writing saves itself, so only a site whose Publish is a save has more to do.
    private func save() {
        if site?.kind.sendsOnSave == true, canSend { send() } else { try? context.save() }
    }

    private func beginEditing() {
        entry.beginEdit()
        selection = TextSelection(insertionPoint: entry.body.endIndex)
        focusRequest += 1
    }

    private func viewOnSite() {
        if let viewURL { openURL(viewURL) }
    }

    private func copyLink() {
        guard let viewURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewURL.absoluteString, forType: .string)
    }

    /// Back to the published version. Undo brings the edit back, and Redo reverts it again.
    private func revert() {
        EditDiscard.discard([entry], name: "Revert to Published", undoManager: undoManager) { [entry] in
            guard entry.modelContext != nil, !entry.isDeleted else { return }
            showsTitle = !entry.title.isEmpty
        }
    }

    /// The popover hangs from the Tags button, which Focus Mode hides, so that ends first.
    private func showTags() {
        guard window.isFocused else { return showingTags = true }
        window.exitFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingTags = true }
    }

    /// An unsent draft, put back by Undo.
    private func delete() {
        guard canDelete else { return }
        let nav = navigation
        EntryDeletion.delete([entry], in: context, navigation: nav, undoManager: undoManager) { restored in
            if let first = restored.first { nav.show(first) }
        }
        nav.openBlankEntry(in: context)
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
        guard canSend, let site else { return }
        let sent = entry
        let isNew = sent.remotePostID == nil
        let (siteName, done) = (site.name, site.kind.doneLabel)
        sent.publishStatus = .published
        Task {
            await publisher.publish(sent)
            // A new entry is done, so start a fresh page. An update stays on the entry.
            if isNew, sent.modelContext != nil, !sent.isDeleted, sent.state == .sent, navigation.selectedEntry == sent {
                window.announce("\(done) to \(siteName)")
                navigation.openBlankEntry(in: context)
            }
        }
    }

    private func apply(_ format: MarkdownFormat) {
        guard isEditable else { return }
        command = EditorCommand(id: (command?.id ?? 0) + 1, action: .format(format))
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
                // The site can be removed while an earlier picture uploads.
                guard site.isLive else { return }
                guard let jpeg = ImagePrep.jpeg(from: image) else {
                    uploadError = "Couldn't read that image."
                    return
                }
                let url = try await publisher.backend(for: site)
                    .uploadImage(jpeg, filename: "quill-\(UUID().uuidString).jpg")
                // Leaving an edit cancels it, or removing the site, and the picture goes with it.
                guard entry.modelContext != nil, !entry.isDeleted, entry.state == .editing, site.isLive else { return }
                entry.uploadedToSiteID = site.id
                command = EditorCommand(id: (command?.id ?? 0) + 1, action: .insert("\n![](\(url.absoluteString))\n", name: "Insert Image"))
            }
        } catch {
            uploadError = error.localizedDescription
            Telemetry.report(error, while: "image upload")
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
