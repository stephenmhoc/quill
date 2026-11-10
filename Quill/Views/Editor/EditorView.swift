import GhostKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Bindable var entry: Entry

    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.usesColumns) private var usesColumns
    @Query(sort: Site.order) private var sites: [Site]

    @State private var selection: TextSelection?
    @State private var showingTags = false
    @State private var showingPreview = false
    @State private var choosingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?
    /// Pictures waiting for a yes before they go to a public site.
    @State private var pendingPublicImages: [ImageLoad] = []
    @State private var bodyFocused = false
    @State private var focusRequest = 0
    /// The title stays out of the way unless it's turned on, or the entry already has one.
    @State private var showsTitle = false
    @State private var focusTitle = false
    /// The focus mode button fades while words are arriving and comes back in a pause.
    @State private var isTyping = false
    @State private var saveFailed = false
    /// The keyboard goes while Quill is locked, and comes back with it.
    @State private var refocusAfterUnlock = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isFocused: Bool { navigation.isFocused }
    private var isEditable: Bool { entry.state == .editing }
    private var isSending: Bool { publisher.sending.contains(entry.id) }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !isSending
    }
    private var viewURL: URL? { entry.remoteStatus == .draft ? nil : entry.remoteURL }

    var body: some View {
        EditorTextView(text: $entry.body, selection: $selection, isFocused: $bodyFocused,
                       focusRequest: focusRequest, isEditable: isEditable,
                       margin: usesColumns ? 48 : 20, reuseID: entry.id, reuse: navigation.editorReuse,
                       formatting: isFocused ? nil : formatting,
                       onImages: { providers in offerImages(providers.map { provider in { try await provider.loadImageData() } }) },
                       onEscape: isFocused ? { navigation.toggleFocus() } : nil) {
            // Hosted inside UIKit, so the environment has to be passed along.
            EditorHeader(entry: entry, site: site, isEditable: isEditable, showsTitle: showsTitle,
                         focusesTitle: focusTitle, onTags: { showingTags = true }, onSubmit: { focusRequest += 1 })
                .environment(navigation)
                .environment(publisher)
        }
        .background(Color.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if saveFailed {
                    Label("Couldn't save to this device. Keep this page open and free up some space.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, usesColumns ? 48 : 16)
                        .padding(.vertical, 8)
                        .background(Color.paper)
                }
                // Calm news only, and never over the keyboard: writing keeps all the room.
                if !isFocused && !bodyFocused { statusBar.tint(.secondary) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isFocused {
                focusButton
                    .opacity(isTyping ? 0.15 : 0.6)
                    .animation(.easeInOut(duration: 0.2), value: isTyping)
                    .padding(8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFocused ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(isFocused)
        .persistentSystemOverlays(isFocused ? .hidden : .automatic)
        .toolbar { toolbar }
        .focusedSceneValue(\.editorActions, actions)
        .sheet(isPresented: $showingTags) { TagEditor(entry: entry, site: site) }
        .modifier(PreviewPresentation(isPresented: $showingPreview, asInspector: usesColumns, entry: entry, site: site))
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .confirmationDialog("Upload image to \(site?.name ?? "")?", isPresented: Binding(
            get: { !pendingPublicImages.isEmpty }, set: { if !$0 { pendingPublicImages = [] } }
        ), titleVisibility: .visible) {
            Button("Upload to Public Site") {
                let images = pendingPublicImages
                Task { await insertImages(images) }
                pendingPublicImages = []
            }
        } message: {
            Text("The image goes to \(site?.host ?? "the site") now, before you publish, and this entry stays on that site.")
        }
        .alert("Image upload failed", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
            Button("OK") { uploadError = nil }
        } message: { Text(uploadError ?? "") }
        // A tap when it lands or doesn't, since the page may have moved on.
        .sensoryFeedback(trigger: entry.stateRaw) { old, new in
            guard old == Entry.State.sending.rawValue else { return nil }
            switch Entry.State(rawValue: new) {
            case .sent: return .success
            case .failed: return .error
            default: return nil
            }
        }
        // Throttled: updatedAt re-sorts every list on screen.
        .onChange(of: entry.title) { touchIfStale() }
        .onChange(of: entry.body) {
            touchIfStale()
            if bodyFocused && isFocused { isTyping = true }
        }
        // Saved as you type, so there's nothing to do to keep a draft.
        .task(id: "\(entry.title)\(entry.body)") {
            try? await Task.sleep(for: .seconds(1))
            await saveUntilItWorks()
        }
        .task(id: entry.body) {
            try? await Task.sleep(for: .seconds(0.5))
            if !Task.isCancelled { isTyping = false }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            offerImages([{ try await item.loadTransferable(type: Data.self) }])
        }
        .onAppear {
            showsTitle = !entry.title.isEmpty
            if isEditable && entry.isBlank && navigation.focusNextEntry { focusRequest += 1 }
            navigation.focusNextEntry = false
        }
        // The autosave above waits for a pause, and leaving the page cancels it.
        .onDisappear { saveNow() }
        .onChange(of: lock.isUnlocked) { _, unlocked in
            if !unlocked {
                refocusAfterUnlock = bodyFocused
                saveNow()
            } else if refocusAfterUnlock {
                refocusAfterUnlock = false
                focusRequest += 1
            }
        }
    }

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

    private func saveNow() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Telemetry.report(error, while: "save")
        }
    }

    private func touchIfStale() {
        if Date.now.timeIntervalSince(entry.updatedAt) > 30 { entry.touch() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SitePicker(entry: entry, sites: sites, locked: entry.remotePostID != nil || entry.uploadedToSiteID != nil || uploading || !isEditable)
        }
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
        // The main action, top right like Mail's Send. Edit takes its place once it's sent.
        ToolbarItem(placement: .topBarTrailing) { primaryAction }
    }

    @ViewBuilder private var primaryAction: some View {
        if isEditable {
            Button(action: send) {
                if isSending { ProgressView() } else { Text(sendLabel).fontWeight(.semibold) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .accessibilityIdentifier("sendButton")
        } else if entry.state == .sent {
            Button("Edit", action: beginEditing)
        }
    }

    private var moreMenu: some View {
        Menu {
            if isEditable {
                Button { showingTags = true } label: {
                    Label(entry.tags.isEmpty ? "Tags" : "Tags (\(entry.tags.count))", systemImage: "tag")
                }
                Toggle(isOn: Binding(get: { showsTitle }, set: { if $0 != showsTitle { toggleTitle() } })) {
                    Label("Title", systemImage: "textformat")
                }
                Button { choosingPhoto = true } label: { Label("Insert Image", systemImage: "photo") }
                    .disabled(site == nil || uploading)
            }
            Button { showingPreview.toggle() } label: {
                Label(showingPreview ? "Hide Preview" : "Preview", systemImage: "eye")
            }
            .disabled(entry.isBlank)
            .accessibilityIdentifier("previewButton")
            Button { navigation.toggleFocus() } label: {
                Label("Focus Mode", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if let url = viewURL {
                Divider()
                Button { openURL(url) } label: { Label("View on Site", systemImage: "safari") }
                ShareLink(item: url)
            }
            if entry.hasUnpublishedChanges {
                Divider()
                Button(role: .destructive, action: discardChanges) {
                    Label("Discard Changes", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private var focusButton: some View {
        Button { navigation.toggleFocus() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(.primary)
                .padding(12)
                .contentShape(Rectangle())
        }
        .hoverEffect()
        .accessibilityLabel("Leave Focus Mode")
    }

    /// For the menu bar and the shortcuts a keyboard shows.
    private var actions: EditorActions {
        EditorActions(canPublish: canSend, publishLabel: sendLabel, publish: send,
                      canBeginEditing: entry.state == .sent, beginEditing: beginEditing,
                      canDiscard: entry.hasUnpublishedChanges, discardChanges: discardChanges,
                      viewURL: viewURL, viewOnSite: { if let viewURL { openURL(viewURL) } },
                      canFormat: isEditable, format: apply,
                      hasTitle: showsTitle, toggleTitle: toggleTitle,
                      canInsertImage: isEditable && site != nil && !uploading, insertImage: { choosingPhoto = true },
                      canPreview: !entry.isBlank, isPreviewing: showingPreview, togglePreview: { showingPreview.toggle() })
    }

    private var formatting: PageFormatting {
        PageFormatting(format: apply, insertImage: { choosingPhoto = true }, canInsertImage: site != nil && !uploading)
    }

    // MARK: Status bar

    /// Where the entry stands, down here so the page above is only the writing. Problems that need
    /// a decision stay above the text, in `StatusBanner`.
    @ViewBuilder private var statusBar: some View {
        switch entry.state {
        case .editing where entry.hasUnpublishedChanges:
            statusRow {
                StatusNote(text: "Changes wait in Drafts until you \(sendLabel.lowercased()).", icon: "pencil", color: .secondary)
                Spacer()
                Button("Discard", action: discardChanges)
            }
        case .sending:
            statusRow { StatusNote(text: "Sending to \(site?.name ?? "the site")…", icon: "arrow.up.circle", color: .secondary) }
        case .sent:
            statusRow {
                StatusNote(text: entry.remoteStatus == .draft ? "Draft" : site?.kind.doneLabel ?? "Published",
                           icon: "checkmark.circle", color: .green)
                Spacer()
                if let url = viewURL {
                    Button("View on Site") { openURL(url) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func statusRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, usesColumns ? 48 : 16)
            .padding(.vertical, 10)
            .background(Color.paper)
    }

    private func discardChanges() {
        hideKeyboard()
        entry.cancelEdit()
    }

    private func beginEditing() {
        entry.beginEdit()
        selection = TextSelection(insertionPoint: entry.body.endIndex)
        focusRequest += 1
    }

    private var sendLabel: String {
        let kind = site?.kind ?? .ghost
        if entry.remotePostID != nil, entry.remoteStatus != .draft { return kind.updateLabel }
        return kind.publishLabel
    }

    private func toggleTitle() {
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
        hideKeyboard()
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

    // MARK: Formatting

    private func apply(_ format: MarkdownFormat) {
        guard isEditable else { return }
        let (text, newSelection) = format.apply(to: entry.body, selection: selection)
        entry.body = text
        selection = newSelection
        focusRequest += 1
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Pictures from the picker, a paste or a drop.
    private func offerImages(_ images: [ImageLoad]) {
        guard !images.isEmpty, isEditable, site != nil, !uploading else { return }
        if site?.isPublic == true { pendingPublicImages = images } else { Task { await insertImages(images) } }
    }

    private func insertImages(_ images: [ImageLoad]) async {
        guard let site else { return }
        uploading = true
        defer { uploading = false }
        for load in images {
            do {
                guard let data = try await load(), let jpeg = ImagePrep.jpeg(from: data) else {
                    uploadError = "Couldn't read that image."
                    continue
                }
                let url = try await publisher.backend(for: site)
                    .uploadImage(jpeg, filename: "quill-\(UUID().uuidString).jpg")
                // Discarding the edit while this uploaded drops the picture with it.
                guard entry.modelContext != nil, !entry.isDeleted, entry.state == .editing else { return }
                entry.uploadedToSiteID = site.id
                let (text, newSelection) = MarkdownFormat.insert("\n![](\(url.absoluteString))\n", into: entry.body, at: selection)
                entry.body = text
                selection = newSelection
            } catch {
                uploadError = error.localizedDescription
                Telemetry.report(error, while: "image upload")
            }
        }
    }
}

/// On iPad the preview sits beside the page and follows the writing. On iPhone it's a sheet.
private struct PreviewPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let asInspector: Bool
    let entry: Entry
    let site: Site?

    func body(content: Content) -> some View {
        if asInspector {
            content.inspector(isPresented: $isPresented) {
                LivePreview(title: entry.title, markdown: entry.body, site: site)
                    .background(Color.paper.ignoresSafeArea())
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 640)
            }
        } else {
            content.sheet(isPresented: $isPresented) { EntryPreview(title: entry.title, markdown: entry.body) }
        }
    }
}

/// Follows the text a moment behind, so typing never waits on a page load. Images load only from
/// the entry's own site, since a pasted link to a tracked image shouldn't call out from a draft.
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
            .opensLinksInChosenBrowser()
            .task(id: source) {
                try? await Task.sleep(for: .seconds(0.25))
                if !Task.isCancelled { html = source }
            }
    }
}

/// Reads one picture's data, wherever it came from.
typealias ImageLoad = () async throws -> Data?

private extension NSItemProvider {
    nonisolated func loadImageData() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: .image) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }
}
